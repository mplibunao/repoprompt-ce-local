# Investigation: Keychain prompt on the first launch of each local production build

> Investigation report, observed 2026-10-15 on local build 53. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Install a local production build.

## Summary

Each newly signed local production build gets a new Keychain partition ID. Every item in a file-based macOS keychain has a partition list, a list of code identities that `securityd` checks, separately from the item's trusted applications, before a process may decrypt the item. `securityd` gives code that isn't signed by an Apple-issued certificate the partition ID `cdhash:<CDHash>`. The CDHash is the hash of the signature's code directory and identifies one exact signed binary, so it changes with every build. The first time a new build reads a stored secret, `securityd` doesn't find that partition ID in the item's partition list and asks the user to approve. Always Allow appends the new partition ID to the list, so later launches of the same build read silently.

The installer's continuity guarantees work as documented. Builds 43 through 53 use the same certificate fingerprint and Keychain service, and builds 52 and 53 have the same designated requirement. Those guarantees cover the check against the item's trusted applications. The partition list is a separate check that they don't reach. The hypothesis from the retrospective is right in substance. For this self-signed certificate, the partition list ties Keychain item access to the exact build.

No partition ID other than `cdhash:` can describe self-signed code, so nothing within the self-signed setup removes the prompt. Signing production with an Apple Development certificate does, because its partition ID is `teamid:<Team ID>`, which stays the same across builds.

## Scope

The question is why the prompt still appears although `docs/releasing.md` ("Install a local self-signed production build") pins the signing identity by certificate fingerprint. The investigation was read-only. It didn't stop, relaunch, or reinstall the production app, and it didn't read or change any Keychain item.

## Symptoms

- Production shows a macOS Keychain prompt on the first launch after each promotion, and none on later launches of the same build.
- The debug app never prompts, because ad-hoc debug builds keep secrets in memory (`EphemeralSecureKeyValueStore`).

## Evidence

### The signing identity is the same in every build

Installed build 53 and archived build 52 (`~/Archives/repoprompt-ce/local/v1.4.0-b52/app.zip`) have the same designated requirement, and build 52 satisfies build 53's requirement under `codesign --verify -R=`:

```text
identifier "com.pvncher.repoprompt.ce" and certificate leaf = H"<certificate hash>"
```

Both report `TeamIdentifier=not set`, which `Scripts/package_app.sh:497` requires of a local self-signed build. The archives of builds 43 to 52 each contain the same registry record as the installed app's `~/Library/Application Support/RepoPrompt CE/local-signing-identity-v1.json`: the same certificate SHA-256 and the same service generation. Each of those builds used the Keychain service `com.pvncher.repoprompt.ce.local-self-signed.<fingerprint>.keychain.v<generation>`.

The CDHash, read with `codesign -dvvv` from each build's main executable, was different for every build from b43 (signed 2026-09-23) through b53 (installed, signed 2026-10-15).

### The app stores secrets as file-based Keychain items with the default ACL

`SecureKeyValueStorageFactory.selection(for:)` maps the `.localSelfSigned` domain to `KeychainService.localSelfSigned(fingerprint:generation:)` (`Sources/RepoPrompt/Infrastructure/Security/SecureKeyValueStorageBackend.swift:119`). That service has no creation-attribute provider and no ACL validator. `KeychainService.add` (`KeychainService.swift:701`) calls `SecItemAdd` with neither `kSecUseDataProtectionKeychain` nor `kSecAttrAccess`. macOS stores such an item in the file-based login keychain with the default ACL it builds for the creating process. That ACL lists the creating app as a trusted application, checked against its designated requirement, and adds a partition list that contains the creating process's partition ID.

### `securityd` assigns self-signed code a per-build partition ID

`ClientIdentification::partitionIdForProcess` in Apple's `securityd/src/clientid.cpp` (apple-oss-distributions/Security) chooses the partition ID in this order:

1. Code that satisfies `anchor apple` gets `apple:`, or `apple-tool:` for `security(1)`.
2. Mac App Store and TestFlight code gets `teamid:` plus the embedded Team ID.
3. Developer ID code and Apple development or distribution code, meaning `anchor apple generic` plus the Apple Worldwide Developer Relations (WWDR) or Developer ID intermediate and leaf OIDs, gets `teamid:` plus the signing certificate's OU.
4. Any other signed code gets `cdhash:` plus the hex CDHash.

The local certificate is self-signed. The installer marks it trusted for code signing in the user's trust settings (`security add-trusted-cert -r trustRoot -p codeSign`, `Scripts/install_local_production.sh:140`), but user trust doesn't satisfy `anchor apple generic`. The app matches only the fourth case.

### A partition mismatch prompts, and Always Allow adds the new ID

In Apple's `securityd/src/acls.cpp`, `validatePartition` compares the client's partition ID with the item's partition list. When the ID is missing and UI is allowed for a read, `extendPartition` runs the item's keychain-prompt ACL entry. If the user approves, the callback calls `addClientPartitionID`, which writes the new ID into the item's list. That explains why the next launch of the same build doesn't prompt.

### Confirmed with a probe

A throwaway probe binary, rebuilt to get a second CDHash and run with Keychain UI turned off (`SecKeychainSetUserInteractionAllowed(false)`), created one generic-password item in the login keychain under a probe-only service, then deleted it. Results on macOS 26.6.2:

| Signing | Second build reads | Second build updates | Second build deletes |
| --- | --- | --- | --- |
| Self-signed (the local certificate) | `errSecAuthFailed` (-25293) | ok | `errSecInvalidOwnerEdit` (-25244) |
| Apple Development, Personal Team | ok | ok | `errSecInvalidOwnerEdit` (-25244) |
| Ad-hoc second build | `errSecAuthFailed` (-25293) | not run | not run |

The self-signed row is the per-build approval this investigation describes, and the Apple Development row shows a new build reading without approval. Deleting from a build other than the creator fails with either signing. Fix A is in pull request #192.

### What wasn't checked

The investigation didn't read the item ACLs themselves. The session's permission classifier blocked a read-only probe of ACL metadata as credential exploration, and the probe wasn't rerouted through another tool. The first confirmation check below covers it.

## Cause

The local self-signed signing design keeps the certificate, designated requirement, and service name stable, but the Keychain partition list is keyed to the CDHash for code that Apple's CA didn't sign. A new build needs one approval per stored item on its first launch. This follows the signed build, not the version number, so a rescue or retry rebuild of the same version prompts too.

## Related finding: "non-interactive" reads don't suppress this prompt

`KeychainAccessMode.nonInteractive` only adds `kSecUseAuthenticationUI: kSecUseAuthenticationUISkip` to the query (`KeychainService.swift:559-566`). On macOS, `SecItemCopyMatching` routes a query without `kSecUseDataProtectionKeychain` to both the data-protection and the file-based code path (`SecItemCategorizeQuery` in `OSX/libsecurity_keychain/lib/SecItem.cpp`). The file-based path, `SecItemCopyMatching_osx`, never reads `kSecUseAuthenticationUI`, and that file contains no reference to it. The launch settings load, which passes `.nonInteractive(reason: .bulkSettingsLoad)` (`APISettingsViewModel.swift:1156`), can still raise this prompt for file-based items.

This comes from reading the source and hasn't been observed yet. If it holds, the prompt appears during launch, before any provider request. It breaks the access-mode contract for every file-based backend, the official Developer ID backend included, so it needs its own issue. Making those reads truly non-interactive wouldn't remove the prompt. It would turn it into a silent read failure after each promotion until an interactive read prompts later.

## Proposed fixes

### A. Sign production with an Apple Development certificate (recommended)

An Apple Development certificate, including one from a free Personal Team, chains to the WWDR intermediate. Its leaf certificate has the Mac development extension (object identifier, or OID, `1.2.840.113635.100.6.1.12`) that this repository already requires in `RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement`. `securityd` then assigns `teamid:<Team ID>`, which stays the same across builds and across certificate renewals, so new builds stop prompting.

Tradeoffs:

- It needs an Apple ID signed in to Xcode and an Apple-issued certificate that expires and must be renewed through Xcode.
- The registry, the bundle metadata, and the designated requirement must pin the Team ID instead of the leaf certificate's fingerprint. Otherwise a certificate renewal would break continuity in the app's own policy while the Keychain partition ID stayed the same.
- The change touches `RuntimeCodeSigningPolicy` and its detector (a new signing-mode marker that requires the Team ID, where `local-self-signed` requires none at `RuntimeCodeSigningPolicy.swift:232`), `LocalSigningIdentityRegistry`, `Scripts/install_local_production.sh`, `Scripts/local_signing_identity.py`, `verify_signed_app_identity` in `Scripts/package_app.sh`, the archive and restore scripts that save and restore the registry, and the install section of `docs/releasing.md`.
- The switch costs one more round of prompts. The first team-signed build matches neither the stored partition list nor the trusted-application requirement, so it prompts once per stored item. The alternative is a new Keychain service and re-entering each secret. Builds after that one read their secrets silently.

Before committing to it, sign a throwaway build with the Personal Team certificate and confirm three things. First, `codesign -dvvv` shows a Team ID. Second, the build satisfies `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12] exists`, the requirement `securityd` checks before it assigns `teamid:`. Third, the app launches with its hardened-runtime entitlements and no provisioning profile.

### B. Keep self-signed signing and document the prompt

This doesn't change any code. `docs/releasing.md` would state that the partition list follows each build's CDHash, and the acceptance steps would include approving the prompt with Always Allow once per stored item. The prompt stays, and each item's partition list grows by one entry per build launched, which is small.

### Options that don't work

- Pre-authorizing the new CDHash in the installer with `security set-generic-password-partition-list` needs the login keychain password on every install, either typed in the terminal or passed in argv, and has the installer rewrite ACLs on items that hold secrets. It moves the prompt to install time rather than removing it.
- The data-protection keychain needs an application identifier or keychain access group entitlement backed by a team provisioning profile. Self-signed code can't get one, and with a team certificate option A already removes the prompt.
- An explicit `kSecAttrAccess` at item creation, as the identity migration builds with `TrustedApplicationsKeychainAttributeProvider`, controls the trusted-application list, which already passes. The only partition ID that matches a self-signed build is its own CDHash, which doesn't exist until that build is signed.

## Confirmation checks

1. Read the item ACLs without decrypting anything. `dump-keychain` without `-d` prints attributes and ACLs only. The filter below wasn't run in this investigation:

   ```bash
   security dump-keychain -a "$HOME/Library/Keychains/login.keychain-db" | awk '/^keychain: /{if (keep) printf "%s", block; block=""; keep=0} {block = block $0 "\n"} /com\.pvncher\.repoprompt\.ce\.local-self-signed\./{keep=1} END{if (keep) printf "%s", block}'
   ```

   Each item's `partition_id` entry should list one `cdhash:` value for each build launched since the item was created, matching each build's `codesign -dvvv` CDHash. If the entry's description prints as hex, decode it with `xxd -r -p`.
2. At the next promotion, record the prompt's exact text and buttons, the number of prompts, and whether they appear during launch or only at the first provider request. One prompt per stored item, shown during launch, supports both the cause and the related finding.

## Open questions

- Whether Allow, as opposed to Always Allow, also adds the CDHash wasn't checked.
