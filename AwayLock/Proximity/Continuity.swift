import Foundation

/// Apple Continuity messages inside manufacturer data: `4C 00`, then `type, length, value…`.
/// Experimental (flag `experimentalNearbyInfo`): the activity codes are from published reverse
/// engineering (furiousMAC continuity dissector), not yet confirmed on real devices
/// (`spike continuity` logs them).
nonisolated struct ContinuityTLV: Sendable, Equatable {
    var type: UInt8
    var value: [UInt8]
}

nonisolated struct NearbyInfo: Sendable, Equatable {
    static let type: UInt8 = 0x10
    /// Codes that allow a typed-password unlock: active user with screen on (0x07), Watch on
    /// wrist and unlocked (0x0A), recent user interaction (0x0B).
    static let unlockCodes: Set<UInt8> = [0x07, 0x0A, 0x0B]

    /// Low nibble of the first value byte.
    var activity: UInt8
    /// High nibble of the first value byte (status flags).
    var flags: UInt8
}

nonisolated enum ContinuityParser {
    /// TLVs in order. Not Apple data → empty. A truncated TLV ends the list.
    static func parse(_ manufacturerData: Data) -> [ContinuityTLV] {
        let b = [UInt8](manufacturerData)
        guard b.count >= 2, b[0] == 0x4C, b[1] == 0x00 else { return [] }
        var out: [ContinuityTLV] = []
        var i = 2
        while i + 2 <= b.count {
            let type = b[i], length = Int(b[i + 1])
            i += 2
            guard i + length <= b.count else { break }
            out.append(ContinuityTLV(type: type, value: Array(b[i ..< i + length])))
            i += length
        }
        return out
    }

    static func nearbyInfo(_ manufacturerData: Data) -> NearbyInfo? {
        guard let first = parse(manufacturerData).first(where: { $0.type == NearbyInfo.type })?.value.first else { return nil }
        return NearbyInfo(activity: first & 0x0F, flags: first >> 4)
    }
}
