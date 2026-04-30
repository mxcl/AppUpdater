# AppUpdater

[![Coverage Status][coveralls-badge]][coveralls]

A simple app-updater for macOS that checks your GitHub releases for a binary
asset and stages verified updates for your app to install explicitly.

[coveralls-badge]: https://coveralls.io/repos/github/mxcl/AppUpdater/badge.svg
[coveralls]: https://coveralls.io/github/mxcl/AppUpdater

## Caveats

* Your app owns the user experience for asking to quit and install an update.
* Assets must be named: `\(reponame)-\(semanticVersion).ext`.
* Will not work if App is installed as a root user.

## Features

* Full semantic versioning support: we understand alpha/beta etc.
* We check the code-sign identity of the download matches the app that is
    running before doing the update.
* We support zip files or tarballs.

## Usage

```swift
package.dependencies.append(
    .package(url: "https://github.com/mxcl/AppUpdater.git", from: "2.0.0")
)
```

Then:

```swift
import AppKit
import AppUpdater

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater(
        owner: "your-github-username",
        repo: "your-github-repo-name"
    )

    @IBAction func userRequestedAnExplicitUpdateCheck() {
        Task {
            do {
                guard let update = try await updater.check() else {
                    return
                }

                // Ask the user to save work and confirm a relaunch.
                try await update.installAndRelaunch()
            } catch {
                // Show an alert for this error.
            }
        }
    }
}
```

`check()` downloads and verifies an update, but does not install it. To check
daily, own the scheduling in your app and decide when to present the staged
update:

```swift
import AppKit
import AppUpdater

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater(
        owner: "your-github-username",
        repo: "your-github-repo-name"
    )
    var availableUpdate: Update?

    lazy var updateActivity: NSBackgroundActivityScheduler = {
        let activity = NSBackgroundActivityScheduler(
            identifier: "com.example.MyApp.update-check"
        )
        activity.repeats = true
        activity.interval = 24 * 60 * 60
        return activity
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateActivity.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            guard !self.updateActivity.shouldDefer else {
                completion(.deferred)
                return
            }

            Task { @MainActor in
                do {
                    if let update = try await self.updater.check() {
                        // Store this or notify the user at an appropriate time.
                        self.availableUpdate = update
                    }
                } catch {
                    // Log the error, or ignore it for background checks.
                }
                completion(.finished)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.updateActivity.invalidate()
    }
}
```

## Alternatives

* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [Squirrel](https://github.com/Squirrel/Squirrel.Mac)
