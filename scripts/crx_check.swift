// Self-check for UniBrowser/Extensions/CRX.swift:
//   swiftc -parse-as-library UniBrowser/Extensions/CRX.swift scripts/crx_check.swift -o /tmp/crx_check && /tmp/crx_check
import Foundation

@main
enum CRXCheck {
    static func main() throws {
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 1, 2, 3]
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] }
        let magic: [UInt8] = Array("Cr24".utf8)

        let crx3 = Data(magic + le(3) + le(5) + [9, 9, 9, 9, 9] + zip)
        let payload3 = try CRX.zipPayload(of: crx3)
        assert(payload3 == Data(zip))

        let crx2 = Data(magic + le(2) + le(2) + le(3) + [7, 7] + [8, 8, 8] + zip)
        let payload2 = try CRX.zipPayload(of: crx2)
        assert(payload2 == Data(zip))

        assert((try? CRX.zipPayload(of: Data(zip))) == nil)
        assert((try? CRX.zipPayload(of: Data(magic + le(3) + le(500) + zip))) == nil)
        assert((try? CRX.zipPayload(of: Data(magic + le(4) + le(0) + zip))) == nil)

        let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        assert(CRX.storeID(from: id) == id)
        assert(CRX.storeID(from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)") == id)
        assert(CRX.storeID(from: "https://chromewebstore.google.com/detail/\(id)?hl=ru") == id)
        assert(CRX.storeID(from: "apple.com") == nil)
        assert(CRX.storeID(from: "x\(id)") == nil)
        print("CRX checks passed")
    }
}
