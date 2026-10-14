import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class PipeEndpointTests: XCTestCase {
    func testRetireStopsABlockedWriterWithoutReleasingItsDescriptor() throws {
        let pipe = Pipe()
        // The test holds the read end and never reads it, so the writer blocks once the pipe fills.
        let readEnd = try PipeEndpoint(adopting: pipe.fileHandleForReading, role: .output)
        let writeEnd = try PipeEndpoint(adopting: pipe.fileHandleForWriting, role: .input)
        let writeFinished = DispatchSemaphore(value: 0)
        let mayClose = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let writeOutcome = WriteOutcome()
        addTeardownBlock {
            // Closing the read end makes a writer the test failed to stop fail with EPIPE.
            mayClose.signal()
            readEnd.close()
        }

        DispatchQueue.global().async {
            do {
                try FDWriteSupport.writeAll(Data(count: 1 << 20), to: writeEnd.fd)
                writeOutcome.set(nil)
            } catch {
                writeOutcome.set(error)
            }
            writeFinished.signal()
            mayClose.wait()
            writeEnd.close()
            closed.signal()
        }

        // Bytes in the pipe mean the writer is inside its one `write(2)`, which cannot finish:
        // 1 MiB is larger than any pipe buffer.
        let deadline = Date().addingTimeInterval(10)
        while (readEnd.bufferedByteCount() ?? 0) == 0, Date() < deadline {
            usleep(1000)
        }
        XCTAssertGreaterThan(readEnd.bufferedByteCount() ?? 0, 0, "the writer never started writing")

        writeEnd.retire()

        XCTAssertEqual(writeFinished.wait(timeout: .now() + 10), .success, "retire() did not wake the writer")
        switch writeOutcome.error as? FDWriteError {
        case .brokenPipe, .badDescriptor:
            break
        default:
            XCTFail("expected brokenPipe or badDescriptor, got \(String(describing: writeOutcome.error))")
        }
        XCTAssertFalse(writeEnd.isOpen)
        let descriptorFlags = fcntl(writeEnd.fd, F_GETFD)
        XCTAssertNotEqual(descriptorFlags, -1, "the descriptor number was released before its owner closed it")
        XCTAssertEqual(descriptorFlags & FD_CLOEXEC, FD_CLOEXEC)

        var sentinel: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.pipe(&sentinel), 0)
        XCTAssertFalse(sentinel.contains(writeEnd.fd))
        sentinel.forEach { Darwin.close($0) }

        mayClose.signal()
        XCTAssertEqual(closed.wait(timeout: .now() + 10), .success)
    }
}

private final class WriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func set(_ error: Error?) {
        lock.withLock { storedError = error }
    }
}
