# Manual protected-install release test

Run this test before a release on every supported macOS major version. Use a
non-admin account and install the signed test app in `/Applications` so the
account cannot write the app or its parent.

1. Publish a Developer ID signed DMG with one correctly named top-level app.
2. Start the old app and begin an update. Confirm that Finder asks for an
   administrator's authorization during `prepareInstallation()`.
3. Before continuing, inspect the hidden promoted DMG beside the app. Confirm
   that the non-admin account cannot write, rename, remove, replace, or change
   the mode of that file.
4. Inspect `hdiutil info`. Confirm that AppUpdater mounted the promoted DMG
   read-only and non-browsable.
5. Quiesce the app and call `installAndRelaunch()`. Confirm that the old and new
   processes overlap, the new bundle occupies the original path, and the old
   process exits only after the new process launches.
6. Force-terminate the old process after each transaction phase in separate
   runs: before backup, after backup, after candidate copy, after final
   validation, and after launch. Confirm that the next run only touches hidden
   names matching AppUpdater's UUID format and never follows a symlink.
7. Test copy failure, installed-copy validation failure, and launch failure.
   Confirm that each failure restores the old bundle, keeps the old process
   running, leaves the bundle at its original path, and reports rollback failure
   if restoration itself fails.
8. Replace or mutate the original downloaded DMG after promotion. Confirm that
   installation reads the protected promoted copy or rejects preparation; it
   must never install from the changed original.
9. Confirm that successful cleanup removes the backup and promoted DMG and
   detaches both mounts.
