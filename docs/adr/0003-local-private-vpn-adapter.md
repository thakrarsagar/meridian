---
status: accepted
---

# Isolate local private VPN control

The personal app requires native IKEv2 without paid Apple signing. Public Personal VPN provisioning is unavailable under that constraint. A bounded test demonstrated a disabled configuration write and removal by an ad-hoc-signed ordinary-user app with standard Authorization Services.

Use a native module around private configuration and session controls. Rust owns catalogue validation, selection, and connection decisions. The native module hides ownership checks, authorization, save visibility, and session lifecycle behind observe, connect, disconnect, and status delivery.

Control only the stored Meridian UUID with matching application ownership and protocol type. Preserve other VPNs, Tailscale, Wi-Fi, global DNS, routes, and security settings. Never add entitlement bypasses or a privileged helper to work around failure.

Private controls may break after a macOS update. The app must fail clearly. Actual activation, credential access, switching, and coexistence remain unverified until a separately authorized live test. The user confirmed implementation with these limits and required current working networking to remain unchanged.
