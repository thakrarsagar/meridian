# Architecture

Meridian has a Rust core, native platform modules, and an AppKit host. Each hides behavior behind an interface small enough to exercise directly.

## Rust core

The host creates one core handle and submits JSON commands through `nord_core_call`. Commands return state and, when needed, a single effect. This seam contains catalogue validation, case-insensitive multiword search, recommendation eligibility, requested versus connected locations, retry policy, and request generations. Rust makes no system calls for networking or credentials.

The caller serializes calls on the main thread and frees each returned string once. Core input is limited to 1 MiB; the HTTP adapter applies tighter response limits before parsing. New Connect and Disconnect actions advance a generation. Async results from an earlier generation cannot change the current request.

Tests use this same command implementation rather than mocking its private parsing or state fields. A catalogue update is transactional: invalid data leaves the previous list available.

## Native VPN module

`NativeVPN` exposes observe, connect, disconnect, and status delivery. It hides private declarations, ordinary Authorization Services, session lifecycle, stop-before-save ordering, and independent readback of a saved configuration. The host supplies a validated hostname, username, and opaque persistent Keychain reference.

Ownership requires all of the stored UUID, application identifier, Meridian name, and IKEv2 protocol type to match. Finding a matching name alone never grants ownership. A first creation records its identity before saving so an interrupted save is recoverable. Writes are initiated only by explicit connection actions or restoration of a connection explicitly requested in the current process.

The module stops the old owned session before updating the endpoint. After authorization, it loads and validates the owned profile through the same manager that will save it. Revision caches belong to each manager; passing a profile from a reader to an unloaded writer causes a stale-configuration error on updates. Ownership and the operation generation are checked again after that load. A separate fresh manager verifies the saved hostname, remote identity, credential reference, and activation flags before the OS is asked to start. Save visibility retries are bounded to six seconds; stop waits and connection attempts have separate deadlines. System-reported Connected is the only success signal.

At Start, the adapter resolves the supplied persistent reference with a read-only Keychain query and passes the username and password through Apple's documented [per-start credential options](https://developer.apple.com/documentation/networkextension/nevpnconnectionstartoptionpassword). The private session transport takes an XPC dictionary, matching [Apple's SystemConfiguration implementation](https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/SCNetworkConnection.c). This avoids relying on the provider's failed lookup of the login-Keychain reference. The password exists transiently in the native start operation; it never reaches Rust, logs, files, or app state. Denied or invalid credential access prevents Start. The operation is checked again after the Keychain read because authorization may run a nested event loop.

The native Connect regression test uses in-process configuration-manager, authorization, Keychain, and session adapters. It exercises the production Connect method with an existing profile, rejects an unloaded writer, and verifies that a post-authorization ownership conflict never reaches Save. Dummy credential reads verify the actual XPC option keys and that denied access or cancellation during a read never reaches Start. It does not call the system's save/start/stop or Keychain APIs or persist preferences.

On-demand configuration is disabled. This keeps a saved configuration from reconnecting merely because the user logs in or Meridian starts. A running Meridian restores an established, requested connection using one-shot retries with backoff up to sixty seconds. Initial failures and failed location switches require Retry. No retry changes the requested location.

## Native host

AppKit uses system fonts, semantic colors, SF Symbols, standard search and table controls, and native light/dark appearance. A single layout metric set keeps the compact popover consistent. Status, requested destination, actions, search, results, and refresh are ordered by their importance to the user. Keyboard users can search, move through results with arrow keys, and press Return to connect.

URLSession owns HTTP and TLS. Its ephemeral session has no cookies, credential storage, or URL cache. It bounds time and body size, refuses redirects, and counts requests and compressed response bytes using task metrics. The disk cache stores only public catalogue data and a Last-Modified value. It is refreshed on first use without a cache or by explicit request.

Keychain stores the password with access for this app, `neagent`, `nesessionmanager`, and Apple's actual `NEIKEv2Provider` executable, resolved from the system framework's plug-ins directory. New saves and replacements include this read policy. Before a requested connection, the credential module repairs an older entry's decrypt policy only if the IKEv2 reader is missing. This appends that reader while preserving other readers, prompt flags, the secret, and the persistent reference. An already-correct policy is not rewritten. Startup and Settings reads remain read-only. Only the username and persistent reference leave the credential module; the native VPN adapter reads the password at Start. Certificate setup requires an explicit user action, a matching SHA-256 digest, and scoped EAP/IPsec trust. Existing user trust settings are preserved.

## Nord Account import

`NordAccount` exposes sign-in and cancel. Its injected adapters are the shared bounded HTTP transport, a browser opener, and a credential save operation. The production adapters use AuthenticationServices and Keychain; tests use URLProtocol, a controlled return link, and a recording save. Tests cross the same interface as Settings, including cancellation while fetching credentials.

Each attempt uses a new random 24-byte proof key. Nord's published client protocol encodes the verifier and SHA-256 challenge in hexadecimal. The returned login URL must be Nord's exact HTTPS login-redirect endpoint and carry the matching UUID. Apple handles browser authentication and the session-local `nordvpn` return scheme; Meridian does not register or replace the system's NordVPN URL handler.

The return link must match the expected scheme, host, action, and status, contain a single bounded exchange token, and contain no duplicate parameters or user information. The token exchange includes the current attempt and verifier. Meridian fetches only the service-credential endpoint using the short-lived account token, ignores refresh tokens and unrelated response fields, and saves the IKEv2 username/password through the existing Keychain operation. Nord requires `Authorization: Bearer token:<value>`, as implemented in its [request helper](https://github.com/NordSecurity/nordvpn-linux/blob/main/request/request.go). A plain Bearer value causes HTTP 400. The offline success fixture enforces this wire contract. Meridian does not persist account tokens, poll, refresh an account session, or expose secrets to Rust or logs.

A generation guard and five-minute deadline cover the whole import. Cancellation stops the browser and pending request; superseded completions cannot save credentials. Invalid responses and failed requests preserve the existing entry. A successful import does not save, update, start, or stop any VPN. Credential replacement is explicit through sign-in or manual save.

Settings presents sign-in first, with manual entry behind a disclosure. Its activity indicator runs only during import. Completion brings Settings forward and offers Choose a location without connecting. HTTP errors identify whether opening sign-in, verifying the return, or fetching credentials failed; response bodies and tokens never appear in errors.

This uses Nord's published first-party client protocol, rather than a documented independent-app OAuth registration contract. Vendor changes may require maintenance. The system browser has its own resource use; it is not embedded in Meridian. The legacy initializer on macOS 14.0–14.3 preserves the published deployment target; newer systems use Apple's callback object.

## Operational limits

The bundle and Keychain identifiers retain their initial local-preview identity across the Meridian rename. Existing saved credentials are concrete stored data; keeping the identifier avoids introducing a credential migration or adopting profiles by name.

Ad-hoc signing is suitable for this personal build, not general distribution. Private interfaces may disappear or change. Keychain access uses macOS login-Keychain ACL facilities that Apple has deprecated; native authentication must be tested on the target OS.

Live traffic changes, credential persistence, and reconnect behavior have not been proved by the offline tests. A dedicated live acceptance session must verify these while checking actual Tailscale reachability. No development script changes network configuration.
