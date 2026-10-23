# Native Nord location switcher

Status: design confirmed for implementation on 2026-10-24. Initial native build implemented; live VPN acceptance remains pending.

## Accepted scope

- Fetch every currently available Nord IKEv2 country and city and switch one reusable native configuration.
- Use a Rust core with native Apple adapters for HTTP, Keychain, and VPN control.
- Use a compact native menu-bar interface with search, clear status, and a small settings window.
- Build for the current Mac first without paid signing, using the tested private configuration path and ordinary OS authorization.
- Preserve existing network and Tailscale settings. Actual coexistence must be checked in a separately requested live test.
- Allow ordinary internet to use its normal connection during a switch or disconnection. No kill switch.
- Restore the chosen connection after an established session drops, sleep, or a network change while the app is running, until explicit Disconnect. No startup connection.
- Keep a failed switch's requested location and offer Retry rather than choosing a different location.
- Store service credentials only in Keychain. Keep the password out of Rust and HTTP.
- Measure the initial native release before adopting a hard memory cap. Report OS VPN costs separately.

## Implementation

The Rust library validates and searches the small country/city catalogue and accepts only matching online IKEv2 recommendations. The AppKit host uses system controls and system TLS. The native VPN module authorizes writes, enforces ownership, stops the old owned session, verifies settings, and observes native connection status.

The app fetches the catalogue on first opening without a cache and on manual refresh. A connection request fetches one recommendation. Reconnect uses the selected endpoint with backoff. There is no background catalogue polling, telemetry, web runtime, helper, custom network engine, or system extension.

## Acceptance

Offline tests must cover catalogue validation, matching recommendations, stale generations, cancellation, retained requests after failure, and retry decisions. The native build must pass the Rust interface self-check and UI inspection without VPN or trust writes.

Live acceptance must separately cover real authentication, Keychain reuse, location switching, failure handling, disconnect, sleep/wake, and network changes while proving Tailscale reachability. Building the app does not authorize development tools to perform those live actions.

See [verification](verification.md), [architecture](architecture.md), and the [private-adapter decision](adr/0003-local-private-vpn-adapter.md).
