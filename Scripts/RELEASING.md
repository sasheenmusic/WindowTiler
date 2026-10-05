# Local release preparation

Build the local app with `Scripts/build-app.sh`. It uses an Apple Development identity when available. `WINDOW_TILER_SIGNING_IDENTITY=- Scripts/build-app.sh` explicitly builds an ad-hoc app. Extra arguments are forwarded to `swift build` (for example, `--disable-sandbox` when the host requires it). `Scripts/test-sparkle-bundle.sh` tests framework loading in a disposable ad-hoc copy without starting Window Tiler.

Run `Scripts/package-release.sh` to create `dist/releases/vVERSION-buildBUILD/`. It copies the local app, signs the copy with **Developer ID Application** for team **B697BHH54U**, preserves Sparkle's framework links, and verifies the extracted archive. The local app keeps its existing signature. A missing or unsuitable identity stops packaging; there is no ad-hoc or Apple Development fallback.

The script selects a single valid matching identity in Keychain. If several are available, pass `--signing-identity CERTIFICATE_FINGERPRINT` or set `WINDOW_TILER_PUBLIC_SIGNING_IDENTITY`. Keep this on the same Developer ID team when renewing certificates. Never export signing keys into this repository.

Public signing uses hardened runtime and a secure timestamp. It preserves helper entitlements and lets `codesign` generate the designated requirement. The verifier requires the app identifier, Apple trust anchor, Developer ID CA/Application certificate markers, and this Team ID. It rejects a build hash, leaf certificate pin, or weaker alternative. Certificate renewal on the same team can satisfy the same identity; switching from old ad-hoc/development releases still needs one new user permission grant. Do not weaken the requirement to keep old permissions.

Run `python3 Scripts/test-public-signing-policy.py` for offline rejection checks. Once the certificate is available, run `python3 Scripts/test-public-signing-policy.py --live --app "dist/Window Tiler.app"`. It signs two disposable, distinct binaries and checks both requirements against both builds, then rejects an ad-hoc copy. It never starts the app or changes Accessibility settings.

The current packager does not notarize or staple the app. Developer ID keeps the signing identity stable; notarization is a separate recommended distribution step and must not be claimed unless completed. With existing notarization credentials, notarize and staple the staged app before creating the final ZIP and EdDSA signatures. Modifying an already-signed release requires a new archive, checksum, and signed feed. Verify the final extracted ZIP with `Scripts/public-signing-policy.py verify APP_PATH` and test the actual opening experience on a quarantined copy.

The output contains `Window-Tiler-VERSION.zip`, its `.sha256` file, and an EdDSA-signed `appcast.xml`. Signing uses only the existing Keychain account `windowtiler`; the bundle's public key must match that account. Private keys are never exported. Both signatures are verified before output is saved.

The default archive URL is `https://github.com/sasheenmusic/WindowTiler/releases/download/vVERSION/Window-Tiler-VERSION.zip`. Use `--download-url HTTPS_URL` to change it, `--app PATH` to select an app, or `--output NEW_DIRECTORY` for another staging directory. Existing output directories are refused. The feed records the app's actual CPU architectures, version, build, and minimum macOS version.

After reviewing the artifacts, upload the ZIP and checksum to that GitHub release and publish the generated feed as the repository's root `appcast.xml`. Publish the archive before the feed. These scripts do not publish, install, or change the running app. Once signed, any feed edit requires signing it again. Version/build numbers and the public key are maintained in `Resources/Info.plist`; builds must increase for each update.

Increase both the marketing version and build number for every public release. The shell installer compares marketing versions; Sparkle compares build numbers. Keep the signing key in Keychain and maintain a secure backup outside this repository. Losing the private key prevents signing future updates for installed copies.
