# OpenMime build plan

## Product definition

OpenMime is an open-source, Gmail-only desktop mail client for macOS. It should feel instant, remain useful during short network outages, and preserve the compact three-pane workflow shown in the reference screenshots without copying another product's branding or assets.

The first stable release targets:

- macOS 14 Sonoma or newer, Apple silicon and Intel.
- One or more consumer Gmail or Google Workspace accounts.
- A native, keyboard-friendly three-pane interface: labels, thread list, message/conversation view.
- Read, search, compose, reply, reply-all, forward, draft, send, archive, trash, spam, star, mark read/unread, and label operations.
- Attachments for viewing, downloading, and sending.
- Optional read-only Google Contacts suggestions plus suggestions learned locally from message correspondents.
- Direct distribution as a signed and notarized DMG through GitHub Releases.
- Installed size target of 35 MB or less, a normal total memory target of 120–140 MB, and a hard release ceiling of 150 MB for a mailbox with 10,000 cached message summaries. Memory is the aggregate resident footprint of OpenMime and all WebKit/helper processes, measured with the main window open on a representative HTML conversation—not merely the main process while idle or minimized.

Not in v1: non-Gmail accounts, calendar, contact editing, rules, extensions, read receipts, scheduled send, snooze, confidential mode, server infrastructure, telemetry, or AI features.

## Product principles

1. Native shell, bounded WebKit. Use Swift 6, SwiftUI for views and state, and AppKit for window/toolbar control, drag and drop, menus, and keyboard routing. Use WebKit only where it materially improves HTML email fidelity, with a deliberately small renderer pool and total-process memory accounting.
2. Local first, not local only. Cache enough metadata and recently opened bodies to launch and browse immediately, but keep Gmail authoritative.
3. Least privilege. Request mail access at sign-in; request contacts separately only when the user enables Google Contacts suggestions.
4. No OpenMime backend. OAuth, Gmail, and People API traffic goes directly from the app to Google. Tokens and secrets never enter logs or the local database.
5. Bounded resources. Paginate every mailbox operation, fetch bodies lazily, cap decoded image and attachment caches, and measure size and memory in CI/release qualification.

## User experience

### Main window

- `NavigationSplitView`-style three columns with persisted widths and optional collapse to two or one column.
- Sidebar sections for Gmail categories, system labels, and user labels. Counts are fetched lazily and may be approximate.
- Thread list virtualized with compact sender, subject, snippet, timestamp, unread/star/attachment state, and multi-selection.
- Conversation view renders all messages in a thread, initially collapsed except the newest unread/current message.
- Native toolbar and menus expose compose, archive, trash, spam, read/unread, star, labels, reply variants, refresh, and search.
- Full keyboard navigation, standard shortcuts, VoiceOver labels, high contrast, reduced motion, text scaling, light/dark mode, and localization-ready strings from the start.

### Composer

- Separate native window with To/Cc/Bcc token fields, subject, rich body, attachments, account/sender selector, draft state, and send progress.
- Address suggestions merge, in priority order: exact addresses already entered, locally learned correspondents, and optional People API results.
- Autosave locally after a short debounce and remotely as a Gmail draft after idle/close. Closing offers keep draft or discard.
- MVP formatting: plain text plus bold, italic, underline, lists, links, and inline images. Generate standards-compliant MIME using a small in-repo MIME layer, not a web editor framework.

### Sign-in and permissions

- Use system browser OAuth 2.0 Authorization Code flow with PKCE and a loopback redirect for the Desktop OAuth client.
- Store refresh tokens in Keychain with `ThisDeviceOnly` accessibility; keep access tokens in memory.
- Initial scopes: `openid`, `email`, and `https://www.googleapis.com/auth/gmail.modify`. This supports normal read/compose/send/label/trash behavior without requesting permanent-delete access. OpenMime does not request `mail.google.com` and does not use IMAP.
- Optional contacts connection requests `https://www.googleapis.com/auth/contacts.readonly` incrementally. The app remains fully usable when declined or revoked.
- Provide an account permissions screen with scope explanations, disconnect, clear local data, and links to revoke Google access.

The personal build uses an External OAuth project published as unverified Production. One or two owner-approved accounts click through Google's warning once and receive durable refresh tokens; do not leave the project in Testing, where test-user authorization expires after seven days. Public distribution can remain unverified until interest justifies approval work, subject to Google's personal-use/user-cap rules. Because restricted Gmail data remains on the user's device and is never sent to an OpenMime server, document that architecture clearly if verification is pursued later.

## Technical architecture

Create one Xcode project with a macOS app and focused local Swift packages. Avoid large binary dependencies and use Apple frameworks wherever practical.

```text
OpenMimeApp
  Presentation       SwiftUI scenes, AppKit bridges, commands, accessibility
  Features           Accounts, Mailbox, Conversation, Composer, Search, Settings
  Domain             Models, use cases, repository protocols, error vocabulary
  GmailCore          REST client, DTOs, pagination, retry, rate limiting, MIME
  AuthCore           PKCE, browser session/loopback callback, token refresh, Keychain
  StoreCore          SQLite schema, migrations, repositories, bounded file cache
  ContactsCore       Local correspondents and optional People API search
  TestSupport        Fixtures, fake clock, fake transport, deterministic mailbox
```

Use structured concurrency and actors:

- `AccountSession` actor owns tokens and refresh de-duplication.
- `GmailClient` uses `URLSession` with typed endpoints and injectable transport.
- `MailboxSyncEngine` actor serializes sync per account and publishes small change sets.
- `MailStore` actor owns SQLite access; UI never performs database or MIME work on the main actor.
- `AttachmentCache` enforces per-file, per-account, and total limits.

Use SQLite directly through a small, source-based Swift package such as GRDB only if its measured size and maintenance cost beat a thin SQLite3 layer. Make that choice in milestone 1 with a prototype benchmark. Do not use SwiftData/Core Data unless the same spike proves predictable migrations, FTS, and background access.

### Local data model

- `accounts`: Google subject, email, display name, latest history ID, sync timestamps.
- `labels`: Gmail ID, name, type, colors, visibility, counters.
- `threads`: ID, history ID, snippet, latest timestamp, cached aggregate flags.
- `messages`: ID, thread ID, internal date, headers, label IDs, size, body-cache state.
- `parts`: MIME tree metadata, attachment ID, content ID, filename, media type, size.
- `drafts`: Gmail draft/message IDs, local revision, remote revision, MIME source state.
- `correspondents`: normalized email, display name, frequency, recency, source.
- FTS5 index over sender, recipients, subject, and cached plain-text body.

Never persist OAuth tokens, raw authorization responses, tracking query data, or remote images. Store tokens only in Keychain. Encrypting the mail database is deferred because macOS Data Protection/FileVault already protects the user account and adding bundled SQLCipher conflicts with the size goal; document this honestly in the threat model.

### Gmail synchronization

1. On first sign-in, fetch profile and labels, then page through recent threads. Fetch enough metadata for a responsive list; fetch full conversation bodies lazily on selection.
2. Store the newest `historyId`. Refresh immediately on launch, foreground activation, wake, network recovery, account changes, and manual refresh. While OpenMime is running, poll once every 60 seconds and call `history.list` to apply additions/deletions/label changes transactionally.
3. If Gmail returns 404 for an expired history cursor, perform a reconciliatory full sync while preserving locally pending drafts/actions.
4. Apply optimistic UI updates for reversible actions, enqueue the remote mutation, and roll back with a visible error if it fails.
5. Coalesce mutations, use exponential backoff with jitter for 429/5xx responses, respect cancellation, and never retry permanent 4xx errors blindly.
6. Keep the 60-second timer suspended while offline and prevent overlapping polls. Add small random jitter when multiple accounts are configured. Closing all windows leaves OpenMime running and polling; explicitly quitting stops synchronization. Cloud Pub/Sub and IMAP are outside v1.
7. Gmail search uses server-side Gmail query syntax. Local FTS provides instant recent/offline results and is clearly labeled when offline.

### HTML and MIME rendering

- Parse MIME in a non-UI module with recursive depth, decoded-size, and decompression limits.
- Prefer a message's plain-text MIME alternative when the user selects plain-text mode. Render HTML email in a locked-down `WKWebView` after sanitization, with scripts off, no popups, no file access, no arbitrary navigation, a restrictive injected content security policy, and a nonpersistent website data store.
- Do not create one WebView per message. Collapsed messages remain lightweight native summary views. Reuse a single WebView for the selected/expanded HTML message where practical; allow a pool of at most two only if conversation usability testing proves it necessary and the aggregate 150 MB gate still passes.
- Tear down the renderer pool on account removal and under sustained memory pressure. Recreate a misbehaving WebKit process instead of allowing unbounded growth, while preserving selection and scroll state where possible.
- Offer an explicit “Open in Gmail” action for messages whose original layout cannot be represented safely.
- Block remote images by default and offer per-message load plus a user setting. Proxy nothing through an OpenMime service.
- Open links through the system after scheme validation. Never execute attachment content in-process.
- Strip active content and dangerous elements/attributes with an allowlist sanitizer covered by hostile fixtures.

## Repository layout

```text
.github/
  workflows/ci.yml
  workflows/release.yml
  dependabot.yml
OpenMime.xcodeproj/
Sources/
Packages/
Tests/
  Fixtures/                 redacted/generated MIME and API samples
  Unit/
  Integration/
  UI/
Scripts/
  bootstrap.sh
  ci.sh
  package_release.sh
  verify_release.sh
Config/
  Debug.xcconfig
  Release.xcconfig
  Secrets.example.xcconfig
Docs/
  architecture.md
  google-cloud-setup.md
  oauth-verification.md
  privacy.md
  threat-model.md
  testing.md
LICENSE                       Apache-2.0 (proposed)
README.md
CONTRIBUTING.md
SECURITY.md
```

OAuth client IDs are identifiers rather than effective secrets, but forks need their own Google Cloud project and consent screen. Keep the personal production client configuration in an untracked generated xcconfig and as a GitHub release-environment secret; commit only an example configuration and setup instructions. Never commit the downloaded OAuth JSON or embed a client secret as though it could protect a desktop app.

## Google Cloud setup and handoff

The required credential is an **OAuth 2.0 Desktop client**, not a Google API key. An API key cannot authorize access to a private Gmail account.

### One-time actions only the project owner can perform

1. Sign into [Google Cloud Console](https://console.cloud.google.com/) with the Google account that will own OpenMime's OAuth project.
2. Create or select a dedicated project such as `openmime-personal`. Do not reuse an unrelated production project.
3. In Google Auth Platform, choose an External audience and provide the app name, support email, and developer contact email.
4. While initially developing, add the one or two Gmail addresses as test users.
5. Create an OAuth client with application type **Desktop app**, name it `OpenMime macOS`, and download its JSON file.
6. Give Codex the local path to that downloaded JSON. Do not paste its contents into chat, commit it, or upload it to an issue.
7. After sign-in and token refresh are proven, publish the OAuth app to unverified Production so personal authorization does not expire every seven days. Google will show a click-through warning when each account first connects.

These browser steps require the owner's authenticated Google session and explicit consent, so they cannot be safely automated away.

### Work Codex should drive after receiving the JSON path

1. Validate that the file is a Desktop OAuth client and extract only the client ID and required redirect configuration into `Config/Secrets.local.xcconfig`, which is gitignored.
2. Enable the Gmail API and, only when optional contact suggestions are implemented, the People API. Prefer an authenticated `gcloud` command where available; otherwise take the owner directly to the exact Console page and verify the resulting state.
3. Wire the loopback PKCE callback, requested scopes, Keychain token storage, account picker, and disconnect/revoke flow.
4. Run the app, pause only for the owner's browser consent, then verify `users.getProfile`, token refresh after relaunch, and removal of local credentials.
5. Configure the same client values as protected GitHub release-environment secrets without placing the downloaded JSON in artifacts or logs.
6. Generate `Docs/google-cloud-setup.md` with reproducible instructions for forks to create their own OAuth project.

The project must continue to build and run in fixture mode without any Google credential, so pull requests and forks never depend on the owner's account.

## Testing strategy

### Unit tests on every pull request

- Endpoint encoding, pagination, retry classification, PKCE generation, and token refresh races.
- Gmail DTO mapping, label/category semantics, thread aggregation, and history application.
- RFC 5322/MIME parsing and generation: multipart alternatives, nested messages, Unicode headers, quoted-printable/base64, inline resources, malformed input, and size/depth bombs.
- Composer draft state, recipient normalization, optimistic actions, conflict/recovery behavior.
- Database migrations, FTS, cache eviction, account isolation, and deterministic sync checkpoints.
- HTML sanitization and URL-scheme policy with adversarial fixtures.

### Integration tests on every pull request

- Run the real URL loading stack against a local deterministic HTTP stub; exercise initial sync, pagination, incremental history, cursor expiry, rate limits, auth refresh, and offline recovery.
- Run SQLite repositories against temporary databases and migration snapshots.
- Round-trip generated messages through an independent MIME parser where licensing/size permit it as a test-only dependency.

No real Gmail credentials are used in pull-request CI, especially not for forks.

### UI and end-to-end tests

- Pull requests run a short deterministic XCUITest smoke suite: launch, seeded inbox, open thread, search, compose, save draft, send through fake transport, archive, and keyboard navigation.
- Nightly/manual workflow may use a dedicated disposable Gmail test account and encrypted environment secrets. It sends uniquely tagged mail to itself, verifies receipt/history updates, tests draft/update/delete, and always cleans up. It never runs on forked code.
- Accessibility tests assert identifiers, keyboard focus order, and critical VoiceOver labels; manual release QA covers VoiceOver, reduced motion, high contrast, and text sizing.

### Performance and release gates

- Benchmarks use generated 10k-thread/50k-message metadata and large/adversarial MIME fixtures.
- Track cold launch, mailbox render, scroll hitching, search latency, sync time, cache size, app bundle size, and energy impact. Record resident memory for the main app and every child/helper process separately, then gate on their aggregate.
- Release candidate gates: clean launch under 1 second on the documented reference Mac; first cached inbox render under 250 ms; local search p95 under 100 ms; normal aggregate memory target of 120–140 MB and a hard failure above 150 MB; signed app at or below 35 MB; no high-severity sanitizer/security failures.
- Treat numerical gates as targets until milestone 1 records a reproducible baseline and CI hardware variance.

## GitHub Actions

### `ci.yml`

Triggers on pull requests and pushes to `main`.

1. `lint`: SwiftFormat check, repository policy checks, secret scan, and generated-file drift check.
2. `test`: pin an Xcode version on a GitHub-hosted macOS runner; resolve packages from `Package.resolved`; build with warnings treated as errors; run unit and integration tests with code coverage.
3. `ui-smoke`: build and run the small XCUITest suite against fixture mode.
4. `analyze`: run Xcode static analysis and dependency/license audit.
5. `package-unsigned`: archive both `arm64` and `x86_64` release builds, create a universal app, verify architectures and bundle contents, report app size, and upload a short-lived unsigned artifact for maintainers. Never present this artifact as an end-user release.

Pin third-party actions to full commit SHAs. Give jobs minimal `permissions`, use concurrency cancellation for stale PR runs, do not expose secrets to forks, and retain test results/coverage on failures.

### `release.yml`

Trigger only on a signed tag matching `v*`, with a protected `release` environment and manual approval initially.

1. Verify tag/version/changelog consistency and rerun the complete test suite.
2. Archive Release builds for both architectures and combine only where necessary; fail if unexpected dynamic libraries or architectures are present.
3. Import the Developer ID Application certificate from encrypted GitHub secrets into an ephemeral keychain.
4. Sign with hardened runtime and timestamp; validate with `codesign --verify --deep --strict`.
5. Package a DMG, notarize with `xcrun notarytool`, staple the ticket, and validate with `spctl` plus `stapler validate`.
6. Generate SHA-256 checksums, an SBOM, acknowledgements/licenses, and a provenance attestation.
7. Publish the DMG, checksum, SBOM, and release notes to the GitHub Release using least-privilege `contents: write` only in the publish job.
8. Keep signing certificate, certificate password, Apple team ID, key ID, issuer ID/private key, and production OAuth client configuration in environment secrets. Delete the ephemeral keychain in an `always()` cleanup step.

Add automatic updates only after stable releases exist. Prefer Sparkle 2 with EdDSA signatures if its size/security tradeoff passes measurement; otherwise direct users to GitHub Releases for v1.

## Delivery milestones

### M0 — Project and compliance foundation (week 1)

- Select final name, bundle ID, license, minimum macOS, and icon/visual identity.
- Create Xcode project, package boundaries, formatting, CI, fixture mode, contribution/security docs.
- Complete the owner/Codex Google Cloud handoff: create the project and Desktop OAuth client, enable Gmail API, generate the local configuration, and prove one-account login. Defer People API enablement until contacts work begins.
- Draft privacy policy, data-flow diagram, threat model, and OAuth verification checklist.

Exit: a notarization-ready empty shell builds/tests in CI; a contributor can bootstrap without private credentials.

### M1 — Risk spikes and budgets (week 2)

- Prove system-browser PKCE sign-in, Keychain refresh, and account removal.
- Compare SQLite3 vs GRDB with migrations/FTS and select one.
- Prove sanitized WebKit MIME/HTML rendering on a representative fixture corpus; compare one reusable WebView against a maximum pool of two and keep the smallest design that meets conversation usability and the aggregate memory gate.
- Prototype virtualized 10k-row thread list and measure launch, scroll, memory, and bundle size.

Exit: architecture decisions are recorded; no unresolved risk makes the 35 MB size, 120–140 MB normal aggregate-memory target, or 150 MB hard ceiling implausible.

### M2 — Read-only mail vertical slice (weeks 3–5)

- Labels/sidebar, initial and incremental sync, cached thread list, conversation rendering, attachment download, Gmail and local search.
- Offline launch, stale-state indicators, cursor-expiry recovery, remote-image controls.

Exit: a tester can sign in and reliably browse/search a real Gmail mailbox without modifying it.

### M3 — Mail actions and composer (weeks 6–8)

- Archive/trash/spam/star/read/labels with optimistic state and rollback.
- Compose/reply/reply-all/forward, MIME generation, attachment upload, draft autosave, send.
- Local correspondent suggestions; optional People API connection and incremental consent.
- Resolve thread-list participant names through optional Google Contacts so rows match Gmail-style names (for example `Taylor, me`), with the message `From` display name as the offline/no-permission fallback.

Exit: complete daily email loop works against consumer Gmail and a Google Workspace test account.

### M4 — Quality and beta (weeks 9–10)

- Keyboard/menu polish, accessibility, account switching, error/recovery UX, cache controls.
- Security review, hostile MIME tests, performance/energy profiling, crash-free soak, localization readiness.
- Signed/notarized prerelease workflow and manual clean-Mac installation/upgrade checks.

Exit: published beta meets functional, security, size, and memory gates with known limitations documented.

### M5 — Public release (timing depends on Google verification)

- Complete OAuth restricted-scope verification and any currently applicable external security assessment.
- Finish privacy site, support/security intake, release notes, contributor docs, and reproducible release checklist.
- Publish `v1.0.0` DMG and checksums through GitHub Releases.

Exit: a new user can download, pass Gatekeeper, authenticate without an unverified-app warning, and complete the acceptance suite.

## v1 acceptance suite

On a clean supported Mac:

1. Install the notarized DMG and launch without bypassing Gatekeeper.
2. Sign into consumer Gmail in the system browser; restart and confirm silent token refresh.
3. Load a large mailbox, quit offline, relaunch, and browse cached mail.
4. Receive a new message and see it within one 60-second polling interval while OpenMime is running; verify immediate activation/manual refresh, then simulate an expired history cursor and recover without duplicates.
5. Search Gmail, open a multipart HTML/plain message, safely load remote images on demand, and download an attachment.
6. Compose with To/Cc/Bcc, formatting, Unicode, and attachments; save/reopen a draft; send and verify the resulting MIME in Gmail web.
7. Reply, reply-all, forward, star, read/unread, archive, label, spam, and trash; confirm Gmail web matches.
8. Decline contacts and compose successfully from local suggestions; then connect contacts and verify read-only suggestions.
9. Revoke Google access, observe a clear reauthentication state, then remove the account and verify tokens/database/cache are gone.
10. Run VoiceOver/keyboard smoke checks and record release size, memory, launch, search, and energy measurements.

## Decisions to make before implementation

- Final open-source license: Apache-2.0 is proposed for explicit patent terms; confirm project preference.
- Final bundle ID and Google Cloud project owner.
- Developer ID signing owner and whether v1 distribution is GitHub-only or also Mac App Store later.
- Whether multiple accounts are required for v1. The architecture supports them; a single-account UI could shorten the first beta.
- Whether the minimum target can be macOS 14. Lower targets increase compatibility work and reduce available SwiftUI behavior.
- Whether to include Sparkle in v1 after its measured bundle and maintenance cost is known.

## Primary external constraints

- Gmail `gmail.modify` is a restricted scope. Public clients need OAuth verification; avoid the broader `mail.google.com` scope because permanent deletion is not needed.
- Installed-app OAuth should use the authorization-code flow with PKCE in the system browser. Desktop loopback redirects are supported; an embedded web view and deprecated copy/paste flow are not acceptable.
- Gmail sync should combine a bounded initial sync with `history.list`, immediate lifecycle-triggered refreshes, and one poll per minute while running; an expired history cursor returns HTTP 404 and requires a full reconciliation.
- Gmail API push requires Cloud Pub/Sub infrastructure and IMAP OAuth requires the broader `mail.google.com` scope. Neither is used in the backend-free v1.
- People API contact search needs `contacts.readonly`, supports only a small result page, and requires a warm-up request before prefix search. Keep this optional.
- Direct macOS distribution needs Developer ID signing, hardened runtime, secure timestamp, notarization, and ticket stapling. GitHub Actions must use macOS runners for the signing/notarization toolchain.

## References

- [Google: Choose Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Google: OAuth 2.0 for iOS and desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google: Synchronize clients with Gmail](https://developers.google.com/workspace/gmail/api/guides/sync)
- [Google: People API `people.searchContacts`](https://developers.google.com/people/api/rest/v1/people/searchContacts)
- [Google: Gmail API `users.watch`](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/watch)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub: Workflow artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)
