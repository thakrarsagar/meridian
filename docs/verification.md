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

The user completed certificate setup and credential entry during preview. This demonstrates that those UI actions ran locally, not that the entered credentials authenticate or that the tunnel connects. Meridian itself never asks for a Nord Account password; use manual IKEv2 service credentials.

Known risks are unsupported private macOS controls, deprecated login-Keychain ACL facilities, and unverified live transition behavior. The app does not implement a kill switch. See [the feasibility record](feasibility-report.md) for the earlier bounded experiment and subsequent connectivity incident.
