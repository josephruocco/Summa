import Foundation

final class TrainingDataStore {
    static let shared = TrainingDataStore()

    private struct SelectionRecord: Codable {
        let timestampISO8601: String
        let phrase: String
        let windowLabel: String?
        let contextBefore: String
        let contextAfter: String
        let selectedTitle: String?
        let selectedPageURL: String?
        let selectedScore: Double?
        let requested: String
    }

    private let lock = NSLock()
    private let fileURL: URL?

    private init() {
        fileURL = Self.makeFileURL()
    }

    func record(highlight: HighlightBox, windowLabel: String, selected: WikiResult) {
        let record = SelectionRecord(
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            phrase: highlight.text,
            windowLabel: windowLabel.isEmpty ? nil : windowLabel,
            contextBefore: highlight.contextBefore,
            contextAfter: highlight.contextAfter,
            selectedTitle: selected.title,
            selectedPageURL: selected.pageURL,
            selectedScore: selected.score,
            requested: selected.requested
        )
        append(record)
    }

    private func append(_ record: SelectionRecord) {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8) else { return }

        let payload = Data((line + "\n").utf8)

        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
            return
        }

        try? payload.write(to: fileURL, options: [.atomic])
    }

    private static func makeFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport.appendingPathComponent("Summa", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("training-choices.jsonl")
    }
}
