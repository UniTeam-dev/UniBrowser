import Foundation

/// Chrome Web Store packages (.crx): a small signed header in front of a ZIP archive.
enum CRX {
    enum Failure: Error, Equatable {
        case notCRX
        case unsupportedVersion(UInt32)
        case truncated
    }

    /// The ZIP archive inside a CRX2 or CRX3 file.
    /// ponytail: the package signature is not verified; it comes over HTTPS from Google's update server.
    static func zipPayload(of data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0 ..< 4] == [0x43, 0x72, 0x32, 0x34] else { throw Failure.notCRX } // "Cr24"
        func uint32(at offset: Int) throws -> Int {
            guard offset + 4 <= bytes.count else { throw Failure.truncated }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let version = try uint32(at: 4)
        let start: Int
        switch version {
        case 3: start = try 12 + uint32(at: 8) // header length, then the protobuf header
        case 2: start = try 16 + uint32(at: 8) + uint32(at: 12) // public key and signature lengths
        default: throw Failure.unsupportedVersion(UInt32(version))
        }
        guard start + 4 <= bytes.count, bytes[start ..< start + 4] == [0x50, 0x4B, 0x03, 0x04] else { throw Failure.truncated } // "PK\3\4"
        return Data(bytes[start...])
    }

    /// The 32-letter extension ID from a Chrome Web Store link or a bare ID.
    static func storeID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = text.firstMatch(of: #/(?:^|[\/=])([a-p]{32})(?:$|[\/?#&])/#) else { return nil }
        if !text.hasPrefix("http") && text.count != 32 { return nil }
        return String(match.1)
    }

    /// Google's update endpoint redirects to the current package for an ID.
    static func downloadURL(for id: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "131.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url!
    }
}
