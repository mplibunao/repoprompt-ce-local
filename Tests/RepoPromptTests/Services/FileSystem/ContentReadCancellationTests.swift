import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContentReadCancellationTests: XCTestCase {
    func testCooperativeChunkReadCancellationSettlesAndReleasesLimiter() async throws {
        let rootURL = try makeTemporaryRoot()
        try "cooperative physical read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: rootURL.path)
        let chunkReadEntered = AsyncSignal()
        let cancellationGate = CancellableTestGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { await cancellationGate.releaseAll() }
        cleanup.addHookReset { await service.setContentReadChunkHandlerForTesting(nil) }
        await service.setContentReadChunkHandlerForTesting { _ in
            await chunkReadEntered.signal()
            _ = try? await cancellationGate.wait()
        }

        await probe.observe {
            let readTask = Task {
                try await service.loadContent(
                    ofRelativePath: "Target.swift",
                    workloadClass: .interactiveRead
                )
            }
            cleanup.retain(readTask, "Cooperative chunk read")
            guard await waitUntil({ await chunkReadEntered.isSignaledSnapshot() }) else {
                return XCTFail("Chunk read did not reach the controlled cancellation gate")
            }
            readTask.cancel()

            guard let readResult = await waitForTaskResult(readTask) else {
                return XCTFail("Cooperative chunk read did not settle after cancellation")
            }
            do {
                _ = try readResult.get()
                XCTFail("Expected cooperative chunk read cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testWatchdogCancellationSettlesBeforeBlockedSynchronousFingerprintIsReleased() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked physical read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: rootURL.path)
        let physicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let events = WatchdogEventRecorder()
        let settlementRecorder = SettlementRecorder()
        let phaseRecorder = MCPToolExecutionHandlerPhaseRecorder(origin: .zero, now: { .zero })
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalReadGate.release() }
        cleanup.addSleeperRelease { await sleeps.releaseAll() }
        cleanup.addHookReset { await service.setContentPhysicalReadHandlerForTesting(nil) }
        await service.setContentPhysicalReadHandlerForTesting {
            physicalReadGate.blockUntilReleased()
        }

        try await probe.observe {
            let watchdogTask = Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        ),
                        onEvent: { event in await events.record(event) },
                        onSynchronousSettlement: { settlement in
                            await settlementRecorder.record(settlement)
                        }
                    ) {
                        try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(phaseRecorder) {
                            await MCPToolExecutionHandlerPhaseContext.report(.readFileContentRead)
                            let fingerprint = try await service.contentFingerprint(ofRelativePath: "Target.swift")
                            _ = try await service.loadValidatedContent(
                                ofRelativePath: "Target.swift",
                                expectedFingerprint: fingerprint,
                                workloadClass: .interactiveRead
                            )
                            await MCPToolExecutionHandlerPhaseContext.report(
                                .readFileContentRead,
                                transition: .completed
                            )
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            cleanup.retain(watchdogTask, "Watchdog-wrapped fingerprint read")

            guard await waitUntil({ physicalReadGate.isBlockedSnapshot() }) else {
                return XCTFail("Fingerprint read did not reach the physical gate")
            }
            guard await waitUntil({ await sleeps.registeredCountSnapshot() >= 1 }) else {
                return XCTFail("Watchdog deadline did not register")
            }
            await sleeps.releaseNext()

            guard let observedWatchdogResult = await waitForTaskResult(watchdogTask) else {
                return XCTFail("Watchdog did not settle within the bounded observation window")
            }
            let watchdogResult = try observedWatchdogResult.get()
            guard case let .failure(error) = watchdogResult,
                  error as? MCPToolExecutionWatchdogError == .executionTimedOut(settlement: .cancellation)
            else {
                return XCTFail("Expected the blocked physical read caller to settle cancellation during grace")
            }
            let recordedEvents = await events.snapshot()
            XCTAssertEqual(
                recordedEvents,
                [
                    .deadlineExpired,
                    .cancellationRequested(origin: .watchdogDeadline),
                    .settledDuringGrace(.cancellation, cancellationRequested: true)
                ]
            )
            XCTAssertEqual(phaseRecorder.snapshot()?.phase, .readFileContentRead)
            XCTAssertEqual(phaseRecorder.snapshot()?.transition, .started)

            let settlementBeforeRelease = await settlementRecorder.snapshot()
            XCTAssertEqual(
                settlementBeforeRelease,
                .cancellation,
                "Detached read must settle before a blocked synchronous filesystem operation is released"
            )
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 1, "Owned work while the fingerprint read is blocked: \(blocked)")
            XCTAssertEqual(blocked.queuedCount, 0)
            XCTAssertEqual(blocked.liveProducerCount, 1)

            physicalReadGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testOuterProviderSettlementReleasesRegistryBeforeBlockedPhysicalReadReturns() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked provider read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let physicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let registry = MCPCodeStructureSettlementRegistry()
        let windowID = 949
        let connectionID = UUID()
        let invocationID = UUID()
        let admission = registry.admit(
            windowID: windowID,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: MCPWindowToolName.readFile,
            now: .zero,
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        guard case let .admitted(settlementSlot) = admission else {
            return XCTFail("Expected settlement-registry admission")
        }

        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalReadGate.release() }
        cleanup.addSleeperRelease { await sleeps.releaseAll() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalReadGate.blockUntilReleased()
        }

        try await probe.observe {
            let watchdogTask = Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runMainActorProviderTask(
                            store: store,
                            record: record,
                            roots: store.rootRefs(scope: .visibleWorkspace)
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            cleanup.retain(watchdogTask, "Watchdog-wrapped outer provider")

            guard await waitUntil({ physicalReadGate.isBlockedSnapshot() }) else {
                return XCTFail("Provider read did not reach the controlled physical gate")
            }
            guard await waitUntil({ await sleeps.registeredCountSnapshot() >= 1 }) else {
                return XCTFail("Watchdog deadline did not register")
            }
            await sleeps.releaseNext()

            guard let observedWatchdogResult = await waitForTaskResult(watchdogTask) else {
                return XCTFail("Outer provider did not settle within the bounded observation window")
            }
            let watchdogResult = try observedWatchdogResult.get()
            guard case let .failure(error) = watchdogResult,
                  error as? MCPToolExecutionWatchdogError == .executionTimedOut(settlement: .cancellation)
            else {
                return XCTFail("Expected the outer provider to settle cancellation during grace")
            }
            XCTAssertEqual(
                registry.snapshot(windowID: windowID),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 1, "Owned work while the provider read is blocked: \(blocked)")

            physicalReadGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testDomainHostAndRunToolCancellationChainSettlesBeforeBlockedPhysicalReadReturns() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked nested provider read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let physicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let registry = MCPCodeStructureSettlementRegistry()
        let admission = registry.admit(
            windowID: 950,
            connectionID: UUID(),
            invocationID: UUID(),
            toolName: MCPWindowToolName.readFile,
            now: .zero,
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        guard case let .admitted(settlementSlot) = admission else {
            return XCTFail("Expected settlement-registry admission")
        }

        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalReadGate.release() }
        cleanup.addSleeperRelease { await sleeps.releaseAll() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalReadGate.blockUntilReleased()
        }

        await probe.observe {
            let watchdogTask = Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runDomainHostProviderTask {
                            try await runDomainReadProviderTask(path: record.standardizedRelativePath) {
                                try await runMainActorProviderTask(
                                    store: store,
                                    record: record,
                                    roots: store.rootRefs(scope: .visibleWorkspace)
                                )
                            }
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            cleanup.retain(watchdogTask, "Watchdog-wrapped nested provider")

            guard await waitUntil({ physicalReadGate.isBlockedSnapshot() }) else {
                return XCTFail("Nested provider did not reach the controlled physical gate")
            }
            guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
                return XCTFail("Watchdog deadline did not register")
            }
            let deadlineSleepReleased = await sleeps.releaseNext()
            XCTAssertTrue(deadlineSleepReleased)

            guard let observedResult = await waitForTaskResult(watchdogTask) else {
                return XCTFail("Nested provider did not settle within cancellation grace")
            }
            guard case let .failure(error) = observedResult.get() else {
                return XCTFail("Expected nested provider timeout")
            }
            XCTAssertEqual(
                error as? MCPToolExecutionWatchdogError,
                .executionTimedOut(settlement: .cancellation)
            )
            XCTAssertEqual(
                registry.snapshot(windowID: 950),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )

            physicalReadGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testConcreteDomainHostAndAppBinderSettleBeforeBlockedPhysicalReadReturns() async throws {
        let rootURL = try makeTemporaryRoot()
        try "blocked concrete host read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let physicalReadGate = SynchronousPhysicalReadGate()
        let runtimeDirectory = rootURL.appendingPathComponent("Runtime", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "content-read-cancellation",
            storageDirectory: runtimeDirectory,
            eventDirectory: rootURL.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: rootURL.appendingPathComponent("Temporary", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }

        let path = record.standardizedRelativePath
        let connectionID = UUID()
        let readContext = DomainReadInvocationContext(
            handle: DomainReadContextHandle(
                runtimeID: runtime.identity.runtimeID,
                runtimeGeneration: runtime.identity.lifecycleGeneration,
                connectionID: connectionID,
                connectionGeneration: 1,
                context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
                workspaceRevision: 1,
                contextRevision: 1,
                routingRevision: 1,
                bindingKind: .explicit
            ),
            connectionID: connectionID,
            refreshesDomainRouting: false
        )
        let rawProvider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in readContext },
            backend: MCPDomainReadToolBackend { _, _, _, _ in
                try await runMainActorProviderTask(
                    store: store,
                    record: record,
                    roots: store.rootRefs(scope: .visibleWorkspace)
                )
                return .null
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: runtime.identity)
        )
        let rawBinding = try XCTUnwrap(rawProvider.binding(named: MCPWindowToolName.readFile))
        let (appBoundTool, appBinderRetention) = try await MainActor.run {
            let binder = MCPAppToolBinder(windowID: 952) { _, _, arguments, implementation in
                try await runAppBinderProviderTask {
                    try await implementation(
                        MCPAppToolInvocation(toolName: MCPWindowToolName.readFile, windowID: 952),
                        arguments
                    )
                }
            }
            return try (
                Tool(domainBinding: rawBinding, runtime: binder),
                SendableObjectRetention(binder)
            )
        }
        let registeredBinding = try appBoundTool.domainBinding()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .window(id: 952),
            bindings: [registeredBinding]
        )

        _ = await runtime.routingCoordinator.registerConnection(
            connectionID: connectionID,
            operationID: UUID()
        )
        let registration = try await runtime.routingCoordinator.currentRegistration(
            connectionID: connectionID
        )
        let resolution = try await runtime.domainHost.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 952)
        )
        let invocationID = UUID()
        let securityContext = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "content-read-cancellation",
                displayName: "ContentReadCancellationTests",
                kind: .appProxy,
                assurance: .verifiedProcess,
                processID: 949,
                runID: nil,
                provider: "test",
                verifiedIdentityFingerprint: "content-read-cancellation"
            ),
            connectionID: connectionID,
            connectionGeneration: registration.generation,
            invocationID: invocationID,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            ephemeralGrantedToolNames: []
        )

        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        let registry = MCPCodeStructureSettlementRegistry()
        let admission = registry.admit(
            windowID: 952,
            connectionID: connectionID,
            invocationID: invocationID,
            toolName: MCPWindowToolName.readFile,
            now: .zero,
            handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
        )
        guard case let .admitted(settlementSlot) = admission else {
            return XCTFail("Expected settlement-registry admission")
        }

        // Started after the runtime registers its shutdown, so teardown joins owned reads first.
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalReadGate.release() }
        cleanup.addSleeperRelease { await sleeps.releaseAll() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalReadGate.blockUntilReleased()
        }

        await probe.observe {
            let watchdogTask = Task { () -> Result<Value, Error> in
                do {
                    return try await .success(MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runtime.domainHost.invoke(MCPDomainHostInvocation(
                            invocationID: invocationID,
                            connectionID: connectionID,
                            resolution: resolution,
                            arguments: ["path": .string(path)],
                            securityContext: securityContext
                        ))
                    })
                } catch {
                    return .failure(error)
                }
            }

            cleanup.retain(watchdogTask, "Watchdog-wrapped concrete host provider")

            guard await waitUntil({ physicalReadGate.isBlockedSnapshot() }) else {
                watchdogTask.cancel()
                if let earlyResult = await waitForTaskResult(watchdogTask),
                   case let .failure(error) = earlyResult.get()
                {
                    return XCTFail("Concrete host provider failed before the physical gate: \(String(reflecting: error))")
                }
                return XCTFail("Concrete host provider did not reach the controlled physical gate")
            }
            guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
                return XCTFail("Watchdog deadline did not register")
            }
            let deadlineSleepReleased = await sleeps.releaseNext()
            XCTAssertTrue(deadlineSleepReleased)

            guard let observedResult = await waitForTaskResult(watchdogTask) else {
                return XCTFail("Concrete host provider did not settle within cancellation grace")
            }
            guard case let .failure(error) = observedResult.get() else {
                return XCTFail("Expected concrete host provider timeout")
            }
            XCTAssertEqual(
                error as? MCPToolExecutionWatchdogError,
                .executionTimedOut(settlement: .cancellation)
            )
            XCTAssertEqual(
                registry.snapshot(windowID: 952),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )

            physicalReadGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
        _ = appBinderRetention
    }

    func testSuccessiveDomainProviderExplicitMaterializationTimeoutsDoNotExhaustReleasedProviderAllowance() async throws {
        let firstRootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(
            to: firstRootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let firstTargetURL = firstRootURL.appendingPathComponent("Ignored.swift")
        try "first materialized read\n".write(to: firstTargetURL, atomically: true, encoding: .utf8)
        let firstStore = WorkspaceFileContextStore()
        let firstRoot = try await firstStore.loadRoot(path: firstRootURL.path)
        let firstRoots = await firstStore.rootRefs(scope: .visibleWorkspace)
        let firstCatalogedTarget = await firstStore.file(rootID: firstRoot.id, relativePath: "Ignored.swift")
        XCTAssertNil(firstCatalogedTarget)

        let secondRootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(
            to: secondRootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let secondTargetURL = secondRootURL.appendingPathComponent("Ignored.swift")
        try "second materialized read\n".write(to: secondTargetURL, atomically: true, encoding: .utf8)
        let secondStore = WorkspaceFileContextStore()
        let secondRoot = try await secondStore.loadRoot(path: secondRootURL.path)
        let secondRoots = await secondStore.rootRefs(scope: .visibleWorkspace)
        let secondCatalogedTarget = await secondStore.file(rootID: secondRoot.id, relativePath: "Ignored.swift")
        XCTAssertNil(secondCatalogedTarget)

        let firstPhysicalReadGate = SynchronousPhysicalReadGate()
        let secondPhysicalReadGate = SynchronousPhysicalReadGate()
        let clock = SynchronousDurationClock()
        let registry = MCPCodeStructureSettlementRegistry()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener {
            firstPhysicalReadGate.release()
            secondPhysicalReadGate.release()
        }
        cleanup.addHookReset {
            try? await firstStore.setContentPhysicalReadHandlerForTesting(rootID: firstRoot.id, nil)
            try? await secondStore.setContentPhysicalReadHandlerForTesting(rootID: secondRoot.id, nil)
        }
        try await firstStore.setContentPhysicalReadHandlerForTesting(rootID: firstRoot.id) {
            firstPhysicalReadGate.blockUntilReleased()
        }
        try await secondStore.setContentPhysicalReadHandlerForTesting(rootID: secondRoot.id) {
            secondPhysicalReadGate.blockUntilReleased()
        }

        await probe.observe {
            let attempts = [
                (
                    store: firstStore,
                    roots: firstRoots,
                    targetURL: firstTargetURL,
                    physicalReadGate: firstPhysicalReadGate
                ),
                (
                    store: secondStore,
                    roots: secondRoots,
                    targetURL: secondTargetURL,
                    physicalReadGate: secondPhysicalReadGate
                )
            ]
            var watchdogTasks: [Task<Result<Void, Error>, Never>] = []
            var watchdogResults: [Result<Void, Error>] = []
            var controlledSleeps: [ControlledWatchdogSleeps] = []

            for (index, attempt) in attempts.enumerated() {
                let attemptNumber = index + 1
                let sleeps = ControlledWatchdogSleeps(clock: clock)
                controlledSleeps.append(sleeps)
                cleanup.addSleeperRelease { await sleeps.releaseAll() }
                let admission = registry.admit(
                    windowID: 951,
                    connectionID: UUID(),
                    invocationID: UUID(),
                    toolName: MCPWindowToolName.readFile,
                    now: clock.now(),
                    handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
                )
                guard case let .admitted(settlementSlot) = admission else {
                    return XCTFail("Explicit-materialization attempt \(attemptNumber) was blocked before execution")
                }
                let watchdogTask = Task { () -> Result<Void, Error> in
                    do {
                        try await MCPToolExecutionWatchdog.execute(
                            deadline: .seconds(30),
                            cancellationGrace: .seconds(5),
                            cleanupDisposition: .detachAndSettle,
                            settlementSlot: settlementSlot,
                            environment: MCPToolExecutionWatchdogEnvironment(
                                now: { clock.now() },
                                sleep: { duration in try await sleeps.sleep(for: duration) }
                            )
                        ) {
                            try await runDomainReadProviderTask(path: attempt.targetURL.path) {
                                let materialization = try await attempt.store.materializeExplicitlyRequestedFile(
                                    attempt.targetURL.path,
                                    rootRefs: attempt.roots
                                )
                                guard case .materialized = materialization else {
                                    throw PhysicalReadTestError.syntheticFailure
                                }
                            }
                        }
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                watchdogTasks.append(watchdogTask)
                cleanup.retain(watchdogTask, "Explicit-materialization attempt \(attemptNumber)")

                guard await waitUntil({ attempt.physicalReadGate.isBlockedSnapshot() }) else {
                    return XCTFail("Explicit-materialization attempt \(attemptNumber) did not reach its physical probe")
                }
                guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
                    return XCTFail("Explicit-materialization attempt \(attemptNumber) did not register its deadline")
                }
                let deadlineSleepReleased = await sleeps.releaseNext()
                XCTAssertTrue(deadlineSleepReleased)
                var observedResult = await waitForTaskResult(watchdogTask)
                if observedResult == nil {
                    guard await waitUntil({ await sleeps.pendingCountSnapshot() >= 1 }) else {
                        return XCTFail("Explicit-materialization attempt \(attemptNumber) did not register cancellation grace")
                    }
                    let graceSleepReleased = await sleeps.releaseNext()
                    XCTAssertTrue(graceSleepReleased)
                    observedResult = await waitForTaskResult(watchdogTask)
                }
                guard let observedResult else {
                    return XCTFail("Explicit-materialization attempt \(attemptNumber) did not settle")
                }
                watchdogResults.append(observedResult.get())

                if index == 0 {
                    clock.advance(by: .seconds(30))
                }
            }

            let thirdAdmission = registry.admit(
                windowID: 951,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            let thirdAdmissionSucceeded: Bool
            switch thirdAdmission {
            case let .admitted(slot):
                thirdAdmissionSucceeded = true
                _ = slot.closeBeforeExecutionExit()
            case .busy:
                thirdAdmissionSucceeded = false
            }

            for (index, result) in watchdogResults.enumerated() {
                guard case let .failure(error) = result else {
                    XCTFail("Explicit-materialization attempt \(index + 1) did not time out")
                    continue
                }
                XCTAssertEqual(
                    error as? MCPToolExecutionWatchdogError,
                    .executionTimedOut(settlement: .cancellation),
                    "Explicit-materialization attempt \(index + 1) detached instead of settling cancellation"
                )
            }
            XCTAssertTrue(thirdAdmissionSucceeded, "Two released providers exhausted replacement admission")
            XCTAssertEqual(
                registry.snapshot(windowID: 951),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 2, "Owned work while both physical probes are blocked: \(blocked)")
            XCTAssertEqual(blocked.queuedCount, 0)

            firstPhysicalReadGate.release()
            secondPhysicalReadGate.release()
            for sleeps in controlledSleeps {
                await sleeps.releaseAll()
            }
            for task in watchdogTasks {
                _ = await waitForTaskResult(task)
            }
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testExplicitMaterializationReusesItsValidatedPhysicalEligibility() async throws {
        let rootURL = try makeTemporaryRoot()
        try "Ignored.swift\n".write(
            to: rootURL.appendingPathComponent(".repo_ignore"),
            atomically: true,
            encoding: .utf8
        )
        let targetURL = rootURL.appendingPathComponent("Ignored.swift")
        try "single physical eligibility probe\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let probeCount = SynchronousInvocationCounter()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            probeCount.recordInvocation()
        }

        try await cleanup.probe.observe {
            let result = try await store.materializeExplicitlyRequestedFile(
                targetURL.path,
                rootRefs: roots
            )
            guard case let .materialized(file) = result else {
                return XCTFail("Expected ignored file to materialize")
            }
            XCTAssertEqual(file.standardizedFullPath, StandardizedPath.absolute(targetURL.path))
            XCTAssertEqual(probeCount.snapshot(), 1)
        }
    }

    func testExplicitRegistrationRechecksIgnoreRuleRevisionAfterEligibilityValidation() async throws {
        let rootURL = try makeTemporaryRoot()
        try "policy drift\n".write(
            to: rootURL.appendingPathComponent("Ignored.swift"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await FileSystemService(path: rootURL.path)
        let probeCount = SynchronousInvocationCounter()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset { await service.setContentPhysicalReadHandlerForTesting(nil) }
        await service.setContentPhysicalReadHandlerForTesting {
            probeCount.recordInvocation()
        }

        try await cleanup.probe.observe {
            let evidence = try await service.cancellationResponsiveCatalogRegularFileEligibilityWithPolicy(
                relativePath: "Ignored.swift"
            )
            XCTAssertEqual(evidence.eligibility, .eligible)

            try "Ignored.swift\n".write(
                to: rootURL.appendingPathComponent(".gitignore"),
                atomically: true,
                encoding: .utf8
            )
            try await service.refreshIgnoreRules()
            let refreshedPolicyIdentity = await service.currentWorkspaceRootCatalogPolicyIdentity()
            XCTAssertEqual(refreshedPolicyIdentity, evidence.policyIdentity)
            let registeredEligibility = try await service.registerExplicitlyManagedRegularFile(
                relativePath: "Ignored.swift",
                validatedEligibility: evidence.eligibility,
                policyIdentity: evidence.policyIdentity,
                ignoreRulesRevision: evidence.ignoreRulesRevision
            )

            XCTAssertEqual(registeredEligibility, .ineligible(.ignored))
            XCTAssertEqual(probeCount.snapshot(), 1)
        }
    }

    func testExplicitRegistrationRechecksPhysicalEligibilityAfterPolicyIdentityChanges() async throws {
        let rootURL = try makeTemporaryRoot()
        let realDirectoryURL = rootURL.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectoryURL, withIntermediateDirectories: true)
        try "policy identity drift\n".write(
            to: realDirectoryURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("Alias"),
            withDestinationURL: realDirectoryURL
        )

        let service = try await FileSystemService(path: rootURL.path, skipSymlinks: false)
        let probeCount = SynchronousInvocationCounter()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset { await service.setContentPhysicalReadHandlerForTesting(nil) }
        await service.setContentPhysicalReadHandlerForTesting {
            probeCount.recordInvocation()
        }

        try await cleanup.probe.observe {
            let evidence = try await service.cancellationResponsiveCatalogRegularFileEligibilityWithPolicy(
                relativePath: "Alias/Target.swift"
            )
            XCTAssertEqual(evidence.eligibility, .eligible)

            await service.updateSkipSymlinks(true)
            let registeredEligibility = try await service.registerExplicitlyManagedRegularFile(
                relativePath: "Alias/Target.swift",
                validatedEligibility: evidence.eligibility,
                policyIdentity: evidence.policyIdentity,
                ignoreRulesRevision: evidence.ignoreRulesRevision
            )

            XCTAssertEqual(registeredEligibility, .ineligible(.symlinkComponent))
            XCTAssertEqual(probeCount.snapshot(), 2)
        }
    }

    func testExplicitMaterializationRechecksIgnoreRuleRevisionAfterCodemapFence() async throws {
        let rootURL = try makeTemporaryRoot()
        let ignoreURL = rootURL.appendingPathComponent(".gitignore")
        try "Ignored.swift\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
        let targetURL = rootURL.appendingPathComponent("Ignored.swift")
        try "fence policy drift\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let probeCount = SynchronousInvocationCounter()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset {
            try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
            await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting(nil)
        }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            probeCount.recordInvocation()
        }
        await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting { service in
            try? "".write(to: ignoreURL, atomically: true, encoding: .utf8)
            try? await service.refreshIgnoreRules()
        }

        try await cleanup.probe.observe {
            let result = try await store.materializeExplicitlyRequestedFile(
                targetURL.path,
                rootRefs: roots
            )
            guard case let .materialized(file) = result else {
                return XCTFail("Expected file to materialize after ignore policy changed")
            }
            let isManagedOnly = await store.isManagedOnlyFileForTesting(file.id)
            XCTAssertFalse(isManagedOnly)
            XCTAssertEqual(probeCount.snapshot(), 1)
        }
    }

    func testExplicitMaterializationRejectsRootTurnoverDuringPolicyRevalidation() async throws {
        let rootURL = try makeTemporaryRoot()
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        try "root turnover\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let physicalGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addGateOpener { physicalGate.release() }
        cleanup.addHookReset { await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting(nil) }
        await store.setExplicitMaterializationDidAcquireCodemapFenceHandlerForTesting { service in
            await service.updateSkipSymlinks(false)
            await service.setContentPhysicalReadHandlerForTesting {
                physicalGate.blockUntilReleased()
            }
        }

        try await cleanup.probe.observe {
            let materializationTask = Task {
                try await store.materializeExplicitlyRequestedFile(targetURL.path, rootRefs: roots)
            }
            cleanup.retain(materializationTask, "Explicit materialization")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("Policy revalidation did not reach the controlled physical boundary")
            }

            await store.unloadRoot(id: root.id)
            physicalGate.release()
            guard let materializationResult = await waitForTaskResult(materializationTask) else {
                return XCTFail("Materialization did not settle after root turnover")
            }
            XCTAssertEqual(try materializationResult.get(), .noCandidate)
            let materializedFile = await store.file(rootID: root.id, relativePath: "Target.swift")
            XCTAssertNil(materializedFile)
        }
    }

    func testExplicitMaterializationRejectsRootTurnoverDuringInitialEligibility() async throws {
        let rootURL = try makeTemporaryRoot()
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        try "initial eligibility turnover\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let physicalGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addGateOpener { physicalGate.release() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalGate.blockUntilReleased()
        }

        try await cleanup.probe.observe {
            let materializationTask = Task {
                try await store.materializeExplicitlyRequestedFile(targetURL.path, rootRefs: roots)
            }
            cleanup.retain(materializationTask, "Explicit materialization")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("Initial eligibility did not reach the controlled physical boundary")
            }

            try await store.replaceRootLifetimeForTesting(rootID: root.id)
            physicalGate.release()
            guard let materializationResult = await waitForTaskResult(materializationTask) else {
                return XCTFail("Materialization did not settle after initial-eligibility root turnover")
            }
            XCTAssertEqual(try materializationResult.get(), .noCandidate)
        }
    }

    func testExactCandidatesRejectUncataloguedEligibilityAfterRootTurnover() async throws {
        let catalogRootURL = try makeTemporaryRoot()
        let ignoredRootURL = try makeTemporaryRoot()
        try "catalog match\n".write(
            to: catalogRootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "Target.swift\n".write(
            to: ignoredRootURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored physical match\n".write(
            to: ignoredRootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: catalogRootURL.path)
        let ignoredRoot = try await store.loadRoot(path: ignoredRootURL.path)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let ignoredCatalogFile = await store.file(rootID: ignoredRoot.id, relativePath: "Target.swift")
        XCTAssertNil(ignoredCatalogFile)
        let physicalGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addGateOpener { physicalGate.release() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: ignoredRoot.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: ignoredRoot.id) {
            physicalGate.blockUntilReleased()
        }

        try await cleanup.probe.observe {
            let resolutionTask = Task {
                try await store.resolveExactExistingWorkspaceFile(
                    WorkspaceExactFileInput.parse("Target.swift"),
                    namespace: WorkspaceExactFileNamespace.identity(roots: roots)
                )
            }
            cleanup.retain(resolutionTask, "Exact resolution")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("Uncatalogued eligibility did not reach the controlled physical boundary")
            }

            try await store.replaceRootLifetimeForTesting(rootID: ignoredRoot.id)
            physicalGate.release()
            guard let observedResolution = await waitForTaskResult(resolutionTask) else {
                return XCTFail("Exact resolution did not settle after root turnover")
            }
            XCTAssertEqual(
                try observedResolution.get(),
                .issue(.unresolved(input: "Target.swift"))
            )
        }
    }

    func testSuccessiveOuterProviderTimeoutsDoNotEnterUnrelatedGitArtifactPreflight() async throws {
        XCTAssertTrue(MCPServerViewModel.shouldAttemptSelectedGitArtifactReadForTesting(
            requestedPath: "_git_data/repos/repo/snapshot/MAP.txt",
            translatedLookupPath: "/workspace/_git_data/repos/repo/snapshot/MAP.txt"
        ))
        XCTAssertFalse(MCPServerViewModel.shouldAttemptSelectedGitArtifactReadForTesting(
            requestedPath: "Target.swift",
            translatedLookupPath: "/workspace/Target.swift"
        ))

        let rootURL = try makeTemporaryRoot()
        try "successive provider timeout\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let registry = MCPCodeStructureSettlementRegistry()
        let gitArtifactPreflightGate = AsyncSignal()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { await gitArtifactPreflightGate.signal() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }

        try await probe.observe {
            for attempt in 1 ... 2 {
                let physicalReadGate = SynchronousPhysicalReadGate()
                let clock = SynchronousDurationClock()
                let sleeps = ControlledWatchdogSleeps(clock: clock)
                cleanup.addGateOpener { physicalReadGate.release() }
                cleanup.addSleeperRelease { await sleeps.releaseAll() }
                let invocationID = UUID()
                let admission = registry.admit(
                    windowID: 949,
                    connectionID: UUID(),
                    invocationID: invocationID,
                    toolName: MCPWindowToolName.readFile,
                    now: clock.now(),
                    handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
                )
                guard case let .admitted(settlementSlot) = admission else {
                    return XCTFail("Timeout attempt \(attempt) was blocked by prior provider settlement debt")
                }

                try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
                    physicalReadGate.blockUntilReleased()
                }
                let watchdogTask = Task { () -> Result<Void, Error> in
                    do {
                        try await MCPToolExecutionWatchdog.execute(
                            deadline: .seconds(30),
                            cancellationGrace: .seconds(5),
                            cleanupDisposition: .detachAndSettle,
                            settlementSlot: settlementSlot,
                            environment: MCPToolExecutionWatchdogEnvironment(
                                now: { clock.now() },
                                sleep: { duration in try await sleeps.sleep(for: duration) }
                            )
                        ) {
                            if MCPServerViewModel.shouldAttemptSelectedGitArtifactReadForTesting(
                                requestedPath: "Target.swift",
                                translatedLookupPath: record.standardizedFullPath
                            ) {
                                await gitArtifactPreflightGate.wait()
                            }
                            try await runMainActorProviderTask(
                                store: store,
                                record: record,
                                roots: store.rootRefs(scope: .visibleWorkspace)
                            )
                        }
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }

                cleanup.retain(watchdogTask, "Timeout attempt \(attempt)")

                guard await waitUntil({ physicalReadGate.isBlockedSnapshot() }) else {
                    return XCTFail("Timeout attempt \(attempt) stalled in unrelated Git-artifact preflight")
                }
                guard await waitUntil({ await sleeps.registeredCountSnapshot() >= 1 }) else {
                    return XCTFail("Timeout attempt \(attempt) did not register its watchdog deadline")
                }
                await sleeps.releaseNext()

                guard let observedWatchdogResult = await waitForTaskResult(watchdogTask) else {
                    return XCTFail("Timeout attempt \(attempt) did not settle during cancellation grace")
                }
                let watchdogResult = try observedWatchdogResult.get()
                guard case let .failure(error) = watchdogResult,
                      error as? MCPToolExecutionWatchdogError == .executionTimedOut(settlement: .cancellation)
                else {
                    return XCTFail("Timeout attempt \(attempt) did not report cancellation settlement")
                }
                XCTAssertEqual(
                    registry.snapshot(windowID: 949),
                    .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
                )

                physicalReadGate.release()
                await assertOwnedContentReadWorkSettles(probe)
                try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil)
            }
        }
    }

    func testSuccessiveDomainProviderExactResolutionPathStateStallsSettleAndRecover() async throws {
        let parentURL = try makeTemporaryRoot()
        let rootURLs = ["catalog-hit", "catalog-miss-a", "catalog-miss-b"].map {
            parentURL.appendingPathComponent($0, isDirectory: true)
        }
        for rootURL in rootURLs {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        try "cataloged target\n".write(
            to: rootURLs[0].appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        for rootURL in rootURLs {
            _ = try await store.loadRoot(path: rootURL.path)
        }
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        guard let catalogRoot = roots.first(where: {
            $0.standardizedFullPath == StandardizedPath.absolute(rootURLs[0].path)
        }), let record = await store.file(rootID: catalogRoot.id, relativePath: "Target.swift")
        else {
            return XCTFail("Expected cataloged target record")
        }
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let missingRootIDs = roots
            .filter { $0.standardizedFullPath != StandardizedPath.absolute(rootURLs[0].path) }
            .map(\.id)
        XCTAssertEqual(missingRootIDs.count, 2)

        let physicalReadGates = PeriodicPhysicalReadGates(interval: 2, count: 2)
        let physicalReadHandler: @Sendable () -> Void = {
            physicalReadGates.reachNextProbe()
        }
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalReadGates.releaseAll() }
        cleanup.addHookReset {
            for rootID in missingRootIDs {
                try? await store.setContentPhysicalReadHandlerForTesting(rootID: rootID, nil)
            }
        }
        for rootID in missingRootIDs {
            try await store.setContentPhysicalReadHandlerForTesting(
                rootID: rootID,
                physicalReadHandler
            )
        }

        let registry = MCPCodeStructureSettlementRegistry()
        let clock = SynchronousDurationClock()
        func startWatchdogAttempt(
            _ attempt: Int,
            sleeps: ControlledWatchdogSleeps
        ) -> Task<Result<Void, Error>, Never>? {
            let admission = registry.admit(
                windowID: 949,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(settlementSlot) = admission else {
                XCTFail("Exact-resolution attempt \(attempt) was blocked before execution")
                return nil
            }
            return Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runDomainReadProviderTask(
                            store: store,
                            record: record,
                            roots: roots
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }

        func finishWatchdogAttempt(
            _ task: Task<Result<Void, Error>, Never>,
            sleeps: ControlledWatchdogSleeps
        ) async -> Result<Void, Error>? {
            let deadlineDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard deadlineDidRegister else {
                task.cancel()
                await sleeps.releaseAll()
                return nil
            }
            guard await sleeps.releaseNext() else {
                XCTFail("Exact-resolution deadline sleeper disappeared before release")
                return nil
            }
            if let observedResult = await waitForTaskResult(task) {
                return observedResult.get()
            }
            let graceDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard graceDidRegister else { return nil }
            guard await sleeps.releaseNext() else {
                XCTFail("Exact-resolution grace sleeper disappeared before release")
                return nil
            }
            guard let observedResult = await waitForTaskResult(task) else { return nil }
            return observedResult.get()
        }

        try await probe.observe {
            let firstSleeps = ControlledWatchdogSleeps(clock: clock)
            cleanup.addSleeperRelease { await firstSleeps.releaseAll() }
            guard let firstTask = startWatchdogAttempt(1, sleeps: firstSleeps) else { return }
            cleanup.retain(firstTask, "Exact-resolution attempt 1")
            guard await waitUntil({ physicalReadGates.isBlocked(at: 0) }) else {
                firstTask.cancel()
                let earlyResult = await waitForTaskResult(firstTask)
                return XCTFail("First exact-resolution path-state probe did not block; result=\(String(describing: earlyResult))")
            }
            let firstResult = await finishWatchdogAttempt(firstTask, sleeps: firstSleeps)

            // The settlement registry's recovery horizon admits a replacement provider even
            // while the first cancellation-ignoring producer still owns its physical work.
            clock.advance(by: .seconds(30))
            let secondSleeps = ControlledWatchdogSleeps(clock: clock)
            cleanup.addSleeperRelease { await secondSleeps.releaseAll() }
            guard let secondTask = startWatchdogAttempt(2, sleeps: secondSleeps) else { return }
            cleanup.retain(secondTask, "Exact-resolution attempt 2")
            let secondPhysicalReadDidBlock = await waitUntil { physicalReadGates.isBlocked(at: 1) }
            let secondResult = await finishWatchdogAttempt(secondTask, sleeps: secondSleeps)

            let thirdAdmission = registry.admit(
                windowID: 949,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            let thirdAdmissionSucceeded: Bool
            switch thirdAdmission {
            case let .admitted(slot):
                thirdAdmissionSucceeded = true
                _ = slot.closeBeforeExecutionExit()
            case .busy:
                thirdAdmissionSucceeded = false
            }

            XCTAssertTrue(secondPhysicalReadDidBlock, "The second provider remained queued behind the first actor-pinning probe")
            for (attempt, result) in [firstResult, secondResult].enumerated() {
                guard case let .failure(error) = result else {
                    XCTFail("Exact-resolution attempt \(attempt + 1) did not time out")
                    continue
                }
                XCTAssertEqual(
                    error as? MCPToolExecutionWatchdogError,
                    .executionTimedOut(settlement: .cancellation),
                    "Exact-resolution attempt \(attempt + 1) detached instead of settling cancellation"
                )
            }
            XCTAssertTrue(thirdAdmissionSucceeded, "Two detached providers exhausted the released-provider allowance")
            XCTAssertEqual(
                registry.snapshot(windowID: 949),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )

            physicalReadGates.releaseAll()
            await firstSleeps.releaseAll()
            await secondSleeps.releaseAll()
            _ = await waitForTaskResult(firstTask)
            _ = await waitForTaskResult(secondTask)
            await assertOwnedContentReadWorkSettles(probe)

            let recovered = try await store.resolveExactExistingWorkspaceFile(
                WorkspaceExactFileInput.parse("Target.swift"),
                namespace: namespace
            )
            guard case let .matched(match) = recovered else {
                return XCTFail("Expected exact resolution to recover after both physical reads returned")
            }
            XCTAssertEqual(match.file.standardizedFullPath, StandardizedPath.absolute(rootURLs[0].appendingPathComponent("Target.swift").path))
            // A successful read releases its permit and ends its producer before returning.
            let afterRecovery = probe.snapshot()
            XCTAssertTrue(afterRecovery.isSettled, "Owned work after the recovered resolution: \(afterRecovery)")
        }
    }

    func testSuccessiveExactResolutionMissingFileRechecksSettleAndRecover() async throws {
        let parentURL = try makeTemporaryRoot()
        let rootURLs = ["catalog-hit", "catalog-miss-a", "catalog-miss-b"].map {
            parentURL.appendingPathComponent($0, isDirectory: true)
        }
        for rootURL in rootURLs {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        try "cataloged target\n".write(
            to: rootURLs[0].appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        for rootURL in rootURLs {
            _ = try await store.loadRoot(path: rootURL.path)
        }
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        guard let catalogRoot = roots.first(where: {
            $0.standardizedFullPath == StandardizedPath.absolute(rootURLs[0].path)
        }), let record = await store.file(rootID: catalogRoot.id, relativePath: "Target.swift")
        else {
            return XCTFail("Expected cataloged target record")
        }
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let missingRootIDs = roots
            .filter { $0.standardizedFullPath != StandardizedPath.absolute(rootURLs[0].path) }
            .map(\.id)
        XCTAssertEqual(missingRootIDs.count, 2)

        let physicalReadGates = PeriodicPhysicalReadGates(interval: 3, count: 2)
        let physicalReadHandler: @Sendable () -> Void = {
            physicalReadGates.reachNextProbe()
        }
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalReadGates.releaseAll() }
        cleanup.addHookReset {
            for rootID in missingRootIDs {
                try? await store.setContentPhysicalReadHandlerForTesting(rootID: rootID, nil)
            }
        }
        for rootID in missingRootIDs {
            try await store.setContentPhysicalReadHandlerForTesting(
                rootID: rootID,
                physicalReadHandler
            )
        }

        let registry = MCPCodeStructureSettlementRegistry()
        let clock = SynchronousDurationClock()
        func startWatchdogAttempt(
            _ attempt: Int,
            sleeps: ControlledWatchdogSleeps
        ) -> Task<Result<Void, Error>, Never>? {
            let admission = registry.admit(
                windowID: 950,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(settlementSlot) = admission else {
                XCTFail("Exact-resolution attempt \(attempt) was blocked before execution")
                return nil
            }
            return Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: settlementSlot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        try await runMainActorProviderTask(
                            store: store,
                            record: record,
                            roots: roots
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }

        func finishWatchdogAttempt(
            _ task: Task<Result<Void, Error>, Never>,
            sleeps: ControlledWatchdogSleeps
        ) async -> Result<Void, Error>? {
            let deadlineDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard deadlineDidRegister else {
                task.cancel()
                await sleeps.releaseAll()
                return nil
            }
            guard await sleeps.releaseNext() else {
                XCTFail("Missing-file deadline sleeper disappeared before release")
                return nil
            }
            if let observedResult = await waitForTaskResult(task) {
                return observedResult.get()
            }
            let graceDidRegister = await waitUntil {
                await sleeps.pendingCountSnapshot() >= 1
            }
            guard graceDidRegister else { return nil }
            guard await sleeps.releaseNext() else {
                XCTFail("Missing-file grace sleeper disappeared before release")
                return nil
            }
            guard let observedResult = await waitForTaskResult(task) else { return nil }
            return observedResult.get()
        }

        try await probe.observe {
            let firstSleeps = ControlledWatchdogSleeps(clock: clock)
            cleanup.addSleeperRelease { await firstSleeps.releaseAll() }
            guard let firstTask = startWatchdogAttempt(1, sleeps: firstSleeps) else { return }
            cleanup.retain(firstTask, "Missing-file attempt 1")
            guard await waitUntil({ physicalReadGates.isBlocked(at: 0) }) else {
                return XCTFail("First exact-resolution missing-file recheck did not block")
            }
            let firstResult = await finishWatchdogAttempt(firstTask, sleeps: firstSleeps)

            clock.advance(by: .seconds(30))
            let secondSleeps = ControlledWatchdogSleeps(clock: clock)
            cleanup.addSleeperRelease { await secondSleeps.releaseAll() }
            guard let secondTask = startWatchdogAttempt(2, sleeps: secondSleeps) else { return }
            cleanup.retain(secondTask, "Missing-file attempt 2")
            let secondPhysicalReadDidBlock = await waitUntil {
                physicalReadGates.isBlocked(at: 1)
            }
            let secondResult = await finishWatchdogAttempt(secondTask, sleeps: secondSleeps)

            let thirdAdmission = registry.admit(
                windowID: 950,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            let thirdAdmissionSucceeded: Bool
            switch thirdAdmission {
            case let .admitted(slot):
                thirdAdmissionSucceeded = true
                _ = slot.closeBeforeExecutionExit()
            case .busy:
                thirdAdmissionSucceeded = false
            }

            XCTAssertTrue(
                secondPhysicalReadDidBlock,
                "The second provider remained queued behind the first actor-isolated regular-file probe"
            )
            for (attempt, result) in [firstResult, secondResult].enumerated() {
                guard case let .failure(error) = result else {
                    XCTFail("Exact-resolution attempt \(attempt + 1) did not time out")
                    continue
                }
                XCTAssertEqual(
                    error as? MCPToolExecutionWatchdogError,
                    .executionTimedOut(settlement: .cancellation),
                    "Exact-resolution attempt \(attempt + 1) detached instead of settling cancellation"
                )
            }
            XCTAssertTrue(thirdAdmissionSucceeded, "A released provider plus a second detachment exhausted admission")
            XCTAssertEqual(
                registry.snapshot(windowID: 950),
                .init(activeCount: 0, detachedCount: 0, releasedCount: 0)
            )
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 2, "Owned work while both missing-file rechecks are blocked: \(blocked)")
            XCTAssertEqual(blocked.queuedCount, 0)

            physicalReadGates.releaseAll()
            await firstSleeps.releaseAll()
            await secondSleeps.releaseAll()
            _ = await waitForTaskResult(firstTask)
            _ = await waitForTaskResult(secondTask)
            await assertOwnedContentReadWorkSettles(probe)

            let recovered = try await store.resolveExactExistingWorkspaceFile(
                WorkspaceExactFileInput.parse("Target.swift"),
                namespace: namespace
            )
            guard case let .matched(match) = recovered else {
                return XCTFail("Expected exact resolution to recover after both missing-file probes returned")
            }
            XCTAssertEqual(
                match.file.standardizedFullPath,
                StandardizedPath.absolute(rootURLs[0].appendingPathComponent("Target.swift").path)
            )
        }
    }

    func testLimiterReportsBackpressureAndRemovesCancelledQueuedRead() async throws {
        let limiter = ContentReadAsyncLimiter(
            capacity: 1,
            bulkPermitLimit: 1,
            maxQueuedWaiterCount: 1,
            retryAfterMilliseconds: 37
        )
        let activeReadStarted = AsyncSignal()
        let releaseActiveRead = AsyncSignal()
        let activeTask = Task {
            try await limiter.withPermit(workloadClass: .interactiveRead, ownerID: UUID()) {
                await activeReadStarted.signal()
                await releaseActiveRead.wait()
            }
        }
        let activeReadDidStart = await waitUntil { await activeReadStarted.isSignaledSnapshot() }
        guard activeReadDidStart else {
            activeTask.cancel()
            await releaseActiveRead.signal()
            return XCTFail("Active limiter read did not start")
        }

        let queuedTask = Task {
            try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {}
        }
        let queuedSnapshot = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
        XCTAssertEqual(queuedSnapshot.activePermitCount, 1)
        XCTAssertEqual(queuedSnapshot.ownerLaneCount, 2)

        do {
            try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {}
            XCTFail("Expected an explicit queue-full error")
        } catch {
            XCTAssertEqual(error as? ContentReadSchedulerError, .queueFull(retryAfterMilliseconds: 37))
        }

        queuedTask.cancel()
        guard let queuedResult = await waitForTaskResult(queuedTask) else {
            await releaseActiveRead.signal()
            return XCTFail("Queued limiter read did not settle after cancellation")
        }
        do {
            try queuedResult.get()
            XCTFail("Expected queued read cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshot = await limiter.snapshotForTesting()
        XCTAssertEqual(cancelledSnapshot.activePermitCount, 1)
        XCTAssertEqual(cancelledSnapshot.queuedWaiterCount, 0)
        XCTAssertEqual(cancelledSnapshot.ownerLaneCount, 1)
        XCTAssertEqual(cancelledSnapshot.cancellationCount, 1)
        XCTAssertEqual(cancelledSnapshot.overloadCount, 1)

        await releaseActiveRead.signal()
        guard let activeResult = await waitForTaskResult(activeTask) else {
            return XCTFail("Active limiter read did not settle after release")
        }
        try activeResult.get()
        let idleSnapshot = await limiter.snapshotForTesting()
        XCTAssertTrue(idleSnapshot.isIdle)
    }

    func testDetachedPhysicalReadPreservesTaskLocalAttribution() async throws {
        let rootURL = try makeTemporaryRoot()
        let contents = "attributed physical read\n"
        try contents.write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: rootURL.path)
        EditFlowPerf.resetDebugCaptureForTesting()
        _ = EditFlowPerf.beginDebugCapture(label: "physical-read-attribution", maxSamples: 32)
        guard let lifecycleCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive() else {
            return XCTFail("Expected an active lifecycle correlation")
        }
        let benchmarkMetricTag = WorktreeStartupInstrumentation.BenchmarkMetricTag(
            correlationID: UUID(),
            contextID: UUID(),
            agentSessionID: UUID(),
            logicalRootID: UUID(),
            repositoryID: "repository",
            destinationID: "destination"
        )
        let attributionRecorder = PhysicalReadAttributionRecorder()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset {
            await service.setContentPhysicalReadHandlerForTesting(nil)
            MCPToolWorkCountDiagnostics.resetForTesting()
            EditFlowPerf.resetDebugCaptureForTesting()
        }
        await service.setContentPhysicalReadHandlerForTesting {
            attributionRecorder.record(
                lifecycleCorrelationID: EditFlowPerf.currentLifecycleCorrelation?.id,
                benchmarkMetricTag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            )
        }
        MCPToolWorkCountDiagnostics.resetForTesting()

        try await cleanup.probe.observe {
            try await EditFlowPerf.$currentLifecycleCorrelation.withValue(lifecycleCorrelation) {
                try await WorktreeStartupInstrumentation.$currentBenchmarkMetricTag.withValue(benchmarkMetricTag) {
                    try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                        let fingerprint = try await service.contentFingerprint(ofRelativePath: "Target.swift")
                        let snapshot = try await service.loadValidatedContent(
                            ofRelativePath: "Target.swift",
                            expectedFingerprint: fingerprint,
                            workloadClass: .interactiveRead
                        )
                        XCTAssertEqual(snapshot.content, contents)
                    }
                }
            }

            XCTAssertEqual(attributionRecorder.snapshot()?.lifecycleCorrelationID, lifecycleCorrelation.id)
            XCTAssertEqual(attributionRecorder.snapshot()?.benchmarkMetricTag, benchmarkMetricTag)
            let readSnapshots = MCPToolWorkCountDiagnostics.debugSnapshots().readFile
            XCTAssertEqual(readSnapshots.count, 1)
            XCTAssertEqual(readSnapshots.first?.source, "disk")
            XCTAssertEqual(readSnapshots.first?.readBytes, contents.utf8.count)
            XCTAssertEqual(readSnapshots.first?.outcome, "success")
        }
    }

    func testCancellingOnlyInteractiveCacheWaiterRemovesFlight() async throws {
        let cache = WorkspaceInteractiveReadCache()
        let loaderStarted = AsyncSignal()
        let releaseLoader = AsyncSignal()
        let task = Task {
            try await cache.snapshot(
                for: makeInteractiveReadCacheKey(),
                fingerprint: makeFingerprint(),
                invalidationEpoch: 0
            ) {
                await loaderStarted.signal()
                await releaseLoader.wait()
                return WorkspaceInteractiveReadProcessor.prepare("single waiter\n")
            }
        }
        let loaderDidStart = await waitUntil { await loaderStarted.isSignaledSnapshot() }
        guard loaderDidStart else {
            task.cancel()
            await releaseLoader.signal()
            return XCTFail("Single-waiter cache loader did not start")
        }

        task.cancel()
        guard let taskResult = await waitForTaskResult(task) else {
            await releaseLoader.signal()
            return XCTFail("Single cache waiter did not settle after cancellation")
        }
        do {
            _ = try taskResult.get()
            XCTFail("Expected the only cache waiter to observe cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledSnapshot = await waitForCacheSnapshot(cache) {
            $0.activeFlightCount == 0 && $0.cancellationCount == 1
        }
        XCTAssertEqual(cancelledSnapshot.waiterCount, 0)
        XCTAssertEqual(cancelledSnapshot.entryCount, 0)

        await releaseLoader.signal()
    }

    func testCancellingOneOfTwoInteractiveCacheWaitersPreservesSharedFlight() async throws {
        let cache = WorkspaceInteractiveReadCache()
        let key = makeInteractiveReadCacheKey()
        let fingerprint = makeFingerprint()
        let loaderStarted = AsyncSignal()
        let releaseLoader = AsyncSignal()
        let expected = WorkspaceInteractiveReadProcessor.prepare("shared flight\n")
        let firstTask = Task {
            try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 0) {
                await loaderStarted.signal()
                await releaseLoader.wait()
                return expected
            }
        }
        let loaderDidStart = await waitUntil { await loaderStarted.isSignaledSnapshot() }
        guard loaderDidStart else {
            firstTask.cancel()
            await releaseLoader.signal()
            return XCTFail("Shared cache loader did not start")
        }
        let secondTask = Task {
            try await cache.snapshot(for: key, fingerprint: fingerprint, invalidationEpoch: 0) {
                XCTFail("Joined waiter must not start a second loader")
                return nil
            }
        }
        let sharedSnapshot = await waitForCacheSnapshot(cache) { $0.waiterCount == 2 }
        XCTAssertEqual(sharedSnapshot.waiterCount, 2)

        firstTask.cancel()
        guard let firstResult = await waitForTaskResult(firstTask) else {
            await releaseLoader.signal()
            return XCTFail("Cancelled shared cache waiter did not settle")
        }
        do {
            _ = try firstResult.get()
            XCTFail("Expected the cancelled waiter to settle independently")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let joinedSnapshot = await waitForCacheSnapshot(cache) {
            $0.waiterCount == 1 && $0.cancellationCount == 1
        }
        XCTAssertEqual(joinedSnapshot.activeFlightCount, 1)
        XCTAssertEqual(joinedSnapshot.preparationCount, 1)
        XCTAssertEqual(joinedSnapshot.joinCount, 1)

        await releaseLoader.signal()
        guard let observedSecondResult = await waitForTaskResult(secondTask) else {
            return XCTFail("Remaining shared cache waiter did not settle after release")
        }
        let secondResult = try observedSecondResult.get()
        XCTAssertEqual(secondResult.preparedContent, expected)
        let completedSnapshot = await cache.snapshotForTesting()
        XCTAssertEqual(completedSnapshot.activeFlightCount, 0)
        XCTAssertEqual(completedSnapshot.entryCount, 1)
        XCTAssertEqual(completedSnapshot.acceptedPreparationCount, 1)
    }

    func testProducerCompletionBeforeHandleInstallationSettlesSuccessExactlyOnce() async throws {
        let installGate = SynchronousPhysicalReadGate()
        let producerCompleted = AsyncSignal()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { installGate.release() }

        try await probe.observe {
            let task = Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .interactiveRead,
                    schedulerOwnerID: UUID(),
                    priority: .userInitiated,
                    beforeProducerInstallForTesting: { installGate.blockUntilReleased() }
                ) {
                    await producerCompleted.signal()
                    return 42
                }
            }
            cleanup.retain(task, "Completion-before-install caller")

            let installDidBlock = await waitUntil { installGate.isBlockedSnapshot() }
            let producerDidComplete = await waitUntil { await producerCompleted.isSignaledSnapshot() }
            guard installDidBlock, producerDidComplete else {
                return XCTFail("Completion-before-install interleaving was not reached")
            }
            installGate.release()
            guard let observedResult = await waitForTaskResult(task) else {
                return XCTFail("Completion-before-install result did not settle")
            }
            let result = try observedResult.get()
            XCTAssertEqual(result, 42)
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testCancellationBeforeProducerHandleInstallationSettlesPromptlyAndCancelsProducer() async {
        let installGate = SynchronousPhysicalReadGate()
        let producerGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener {
            installGate.release()
            producerGate.release()
        }

        await probe.observe {
            let task = Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .interactiveRead,
                    schedulerOwnerID: UUID(),
                    priority: .userInitiated,
                    beforeProducerInstallForTesting: { installGate.blockUntilReleased() }
                ) {
                    producerGate.blockUntilReleased()
                    try Task.checkCancellation()
                    return 1
                }
            }
            cleanup.retain(task, "Cancellation-before-install caller")
            let installDidBlock = await waitUntil { installGate.isBlockedSnapshot() }
            let producerDidBlock = await waitUntil { producerGate.isBlockedSnapshot() }
            guard installDidBlock, producerDidBlock else {
                return XCTFail("Cancellation-before-install interleaving was not reached")
            }

            task.cancel()
            installGate.release()
            guard let taskResult = await waitForTaskResult(task) else {
                return XCTFail("Cancellation-before-install did not settle promptly")
            }
            do {
                _ = try taskResult.get()
                XCTFail("Expected cancellation before producer-handle installation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 1, "Owned work while the producer is blocked: \(blocked)")

            producerGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testCancelledCallerDiscardsLatePhysicalReadFailure() async {
        let physicalGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalGate.release() }

        await probe.observe {
            let task = Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .interactiveRead,
                    schedulerOwnerID: UUID(),
                    priority: .userInitiated
                ) {
                    physicalGate.blockUntilReleased()
                    throw PhysicalReadTestError.syntheticFailure
                }
            }
            cleanup.retain(task, "Late-failure caller")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("Late physical failure did not reach the controlled gate")
            }

            task.cancel()
            guard let taskResult = await waitForTaskResult(task) else {
                return XCTFail("Caller did not settle before the late physical failure")
            }
            do {
                _ = try taskResult.get()
                XCTFail("Expected caller cancellation to win the late physical failure race")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 1, "Owned work while the late failure is blocked: \(blocked)")

            physicalGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testStoreContentReadGrantsPreserveWorkloadAndOwnerAttribution() async throws {
        let rootURL = try makeTemporaryRoot()
        try "attributed store read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }
        let physicalGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalGate.release() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalGate.blockUntilReleased()
        }
        let ownerIDs = await store.contentReadSchedulerOwnerIDsForTesting()
        XCTAssertNotEqual(ownerIDs.search, ownerIDs.interactive)

        try await probe.observe {
            let searchTask = Task { try await store.searchContentSnapshot(for: record) }
            let interactiveTask = Task { try await store.interactiveReadSnapshot(for: record) }
            cleanup.retain(searchTask, "Store search read")
            cleanup.retain(interactiveTask, "Store interactive read")
            guard await waitUntil({ physicalGate.blockedCountSnapshot() >= 2 }) else {
                return XCTFail("Store reads did not both reach their controlled physical-read grants")
            }

            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 2, "Owned work while both store reads are blocked: \(blocked)")
            XCTAssertEqual(blocked.activeCount(for: .contentSearch), 1)
            XCTAssertEqual(blocked.activeCount(for: .interactiveRead), 1)
            XCTAssertEqual(blocked.activeCountsByOwner[ownerIDs.search], 1)
            XCTAssertEqual(blocked.activeCountsByOwner[ownerIDs.interactive], 1)

            physicalGate.release()
            guard let searchResult = await waitForTaskResult(searchTask),
                  let interactiveResult = await waitForTaskResult(interactiveTask)
            else {
                return XCTFail("Attributed store reads did not settle after release")
            }
            XCTAssertTrue(try searchResult.get().isFresh)
            XCTAssertNotNil(try interactiveResult.get())
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testCacheCommitDoesNotReenterSharedLimiterAfterValidatedRead() async throws {
        let rootURL = try makeTemporaryRoot()
        let contents = "validated content survives cache pressure\n"
        try contents.write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await FileSystemService(path: rootURL.path)
        let fingerprint = try await service.contentFingerprint(ofRelativePath: "Target.swift")
        let cacheCommitReached = AsyncSignal()
        let releaseCacheCommit = AsyncSignal()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { await releaseCacheCommit.signal() }
        cleanup.addHookReset { await service.setContentReadCacheCommitHandlerForTesting(nil) }
        await service.setContentReadCacheCommitHandlerForTesting {
            await cacheCommitReached.signal()
            await releaseCacheCommit.wait()
        }

        try await probe.observe {
            let readTask = Task {
                try await service.loadValidatedContent(
                    ofRelativePath: "Target.swift",
                    expectedFingerprint: fingerprint,
                    workloadClass: .interactiveRead
                )
            }
            cleanup.retain(readTask, "Validated read")
            guard await waitUntil({ await cacheCommitReached.isSignaledSnapshot() }) else {
                return XCTFail("Validated read did not reach the cache-only commit boundary; owned work: \(probe.snapshot())")
            }
            let atCommit = probe.snapshot()
            XCTAssertEqual(atCommit.activeCount, 1, "Owned work at the cache commit: \(atCommit)")

            await releaseCacheCommit.signal()
            guard let observedReadResult = await waitForTaskResult(readTask) else {
                return XCTFail("Validated read did not settle after cache commit")
            }
            let snapshot = try observedReadResult.get()
            XCTAssertEqual(snapshot.content, contents)
            let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Target.swift")
            XCTAssertNotNil(cachedEncoding)
            let afterRead = probe.snapshot()
            XCTAssertEqual(afterRead.grantCount, atCommit.grantCount)
            XCTAssertEqual(afterRead.queueFullCount, atCommit.queueFullCount)
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testCacheCommitRejectsInvalidationAfterFinalFingerprint() async throws {
        let rootURL = try makeTemporaryRoot()
        let targetURL = rootURL.appendingPathComponent("Target.swift")
        let originalContents = "original cache content\n"
        try originalContents.write(to: targetURL, atomically: true, encoding: .utf8)
        let service = try await FileSystemService(path: rootURL.path)
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset { await service.setContentReadCacheCommitHandlerForTesting(nil) }
        await service.setContentReadCacheCommitHandlerForTesting {
            try? "replacement cache content\n".write(to: targetURL, atomically: true, encoding: .utf8)
            await service.advanceContentReadCacheRevisionForTesting()
        }

        try await cleanup.probe.observe {
            let content = try await service.loadContent(
                ofRelativePath: "Target.swift",
                workloadClass: .interactiveRead
            )

            XCTAssertEqual(content, originalContents)
            let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Target.swift")
            XCTAssertNil(cachedEncoding)
        }
    }

    func testCancelledWorkspaceInteractiveReadSuppressesCodeMapUntilPhysicalCompletion() async throws {
        let rootURL = try makeTemporaryRoot()
        try "foreground workspace read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }
        let physicalGate = SynchronousPhysicalReadGate()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalGate.release() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
            physicalGate.blockUntilReleased()
        }

        try await probe.observe {
            let interactiveReadTask = Task { try await store.interactiveReadSnapshot(for: record) }
            cleanup.retain(interactiveReadTask, "Workspace interactive read")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("Workspace read did not reach its controlled physical boundary")
            }

            let codeMap = CodeMapPermitRequest(retainedBy: cleanup)
            guard await waitUntil({ await codeMap.queuedOrGranted(in: probe) }) else {
                return XCTFail("CodeMap work was not held behind workspace interactive activity; owned work: \(probe.snapshot())")
            }
            let grantedBeforeCancellation = await codeMap.granted.isSignaledSnapshot()
            XCTAssertFalse(grantedBeforeCancellation)
            let queued = probe.snapshot()
            XCTAssertEqual(queued.foregroundCount(for: .interactiveRead), 2, "Owned work at the queue boundary: \(queued)")
            XCTAssertEqual(queued.activeCount(for: .codemap), 0)
            XCTAssertEqual(queued.queuedCount(for: .codemap), 1)

            interactiveReadTask.cancel()
            guard let cancelledResult = await waitForTaskResult(interactiveReadTask) else {
                return XCTFail("Cancelled workspace caller did not settle before physical completion")
            }
            do {
                _ = try cancelledResult.get()
                XCTFail("Expected workspace caller cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let cancelled = probe.snapshot()
            XCTAssertEqual(cancelled.activeCount, 1, "Owned work after caller cancellation: \(cancelled)")
            XCTAssertEqual(cancelled.foregroundCount(for: .interactiveRead), 1)
            XCTAssertEqual(cancelled.activeCount(for: .codemap), 0)
            XCTAssertEqual(cancelled.queuedCount(for: .codemap), 1)
            let grantedAfterCallerCancellation = await codeMap.granted.isSignaledSnapshot()
            XCTAssertFalse(grantedAfterCallerCancellation)

            physicalGate.release()
            guard let codeMapResult = await waitForTaskResult(codeMap.task) else {
                return XCTFail("Queued CodeMap work did not settle after physical release")
            }
            try codeMapResult.get()
            let grantedAfterRelease = await codeMap.granted.isSignaledSnapshot()
            XCTAssertTrue(grantedAfterRelease)
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testWorkspaceInteractiveReadSuppressesCodeMapBetweenPhysicalStages() async throws {
        let rootURL = try makeTemporaryRoot()
        try "multi-stage foreground read\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }
        let fingerprintResolved = AsyncSignal()
        let releaseStageGap = AsyncSignal()
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { await releaseStageGap.signal() }
        cleanup.addHookReset { await store.setInteractiveReadFingerprintDidResolveHandlerForTesting(nil) }
        await store.setInteractiveReadFingerprintDidResolveHandlerForTesting {
            await fingerprintResolved.signal()
            await releaseStageGap.wait()
        }

        try await probe.observe {
            let interactiveReadTask = Task { try await store.interactiveReadSnapshot(for: record) }
            cleanup.retain(interactiveReadTask, "Interactive read")
            guard await waitUntil({ await fingerprintResolved.isSignaledSnapshot() }) else {
                return XCTFail("Interactive read did not reach the post-fingerprint stage gap")
            }

            let codeMap = CodeMapPermitRequest(retainedBy: cleanup)
            guard await waitUntil({ await codeMap.queuedOrGranted(in: probe) }) else {
                return XCTFail("CodeMap work was not queued behind the fingerprint stage; owned work: \(probe.snapshot())")
            }
            let grantedBetweenStages = await codeMap.granted.isSignaledSnapshot()
            XCTAssertFalse(grantedBetweenStages)
            let stageGap = probe.snapshot()
            // The fingerprint stage's permit was granted and already released, so the zero active
            // count below describes observed work rather than an empty probe.
            XCTAssertEqual(stageGap.grantCount, 1, "Owned work at the stage gap: \(stageGap)")
            XCTAssertEqual(stageGap.activeCount, 0, "Owned work at the stage gap: \(stageGap)")
            XCTAssertEqual(stageGap.foregroundCount(for: .interactiveRead), 1)
            XCTAssertEqual(stageGap.activeCount(for: .codemap), 0)
            XCTAssertEqual(stageGap.queuedCount(for: .codemap), 1)

            await releaseStageGap.signal()
            guard let interactiveResult = await waitForTaskResult(interactiveReadTask),
                  let codeMapResult = await waitForTaskResult(codeMap.task)
            else {
                return XCTFail("Foreground and CodeMap work did not settle after the stage gap was released")
            }
            XCTAssertNotNil(try interactiveResult.get())
            try codeMapResult.get()
            let grantedAfterRead = await codeMap.granted.isSignaledSnapshot()
            XCTAssertTrue(grantedAfterRead)
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testCancelledAllowlistedExternalReadSuppressesCodeMapUntilPhysicalCompletion() async throws {
        let homeURL = try makeTemporaryRoot()
        let skillsURL = homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        let fileURL = skillsURL.appendingPathComponent("External.md")
        let contents = "foreground external read\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        let physicalGate = SynchronousPhysicalReadGate()
        let readableService = WorkspaceReadableFileService(
            store: WorkspaceFileContextStore(),
            homeDirectoryURL: homeURL,
            beforeExternalReadOpenForTesting: { _ in physicalGate.blockUntilReleased() }
        )
        let file = WorkspaceExternalReadableFile(
            absolutePath: fileURL.path,
            displayPath: "~/.agents/skills/External.md"
        )
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalGate.release() }

        try await probe.observe {
            let externalReadTask = Task { try await readableService.readAlwaysReadableExternalFile(file) }
            cleanup.retain(externalReadTask, "External read caller")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("External read did not reach its controlled physical boundary")
            }

            let codeMap = CodeMapPermitRequest(retainedBy: cleanup)
            guard await waitUntil({ await codeMap.queuedOrGranted(in: probe) }) else {
                return XCTFail("CodeMap work was not held behind external interactive activity; owned work: \(probe.snapshot())")
            }
            let grantedBeforeRelease = await codeMap.granted.isSignaledSnapshot()
            XCTAssertFalse(grantedBeforeRelease)
            let queued = probe.snapshot()
            XCTAssertEqual(queued.activeCount, 1, "Owned work at the queue boundary: \(queued)")
            XCTAssertEqual(queued.foregroundCount(for: .interactiveRead), 1)
            XCTAssertEqual(queued.activeCount(for: .codemap), 0)
            XCTAssertEqual(queued.queuedCount(for: .codemap), 1)

            externalReadTask.cancel()
            guard let cancelledExternalResult = await waitForTaskResult(externalReadTask) else {
                return XCTFail("Cancelled external caller did not settle before physical completion")
            }
            do {
                _ = try cancelledExternalResult.get()
                XCTFail("Expected external caller cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let cancelled = probe.snapshot()
            XCTAssertEqual(cancelled.activeCount, 1, "Owned work after caller cancellation: \(cancelled)")
            XCTAssertEqual(cancelled.foregroundCount(for: .interactiveRead), 1)
            XCTAssertEqual(cancelled.activeCount(for: .codemap), 0)
            XCTAssertEqual(cancelled.queuedCount(for: .codemap), 1)
            let grantedAfterCallerCancellation = await codeMap.granted.isSignaledSnapshot()
            XCTAssertFalse(grantedAfterCallerCancellation)

            physicalGate.release()
            guard let codeMapResult = await waitForTaskResult(codeMap.task) else {
                return XCTFail("Queued CodeMap work did not settle after physical release")
            }
            try codeMapResult.get()
            let grantedAfterRelease = await codeMap.granted.isSignaledSnapshot()
            XCTAssertTrue(grantedAfterRelease)
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testSharedLimiterQueueFullPropagatesThroughStoreAndExternalReadPaths() async throws {
        let rootURL = try makeTemporaryRoot()
        try "queue full\n".write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded file record")
        }

        let homeURL = try makeTemporaryRoot()
        let skillsURL = homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        let externalURL = skillsURL.appendingPathComponent("External.md")
        try "external queue full\n".write(to: externalURL, atomically: true, encoding: .utf8)
        let readableService = WorkspaceReadableFileService(store: store, homeDirectoryURL: homeURL)
        let externalFile = WorkspaceExternalReadableFile(
            absolutePath: externalURL.path,
            displayPath: "~/.agents/skills/External.md"
        )

        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe

        await probe.observe {
            guard let saturation = await saturateSharedContentReadLimiter(cleanup: cleanup) else {
                return XCTFail("Shared content-read limiter did not reach its production bounds")
            }
            let saturated = probe.snapshot()
            XCTAssertEqual(saturated.activeCount, saturation.capacity, "Owned saturation: \(saturated)")
            XCTAssertEqual(saturated.queuedCount, saturation.maxQueuedWaiterCount)
            let expected = ContentReadSchedulerError.queueFull(retryAfterMilliseconds: 1000)

            do {
                _ = try await store.searchContentSnapshot(for: record)
                XCTFail("Expected search fingerprint backpressure")
            } catch {
                XCTAssertEqual(error as? ContentReadSchedulerError, expected)
            }
            do {
                _ = try await store.interactiveReadSnapshot(for: record)
                XCTFail("Expected interactive fingerprint backpressure")
            } catch {
                XCTAssertEqual(error as? ContentReadSchedulerError, expected)
            }
            do {
                _ = try await MCPServerViewModel.prepareAlwaysReadableExternalFileThroughEnvelopeForTesting(
                    externalFile,
                    readableService: readableService
                )
                XCTFail("Expected view-model external-read backpressure")
            } catch {
                XCTAssertEqual(error as? ContentReadSchedulerError, expected)
            }
            let rejected = probe.snapshot()
            XCTAssertEqual(rejected.queueFullCount, 3, "Owned queue-full rejections: \(rejected)")

            await cleanup.run()
            let afterSaturation = await waitForLimiterIdle()
            XCTAssertTrue(afterSaturation.isIdle, "Shared limiter was not idle after saturation")
        }
    }

    func testAllowlistedExternalReadCancellationKeepsSharedPermitUntilPhysicalReturn() async throws {
        let homeURL = try makeTemporaryRoot()
        let skillsURL = homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        let fileURL = skillsURL.appendingPathComponent("External.md")
        try "external read\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let physicalGate = SynchronousPhysicalReadGate()
        let readableService = WorkspaceReadableFileService(
            store: WorkspaceFileContextStore(),
            homeDirectoryURL: homeURL,
            beforeExternalReadOpenForTesting: { _ in physicalGate.blockUntilReleased() }
        )
        let file = WorkspaceExternalReadableFile(absolutePath: fileURL.path, displayPath: "~/.agents/skills/External.md")
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener { physicalGate.release() }

        await probe.observe {
            let task = Task { try await readableService.readAlwaysReadableExternalFile(file) }
            cleanup.retain(task, "External read caller")
            guard await waitUntil({ physicalGate.isBlockedSnapshot() }) else {
                return XCTFail("External read did not reach the controlled open gate")
            }

            task.cancel()
            guard let taskResult = await waitForTaskResult(task) else {
                return XCTFail("External read caller did not settle after cancellation")
            }
            do {
                _ = try taskResult.get()
                XCTFail("Expected external read cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let blocked = probe.snapshot()
            XCTAssertEqual(blocked.activeCount, 1, "Owned work while the physical read is blocked: \(blocked)")
            XCTAssertEqual(blocked.liveProducerCount, 1)

            physicalGate.release()
            await assertOwnedContentReadWorkSettles(probe)
        }
    }

    func testStreamedDecodeUsesReadFileRecorderCapturedBeforeDetachment() async throws {
        let rootURL = try makeTemporaryRoot()
        let contents = "first\nsecond\nthird\n"
        try contents.write(
            to: rootURL.appendingPathComponent("Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await FileSystemService(path: rootURL.path)
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        cleanup.addHookReset { MCPToolWorkCountDiagnostics.resetForTesting() }
        MCPToolWorkCountDiagnostics.resetForTesting()

        try await cleanup.probe.observe {
            try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
                let loaded = try await service.loadEntireFileContentOptimized(
                    ofRelativePath: "Target.swift",
                    chunkSize: 4,
                    workloadClass: .interactiveRead
                )
                XCTAssertEqual(loaded, contents)
            }
        }

        let snapshots = MCPToolWorkCountDiagnostics.debugSnapshots().readFile
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.source, "disk")
        XCTAssertEqual(snapshots.first?.readBytes, contents.utf8.count)
        XCTAssertEqual(snapshots.first?.diskReadRecordCount, 2)
    }

    /// Fills every permit and queue slot of the process-wide limiter. Call it after the drain
    /// precondition. The cleanup owns the release gate and every saturating task, so a failed
    /// fill is joined in teardown like any other scenario work.
    private func saturateSharedContentReadLimiter(
        cleanup: ContentReadScenarioCleanup
    ) async -> SharedLimiterSaturation? {
        let bounds = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        let releaseActiveReads = AsyncSignal()
        cleanup.addGateOpener { await releaseActiveReads.signal() }
        let activeTasks: [Task<Void, Error>] = (0 ..< bounds.capacity).map { _ in
            Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .interactiveRead,
                    schedulerOwnerID: UUID(),
                    priority: .userInitiated
                ) {
                    await releaseActiveReads.wait()
                }
            }
        }
        activeTasks.forEach { cleanup.retain($0, "Saturating active read") }
        let allPermitsHeld = await waitUntil {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.activePermitCount == snapshot.capacity
        }
        guard allPermitsHeld else { return nil }

        let queuedTasks: [Task<Void, Error>] = (0 ..< bounds.maxQueuedWaiterCount).map { _ in
            Task {
                try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                    workloadClass: .contentSearch,
                    schedulerOwnerID: UUID(),
                    priority: .utility
                ) {}
            }
        }
        queuedTasks.forEach { cleanup.retain($0, "Saturating queued read") }
        let queueDidFill = await waitUntil {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return snapshot.activePermitCount == snapshot.capacity
                && snapshot.queuedWaiterCount == snapshot.maxQueuedWaiterCount
        }
        guard queueDidFill else { return nil }
        return SharedLimiterSaturation(
            capacity: bounds.capacity,
            maxQueuedWaiterCount: bounds.maxQueuedWaiterCount
        )
    }

    private func waitForLimiterSnapshot(
        _ limiter: ContentReadAsyncLimiter,
        matching predicate: (ContentReadAsyncLimiter.Snapshot) -> Bool
    ) async -> ContentReadAsyncLimiter.Snapshot {
        await pollContentReadState({ await limiter.snapshotForTesting() }, until: predicate)
    }

    private func waitForCacheSnapshot(
        _ cache: WorkspaceInteractiveReadCache,
        matching predicate: (WorkspaceInteractiveReadCache.Snapshot) -> Bool
    ) async -> WorkspaceInteractiveReadCache.Snapshot {
        await pollContentReadState({ await cache.snapshotForTesting() }, until: predicate)
    }

    private func makeInteractiveReadCacheKey() -> WorkspaceInteractiveReadCacheKey {
        WorkspaceInteractiveReadCacheKey(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            fileID: UUID(),
            standardizedRelativePath: "Target.swift"
        )
    }

    private func makeFingerprint() -> FileContentFingerprint {
        FileContentFingerprint(
            deviceID: 1,
            fileNumber: 2,
            byteSize: 3,
            modificationSeconds: 4,
            modificationNanoseconds: 5,
            statusChangeSeconds: 6,
            statusChangeNanoseconds: 7
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("ContentReadCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class ApplyEditsBoundedPreviewReadTests: XCTestCase {
    func testPreviewReadTimesOutBehindDetachedStructureReadAndRecovers() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("ApplyEditsBoundedPreviewRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("Target.swift")
        let original = "let value = 0\n"
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        guard let record = await store.file(rootID: root.id, relativePath: "Target.swift") else {
            return XCTFail("Expected loaded target file")
        }
        let roots = await store.rootRefs(scope: .visibleWorkspace)

        let releaseFillerPermits = AsyncSignal()
        let physicalReadGate = SynchronousPhysicalReadGate()
        let providerRelease = AsyncSignal()
        let clock = SynchronousDurationClock()
        let sleeps = ControlledWatchdogSleeps(clock: clock)
        guard let cleanup = await startOwnedContentReadScenario() else { return }
        let probe = cleanup.probe
        cleanup.addGateOpener {
            await releaseFillerPermits.signal()
            physicalReadGate.release()
            await providerRelease.signal()
        }
        cleanup.addSleeperRelease { await sleeps.releaseAll() }
        cleanup.addHookReset { try? await store.setContentPhysicalReadHandlerForTesting(rootID: root.id, nil) }
        let capacity = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting().capacity

        try await probe.observe {
            let fillerTasks: [Task<Void, Error>] = (1 ..< capacity).map { _ in
                Task {
                    try await FileSystemService.withCancellationResponsivePhysicalReadPermit(
                        workloadClass: .interactiveRead,
                        schedulerOwnerID: UUID(),
                        priority: .userInitiated
                    ) {
                        await releaseFillerPermits.wait()
                    }
                }
            }
            fillerTasks.forEach { cleanup.retain($0, "Filler read") }
            guard await waitUntil({ probe.snapshot().activeCount == capacity - 1 }) else {
                return XCTFail("Could not reserve the content-read filler permits; owned work: \(probe.snapshot())")
            }

            try await store.setContentPhysicalReadHandlerForTesting(rootID: root.id) {
                physicalReadGate.blockUntilReleased()
            }

            let registry = MCPCodeStructureSettlementRegistry()
            let admission = registry.admit(
                windowID: 958,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.readFile,
                now: clock.now(),
                handlerPhase: { MCPToolExecutionHandlerPhase.readFileContentRead.rawValue }
            )
            guard case let .admitted(slot) = admission else {
                return XCTFail("Structure provider was not admitted")
            }
            let watchdogTask = Task { () -> Result<Void, Error> in
                do {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: .seconds(30),
                        cancellationGrace: .seconds(5),
                        cleanupDisposition: .detachAndSettle,
                        settlementSlot: slot,
                        environment: MCPToolExecutionWatchdogEnvironment(
                            now: { clock.now() },
                            sleep: { duration in try await sleeps.sleep(for: duration) }
                        )
                    ) {
                        do {
                            try await runDomainReadProviderTask(store: store, record: record, roots: roots)
                        } catch {
                            await providerRelease.wait()
                            throw error
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            cleanup.retain(watchdogTask, "Watchdog-wrapped structure provider")

            guard await waitUntil({ physicalReadGate.isBlockedSnapshot() }) else {
                return XCTFail("Structure read did not reach the physical gate")
            }
            let saturated = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            XCTAssertEqual(saturated.activePermitCount, saturated.capacity)
            guard await waitUntil({ await sleeps.pendingCountSnapshot() == 1 }), await sleeps.releaseNext() else {
                return XCTFail("Structure watchdog deadline did not advance")
            }
            guard await waitUntil({ await sleeps.pendingCountSnapshot() == 1 }), await sleeps.releaseNext() else {
                return XCTFail("Structure watchdog cleanup grace did not advance")
            }
            guard let observedWatchdog = await waitForTaskResult(watchdogTask) else {
                return XCTFail("Structure watchdog did not finish")
            }
            let watchdogResult = observedWatchdog.get()
            guard case let .failure(watchdogError) = watchdogResult else {
                return XCTFail("Expected the structure provider to detach")
            }
            XCTAssertEqual(watchdogError as? MCPToolExecutionWatchdogError, .executionDetached)

            guard case .busy = registry.admit(
                windowID: 958,
                connectionID: UUID(),
                invocationID: UUID(),
                toolName: MCPWindowToolName.getCodeStructure,
                now: clock.now(),
                handlerPhase: { nil }
            ) else {
                return XCTFail("Detached structure provider should fence the next structure call")
            }

            let blockedHost = WorkspaceFileEditHost(
                store: store,
                target: .existing(record),
                previewReadTimeout: .milliseconds(20)
            )
            let request = ApplyEditsRequest(
                path: fileURL.path,
                mode: .single(search: "value", replace: "updated", replaceAll: false),
                verbose: false
            )
            let start = ContinuousClock().now
            do {
                _ = try await ApplyEditsService(engine: .default, host: blockedHost).run(request)
                XCTFail("Expected the bounded preview read to fail")
            } catch let failure as MCPMutationRetryableFailure {
                XCTAssertEqual(failure.errorCode, "apply_edits_read_busy")
                XCTAssertTrue(failure.retryable)
                XCTAssertTrue(failure.errorMessage.contains("previous read of the file is still settling"))
            }
            XCTAssertLessThan(ContinuousClock().now - start, .seconds(1))
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), original)

            physicalReadGate.release()
            await providerRelease.signal()
            await releaseFillerPermits.signal()
            for task in fillerTasks {
                _ = try await task.value
            }
            let registrySettled = await waitUntil {
                registry.snapshot(windowID: 958) == .init(activeCount: 0, detachedCount: 0)
            }
            XCTAssertTrue(registrySettled)
            await assertOwnedContentReadWorkSettles(probe)
            let limiterSnapshot = await waitForLimiterIdle()
            XCTAssertTrue(limiterSnapshot.isIdle)

            let recovered = try await ApplyEditsService(
                engine: .default,
                host: WorkspaceFileEditHost(store: store, target: .existing(record))
            ).run(request)
            XCTAssertEqual(recovered.editsApplied, 1)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "let updated = 0\n")
        }
    }
}

/// Polls measure elapsed time rather than count `Task.yield()` calls, because runner load can
/// delay the awaited work by any number of yields. The timeout guards against hangs; gates and
/// controlled watchdog sleepers order the events under test.
private let contentReadPollTimeout: Duration = .seconds(30)
private let contentReadPollInterval: Duration = .milliseconds(1)

/// Returns the first read that matches, or one final read once the deadline passes or the
/// waiting task is cancelled. The deadline is checked between reads, so it can't interrupt a
/// read that never returns.
private func pollContentReadState<State>(
    _ read: () async -> State,
    until predicate: (State) -> Bool
) async -> State {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: contentReadPollTimeout)
    while clock.now < deadline {
        let state = await read()
        if predicate(state) { return state }
        // A cancelled task makes every sleep throw immediately; stop instead of hot-polling.
        do { try await Task.sleep(for: contentReadPollInterval) } catch { break }
    }
    return await read()
}

private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
    await pollContentReadState(predicate, until: { $0 })
}

private func waitForTaskResult<Success: Sendable, Failure: Error & Sendable>(
    _ task: Task<Success, Failure>
) async -> Result<Success, Failure>? {
    let recorder = TaskResultRecorder<Success, Failure>()
    Task { await recorder.record(task.result) }
    guard await waitUntil({ await recorder.hasResult() }) else { return nil }
    return await recorder.snapshot()
}

private func waitForLimiterIdle() async -> ContentReadAsyncLimiter.Snapshot {
    await pollContentReadState(
        { await FileSystemService.contentReadWorkerLimiterSnapshotForTesting() },
        until: \.isIdle
    )
}

/// Waits for content-read work that already occupies the process-wide limiter, such as detached
/// producers left by earlier tests, so the scenario starts with the limiter's full capacity.
/// This prepares the environment; the probe's owned assertions carry the scenario's contract.
/// On timeout the scenario must not start, and the failure names the leftover work.
private func sharedContentReadLimiterDrained(
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Bool {
    let snapshot = await waitForLimiterIdle()
    guard !snapshot.isIdle else { return true }
    XCTFail(
        """
        Pre-existing shared content-read work did not drain before the scenario started: \
        capacity \(snapshot.capacity), active \(snapshot.activePermitCount), \
        queued \(snapshot.queuedWaiterCount), active by workload \(snapshot.activePermitCountsByWorkload), \
        foreground by kind \(snapshot.foregroundActivityCountsByKind), \
        active by owner \(snapshot.activePermitCountsByOwner)
        """,
        file: file,
        line: line
    )
    return false
}

private extension XCTestCase {
    /// Drains leftover shared-limiter work, then gives the test a fresh probe and registers its
    /// cleanup for teardown. Returns nil, after recording the failure, when the drain times out.
    func startOwnedContentReadScenario(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> ContentReadScenarioCleanup? {
        guard await sharedContentReadLimiterDrained(file: file, line: line) else { return nil }
        let cleanup = ContentReadScenarioCleanup(probe: ContentReadTestProbe())
        addTeardownBlock { await cleanup.run(file: file, line: line) }
        return cleanup
    }
}

/// Waits until the probe's own producers, permits, waiters, and foreground tokens have all
/// finished, then requires that every observed event formed a valid sequence.
private func assertOwnedContentReadWorkSettles(
    _ probe: ContentReadTestProbe,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let snapshot = await pollContentReadState({ probe.snapshot() }, until: \.isSettled)
    XCTAssertTrue(snapshot.isSettled, "Owned content-read work did not settle: \(snapshot)", file: file, line: line)
    XCTAssertEqual(snapshot.violations, [], "Owned content-read events were out of sequence", file: file, line: line)
}

/// Tracks the content-read work one test starts, from the limiter's DEBUG observation events,
/// so its assertions never count permits, waiters, or foreground activity that other tests
/// left in the process-wide limiter.
private final class ContentReadTestProbe: @unchecked Sendable {
    struct Snapshot: CustomStringConvertible {
        let liveProducerCount: Int
        let activeCountsByWorkload: [ContentReadWorkloadClass: Int]
        let queuedCountsByWorkload: [ContentReadWorkloadClass: Int]
        let activeCountsByOwner: [UUID: Int]
        let foregroundCountsByKind: [ContentReadForegroundActivityKind: Int]
        let grantCount: Int
        let queueFullCount: Int
        let observedProducerCount: Int
        let observedAttemptCount: Int
        let violations: [String]

        var activeCount: Int {
            activeCountsByWorkload.values.reduce(0, +)
        }

        var queuedCount: Int {
            queuedCountsByWorkload.values.reduce(0, +)
        }

        var foregroundCount: Int {
            foregroundCountsByKind.values.reduce(0, +)
        }

        func activeCount(for workload: ContentReadWorkloadClass) -> Int {
            activeCountsByWorkload[workload, default: 0]
        }

        func queuedCount(for workload: ContentReadWorkloadClass) -> Int {
            queuedCountsByWorkload[workload, default: 0]
        }

        func foregroundCount(for kind: ContentReadForegroundActivityKind) -> Int {
            foregroundCountsByKind[kind, default: 0]
        }

        /// An empty probe is never settled. If the sink stopped reaching the limiter, every
        /// settlement check would otherwise pass without observing anything.
        var isSettled: Bool {
            observedProducerCount + observedAttemptCount > 0
                && liveProducerCount == 0
                && activeCount == 0
                && queuedCount == 0
                && foregroundCount == 0
        }

        var description: String {
            """
            producers live \(liveProducerCount) of \(observedProducerCount) observed; \
            attempts observed \(observedAttemptCount); \
            active \(Self.describe(activeCountsByWorkload)); \
            queued \(Self.describe(queuedCountsByWorkload)); \
            foreground \(Self.describe(foregroundCountsByKind)); \
            grants \(grantCount); queue full \(queueFullCount); violations \(violations)
            """
        }

        private static func describe<Key: RawRepresentable>(_ counts: [Key: Int]) -> String
            where Key.RawValue == String
        {
            "[" + counts.map { "\($0.key.rawValue): \($0.value)" }.sorted().joined(separator: ", ") + "]"
        }
    }

    private let lock = NSLock()
    private var liveProducerIDs: Set<UUID> = []
    private var observedProducerIDs: Set<UUID> = []
    private var queuedAttempts: [UUID: ContentReadTestAttempt] = [:]
    private var activeAttempts: [UUID: ContentReadTestAttempt] = [:]
    private var observedAttemptIDs: Set<UUID> = []
    private var foregroundKindsByID: [UUID: ContentReadForegroundActivityKind] = [:]
    private var observedForegroundIDs: Set<UUID> = []
    private var grantCount = 0
    private var queueFullCount = 0
    private var violations: [String] = []

    /// Runs `body` with this probe as the task-local sink. Child tasks created inside `body`
    /// inherit it, so open the scope before the scenario creates its first task.
    func observe(_ body: () async throws -> Void) async rethrows {
        try await ContentReadTestObservation.$sink.withValue({ [self] event in record(event) }) { try await body() }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            liveProducerCount: liveProducerIDs.count,
            activeCountsByWorkload: Self.counts(activeAttempts.values, by: \.workloadClass),
            queuedCountsByWorkload: Self.counts(queuedAttempts.values, by: \.workloadClass),
            activeCountsByOwner: Self.counts(activeAttempts.values, by: \.ownerID),
            foregroundCountsByKind: Dictionary(grouping: foregroundKindsByID.values, by: { $0 }).mapValues(\.count),
            grantCount: grantCount,
            queueFullCount: queueFullCount,
            observedProducerCount: observedProducerIDs.count,
            observedAttemptCount: observedAttemptIDs.count,
            violations: violations
        )
    }

    /// Records every transition, including impossible ones, as state or a violation. The sink
    /// can run inside the limiter actor, so it only updates memory under the lock.
    private func record(_ event: ContentReadTestEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .producerStarted(id):
            if observedProducerIDs.insert(id).inserted {
                liveProducerIDs.insert(id)
            } else {
                violations.append("producer \(id) started twice")
            }
        case let .producerFinished(id):
            if liveProducerIDs.remove(id) == nil {
                violations.append("producer \(id) finished without a live start")
            }
        case let .queued(attempt):
            if observedAttemptIDs.insert(attempt.id).inserted {
                queuedAttempts[attempt.id] = attempt
            } else {
                violations.append("attempt \(attempt.id) queued after an earlier transition")
            }
        case let .granted(attempt):
            // A grant either dequeues a queued attempt or is the first transition of a direct grant.
            if queuedAttempts.removeValue(forKey: attempt.id) != nil || observedAttemptIDs.insert(attempt.id).inserted {
                activeAttempts[attempt.id] = attempt
                grantCount += 1
            } else {
                violations.append("attempt \(attempt.id) granted while neither queued nor new")
            }
        case let .cancelledWhileQueued(attempt):
            if queuedAttempts.removeValue(forKey: attempt.id) == nil {
                violations.append("attempt \(attempt.id) cancelled while not queued")
            }
        case let .released(attempt):
            if activeAttempts.removeValue(forKey: attempt.id) == nil {
                violations.append("attempt \(attempt.id) released while not active")
            }
        case let .queueFull(attempt, _):
            if observedAttemptIDs.insert(attempt.id).inserted {
                queueFullCount += 1
            } else {
                violations.append("attempt \(attempt.id) rejected as queue full after an earlier transition")
            }
        case let .foregroundBegan(id, kind):
            if observedForegroundIDs.insert(id).inserted {
                foregroundKindsByID[id] = kind
            } else {
                violations.append("foreground activity \(id) began twice")
            }
        case let .foregroundEnded(id):
            if foregroundKindsByID.removeValue(forKey: id) == nil {
                violations.append("foreground activity \(id) ended without a live start")
            }
        }
    }

    private static func counts<Key: Hashable>(
        _ attempts: Dictionary<UUID, ContentReadTestAttempt>.Values,
        by key: KeyPath<ContentReadTestAttempt, Key>
    ) -> [Key: Int] {
        Dictionary(grouping: attempts, by: { $0[keyPath: key] }).mapValues(\.count)
    }
}

/// Cleanup for one test's shared-limiter scenario. Teardown runs it on every exit path, and a
/// test may also run it after its last assertion, so every step is safe to repeat. It opens
/// gates, cancels retained tasks, then releases controlled watchdog sleepers before joining
/// tasks, because a retained task can be blocked on any of them. It resets test hooks only
/// after the probe's detached producers have finished with them.
private final class ContentReadScenarioCleanup: @unchecked Sendable {
    private struct RetainedTask {
        let description: String
        let cancel: @Sendable () -> Void
        let settles: @Sendable () async -> Bool
    }

    let probe: ContentReadTestProbe
    private let lock = NSLock()
    private var gateOpeners: [@Sendable () async -> Void] = []
    private var retainedTasks: [RetainedTask] = []
    private var sleeperReleases: [@Sendable () async -> Void] = []
    private var hookResets: [@Sendable () async -> Void] = []

    init(probe: ContentReadTestProbe) {
        self.probe = probe
    }

    func addGateOpener(_ open: @escaping @Sendable () async -> Void) {
        lock.withLock { gateOpeners.append(open) }
    }

    func addSleeperRelease(_ release: @escaping @Sendable () async -> Void) {
        lock.withLock { sleeperReleases.append(release) }
    }

    func retain(_ task: Task<some Sendable, some Error & Sendable>, _ description: String) {
        let retained = RetainedTask(
            description: description,
            cancel: { task.cancel() },
            settles: { await waitForTaskResult(task) != nil }
        )
        lock.withLock { retainedTasks.append(retained) }
    }

    func addHookReset(_ reset: @escaping @Sendable () async -> Void) {
        lock.withLock { hookResets.append(reset) }
    }

    func run(file: StaticString = #filePath, line: UInt = #line) async {
        let (openers, tasks, sleepers, resets) = lock.withLock {
            (gateOpeners, retainedTasks, sleeperReleases, hookResets)
        }

        for open in openers {
            await open()
        }
        for task in tasks {
            task.cancel()
        }
        for release in sleepers {
            await release()
        }
        for task in tasks {
            let settled = await task.settles()
            XCTAssertTrue(settled, "\(task.description) did not settle during cleanup", file: file, line: line)
        }
        await assertOwnedContentReadWorkSettles(probe, file: file, line: line)
        for reset in resets {
            await reset()
        }
    }
}

@MainActor
private func runMainActorProviderTask(
    store: WorkspaceFileContextStore,
    record: WorkspaceFileRecord,
    roots: [WorkspaceRootRef]
) async throws {
    // `MCPServerViewModel.runTool` creates this task while isolated to MainActor.
    let providerTask = Task {
        let readableService = WorkspaceReadableFileService(store: store)
        let resolution = try await readableService.resolveReadFileRequest(
            .relative(record.standardizedRelativePath),
            rootScope: .visibleWorkspace,
            rootRefs: roots,
            namespace: .identity(roots: roots)
        )
        guard case let .workspace(match) = resolution else {
            throw PhysicalReadTestError.syntheticFailure
        }
        _ = try await store.interactiveReadSnapshot(for: match.file)
    }
    return try await withTaskCancellationHandler {
        try await providerTask.value
    } onCancel: {
        providerTask.cancel()
    }
}

@MainActor
private func runAppBinderProviderTask<T: Sendable>(
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    // `MCPServerViewModel.runTool` creates this task while isolated to MainActor.
    let providerTask = Task {
        try Task.checkCancellation()
        return try await operation()
    }
    return try await withTaskCancellationHandler {
        try await providerTask.value
    } onCancel: {
        providerTask.cancel()
    }
}

private func runDomainHostProviderTask(
    operation: @Sendable @escaping () async throws -> Void
) async throws {
    // `MCPDomainHost.invoke` owns an unstructured invocation task and forwards caller cancellation.
    let invocationTask = Task {
        try Task.checkCancellation()
        try await operation()
    }
    return try await withTaskCancellationHandler {
        try await invocationTask.value
    } onCancel: {
        invocationTask.cancel()
    }
}

private func runDomainReadProviderTask(
    store: WorkspaceFileContextStore,
    record: WorkspaceFileRecord,
    roots: [WorkspaceRootRef]
) async throws {
    try await runDomainReadProviderTask(path: record.standardizedRelativePath) {
        try await runMainActorProviderTask(store: store, record: record, roots: roots)
    }
}

private func runDomainReadProviderTask(
    path: String,
    operation: @Sendable @escaping () async throws -> Void
) async throws {
    let runtimeIdentity = DomainRuntimeIdentity(
        runtimeID: UUID(),
        lifecycleGeneration: 1,
        processID: 949,
        mode: .app,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let connectionID = UUID()
    let context = DomainReadInvocationContext(
        handle: DomainReadContextHandle(
            runtimeID: runtimeIdentity.runtimeID,
            runtimeGeneration: runtimeIdentity.lifecycleGeneration,
            connectionID: connectionID,
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 1,
            contextRevision: 1,
            routingRevision: 1,
            bindingKind: .explicit
        ),
        connectionID: connectionID
    )
    let provider = MCPDomainReadToolProvider(
        resolveContext: { _, _ in context },
        backend: MCPDomainReadToolBackend { _, _, _, _ in
            try await operation()
            return .null
        },
        sideEffects: DomainReadSideEffectCoordinator(identity: runtimeIdentity)
    )
    let readFile = try XCTUnwrap(provider.binding(named: MCPWindowToolName.readFile))
    _ = try await readFile(["path": .string(path)])
}

private struct SharedLimiterSaturation {
    let capacity: Int
    let maxQueuedWaiterCount: Int
}

/// A Code Map permit request retained by one test's cleanup. Create it inside the probe's
/// `observe` scope so the probe records its limiter attempt; `granted` signals once the permit
/// body runs.
private struct CodeMapPermitRequest {
    let task: Task<Void, Error>
    let granted: AsyncSignal

    init(retainedBy cleanup: ContentReadScenarioCleanup) {
        let granted = AsyncSignal()
        self.granted = granted
        task = Task {
            try await FileSystemService.withCodeMapArtifactBuildPermit(
                ownerID: UUID(),
                priority: .utility
            ) {
                await granted.signal()
            }
        }
        cleanup.retain(task, "CodeMap permit request")
    }

    /// True once the request is queued in the probe or already granted. A grant also ends the
    /// wait, so broken suppression fails the caller's held-state assertions at once instead of
    /// timing out the wait.
    func queuedOrGranted(in probe: ContentReadTestProbe) async -> Bool {
        if probe.snapshot().queuedCount(for: .codemap) == 1 { return true }
        return await granted.isSignaledSnapshot()
    }
}

private actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func isSignaledSnapshot() -> Bool {
        isSignaled
    }
}

private actor CancellableTestGate {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    private func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    func releaseAll() {
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor TaskResultRecorder<Success: Sendable, Failure: Error & Sendable> {
    private var result: Result<Success, Failure>?

    func record(_ result: Result<Success, Failure>) {
        self.result = result
    }

    func hasResult() -> Bool {
        result != nil
    }

    func snapshot() -> Result<Success, Failure>? {
        result
    }
}

private enum PhysicalReadTestError: Error {
    case syntheticFailure
}

private final class SendableObjectRetention: @unchecked Sendable {
    private let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }
}

private final class SynchronousPhysicalReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blockedCount = 0
    private var isReleased = false

    func blockUntilReleased() {
        condition.lock()
        blockedCount += 1
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func isBlockedSnapshot() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blockedCount > 0
    }

    func blockedCountSnapshot() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return blockedCount
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class SynchronousInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class PeriodicPhysicalReadGates: @unchecked Sendable {
    private let condition = NSCondition()
    private var probeCount = 0
    private var blockedIndices: Set<Int> = []
    private var releasedIndices: Set<Int> = []
    private let interval: Int
    private let gates: Int

    init(interval: Int, count: Int) {
        self.interval = interval
        gates = count
    }

    func reachNextProbe() {
        condition.lock()
        probeCount += 1
        guard probeCount.isMultiple(of: interval) else {
            condition.unlock()
            return
        }
        let index = probeCount / interval - 1
        guard index < gates else {
            condition.unlock()
            return
        }
        blockedIndices.insert(index)
        condition.broadcast()
        while !releasedIndices.contains(index) {
            condition.wait()
        }
        condition.unlock()
    }

    func isBlocked(at index: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blockedIndices.contains(index)
    }

    func releaseAll() {
        condition.lock()
        releasedIndices.formUnion(0 ..< gates)
        condition.broadcast()
        condition.unlock()
    }
}

private final class PhysicalReadAttributionRecorder: @unchecked Sendable {
    struct Snapshot {
        let lifecycleCorrelationID: UUID?
        let benchmarkMetricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?
    }

    private let lock = NSLock()
    private var value: Snapshot?

    func record(
        lifecycleCorrelationID: UUID?,
        benchmarkMetricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?
    ) {
        lock.lock()
        value = Snapshot(
            lifecycleCorrelationID: lifecycleCorrelationID,
            benchmarkMetricTag: benchmarkMetricTag
        )
        lock.unlock()
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor ControlledWatchdogSleeps {
    private let clock: SynchronousDurationClock
    private var registeredCount = 0
    private var sleepers: [(duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []

    init(clock: SynchronousDurationClock) {
        self.clock = clock
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            registeredCount += 1
            sleepers.append((duration, continuation))
        }
    }

    func registeredCountSnapshot() -> Int {
        registeredCount
    }

    func pendingCountSnapshot() -> Int {
        sleepers.count
    }

    @discardableResult
    func releaseNext() -> Bool {
        guard !sleepers.isEmpty else { return false }
        let sleeper = sleepers.removeFirst()
        clock.advance(by: sleeper.duration)
        sleeper.continuation.resume()
        return true
    }

    func releaseAll() {
        let pending = sleepers
        sleepers.removeAll()
        pending.forEach { $0.continuation.resume() }
    }
}

private final class SynchronousDurationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Duration.zero

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant += duration
        lock.unlock()
    }
}

private actor WatchdogEventRecorder {
    private var events: [MCPToolExecutionWatchdogEvent] = []

    func record(_ event: MCPToolExecutionWatchdogEvent) {
        events.append(event)
    }

    func snapshot() -> [MCPToolExecutionWatchdogEvent] {
        events
    }
}

private actor SettlementRecorder {
    private var settlement: MCPToolExecutionSettlement?

    func record(_ settlement: MCPToolExecutionSettlement) {
        self.settlement = settlement
    }

    func snapshot() -> MCPToolExecutionSettlement? {
        settlement
    }
}
