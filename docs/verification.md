# Verification

Date: 2026-10-24. Initial local release build on Apple Silicon, macOS 26.5.2.

## Passed

- Rust formatting, three focused tests, and Clippy with warnings denied. Cases include an eligible city recommendation, an unexpected disconnect and retry, explicit cancellation, stale callbacks, wrong-location/offline/untrusted-host recommendations, retained requests after failure, and an invalid refresh preserving the catalogue.
- Optimized native compilation and ad-hoc signature verification.
- Native offline self-check through the Rust C interface. Required native controls are present on this OS. This check does not save a profile, access credentials, change trust, or start a tunnel.
- Real requests through the production URLSession implementation and Rust validation: 150 countries, 225 cities, a matching online IKEv2 recommendation, and conditional catalogue refresh returning 304. No returned connect effect is executed by this check.
- AppKit accessibility and visual inspection in the native preview. Verified live search, empty results, arrow-key selection, connection-button enablement, branding, and Settings. Settings text wrapping was corrected after inspection.
- Public-source scan for local machine paths, device identifiers, email addresses, and token/private-key patterns. Diagnostic scratch files and build products are excluded from Git.

Reproduce the offline checks with `rtk proxy bash scripts/check.sh`. Optional live public-metadata verification uses `rtk proxy build/Meridian.app/Contents/MacOS/Meridian --check-catalogue`; it makes three public requests and performs zero VPN operations. `--preview` opens the same interface in a standard native window for accessibility inspection.

## Nord Account import, version 0.2.0

- Offline checks exercise the production HTTP and import implementation with URLProtocol, a controlled browser callback, and a recording save. They cover proof-key binding, Nord's required `Bearer token:` authorization format, invalid/duplicate return parameters, an untrusted login URL, failed/invalid credential responses, browser cancellation, and cancellation during credential retrieval. Tests open no browser, contact no server, and touch no Keychain or VPN.
- A live attempt reproduced HTTP 400 after successful browser return and token exchange. The credential request had omitted Nord's required `token:` prefix. The corrected contract fixture failed before the header fix and passed afterward. A public probe using a deliberately invalid, correctly shaped dummy token distinguished malformed authorization, HTTP 400, from accepted syntax with invalid credentials, HTTP 401.
- The corrected native build completed a real browser sign-in, token exchange, credential fetch, and Keychain save on this Mac. The existing Brave session completed authentication without entering an account password into Meridian. The native UI confirmed that the IKEv2 credentials were saved. Account tokens and credential values were neither logged nor exported.
- Native UI inspection verified the compact account view, optional manual-entry disclosure, and Choose a location returning to the catalogue while still Disconnected. Saved credentials remain available after restarting the app. OS consent and Nord's authentication/MFA steps remain under user control.
- The updated shared transport passed the public metadata check: 150 countries, 225 cities, a valid online IKEv2 recommendation, and conditional HTTP 304. Three requests transferred 13,084 response-body bytes; zero VPN effects were executed.

Account import was tested independently of VPN activation. No network preference, certificate trust, installed browser default, or Tailscale setting was changed during this work.

Read-only checks after import matched the starting Wi-Fi power state, configured Wi-Fi DNS, and Tailscale running/DNS/route/shield preferences. No Meridian VPN service or saved profile identity was present.

The final 0.2.0 release executable is 1,114,288 bytes and its app bundle is 1,527,125 bytes, approximately 1.46 MiB. A fresh normal menu-bar process with the popover closed used 49,264–49,280 KiB RSS, approximately 48.1 MiB. Four one-second-spaced samples reported 0.0% CPU and unchanged cumulative CPU time. This is a short idle sample, not a hard cap or a physical-footprint measurement. The external browser's authentication cost and active IKEv2 service cost are excluded.

## Credential access repair, version 0.2.1

The user reported a repeated native VPN password dialog. Read-only inspection found that Meridian's saved profile had the current username and persistent Keychain reference. The stored entry trusted `neagent` and `nesessionmanager`, but omitted the Apple IKEv2 provider process seen in the connection logs. No secret values or private profile identifiers were inspected or exported.

The read-policy regression check failed before adding that process. It now checks the production policy and verifies that repairing an older in-memory policy is idempotent. A separate local probe applied the production repair to a copy of the real entry's policy: the first pass added the missing reader and the second changed nothing. Independent metadata readback confirmed that the stored policy and reference remained unchanged during verification. Rust checks, the optimized native build, signature verification, and offline native/account checks passed.

The updated app repairs an older entry at the next requested connection, before handing its reference to native VPN controls. Verification did not start or stop a tunnel, change a saved VPN profile, or modify the real entry's policy. An actual connection is still required to confirm that this resolves the dialog; the access defect alone does not rule out a further native credential lookup or server-authentication issue.

## Initial measurements

| Measurement | Observed |
| --- | --- |
| Release executable | 982,064 bytes |
| Complete release app bundle | 1,394,901 bytes |
| Native preview open, RSS | 65,872–66,016 KiB, approximately 64.3–64.5 MiB |
| Same process with preview closed, RSS | 35,776–36,800 KiB, approximately 34.9–35.9 MiB |
| Idle CPU in both states | 0.0% in four one-second-spaced samples; cumulative CPU time unchanged within each sample window |
| Catalogue decoded body | 56,259 bytes |
| Recommendation decoded body | 4,035 bytes |
| Three-request metadata check, transferred response bodies | 13,122 bytes total, including the conditional 304 |

These are initial short samples, not a hard budget or a long-duration profile. The preview uses a standard window to make accessibility inspection possible; exact popover memory may differ. RSS includes resident shared framework pages and is not equivalent to Apple's physical-footprint metric. Network numbers cover response bodies, not DNS/TLS/header overhead. Byte counts and bundle size can change between builds and API responses.

No tunnel was activated during these measurements. Incremental IKEv2 service memory/CPU and traffic throughput remain unmeasured. No hard memory cap has been selected yet.

## Live acceptance still required

Perform only when the user separately requests a live test, starting from their working network. Verify actual service-credential authentication, Keychain reference reuse by Apple helpers, native save/start/stop, country/city switching, failed-switch Retry, disconnect, sleep/wake, and network changes. Check actual Tailscale connectivity throughout. Capture results without account secrets or private network identifiers in public logs.

The user previously completed certificate setup and manual credential entry during preview. Version 0.2.0 additionally completed automatic service-credential import into Keychain. These checks do not prove that Apple helpers can use the saved reference or that the tunnel connects. Meridian itself never asks for a Nord Account password.

Known risks are unsupported private macOS controls, deprecated login-Keychain ACL facilities, and unverified live transition behavior. The app does not implement a kill switch. See [the feasibility record](feasibility-report.md) for the earlier bounded experiment and subsequent connectivity incident.
