# Meridian

A small native macOS menu-bar app for choosing NordVPN IKEv2 countries and cities. Rust handles the catalogue and connection decisions. AppKit supplies the interface; macOS supplies the VPN engine.

Meridian is an independent, unofficial project. It requires an active NordVPN subscription and Nord **service credentials**, which differ from your account sign-in.

## Current status

This is an early preview with a downloadable Apple Silicon app. Nord Account sign-in and automatic Keychain import passed a live check on the development Mac. The user confirmed VPN connections and seamless location switching. Independent Tailscale reachability across switching, sleep/wake, and network changes remains unverified. The catalogue, Rust state transitions, native compilation, and offline checks pass.

The no-paid-signing implementation uses private macOS configuration and session controls with ordinary OS authorization. It does not install a helper or weaken system security. These unsupported interfaces can change after a macOS update. The documented minimum deployment target is macOS 14; runtime availability is checked, but OS compatibility must be tested individually.

## Download and install

Download [Meridian 0.2.4 for Apple Silicon](https://github.com/thakrarsagar/meridian/releases/download/v0.2.4/Meridian-v0.2.4-macOS-arm64.zip) from the [GitHub release](https://github.com/thakrarsagar/meridian/releases/tag/v0.2.4). Running the app does not require Rust, Apple's Command Line Tools, or any command wrapper.

1. Unzip the download and move `Meridian.app` to Applications.
2. Open Meridian. This preview is ad-hoc signed and **not notarized**. macOS may block its first launch. Review [Apple's guidance for unidentified developers](https://support.apple.com/en-us/102445) before deciding whether to allow it. If you choose to proceed, use the app-specific **Open Anyway** action in System Settings > Privacy & Security after the first launch attempt. Managed Macs may not permit this.
3. Open Meridian's menu-bar icon, then Settings, and complete the Nord Account and certificate setup described below. A NordVPN subscription is required.

The binary is ARM64 for Apple Silicon and targets macOS 14 or later. Live testing has only covered one Apple Silicon Mac running macOS 26.5.2. There is no Intel download yet. The release includes `SHA256SUMS.txt` for checking download integrity. No kill switch is implemented; read the connection behavior below before use.

## Build

Install Apple's Command Line Tools and a stable Rust toolchain through rustup. Then run:

```sh
rustup component add rustfmt clippy
bash scripts/check.sh
open build/Meridian.app
```

The script uses the rustup toolchain explicitly, builds for the current Mac's architecture, and ad-hoc signs `build/Meridian.app`. It does not install or launch the application, register a login item, change a VPN, or request a network authorization. No paid signing identity is needed for this local build. This is not a notarized distribution build.

`--self-check` exercises Rust through the native interface and checks native symbol availability. It never saves a VPN, accesses credentials, installs certificates, or starts a tunnel:

```sh
build/Meridian.app/Contents/MacOS/Meridian --self-check
```

For a read-only check against Nord's current public metadata, run the same executable with `--check-catalogue`. It fetches and validates the catalogue and one recommendation, tests conditional refresh, and reports body-transfer metrics. It performs no VPN operation.

## Use

1. Open Meridian from the menu bar. The first opening fetches all available IKEv2 countries and cities; subsequent launches use the disk cache. Use Refresh to update it.
2. Open Settings and choose **Sign in with Nord Account**. Complete any browser consent, Nord sign-in, and MFA that Nord requests. An existing browser session can complete automatically. Meridian returns to the foreground, fetches your IKEv2 service credentials, and saves them in the login Keychain. Choose **Choose a location** when ready. Your account password stays in the browser; account tokens are discarded after import. Manual IKEv2 entry is available behind **Enter IKEv2 credentials manually**. Sign-in does not connect a VPN.
3. If Nord's IKEv2 certificate is not already trusted, use the explicit certificate setup action or the linked official guide. The installer verifies the reviewed certificate's SHA-256 digest and scopes new trust to EAP and IPsec. It refuses to overwrite existing custom trust settings.
4. Select a country for its fastest available server, or choose a city, then click Connect. macOS may request authorization to create or update Meridian's own native configuration.

Version 0.2.1 also repairs older Meridian Keychain entries that omitted Apple's IKEv2 password reader. The repair runs on a requested connection, preserves the credential reference and existing access rules, and skips writes once access is correct. It does not require another Nord Account sign-in. A live connection must still confirm that the repeated VPN password dialog is resolved.

Version 0.2.2 fixes the stale-profile save error on existing configurations. The saving manager reloads the profile and its revision after authorization, then validates ownership again before updating it. The app retains the existing profile identity and Keychain reference.

Version 0.2.3 supplies the saved IKEv2 credential through Apple's per-start password option. The native adapter reads it from Keychain only when starting a requested connection. A failed Keychain read prevents Start, and subsequent Disconnected events preserve the detailed error. The user subsequently confirmed that VPN connection and location switching work.

Version 0.2.4 groups locations under expandable country rows. Countries with one city have a single option. Countries with multiple cities expand to show “Any city” and individual city choices. City searches open the matching country, and searching for a sole city's name still finds its country.

A selected location is a request. Meridian displays Connected only after the native session reports it. A failed switch keeps the requested location and offers Retry. Cancel and Disconnect invalidate pending requests. Reconnection attempts use backoff after an established connection drops, while Meridian remains open; the app does not connect merely because it launches.

Quitting leaves the current VPN as it is and stops the app's automatic reconnects. Disconnect explicitly before quitting if you want the tunnel stopped.

## Footprint and network behavior

- One app process, an in-process Rust library, and Apple's IKEv2 engine. No web runtime, VPN daemon, packet engine, analytics, or login item.
- No catalogue polling or latency probes. A first-use/manual catalogue fetch and one recommendation request per Connect use system URLSession and TLS.
- Bounded responses, conditional catalogue refresh, a small disk cache, and event-driven VPN status. Automatic reconnection reuses the selected endpoint.
- Account import makes three bounded API requests plus the system browser's sign-in traffic. No account polling, persistent account session, embedded web view, or added HTTP/TLS library.
- No Wi-Fi, global DNS, route, Tailscale, or other-VPN preference changes. Only Meridian's UUID with matching app ownership can be updated or controlled.
- No kill switch. Disconnect stops the NordVPN tunnel and automatic reconnects; your normal internet connection remains available. If the tunnel drops or a location switch leaves a gap, ordinary traffic may use that connection until the VPN reconnects.

Tailscale coexistence is a design requirement and a live acceptance test, not a guaranteed result of these settings. See [verification](docs/verification.md) for measurements and known limits.

## Source map

| Module | Responsibility |
| --- | --- |
| `src/lib.rs` | Validate locations and recommendations, search, state transitions, and stale-request protection |
| `native/Core.swift` | Rust interface and bounded system HTTP transport |
| `native/App.swift` | AppKit interface, cache, and event delivery |
| `native/Credentials.swift` | Keychain references and explicit, scoped certificate setup |
| `native/NordAccount.swift` | Native browser sign-in, proof-key exchange, bounded credential import, and cancellation |
| `native/NativeVPN.m` | Owned-profile checks, ordinary authorization, verified saves, and private native session control |

Read [AGENTS.md](AGENTS.md) for engineering conventions and [architecture](docs/architecture.md) for the small interfaces and their invariants. The module design follows [Matt Pocock's codebase-design skill](https://github.com/mattpocock/skills/blob/main/skills/engineering/codebase-design/SKILL.md).

## References

- [Nord's native IKEv2 setup guide](https://support.nordvpn.com/hc/en-us/articles/19921536696977-How-to-connect-to-NordVPN-with-IKEv2-IPSec-on-macOS)
- [Apple Personal VPN](https://developer.apple.com/documentation/networkextension/personal-vpn)
- [VPNStatus source documenting native session control](https://github.com/Timac/VPNStatus)

Private declarations and behavior must be reviewed after macOS changes. Never remove ownership checks or authorization to work around a platform failure.

Account sign-in follows the protocol in [Nord's published Linux client](https://github.com/NordSecurity/nordvpn-linux/blob/main/core/authentication.go). It is not a documented third-party OAuth registration contract. Meridian uses a session-local browser return handler and leaves the installed NordVPN app's URL registration alone.
