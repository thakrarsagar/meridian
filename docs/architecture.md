# Architecture

Meridian has two substantial modules and a native host. Each hides behavior behind an interface small enough to exercise directly.

## Rust core

The host creates one core handle and submits JSON commands through `nord_core_call`. Commands return state and, when needed, a single effect. This seam contains catalogue validation, case-insensitive multiword search, recommendation eligibility, requested versus connected locations, retry policy, and request generations. Rust makes no system calls for networking or credentials.

The caller serializes calls on the main thread and frees each returned string once. Core input is limited to 1 MiB; the HTTP adapter applies tighter response limits before parsing. New Connect and Disconnect actions advance a generation. Async results from an earlier generation cannot change the current request.

Tests use this same command implementation rather than mocking its private parsing or state fields. A catalogue update is transactional: invalid data leaves the previous list available.

## Native VPN module

`NativeVPN` exposes observe, connect, disconnect, and status delivery. It hides private declarations, ordinary Authorization Services, session lifecycle, stop-before-save ordering, and independent readback of a saved configuration. The host supplies a validated hostname, username, and opaque persistent Keychain reference.

Ownership requires all of the stored UUID, application identifier, Meridian name, and IKEv2 protocol type to match. Finding a matching name alone never grants ownership. A first creation records its identity before saving so an interrupted save is recoverable. Writes are initiated only by explicit connection actions or restoration of a connection explicitly requested in the current process.

The module stops the old owned session before updating the endpoint. It verifies the saved hostname, remote identity, credential reference, and activation flags before asking the OS to start. Save visibility retries are bounded to six seconds; stop waits and connection attempts have separate deadlines. System-reported Connected is the only success signal.

On-demand configuration is disabled. This keeps a saved configuration from reconnecting merely because the user logs in or Meridian starts. A running Meridian restores an established, requested connection using one-shot retries with backoff up to sixty seconds. Initial failures and failed location switches require Retry. No retry changes the requested location.

## Native host

AppKit uses system fonts, semantic colors, SF Symbols, standard search and table controls, and native light/dark appearance. A single layout metric set keeps the compact popover consistent. Status, requested destination, actions, search, results, and refresh are ordered by their importance to the user. Keyboard users can search, move through results with arrow keys, and press Return to connect.

URLSession owns HTTP and TLS. Its ephemeral session has no cookies, credential storage, or URL cache. It bounds time and body size, refuses cross-host redirects, and counts requests and compressed response bytes using task metrics. The disk cache stores only public catalogue data and a Last-Modified value. It is refreshed on first use without a cache or by explicit request.

Keychain stores the password with access for this app and the relevant Apple VPN helpers. Only the username and a persistent reference leave the credential module. Certificate setup requires an explicit user action, a matching SHA-256 digest, and scoped EAP/IPsec trust. Existing user trust settings are preserved.

## Operational limits

The bundle and Keychain identifiers retain their initial local-preview identity across the Meridian rename. Existing saved credentials are concrete stored data; keeping the identifier avoids introducing a credential migration or adopting profiles by name.

Ad-hoc signing is suitable for this personal build, not general distribution. Private interfaces may disappear or change. Keychain access uses macOS login-Keychain ACL facilities that Apple has deprecated; native authentication must be tested on the target OS.

Live traffic changes, credential persistence, and reconnect behavior have not been proved by the offline tests. A dedicated live acceptance session must verify these while checking actual Tailscale reachability. No development script changes network configuration.
