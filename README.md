# AppUpdater

A simple app-updater for macOS, checks your GitHub releases for a binary asset
once a day and silently updates your app.

Note we have no allowances for ensuring your app is not in-use at the time of
update. PR welcome.

We also check the code-sign identity of the download matches the app that is
running before doing the update. Thus if you don’t code-sign I’m not sure what
would happen.

We support zip files or tarballs.

Assets must be named: `\(reponame)-\(semanticVersion).ext`
