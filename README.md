# AppUpdater

A simple app-updater for macOS, checks your GitHub releases for a binary asset
once a day and silently updates your app.

## Caveats

* We make no allowances for ensuring your app is not being actively used by the user
    at the time of update. PR welcome.
* Assets must be named: `\(reponame)-\(semanticVersion).ext`.
* Will not work if App is installed as a root user.

## Features

* Full semantic versioning support: we understand alpha/beta etc.
* We check the code-sign identity of the download matches the app that is
    running before doing the update. Thus if you don’t code-sign I’m not sure what
    would happen.
* We support zip files or tarballs.

# Support mxcl

Hey there, I’m Max Howell. I’m a prolific producer of open source software and
probably you already use some of it (for example, I created [`brew`]). I work
full-time on open source and it’s hard; currently *I earn less than minimum
wage*. Please help me continue my work, I appreciate it 🙏🏻

<a href="https://www.patreon.com/mxcl">
	<img src="https://c5.patreon.com/external/logo/become_a_patron_button@2x.png" width="160">
</a>

[Other ways to say thanks](http://mxcl.dev/#donate).

[`brew`]: https://brew.sh

## Usage

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
        updater.check().catch(policy: .allErrors) { error in
            if error.isCancelled {
                // promise is cancelled if we are already up-to-date
            } else {
                // show alert for this error
            }
        }
    }
}
```

## Alternatives

* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [Squirrel](https://github.com/Squirrel/Squirrel.Mac)
