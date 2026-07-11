<p align="center">
  <img src="Resources/OpenMimeIcon.png" width="128" alt="OpenMime icon">
</p>

<h1 align="center">OpenMime</h1>

<p align="center">
  A fast, lightweight, native Gmail client for macOS — and an open alternative to the closed-source clients around it.
</p>

<p align="center">
  <a href="https://github.com/kevb/openmime/actions/workflows/ci.yml"><img src="https://github.com/kevb/openmime/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="Apache 2.0 license"></a>
</p>

OpenMime talks directly to Gmail. There is no OpenMime account, subscription, analytics service, or cloud backend. The interface is SwiftUI/AppKit, with one constrained WebKit process used only where real-world HTML mail makes it worthwhile.

This is an early personal-use preview. It is already a useful mail client, but expect rough edges and please report them.

## Why OpenMime?

- Native three-pane macOS interface with Gmail categories, system folders, and labels.
- Approximately 88 MB observed memory use with an HTML conversation open; the working target is to remain below 150 MB.
- A bounded SQLite cache, incremental Gmail History sync, and one-minute polling while the app is running.
- Threaded conversations, Gmail search with infinite scrolling, unread state, stars, archive, spam, trash, and labels.
- Compose, reply, reply all, forwarding, attachments, autosaved Gmail drafts, and direct Gmail sending.
- Optional, separately authorized Google Contacts autocomplete.
- Remote images blocked by default, with per-message and per-sender controls.
- Apple silicon and Intel support in a small universal DMG.

## Try it

OpenMime does not yet ship a shared, Google-verified OAuth client, so each tester supplies a Google Desktop OAuth JSON file. It takes a few minutes and keeps the project independent of a hosted service.

1. Download the latest DMG from [Releases](https://github.com/kevb/openmime/releases), open it, and drag OpenMime to Applications.
2. Complete the short [Google Cloud setup guide](Docs/google-cloud-setup.md) and download your OAuth client JSON.
3. Launch OpenMime, choose that JSON when prompted, and sign in with Google.
4. Connect Google Contacts later from the compose window if you want richer address suggestions.

The current builds are self-signed and are not notarized because the project does not yet have a paid Apple Developer account. On first launch, macOS may require you to right-click OpenMime and choose **Open**, or approve it under **System Settings → Privacy & Security**. If the project attracts a community, the next distribution step is a stable Developer ID signature and notarization.

Google may also show an “unverified app” warning for your private OAuth client. Personal test accounts can continue through that warning. If OpenMime gains broader interest, the project can adopt a maintained production OAuth client and go through Google's verification process.

## Google access

The required Gmail permission is `gmail.modify`, which allows OpenMime to read, send, and organize mail. Contacts are optional and requested in a separate consent flow with read-only permissions. Calendar is not requested or supported.

Your OAuth JSON is imported by the app and is never copied into this repository. Mail, contacts, cached HTML, and credentials stay on your Mac; network calls go directly to Google's APIs. See the [Google Cloud setup guide](Docs/google-cloud-setup.md) for the exact APIs, consent-screen settings, and scopes.

## Security and privacy

- No OpenMime backend or telemetry.
- OAuth uses Authorization Code + PKCE with a loopback callback.
- Cached mail is bounded and account-isolated.
- Remote images are blocked until you permit them; rendered HTML is sanitized and persistent WebKit storage is disabled.
- Development builds store OAuth tokens in an owner-only (`0600`) file under `~/Library/Application Support/OpenMime`. This avoids repeated Keychain prompts while every local build has a changing ad-hoc identity. FileVault is recommended. A future Developer ID build will move credentials back to Keychain.

Please do not commit an OAuth JSON, token file, signing certificate, or local signing keychain. The repository ignores common credential filenames, but contributors should still inspect every commit.

## Build from source

Requirements: macOS 14 or newer and Xcode 16.4 or newer.

```sh
git clone https://github.com/kevb/openmime.git
cd openmime
Scripts/test.sh
open dist/OpenMime.app
```

`Scripts/test.sh` runs the test suite and creates a debug app bundle. Tests use fixtures and do not access a real mailbox.

To reproduce the universal release package:

```sh
Scripts/build_universal_app.sh
Scripts/package_dmg.sh
```

The build creates a persistent self-signed development identity under the gitignored `Config/LocalSigning` directory. Tagged releases matching `v*` run the tests, build both architectures, verify the DMG and checksum, then publish them as a prerelease through GitHub Actions.

## Project status

The main flows work, but this is not yet a replacement for every part of Gmail. Current priorities include richer composition, deeper label management, participant-name enrichment, sync hardening, accessibility, and polish. See [BACKLOG.md](BACKLOG.md) for the working backlog and [BUILD_PLAN.md](BUILD_PLAN.md) for the architecture and release plan.

Issues, focused pull requests, testing feedback, and design discussion are welcome. Please include macOS version, Mac architecture, and clear reproduction steps with bug reports — but never include message contents or credentials unless you deliberately redact them.

## License

OpenMime is available under the [Apache License 2.0](LICENSE).
