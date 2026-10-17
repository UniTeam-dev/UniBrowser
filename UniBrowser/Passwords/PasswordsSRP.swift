// Direct (Developer ID) build only: launches a system helper, which App Sandbox and App Review rule out.
#if DIRECT
import BigInt
import CryptoKit
import Foundation

/// SRP-6a client for pairing with the Passwords helper (RFC 5054 3072-bit
/// group, SHA-256), plus AES-128-GCM for the messages sent after pairing.
///
/// The helper shows a 6-digit PIN; that PIN is the SRP password. Byte strings
/// travel base64-encoded, numbers as big-endian bytes without leading zeros
/// except where `pad` is used.
struct PasswordsSRP {
    static let N = BigUInt(
        """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510\
        15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
        BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """,
        radix: 16
    )!
    static let g = BigUInt(5)
    static let byteLength = 3072 / 8

    /// Session identifier the helper echoes back as TID.
    let username: String
    private let a: BigUInt
    let A: BigUInt

    private(set) var sessionKey: BigUInt?
    private var B: BigUInt?
    private var salt: BigUInt?

    init() {
        username = Self.randomBytes(16).base64EncodedString()
        a = BigUInt(Self.randomBytes(32))
        A = Self.g.power(a, modulus: Self.N)
    }

    var isPaired: Bool { sessionKey != nil }

    mutating func setServerValues(B: BigUInt, salt: BigUInt) throws {
        guard B % Self.N != 0 else { throw PasswordsBridgeError.protocolError("неверный ключ помощника") }
        self.B = B
        self.salt = salt
    }

    /// Derives the session key from the PIN and returns the client proof M.
    mutating func proof(pin: String) throws -> Data {
        guard let B, let salt else { throw PasswordsBridgeError.protocolError("нет ответа помощника") }
        let N = Self.N, g = Self.g

        let u = BigUInt(Self.sha256(Self.pad(A) + Self.pad(B)))
        let k = BigUInt(Self.sha256(N.serialize() + Self.pad(g)))
        let x = BigUInt(Self.sha256(salt.serialize() + Self.sha256(Data("\(username):\(pin)".utf8))))

        let kv = (k * g.power(x, modulus: N)) % N
        let base = (B % N + N - kv) % N
        let S = base.power(a + u * x, modulus: N)
        let K = BigUInt(Self.sha256(S.serialize()))
        sessionKey = K

        let hN = Self.sha256(N.serialize())
        let hg = Self.sha256(Self.pad(g))
        let hNxorg = Data(zip(hN, hg).map { $0 ^ $1 })
        return Self.sha256(
            hNxorg + Self.sha256(Data(username.utf8)) + salt.serialize() + A.serialize() + B.serialize() + K.serialize()
        )
    }

    /// The helper's proof that it knows the same key: H(A | M | K).
    func expectedServerProof(for M: Data) -> Data? {
        guard let sessionKey else { return nil }
        return Self.sha256(A.serialize() + M + sessionKey.serialize())
    }

    // MARK: - Message encryption

    private var symmetricKey: SymmetricKey? {
        sessionKey.map { SymmetricKey(data: $0.serialize().prefix(16)) }
    }

    /// Client → helper: ciphertext and tag, then the 16-byte IV.
    func encrypt(_ object: [String: Any]) throws -> Data {
        guard let key = symmetricKey else { throw PasswordsBridgeError.notPaired }
        let plaintext = try JSONSerialization.data(withJSONObject: object)
        let iv = Self.randomBytes(16)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        return box.ciphertext + box.tag + iv
    }

    /// Helper → client: the 16-byte IV, then ciphertext and tag.
    func decrypt(_ data: Data) throws -> [String: Any] {
        guard let key = symmetricKey else { throw PasswordsBridgeError.notPaired }
        guard data.count > 32 else { throw PasswordsBridgeError.protocolError("пустой ответ") }
        let iv = data.prefix(16)
        let body = data.dropFirst(16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: body.dropLast(16),
            tag: body.suffix(16)
        )
        let plaintext = try AES.GCM.open(box, using: key)
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw PasswordsBridgeError.protocolError("ответ не JSON")
        }
        return object
    }

    // MARK: - Helpers

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func pad(_ value: BigUInt) -> Data {
        let bytes = value.serialize()
        return Data(repeating: 0, count: max(0, byteLength - bytes.count)) + bytes
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
#endif
