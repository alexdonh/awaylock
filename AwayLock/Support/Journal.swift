import Foundation

/// One line of the local lock history. No device name, no device ID, no password.
nonisolated struct JournalRecord: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case lock, unlock, label, held, radio }

    var t: Date
    var kind: Kind
    // lock
    var reason: LeaveReason?
    var smoothed: Double?
    var slope: Double?
    var lockRSSI: Double?
    var awaySeconds: Int?
    var mode: String?
    var idle: Double?
    var activity: UInt8?
    /// [seconds since the first entry, dBm or null for lost]
    var trace: [[Int?]]?
    // unlock
    var by: String?
    var afterSeconds: Double?
    var nearAfter: Bool?
    // label
    var lock: Date?
    var verdict: LockVerdict?
    // held
    var seconds: Double?
    // radio
    var healthy: Bool?

    init(t: Date = .now, kind: Kind) {
        self.t = t
        self.kind = kind
    }
}

/// `~/Library/Application Support/AwayLock/journal.jsonl`, one JSON object per line.
/// Rotates at 512 KB into `journal.1.jsonl`, so at most two files. Never leaves the Mac.
actor Journal {
    static let maxBytes = 512 * 1024

    nonisolated let url: URL
    private var rotated: URL { url.deletingPathExtension().appendingPathExtension("1.jsonl") }
    private var failed = false

    init(directory: URL = Journal.defaultDirectory) {
        url = directory.appendingPathComponent("journal.jsonl")
    }

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("AwayLock", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func append(_ record: JournalRecord) {
        do {
            var line = try Self.encoder.encode(record)
            line.append(0x0A)
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + line.count > Self.maxBytes {
                try? fm.removeItem(at: rotated)
                try fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            if !failed { Log.session.error("journal write failed: \(error.localizedDescription, privacy: .public)") }
            failed = true
        }
    }

    /// Oldest first. Lines that don't decode are skipped.
    func records() -> [JournalRecord] {
        [rotated, url].flatMap { file -> [JournalRecord] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? Self.decoder.decode(JournalRecord.self, from: Data($0.utf8)) }
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rotated)
    }
}
