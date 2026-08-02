#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
identity="$(
  security find-identity -v -p codesigning |
    awk -F '"' '/Developer ID Application: Max Howell \(ZU76A67LGU\)/ { print $2; exit }'
)"
if [[ -z "$identity" ]]; then
  echo "missing Developer ID Application identity for ZU76A67LGU" >&2
  exit 1
fi

work="$(mktemp -d "$HOME/Library/Caches/appupdater-live-attestation.XXXXXX")"
keep=0
cleanup() {
  status=$?
  if [[ "$status" -ne 0 || "$keep" -eq 0 ]]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT
package="$work/package"
app="$work/Automic Vault.app"
mkdir -p "$package/Sources/Smoke" "$app/Contents/MacOS" "$app/Contents/Resources"

cat >"$package/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Smoke",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "$root")],
    targets: [
        .executableTarget(name: "Smoke", dependencies: ["AppUpdater"]),
    ]
)
EOF

cat >"$package/Sources/Smoke/main.swift" <<'EOF'
import AppKit
import AppUpdater
import Foundation

enum SmokeFailure: Error {
    case noUpdate
    case invalidNegativeControl
}

@main
struct Smoke {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared

        let rejected = AppUpdater(
            owner: "automic-vault",
            repo: "automic-vault",
            configuration: .init(
                attestationPolicy: .init(
                    workflow: ".github/workflows/release.yml",
                    sourceRef: "refs/heads/not-main"
                )
            )
        )
        guard let rejectedUpdate = try await rejected.check() else {
            throw SmokeFailure.noUpdate
        }
        do {
            let prepared = try await rejectedUpdate.prepareInstallation()
            await prepared.discard()
            throw SmokeFailure.invalidNegativeControl
        } catch AppUpdaterError.attestationVerificationFailed {
            print("PASS: incorrect source ref rejected")
        }

        let updater = AppUpdater(
            owner: "automic-vault",
            repo: "automic-vault",
            configuration: .init(
                attestationPolicy: .init(
                    workflow: ".github/workflows/release.yml",
                    sourceRef: "refs/heads/main"
                )
            )
        )
        guard let update = try await updater.check() else {
            throw SmokeFailure.noUpdate
        }
        let prepared = try await update.prepareInstallation()
        print("PASS: prepared attested \(update.assetName)")

        if ProcessInfo.processInfo.environment["APPUPDATER_SMOKE_INSTALL"] == "1" {
            print("Installing into disposable bundle at \(Bundle.main.bundlePath)")
            try await prepared.installAndRelaunch()
        } else {
            await prepared.discard()
        }
    }
}
EOF

swift build -c release --package-path "$package"
bin="$(swift build -c release --package-path "$package" --show-bin-path)"
cp "$bin/Smoke" "$app/Contents/MacOS/Smoke"
find "$bin" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;

plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Smoke "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.automicvault "$app/Contents/Info.plist"
plutil -insert CFBundleName -string 'Automic Vault' "$app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.0.1 "$app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 12.0 "$app/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$app/Contents/Info.plist"

codesign --force --sign "$identity" --options runtime --timestamp "$app"
codesign --verify --deep --strict "$app"

echo "Disposable app: $app"
"$app/Contents/MacOS/Smoke"

if [[ "${APPUPDATER_SMOKE_INSTALL:-}" == "1" ]]; then
  version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
  [[ "$version" != "0.0.1" ]]
  codesign --verify --deep --strict "$app"
  echo "PASS: installed and verified Automic Vault $version at $app"
  keep=1
fi
