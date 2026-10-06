# Encryption implementation inventory

This technical inventory supports the account holder's export-compliance review. It is not an export classification or legal exemption declaration.

- Desktop history export uses Apple CryptoKit: Curve25519 key agreement, HKDF-SHA256 and AES-GCM authenticated encryption. Identity keys are stored through native Keychain APIs.
- Remote developer pairing uses third-party Rust implementations: X25519 key agreement, Ed25519 signatures, HKDF-SHA512 and ChaCha20-Poly1305.
- The developer TCP tunnel uses a TLS 1.2 pre-shared-key implementation, offering AES-256-CBC/HMAC-SHA384 and AES-128-CBC/HMAC-SHA1 suites. These encrypt captured context in transit; they are not limited to authentication.
- The enabled `ring` feature also includes rustls/tokio-rustls. This is additional to cryptography supplied by Apple's operating system.

Sources in this repository: `Shared/DesktopAccess.swift`, `Core/Cargo.toml`, and `ThirdParty/idevice/src/remote_pairing/{mod.rs,tls_psk.rs,tunnel.rs}`.

The App Store Connect algorithm answer is standard encryption in addition to Apple's operating system. France availability and any documentation or exemption requirements must be resolved before saving the final compliance answers. No `ITSAppUsesNonExemptEncryption` exemption is inferred automatically.
