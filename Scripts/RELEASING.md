# Local release preparation

Build the local app with `Scripts/build-app.sh`. It uses an Apple Development identity when available. `WINDOW_TILER_SIGNING_IDENTITY=- Scripts/build-app.sh` explicitly builds an ad-hoc app. Extra arguments are forwarded to `swift build` (for example, `--disable-sandbox` when the host requires it). `Scripts/test-sparkle-bundle.sh` tests framework loading in a disposable ad-hoc copy without starting Window Tiler.

Run `Scripts/package-release.sh` to create `dist/releases/vVERSION-buildBUILD/`. It copies the local app, signs the copy ad-hoc, preserves Sparkle's framework links, and verifies the extracted archive. The local app keeps its existing signature.

The output contains `Window-Tiler-VERSION.zip`, its `.sha256` file, and an EdDSA-signed `appcast.xml`. Signing uses only the existing Keychain account `windowtiler`; the bundle's public key must match that account. Private keys are never exported. Both signatures are verified before output is saved.

The default archive URL is `https://github.com/sasheenmusic/WindowTiler/releases/download/vVERSION/Window-Tiler-VERSION.zip`. Use `--download-url HTTPS_URL` to change it, `--app PATH` to select an app, or `--output NEW_DIRECTORY` for another staging directory. Existing output directories are refused. The feed records the app's actual CPU architectures, version, build, and minimum macOS version.

After reviewing the artifacts, upload the ZIP and checksum to that GitHub release and publish the generated feed as the repository's root `appcast.xml`. Publish the archive before the feed. These scripts do not publish, install, or change the running app. Once signed, any feed edit requires signing it again. Version/build numbers and the public key are maintained in `Resources/Info.plist`; builds must increase for each update.

Increase both the marketing version and build number for every public release. The shell installer compares marketing versions; Sparkle compares build numbers. Keep the signing key in Keychain and maintain a secure backup outside this repository. Losing the private key prevents signing future updates for installed copies.
