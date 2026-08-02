# AppUpdater

[![Coverage Status][coveralls-badge]][coveralls]

A small, self-update library for Developer ID signed macOS apps. AppUpdater checks
GitHub Releases, validates a DMG, replaces the running app, and relaunches it.

[coveralls-badge]: https://coveralls.io/repos/github/mxcl/AppUpdater/badge.svg
[coveralls]: https://coveralls.io/github/mxcl/AppUpdater

AppUpdater supports macOS 12 and later. Version 4 separates update discovery
from downloading and preparing an installation.

## Package

```swift
package.dependencies.append(
    .package(url: "https://github.com/mxcl/AppUpdater.git", from: "4.1.0")
)
```

## Release layout

AppUpdater only accepts DMG assets. Name each asset
`<repository>-<semantic-version>.dmg`, for example `MyApp-2.1.0.dmg`.

The mounted DMG must contain one top-level app. Its filename must match the
installed app, including case. A release for `MyApp.app` therefore contains:

```text
MyApp-2.1.0.dmg
└── MyApp.app
```

AppUpdater ignores ZIP files, tarballs, packages, and DMGs with missing,
multiple, or misnamed apps.

## Usage

```swift
import AppKit
import AppUpdater

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater(
        owner: "your-github-username",
        repo: "your-github-repo-name"
    )

    @IBAction func checkForUpdates(_ sender: Any?) {
        Task { @MainActor in
            do {
                guard let update = try await updater.check() else { return }
                print("Version \(update.version) is available")

                // This downloads and validates the update. The app can keep
                // operating while it runs. Finder may ask for authorization
                // when the app lives in a protected folder.
                let prepared = try await update.prepareInstallation()

                // Save documents, stop background work, close helper processes,
                // and finish every read from Bundle.main here.
                try await quiesceForUpdate()

                // Do not read code or resources from the old bundle after this call.
                try await prepared.installAndRelaunch()
            } catch {
                // Present or log the error. A failed launch restores the old app.
            }
        }
    }
}
```

`check()` fetches bounded GitHub release metadata and returns a lightweight,
one-shot `Update` with `version` and `assetName`. It does not download the DMG.

`prepareInstallation()` downloads the DMG, mounts it read-only and
non-browsable, enforces the configured resource limits, and validates the app.
It then copies the DMG beside the installed app, mounts that copy read-only,
and repeats the resource and signature checks. The returned `PreparedUpdate`
is also one-shot. Call `discard()` on either object if you decide not to
continue.

Call `installAndRelaunch()` only after the host has saved its state, stopped
background work, and ceased loading bundle code or resources. The running
instance moves itself to a backup, copies the validated candidate into its old
path, and validates that the installed copy launches. It stops the temporary
validation instance before committing the transaction and restores the backup
if copying, final validation, launch, or probe termination fails. On success,
the old instance exits and an armed fallback launches the installed app.

> [!IMPORTANT]
> Quiescing must not cause the old instance to exit. In particular, hosts that
> return `true` from `applicationShouldTerminateAfterLastWindowClosed(_:)`
> must suppress that behavior during installation. If the host exits while
> AppUpdater is copying the replacement, the transaction cannot finish or
> relaunch the app. Let `installAndRelaunch()` terminate the old instance after
> replacement and validation complete.

## Configuration

The defaults cap downloads at 2 GiB, mounted regular-file content at 4 GiB, and
mounted filesystem entries at 100,000. Network, mount, and enumeration work use
a 10-minute timeout.

```swift
let updater = AppUpdater(
    owner: "example",
    repo: "MyApp",
    configuration: .init(
        maximumDownloadBytes: 2 * 1024 * 1024 * 1024,
        maximumMountedBytes: 4 * 1024 * 1024 * 1024,
        maximumEntries: 100_000,
        timeout: 10 * 60
    ),
    sessionConfiguration: .default
)
```

### GitHub Actions provenance

AppUpdater 4.1 can additionally require GitHub Artifact Attestation provenance:

```swift
let updater = AppUpdater(
    owner: "example",
    repo: "MyApp",
    configuration: .init(
        attestationPolicy: GitHubAttestationPolicy(
            workflow: ".github/workflows/release.yml",
            sourceRef: "refs/heads/main"
        )
    )
)
```

This is opt-in. The default `attestationPolicy == nil` retains AppUpdater 4.0
behavior. When enabled, the GitHub release must expose its exact 40-character
target commit and a `sha256:` digest for the DMG. The configured workflow must
publish SLSA provenance v1 with GitHub's workflow build type, use a GitHub-hosted
runner, and attest the DMG filename, digest, repository, workflow, ref, and
resolved source commit.

Only public GitHub Actions bundles using Sigstore's public-good Fulcio, Rekor,
and CT logs are supported. GitHub release attestations, private-repository RFC
3161 bundles, SBOM predicates, generic Sigstore identities, other build types,
and other trust domains are rejected.

## Security model

AppUpdater aims to prevent privilege amplification. A same-user attacker must
not be able to replace a downloaded candidate and then borrow Finder's
authorization to modify an app that the user cannot otherwise replace.

The result of `check()` is advisory GitHub metadata, not an authenticated app.
Only `prepareInstallation()` downloads and authenticates the candidate. Do not
grant privileges or stop security services based only on an available update.

For every candidate, AppUpdater requires a valid Developer ID Application
signature. The installed and candidate apps must have the same Team ID, signing
identifier, and bundle identifier. Validation covers all architectures, nested
code, strict sealed resources, app-like bundle structure, and restricted
symlinks. AppUpdater rejects ad-hoc, development, self-signed, and broad custom
requirements such as `designated => true`.

With an attestation policy, provenance verification is an additional mandatory
gate; Developer ID validation is never used as a fallback. AppUpdater streams
and hashes the downloaded DMG, matches GitHub's release digest, and verifies the
Sigstore v0.3 DSSE bundle before mounting. Verification covers the Fulcio chain
and signing time, code-signing EKU, GitHub OIDC certificate claims, SCT, DSSE
signature, Rekor SET, RFC 6962 inclusion proof, signed checkpoint, and the
supported in-toto/SLSA assertions. After Finder promotion, AppUpdater hashes
the protected copy again and refuses to mount it unless the verified digest is
unchanged.

Sigstore trust is bootstrapped from the root shipped with AppUpdater and
refreshed from Sigstore's public TUF repository. Refresh performs sequential
root rotation and threshold verification, then verifies timestamp, snapshot,
targets, hashes, lengths, expiry, and rollback state. Cache writes are atomic;
an offline cache is used only when its complete signed metadata chain remains
valid, otherwise the shipped trusted-root snapshot is used. Malformed or
cryptographically invalid online metadata is never treated as an offline
failure.

Missing, malformed, expired, unsupported, oversized, or unverifiable
attestation material fails `prepareInstallation()` with
`AppUpdaterError.attestationVerificationFailed`. No DMG is mounted and no
installation change is attempted.

AppUpdater downloads into a private directory, mounts the DMG read-only, and
keeps the validated mount alive. For a protected installation, Finder copies
the DMG itself into a randomized hidden sibling of the installed app. AppUpdater
rejects the promoted copy unless it is a regular file directly under that
parent, has no symlink path components, and the current user can neither write
nor replace it. AppUpdater then mounts and validates the promoted copy again.
It does not touch the installed app if promotion fails these checks.

An app installed in a user-writable bundle or parent directory is already under
that user's control. AppUpdater still uses a private same-parent DMG copy and
performs the same validation and rollback transaction, but it cannot protect
that path from another process running as the same user.

Neither mode binds a GitHub release version to the version inside the app or
performs a Gatekeeper/notarization assessment. Without an attestation policy,
AppUpdater provides no release provenance or rollback protection and a
compromised Developer ID key can produce an update that passes identity checks.
With a policy, a candidate must also originate from the configured GitHub
workflow/ref and resolve to the release's exact source commit.

## Alternatives

* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [Squirrel](https://github.com/Squirrel/Squirrel.Mac)
