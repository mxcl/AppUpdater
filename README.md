# AppUpdater

A simple app-updater for macOS, checks your GitHub releases for a binary asset
once a day and silently updates your app.

# Caveats

* We make no allowances for ensuring your app is not being actively used by the user
    at the time of update. PR welcome.
* Assets must be named: `\(reponame)-\(semanticVersion).ext`.
* Will not work if App is installed as a root user.

# Features

* Full semantic versioning support: we understand alpha/beta etc.
* We check the code-sign identity of the download matches the app that is
    running before doing the update. Thus if you don’t code-sign I’m not sure what
    would happen.
* We support zip files or tarballs.

# Usage

```swift
package.dependencies.append(.package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"))
```

Then:

```swift
import AppUpdater

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    let updater = AppUpdater(owner: "your-github-username", repo: "your-github-repo-name")

    //NOTE this is optional, the `AppUpdater` object schedules a daily update check itself    
    @IBAction func userRequestedAnExplicitUpdateCheck() {
        updater.check().catch { error in
            // show alert
        }
    }
}
```
