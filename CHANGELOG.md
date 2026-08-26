English | [简体中文](./CHANGELOG_ZH.md)

# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 27.0

This entry records only the final net change in the current source tree relative to the remote `main` baseline.

### Added

- Added multi-modem session ownership through `ModemSessionCoordinator`, with one long-lived IMEI-indexed `ModemStore` per physical module, explicit selection, notes, bind/unbind state, retained-entry deletion, SIM-scoped content, and module-routed notifications.
- Added support for the original first-generation DJI USB identity `2ca3:4006` alongside `2c7c:0125`, including a confirmation-gated identity-only configuration flow with backup, restart, verification, and rollback.
- Added a continuous AT reader, line framer, prompt handling, response collector, unsolicited-event classifier, and event bus so modem events and command transactions share one USB input stream safely.
- Added PDU-mode SMS with text-mode fallback, GSM 7-bit/UCS2 decoding, multipart assembly, binary classification, verification-code extraction, rich links, notification routing, and schema-v3 logical/transport archive repair with iCloud Drive backup support.
- Added deterministic call-state and caller-identity handling, Contacts lookup, call history, DTMF feedback, SIM phonebook capability probing, native call surfaces, CoreAudio/AudioUnit duplex audio, bounded resampling, device preflight, recording, ringtone import, and direct-host System Audio input.
- Added the opt-in QDC507 voice-runtime path. It downloads the fixed MaVo commit only after consent, verifies sizes and SHA-256 values, caches artifacts locally, binds deployment to the same physical module, and gates execution on root, Linux `3.18.44`, identity, ownership, and active-route checks.
- Added GNSS source fallback and USB NMEA handling, network-interface and route diagnostics, traffic history, recovery policy, diagnostic snapshots, date/time preferences, appearance selection, and the validated system-helper protocol for IKE and network-service operations.
- Added remote protocol v2 events, USB NMEA relay, bounded 8 kHz duplex audio frames, and direct-host session repair after a confirmed USB-identity-changing reboot.
- Added local eUICC profile labels, phone numbers, and tags keyed by EID and ICCID, while keeping those values out of card writes.

### Changed

- Reworked the presentation layer into a fixed `640×700 pt` native menu bar popover and a fixed `993×827 pt` standalone window with a non-resizable `216 pt` sidebar, independent navigation state, native `tabBarOnly` categories, shared page components, and all nine primary sections always available.
- Reworked SMS presentation into a Messages-style conversation workspace with safe-area bars, bounded bubbles, links, verification-code copy actions, and management controls in Settings.
- Reorganized Overview, Phone, GNSS, Network, eSTK, VoWiFi, Terminal, and Settings around shared parameter grids, page-local search, localized empty states, consistent scrolling, and system semantic colors and typography.
- Moved privileged IKE and network-service operations behind the new SMAppService system helper while retaining the legacy IKE helper for migration fallback and rollback.
- Extended module-configuration backups and verification to schema v3 fields including IMS, `volte_disable`, and the complete reported USB composition; the QDC507 plan preserves VID/PID and unrelated functions while enabling only the required ADB/UAC interfaces.
- Made version 27.0 and Apple Silicon `arm64` the source and packaging defaults. The package flow now builds both helpers and patched lpac, removes extended attributes, applies ad hoc signatures, and performs deep bundle verification.

### Fixed

- Prevented unsolicited call, SMS, SIM, restart, and disconnect lines from being mistaken for command responses, and guarded notification-center access outside an application bundle.
- Added call-epoch and user-answer gates so stale asynchronous results and ambiguous `CLCC` states cannot activate, terminate, or overwrite another call.
- Removed the single-sample-rate assumption from call audio, added bounded endpoint recovery, excluded modem capture endpoints from physical-microphone fallback, and required `AT+QPCMV=1,2` verification before standard-mode dial/answer audio.
- Rebuilt legacy and cloud SMS projections from transport evidence, retaining incomplete or uncertain records outside the visible logical layer and giving deletion tombstones merge precedence.
- Restored the direct host's complete modem session and event subscriptions before a remote client resumes after an identity-changing reboot.

### Validation boundary

- The source tree includes focused automated coverage and packaging-time bundle/signature checks for these changes. Those checks validate code paths and generated structure when run; they do not prove real-device behavior.
- Multi-module hardware routing, EC25/Baiwang call audio, the optional QDC507 download/deployment path, carrier calls, USB NMEA, module-configuration changes, eUICC operations, two-Mac remote media, and carrier VoWiFi/IMS still require current hardware and network acceptance.
- Local packages are ad hoc signed and not notarized. SMAppService registration, approval, upgrade, and removal require acceptance with a properly signed distribution build.
