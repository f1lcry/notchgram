// Verifies a Sparkle EdDSA signature against a *public* key, independently
// of the keychain that produced it:
//
//     swift scripts/verify_ed_signature.swift <file> <edSignature> <SUPublicEDKey>
//
// `sign_update --verify` checks against the key pair in the keychain; this
// checks against the key the shipped app will actually trust (read it from the
// built Info.plist), which is the property that matters to a user's updater.
// Exit 0 = valid.

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify_ed_signature.swift <file> <signature> <public-key>\n".utf8))
    exit(2)
}

guard let signature = Data(base64Encoded: args[2]),
      let publicKeyBytes = Data(base64Encoded: args[3])
else {
    FileHandle.standardError.write(Data("signature or public key is not base64\n".utf8))
    exit(2)
}

do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
    if publicKey.isValidSignature(signature, for: data) {
        print("EdDSA signature valid for \(args[1]) (\(data.count) bytes) against SUPublicEDKey")
        exit(0)
    }
    FileHandle.standardError.write(Data("EdDSA signature INVALID for \(args[1])\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("verify failed: \(error)\n".utf8))
    exit(1)
}
