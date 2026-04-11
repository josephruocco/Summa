import Foundation

// Event types for the training log. "selected" means the user picked a
// specific candidate from a multi-option picker; "dismissed" means they
// rejected all of them via "None of these". These are semantically
// different signals and should not share the same record shape.
enum TrainingEventKind: String, Codable {
    case selected
    case dismissed
}

final class TrainingDataStore {
    static let shared = TrainingDataStore()

    private struct CandidateRecord: Codable {
        let title: String?
        let pageURL: String?
        let score: Double?
    }

    private struct SelectionRecord: Codable {
        let timestampISO8601: String
        let event: TrainingEventKind
        let phrase: String
        let windowLabel: String?
        let contextBefore: String
        let contextAfter: String
        // Only populated for .selected events.
        let selectedTitle: String?
        let selectedPageURL: String?
        let selectedScore: Double?
        let requested: String
        let candidates: [CandidateRecord]?
    }

    private let lock = NSLock()
    private let fileURL: URL?

    private init() {
        fileURL = Self.makeFileURL()
    }

    func recordSelection(highlight: HighlightBox, windowLabel: String, selected: WikiResult, allCandidates: [WikiResult] = []) {
        let record = SelectionRecord(
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            event: .selected,
            phrase: highlight.text,
            windowLabel: windowLabel.isEmpty ? nil : windowLabel,
            contextBefore: highlight.contextBefore,
            contextAfter: highlight.contextAfter,
            selectedTitle: selected.title,
            selectedPageURL: selected.pageURL,
            selectedScore: selected.score,
            requested: selected.requested,
            candidates: makeCandidateRecords(allCandidates)
        )
        append(record)
    }

    func recordDismissal(highlight: HighlightBox, windowLabel: String, requested: String, allCandidates: [WikiResult] = []) {
        let record = SelectionRecord(
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            event: .dismissed,
            phrase: highlight.text,
            windowLabel: windowLabel.isEmpty ? nil : windowLabel,
            contextBefore: highlight.contextBefore,
            contextAfter: highlight.contextAfter,
            selectedTitle: nil,
            selectedPageURL: nil,
            selectedScore: nil,
            requested: requested,
            candidates: makeCandidateRecords(allCandidates)
        )
        append(record)
    }

    private func makeCandidateRecords(_ candidates: [WikiResult]) -> [CandidateRecord]? {
        guard !candidates.isEmpty else { return nil }
        return candidates.map { CandidateRecord(title: $0.title, pageURL: $0.pageURL, score: $0.score) }
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
