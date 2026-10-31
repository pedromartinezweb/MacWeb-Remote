# MacWeb Remote

Control a Mac desktop from any browser. A native macOS app with an embedded HTTPS server, WebAuthn passkeys and a virtual display for working with physical displays turned off.

## Features

- Responsive browser client, without extensions. Pointer/hover capabilities select desktop or touch controls automatically; real mouse and touch events adapt hybrid devices as you use them. Physical mice always use direct coordinates. Touch users can choose trackpad or direct-touch mode. Hardware keyboard events work in either mode.
- Native dashboard with an always-visible QR code and Copy link button.
- Passkeys with required user verification, single-use challenges, recent authorization for enrollment and revocation, and persistent public credentials.
- Per-installation recovery code; no credentials or network addresses embedded in the source.
- Configurable DNS name, IPv4 listen address and HTTPS port.
- ScreenCaptureKit video through MJPEG at up to 15 fps, with mouse, touch and keyboard input.
- Virtual display and automatic physical-display restoration when browser heartbeats stop.

## Download a build

Release downloads are available from this repository's Releases page. The ZIP contains an Apple Silicon app for macOS 15 or later; verify it with the accompanying `SHA256SUMS.txt`. The app is ad-hoc signed and is not notarized.

The **Build macOS app** GitHub Actions workflow builds and tests on an Apple Silicon macOS runner. Run it manually from Actions, or push a version tag. Each successful run retains the app ZIP and checksum as an artifact for 30 days. CI checks protocol and browser-input tests; screen capture and macOS privacy grants require a real desktop session.

## Build and run

Requires macOS 15 or later and Xcode 26 with Swift 6.2 or later. Dependencies are pinned in `Package.resolved`.

```sh
./build.sh
open "$HOME/Library/Caches/MacWebRemote-build/MacWebRemote.app"
```

The dashboard shows the app version and build number from its bundle metadata. GitHub Actions uses its run number as the build number; local builds use `CFBundleVersion` from `Info.plist` unless `MACWEB_BUILD_NUMBER` is set.

Build output stays outside the repository. Override `MACWEB_BUILD_ROOT` to choose another directory or set `MACWEB_CONFIGURATION=debug` for development.

Set `MACWEB_SIGNING_IDENTITY` to an existing Apple development or distribution signing identity for consistent app identity across builds. The default is an ad-hoc development signature, not a notarized distribution. Replacing an ad-hoc signed executable can invalidate macOS privacy grants even when Settings still shows its switch enabled. No signing certificates are created or installed by the build.

The first launch creates private configuration and local certificates in `~/Library/Application Support/MacWebRemote/`. The primary IPv4 address is detected from the system. Moving the source checkout does not move or reset this runtime data.

## Screen recording and input permissions

1. Run the installed `.app`, rather than its executable from Terminal.
2. Click **Grant access** for Screen recording. Approve the system prompt and enable MacWeb Remote in **System Settings → Privacy & Security → Screen Recording**.
3. Quit and reopen the app if macOS requests it. The dashboard marks recording active only after ScreenCaptureKit starts successfully.
4. Enable **Accessibility** for mouse and keyboard control.

If recording still fails after replacing a development build, remove the old MacWeb Remote entry from Screen Recording settings, add the installed app again and reopen it. Use **Open Screen Recording settings** to return to the relevant panel. The app never edits the TCC database or grants itself permission. Keep a single installed copy when testing permissions: macOS may reopen an older app with the same bundle identifier from a build or backup directory. Archive old bundles rather than leaving them as runnable `.app` copies.

## Configure network access

1. Open **Settings** in the app. Review the DNS name, listen address and HTTPS port.
2. Click **Prepare HTTPS and save**, then reopen the app.
3. Ensure the DNS name resolves to the Mac. The suggested `.local` name uses Bonjour; VPNs do not necessarily transport Bonjour. Configure your network/VPN DNS or use a domain you control.
4. Click **Export certificate…**. The exported `.mobileconfig` profile contains only the public local CA certificate.
5. Install and explicitly trust that certificate on each client device. The app does not modify trust stores automatically. The profile contains no private keys, passwords or passkeys.

**Passkeys require a DNS name and trusted HTTPS. They do not work through a literal IP address or a bypassed certificate warning.** A VPN provides network access but must also resolve the selected name.

For a publicly issued certificate, the optional `certificateFile` setting in `config.json` may identify a PKCS#12 container inside the configuration directory; `tlsPassword` must match it. Keep private keys outside the repository.

The server listens only on the configured IPv4 address. Remote access requires a private route, such as your VPN. The app does not open router ports or create external tunnels.

## Enroll and use a passkey

1. Open the configured DNS link in a browser.
2. Sign in once using the initial QR code or the recovery code shown in the Mac app.
3. In **Options → Passkeys**, enter a name and click **Create passkey**.
4. Confirm enrollment with the browser's authenticator or password manager.
5. On subsequent visits, click **Sign in with passkey** and complete local user verification.

Enrollment and browser revocation require a session created within the last five minutes. Desktop sessions last twelve hours and are invalidated when the app restarts. Registered public credentials remain on the Mac. A synced passkey may work on multiple devices; revoking it on the Mac denies that credential on all devices but does not delete it from the password manager.

Credential databases belong to the configured DNS name. Changing the name requires enrollment for the new name; the previous database is retained so the original configuration can be restored.

## Work with physical displays off

In the browser, choose **Options → Create and use virtual display**. Check the image before choosing **Turn off Mac displays**. Restore them with **Turn on Mac displays** in the browser or **Restore displays** in the native app.

The app prevents idle system sleep during capture and restores displays after thirty seconds without browser heartbeats. Display configuration changes are scoped to the process. Turning displays off is different from putting the Mac to sleep.

Virtual displays and physical-display disabling use private macOS APIs that may change. App Store distribution has not been verified.

## Development and validation

```sh
swift test -j 4
node --check Web/app.js
node --check Web/passkeys.js
node --test tests/*-client.test.cjs
python3 tests/server_smoke.py
python3 tests/capture_smoke.py
```

The HTTPS smoke tests require the installed server and its local runtime configuration. Authentication tests use real P-256 signatures and check persistence, revocation, expiry, origin/RP binding, invalid signatures, iframe contexts and user verification. Client codec tests exercise browser payload conversion with test doubles. These tests do not establish physical-device biometrics or iCloud sync behavior.

`Sources/` owns transport, desktop capture and input; `Auth/` owns WebAuthn and credential storage; `NativeBridge/` contains the virtual-display APIs; `Web/` contains the browser client.

Credentials, generated certificates, private keys, public-credential databases, recordings, binaries and research archives are excluded from Git. Original research artifacts remain local and retain their source language.

## Dependencies and icon

WebAuthn verification uses [Swift WebAuthn](https://github.com/brokenhandsio/swift-webauthn), pinned to a specific revision. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency licenses.

The generated icon master is `Assets/AppIcon.png`. [Assets/README.md](Assets/README.md) records its design and generation process.

## License

MacWeb Remote is **free for private, personal, non-commercial use** under the [MacWeb Remote Personal Use and Commercial License 1.0](LICENSE).

**Business or professional use, commercial use, and resale require a separate prior written agreement with Pedro Martinez.** This includes internal company deployments and commercial products or services based on modified versions. Contact [legal@pedromartinezweb.com](mailto:legal@pedromartinezweb.com) to discuss terms.

The source is publicly available under a custom license; this is not an OSI-approved open-source license. Third-party dependencies retain their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
