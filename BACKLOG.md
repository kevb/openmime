# OpenMime backlog

This is the working product backlog. `BUILD_PLAN.md` remains the original architecture and release plan.

## Next candidates

- Label creation, renaming, deletion, and color management. Applying/removing existing labels is complete.
- Rich-text compose: native formatting controls, safe HTML MIME generation, signatures, and inline images.
- Use connected Google Contacts to enrich Gmail-style thread participant names such as `Taylor, me`; retain message-header names as the offline fallback.
- Continue keyboard/accessibility polish: focus rings, label-picker traversal, attachment controls, and a full VoiceOver audit. J/K navigation, Escape selection clearing, menu commands, and primary row/recipient descriptions are complete.
- Cache controls: show cache size, clear cached mail/rendered conversations, and enforce/document retention bounds.
- Multiple accounts: account switcher, account-isolated state, and compose sender selection.

## Deferred distribution work

- Join the Apple Developer Program only if public distribution justifies its annual cost.
- Create a Developer ID Application certificate and sign with hardened runtime and a secure timestamp.
- Restore OAuth refresh-token storage to Keychain once the app has a stable Developer ID identity. Until then, personal development builds use an owner-only `0600` file under Application Support to avoid repeated Keychain prompts.
- Notarize and staple release builds, package a DMG, and enable signed GitHub release automation.
- Pursue Google's restricted-scope OAuth verification only if the open-source project attracts external users.
- Evaluate Sparkle updates after stable signed releases exist.

## Later polish

- Configurable notification behavior and Dock badge.
- Sender-specific remote-image preferences management.
- Localization readiness and appearance customization.
- Performance, energy, and aggregate WebKit memory profiling against the 150 MB target.

## Recently completed

- Reliability pass: persistent freshness timestamps, visible checking/offline state, cached offline launch, expired-session recovery, and verified one-minute polling.
- Optional Google Contacts: separate contacts-only OAuth, compose connect/dismiss flow, independent settings state, owner-only local cache, and merged address suggestions with the existing offline fallback.
- Existing Gmail labels: searchable picker, single/multi-thread apply and remove, mixed-selection state, optimistic rollback, cached membership, and conversation chips.
- Native thread context menu exposing existing read/star/archive/trash/spam/label actions and reply/forward when the conversation is loaded.
- First keyboard/accessibility pass: J/K navigation, Escape selection clearing, Conversation menu commands, composer-safe shortcut disabling, and VoiceOver descriptions for threads and recipient chips.
