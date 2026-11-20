import Foundation

/// NaCl crypto_secretbox (XSalsa20-Poly1305) in pure Swift.
///
/// Termius stores its local vault as base64(version | options | nonce[24] | secretbox) and
/// encrypts it with a 32-byte key that lives in the login keychain ("Termius" / "localKey").
/// Everything here is standard NaCl, so the implementation is validated against libsodium
/// vectors in TaugeChecks instead of a bundled C library.
public enum Salsa20Poly1305 {
    public enum Failure: Swift.Error, Equatable {
        case badKeySize
        case badNonceSize
        case authenticationFailed
        case shortCiphertext
    }

    public static let keyByteCount = 32
    public static let nonceByteCount = 24
    public static let tagByteCount = 16

    // MARK: - Public API

    /// crypto_secretbox_easy: returns tag || ciphertext.
    public static func seal(message: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyByteCount else { throw Failure.badKeySize }
        guard nonce.count == nonceByteCount else { throw Failure.badNonceSize }
        let stream = try xsalsa20Stream(key: key, nonce: nonce, byteCount: keyByteCount + message.count)
        let polyKey = Array(stream[0..<keyByteCount])
        var ciphertext = [UInt8](repeating: 0, count: message.count)
        for index in 0..<message.count {
            ciphertext[index] = message[index] ^ stream[keyByteCount + index]
        }
        var output = poly1305(ciphertext, key: polyKey)
        output.append(contentsOf: ciphertext)
        return output
    }

    /// crypto_secretbox_open_easy: input is tag || ciphertext.
    public static func open(ciphertext: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyByteCount else { throw Failure.badKeySize }
        guard nonce.count == nonceByteCount else { throw Failure.badNonceSize }
        guard ciphertext.count >= tagByteCount else { throw Failure.shortCiphertext }
        let tag = Array(ciphertext[0..<tagByteCount])
        let body = Array(ciphertext[tagByteCount...])
        let stream = try xsalsa20Stream(key: key, nonce: nonce, byteCount: keyByteCount + body.count)
        let polyKey = Array(stream[0..<keyByteCount])
        let expected = poly1305(body, key: polyKey)
        guard constantTimeEquals(expected, tag) else { throw Failure.authenticationFailed }
        var plaintext = [UInt8](repeating: 0, count: body.count)
        for index in 0..<body.count {
            plaintext[index] = body[index] ^ stream[keyByteCount + index]
        }
        return plaintext
    }

    // MARK: - Salsa20 / XSalsa20

    private static let sigma: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]

    /// XSalsa20: 24-byte nonce = 16-byte HSalsa20 salt + 8-byte Salsa20 nonce.
    static func xsalsa20Stream(key: [UInt8], nonce: [UInt8], byteCount: Int) throws -> [UInt8] {
        guard key.count == keyByteCount else { throw Failure.badKeySize }
        guard nonce.count == nonceByteCount else { throw Failure.badNonceSize }
        let subkey = hsalsa20(key: key, input: Array(nonce[0..<16]))
        return salsa20Stream(key: subkey, nonce: Array(nonce[16..<24]), byteCount: byteCount)
    }

    /// Salsa20 keystream with a 64-bit block counter starting at zero.
    static func salsa20Stream(key: [UInt8], nonce: [UInt8], byteCount: Int) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(byteCount + 64)
        var counter: UInt64 = 0
        while output.count < byteCount {
            let block = salsa20Block(key: key, nonce: nonce, counter: counter)
            output.append(contentsOf: block)
            counter &+= 1
        }
        return Array(output[0..<byteCount])
    }

    static func salsa20Block(key: [UInt8], nonce: [UInt8], counter: UInt64) -> [UInt8] {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = sigma[0]
        state[5] = sigma[1]
        state[10] = sigma[2]
        state[15] = sigma[3]
        for index in 0..<4 { state[1 + index] = littleEndianWord(key, index * 4) }
        state[6] = littleEndianWord(nonce, 0)
        state[7] = littleEndianWord(nonce, 4)
        state[8] = UInt32(truncatingIfNeeded: counter)
        state[9] = UInt32(truncatingIfNeeded: counter >> 32)
        for index in 0..<4 { state[11 + index] = littleEndianWord(key, 16 + index * 4) }

        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 5, 9, 13, 1)
            quarterRound(&working, 10, 14, 2, 6)
            quarterRound(&working, 15, 3, 7, 11)
            quarterRound(&working, 0, 1, 2, 3)
            quarterRound(&working, 5, 6, 7, 4)
            quarterRound(&working, 10, 11, 8, 9)
            quarterRound(&working, 15, 12, 13, 14)
        }

        var output = [UInt8](repeating: 0, count: 64)
        for index in 0..<16 {
            let value = working[index] &+ state[index]
            let offset = index * 4
            output[offset] = UInt8(truncatingIfNeeded: value)
            output[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            output[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            output[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        return output
    }

    /// HSalsa20 produces the XSalsa20 subkey.
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = sigma[0]
        state[5] = sigma[1]
        state[10] = sigma[2]
        state[15] = sigma[3]
        for index in 0..<4 { state[1 + index] = littleEndianWord(key, index * 4) }
        for index in 0..<4 { state[6 + index] = littleEndianWord(input, index * 4) }
        for index in 0..<4 { state[11 + index] = littleEndianWord(key, 16 + index * 4) }

        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 5, 9, 13, 1)
            quarterRound(&state, 10, 14, 2, 6)
            quarterRound(&state, 15, 3, 7, 11)
            quarterRound(&state, 0, 1, 2, 3)
            quarterRound(&state, 5, 6, 7, 4)
            quarterRound(&state, 10, 11, 8, 9)
            quarterRound(&state, 15, 12, 13, 14)
        }

        let picked = [state[0], state[5], state[10], state[15], state[6], state[7], state[8], state[9]]
        var output = [UInt8]()
        for word in picked {
            output.append(UInt8(truncatingIfNeeded: word))
            output.append(UInt8(truncatingIfNeeded: word >> 8))
            output.append(UInt8(truncatingIfNeeded: word >> 16))
            output.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return output
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[b] ^= rotateLeft(state[a] &+ state[d], 7)
        state[c] ^= rotateLeft(state[b] &+ state[a], 9)
        state[d] ^= rotateLeft(state[c] &+ state[b], 13)
        state[a] ^= rotateLeft(state[d] &+ state[c], 18)
    }

    private static func rotateLeft(_ value: UInt32, _ shift: UInt32) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private static func littleEndianWord(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    // MARK: - Poly1305 (32-bit limbs, poly1305-donna style)

    static func poly1305(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let t0 = UInt32(key[0]) | (UInt32(key[1]) << 8) | (UInt32(key[2]) << 16) | (UInt32(key[3]) << 24)
        let t1 = UInt32(key[4]) | (UInt32(key[5]) << 8) | (UInt32(key[6]) << 16) | (UInt32(key[7]) << 24)
        let t2 = UInt32(key[8]) | (UInt32(key[9]) << 8) | (UInt32(key[10]) << 16) | (UInt32(key[11]) << 24)
        let t3 = UInt32(key[12]) | (UInt32(key[13]) << 8) | (UInt32(key[14]) << 16) | (UInt32(key[15]) << 24)

        let r0 = t0 & 0x3ff_ffff
        let r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03
        let r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ff_c0ff
        let r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f0_3fff
        let r4 = (t3 >> 8) & 0x00f_ffff
        let pad0 = UInt32(key[16]) | (UInt32(key[17]) << 8) | (UInt32(key[18]) << 16) | (UInt32(key[19]) << 24)
        let pad1 = UInt32(key[20]) | (UInt32(key[21]) << 8) | (UInt32(key[22]) << 16) | (UInt32(key[23]) << 24)
        let pad2 = UInt32(key[24]) | (UInt32(key[25]) << 8) | (UInt32(key[26]) << 16) | (UInt32(key[27]) << 24)
        let pad3 = UInt32(key[28]) | (UInt32(key[29]) << 8) | (UInt32(key[30]) << 16) | (UInt32(key[31]) << 24)
        let s1 = r1 &* 5
        let s2 = r2 &* 5
        let s3 = r3 &* 5
        let s4 = r4 &* 5

        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0
        var offset = 0
        while offset < message.count {
            let blockLength = min(16, message.count - offset)
            let isFullBlock = blockLength == 16
            var block = [UInt8](repeating: 0, count: 16)
            for index in 0..<blockLength { block[index] = message[offset + index] }
            if !isFullBlock { block[blockLength] = 1 }

            let m0 = UInt32(block[0]) | (UInt32(block[1]) << 8) | (UInt32(block[2]) << 16) | (UInt32(block[3]) << 24)
            let m1 = UInt32(block[4]) | (UInt32(block[5]) << 8) | (UInt32(block[6]) << 16) | (UInt32(block[7]) << 24)
            let m2 = UInt32(block[8]) | (UInt32(block[9]) << 8) | (UInt32(block[10]) << 16) | (UInt32(block[11]) << 24)
            let m3 = UInt32(block[12]) | (UInt32(block[13]) << 8) | (UInt32(block[14]) << 16) | (UInt32(block[15]) << 24)

            h0 &+= m0 & 0x3ff_ffff
            h1 &+= ((m1 << 6) | (m0 >> 26)) & 0x3ff_ffff
            h2 &+= ((m2 << 12) | (m1 >> 20)) & 0x3ff_ffff
            h3 &+= ((m3 << 18) | (m2 >> 14)) & 0x3ff_ffff
            h4 &+= (m3 >> 8) | (isFullBlock ? (1 << 24) : 0)

            var d0 = UInt64(h0) &* UInt64(r0) &+ UInt64(h1) &* UInt64(s4) &+ UInt64(h2) &* UInt64(s3) &+ UInt64(h3) &* UInt64(s2) &+ UInt64(h4) &* UInt64(s1)
            var d1 = UInt64(h0) &* UInt64(r1) &+ UInt64(h1) &* UInt64(r0) &+ UInt64(h2) &* UInt64(s4) &+ UInt64(h3) &* UInt64(s3) &+ UInt64(h4) &* UInt64(s2)
            var d2 = UInt64(h0) &* UInt64(r2) &+ UInt64(h1) &* UInt64(r1) &+ UInt64(h2) &* UInt64(r0) &+ UInt64(h3) &* UInt64(s4) &+ UInt64(h4) &* UInt64(s3)
            var d3 = UInt64(h0) &* UInt64(r3) &+ UInt64(h1) &* UInt64(r2) &+ UInt64(h2) &* UInt64(r1) &+ UInt64(h3) &* UInt64(r0) &+ UInt64(h4) &* UInt64(s4)
            var d4 = UInt64(h0) &* UInt64(r4) &+ UInt64(h1) &* UInt64(r3) &+ UInt64(h2) &* UInt64(r2) &+ UInt64(h3) &* UInt64(r1) &+ UInt64(h4) &* UInt64(r0)

            var carry = UInt32(truncatingIfNeeded: d0 >> 26); h0 = UInt32(truncatingIfNeeded: d0) & 0x3ff_ffff
            d1 &+= UInt64(carry)
            carry = UInt32(truncatingIfNeeded: d1 >> 26); h1 = UInt32(truncatingIfNeeded: d1) & 0x3ff_ffff
            d2 &+= UInt64(carry)
            carry = UInt32(truncatingIfNeeded: d2 >> 26); h2 = UInt32(truncatingIfNeeded: d2) & 0x3ff_ffff
            d3 &+= UInt64(carry)
            carry = UInt32(truncatingIfNeeded: d3 >> 26); h3 = UInt32(truncatingIfNeeded: d3) & 0x3ff_ffff
            d4 &+= UInt64(carry)
            carry = UInt32(truncatingIfNeeded: d4 >> 26); h4 = UInt32(truncatingIfNeeded: d4) & 0x3ff_ffff
            h0 &+= carry &* 5
            h1 &+= h0 >> 26; h0 &= 0x3ff_ffff

            offset += blockLength
            if blockLength < 16 { break }
        }

        var carry = h1 >> 26; h1 &= 0x3ff_ffff
        h2 &+= carry; carry = h2 >> 26; h2 &= 0x3ff_ffff
        h3 &+= carry; carry = h3 >> 26; h3 &= 0x3ff_ffff
        h4 &+= carry; carry = h4 >> 26; h4 &= 0x3ff_ffff
        h0 &+= carry &* 5
        carry = h0 >> 26; h0 &= 0x3ff_ffff
        h1 &+= carry

        // Compute h + -p (i.e. h - (2^130 - 5)) and select it when it is non-negative.
        var g0 = h0 &+ 5; carry = g0 >> 26; g0 &= 0x3ff_ffff
        var g1 = h1 &+ carry; carry = g1 >> 26; g1 &= 0x3ff_ffff
        var g2 = h2 &+ carry; carry = g2 >> 26; g2 &= 0x3ff_ffff
        var g3 = h3 &+ carry; carry = g3 >> 26; g3 &= 0x3ff_ffff
        let g4 = h4 &+ carry &- (1 << 26)

        let needsReduce = (g4 & 0x8000_0000) == 0
        if needsReduce {
            h0 = g0; h1 = g1; h2 = g2; h3 = g3; h4 = g4
        }

        // h = h % 2^128, then add the second half of the key (32-bit limbs, 64-bit carry).
        var accumulator = UInt64(h0 | (h1 << 26)) &+ UInt64(pad0)
        let f0 = UInt32(truncatingIfNeeded: accumulator)
        accumulator >>= 32
        accumulator &+= UInt64((h1 >> 6) | (h2 << 20)) &+ UInt64(pad1)
        let f1 = UInt32(truncatingIfNeeded: accumulator)
        accumulator >>= 32
        accumulator &+= UInt64((h2 >> 12) | (h3 << 14)) &+ UInt64(pad2)
        let f2 = UInt32(truncatingIfNeeded: accumulator)
        accumulator >>= 32
        accumulator &+= UInt64((h3 >> 18) | (h4 << 8)) &+ UInt64(pad3)
        let f3 = UInt32(truncatingIfNeeded: accumulator)

        var tag = [UInt8](repeating: 0, count: 16)
        writeLittleEndian(f0, &tag, 0)
        writeLittleEndian(f1, &tag, 4)
        writeLittleEndian(f2, &tag, 8)
        writeLittleEndian(f3, &tag, 12)
        return tag
    }

    private static func writeLittleEndian(_ value: UInt32, _ bytes: inout [UInt8], _ offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
