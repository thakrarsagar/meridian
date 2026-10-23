# Use a Rust backend and native menu-bar interface

The user requires Rust for the backend and selected a native menu-bar app for this Mac first. Use an in-process Rust library with a small native interface, rather than a browser frontend or a separate local server, to limit runtime and packaging costs.

The user approved thin Apple platform adapters. Rust owns catalogue parsing, validation, search, selection, and application decisions; Apple APIs handle HTTP transport, credentials, and native VPN operations. This deliberately avoids adding a second HTTP/TLS runtime merely to make transport Rust-owned. Measure the first native release build before selecting a hard memory cap, and account for system VPN-service costs separately.
