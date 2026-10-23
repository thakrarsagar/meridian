# Local IKEv2 feasibility

Date: 2026-10-24. The bounded feasibility test was separate from product implementation.

## Bounded result

On macOS 26.5.2, an ad-hoc-signed ordinary-user process used private native configuration controls and the standard network-preferences authorization right to create a unique disabled IKEv2 configuration. An independent reader confirmed the saved profile. A cleanup process removed that exact identifier and a fresh reader confirmed no test profile remained.

The test used a reserved invalid destination, disabled activation and on-demand flags, and no credentials or certificates. It contained no tunnel-start operation and wrote no existing configuration. No root process, helper, entitlement bypass, security-policy change, or paid signing was used.

The same process initially read a stale configuration list after a successful save callback. The product therefore uses fresh-manager readback, verifies ownership and requested settings, and bounds its wait before starting a session.

## Connectivity incident and limits

Immediate checks before and after the bounded experiment showed working Tailscale access and unchanged checked preferences and routes. Later, the user reported a connectivity outage. Read-only diagnostics at that point found working numeric-IP internet access, failing DNS through the current router, and a missing Tailscale route despite a connected service label. The user restored connectivity by disabling and enabling Wi-Fi and subsequently reported the issue resolved.

The sequence does not establish what caused the outage. Immediate successful checks are not evidence that the experiment had no later effect. No further configuration experiment was performed to resolve that uncertainty.

The user subsequently authorized product development while explicitly requiring the working network and Tailscale settings to remain untouched. Current build verification does not create profiles, connect or disconnect VPNs, change trust, or alter network preferences.

## Remaining live evidence

The bounded test did not prove authenticated Nord connections, updating an active app-owned configuration, credential accessibility by native VPN helpers, scoped certificate setup, reconnect behavior, or Tailscale coexistence during transitions. These remain live acceptance requirements.

Private declarations are unsupported macOS contracts. Runtime capability checks can detect missing entry points but cannot prove behavior or ABI compatibility after OS updates.
