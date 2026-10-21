import Foundation
import CryptoKit

func verify(_ key: String, _ signature: Data, _ payload: Data) throws {
    guard let bytes = Data(base64Encoded: key), let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes), publicKey.isValidSignature(sig, for: payload) else {
        throw NSError(domain: "RoomyRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Release signature did not verify"])
    }
}

do {
    let a = CommandLine.arguments
    if a.count == 2 && a[1] == "--self-test" {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("Roomy verification fixture".utf8)
        let signature = try key.signature(for: payload).base64EncodedData()
        try verify(key.publicKey.rawRepresentation.base64EncodedString(), signature, payload)
        var rejected = false
        do { try verify(key.publicKey.rawRepresentation.base64EncodedString(), signature, payload + Data([0])) }
        catch { rejected = true }
        guard rejected else { throw NSError(domain: "RoomyRelease", code: 2) }
        print("Ed25519: valid fixture accepted; tampered fixture rejected")
    } else {
        guard a.count == 4 || a.count == 6 else {
            throw NSError(domain: "RoomyRelease", code: 3, userInfo: [NSLocalizedDescriptionKey: "usage: verifier public-key-base64 signature-file payload-file [version zip-file]"])
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: a[3]))
        try verify(a[1], Data(contentsOf: URL(fileURLWithPath: a[2])), payload)
        if a.count == 6 {
            guard let manifest = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  manifest["schema"] as? Int == 1, manifest["version"] as? String == a[4],
                  let assets = manifest["assets"] as? [String: String],
                  URL(fileURLWithPath: a[5]).lastPathComponent == "Roomy-\(a[4]).zip",
                  let expected = assets["Roomy-\(a[4]).zip"] else { throw NSError(domain: "RoomyRelease", code: 4) }
            let zip = try Data(contentsOf: URL(fileURLWithPath: a[5]), options: .mappedIfSafe)
            let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw NSError(domain: "RoomyRelease", code: 5, userInfo: [NSLocalizedDescriptionKey: "Archive checksum did not match the signed manifest"]) }
        }
        print("Release signature verified")
    }
} catch {
    fputs("Release verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
