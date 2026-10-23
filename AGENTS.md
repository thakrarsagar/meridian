# Meridian conventions

Read `CONTEXT.md` for domain language and `docs/architecture.md` before changing a module's interface. The design follows [codebase-design](https://github.com/mattpocock/skills/blob/main/skills/engineering/codebase-design/SKILL.md): put substantial behavior behind a small interface, and test through the same seam callers use.

- Rust owns catalogue validation, search, server eligibility, and connection decisions. It returns effects; it performs no network or platform operations and never receives credentials.
- Swift owns AppKit, URLSession, Keychain, and delivery of system events. Objective-C isolates private native VPN control. Add a seam only when behavior actually varies there.
- All model and UI calls run on the main thread. Async completions carry a generation; discard results from superseded requests.
- Nord Account sign-in is a one-shot native credential import. Keep proof keys and account tokens in memory, validate the attempt and return link, and save only IKEv2 service credentials. Cancellation must prevent late callbacks from changing Keychain. Use AuthenticationServices without registering Nord's URL scheme globally. Sign-in never starts a VPN or changes network preferences. Check wire conventions against Nord's published client, including its request helper, before encoding them in fixtures.
- VPN writes and session control require an explicit user connection action. Control only the UUID stored by Meridian, with matching application ownership and protocol type. Never adopt an existing VPN by name.
- Preserve Wi-Fi, DNS, routes, Tailscale, other VPNs, and system security. Development verification uses offline self-checks and read-only inspection. Live VPN tests require a separate user request.
- Use AppKit controls, semantic system colors, SF Symbols, keyboard navigation, and accessibility labels. Keep layout metrics in `Style`; use native appearance and reduced-motion behavior. No embedded browser, downloaded fonts, decorative animation, or custom rendering loop.
- Use system HTTP/TLS. Fetch locations on first use and explicit refresh; fetch one recommendation per Connect. Bound response size and time. No catalogue polling, full inventory, telemetry, or continuous probes.
- Keep errors actionable and connection status truthful. A requested location is distinct from a confirmed connection. A failed switch retains the request and offers Retry.
- Prefix shell commands with `rtk`; use `rtk proxy` for unfiltered commands. Build and check with the scripts under `scripts/`. Run Rust tests and the offline native self-check for behavior changes.
- Keep public files free of credentials, local network identifiers, machine paths, logs, and diagnostic scratch files. Commit the lockfile; exclude build products and caches.

Before adding a dependency or module, explain which existing platform facility cannot meet the requirement. Measure release memory and CPU rather than claiming a footprint from language choice.
