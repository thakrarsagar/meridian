# Use native IKEv2 and preserve Tailscale access

Use Apple's native IKEv2 implementation for NordVPN. The user has verified that native IKEv2 coexists with their Tailscale installation, whereas Nord's application connection failed. Do not add a custom VPN engine, route-enforcement filter, or packet-processing helper to the first release.

The user accepts ordinary internet using the normal connection while Nord is disconnected. Preserve Tailscale access and display Nord's actual system-reported state. This deliberately trades a custom kill switch for compatibility and a smaller implementation; the app must never claim that Nord protects traffic while disconnected.
