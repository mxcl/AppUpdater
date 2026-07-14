# AppUpdater

[![Coverage Status][coveralls-badge]][coveralls]

A small, self-update library for Developer ID signed macOS apps. AppUpdater checks
GitHub Releases, validates a DMG, replaces the running app, and relaunches it.

[coveralls-badge]: https://coveralls.io/repos/github/mxcl/AppUpdater/badge.svg
[coveralls]: https://coveralls.io/github/mxcl/AppUpdater

AppUpdater supports macOS 12 and later. Version 3 has a source-breaking API.

## Package

```swift
package.dependencies.append(
    .package(url: "https://github.com/mxcl/AppUpdater.git", from: "3.0.0")
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

                // The app can keep operating while this runs. Finder may ask
                // for authorization when the app lives in a protected folder.
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

`check()` downloads the DMG, mounts it read-only and non-browsable, enforces the
configured resource limits, and validates the app. It returns a one-shot
`Update` without exposing staging paths.

`prepareInstallation()` copies the DMG beside the installed app, mounts that
copy read-only, and repeats the resource and signature checks. The returned
`PreparedUpdate` is also one-shot. Call `discard()` on either object if you
decide not to continue.

Call `installAndRelaunch()` only after the host has saved its state, stopped
background work, and ceased loading bundle code or resources. The running
instance moves itself to a backup, copies the validated candidate into its old
path, validates the installed copy, and launches a new instance. It restores
the backup if copying, final validation, or launch fails. The old instance exits
after the new instance launches.

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

## Security model

AppUpdater aims to prevent privilege amplification. A same-user attacker must
not be able to replace a downloaded candidate and then borrow Finder's
authorization to modify an app that the user cannot otherwise replace.

For every candidate, AppUpdater requires a valid Developer ID Application
signature. The installed and candidate apps must have the same Team ID, signing
identifier, and bundle identifier. Validation covers all architectures, nested
code, strict sealed resources, app-like bundle structure, and restricted
symlinks. AppUpdater rejects ad-hoc, development, self-signed, and broad custom
requirements such as `designated => true`.

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

The signature check does not bind a GitHub release version to the version inside
the app. AppUpdater provides no rollback protection and performs no Gatekeeper
or notarization assessment. A compromised Developer ID signing key can produce
an update that passes the identity checks.

## Alternatives

* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [Squirrel](https://github.com/Squirrel/Squirrel.Mac)
