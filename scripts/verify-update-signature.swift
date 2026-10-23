// Checks a Sparkle EdDSA signature against a public key, as an installed Quoth would.
// Usage: swift scripts/verify-update-signature.swift <file> <base64 signature> <base64 public key>
import CryptoKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4, let data = FileManager.default.contents(atPath: a[1]),
      let sig = Data(base64Encoded: a[2]), let pub = Data(base64Encoded: a[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else {
    print("usage: verify-update-signature.swift <file> <signature> <public key>")
    exit(2)
}
if key.isValidSignature(sig, for: data) {
    print("valid")
} else {
    print("INVALID")
    exit(1)
}
