import Foundation

enum Wikipedia {
    static func summary(_ term: String) async -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Wikipedia summary endpoint
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        // Wikipedia likes a UA
        req.setValue("ScreenGlossMVP/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            // minimal parse: { "extract": "..." }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let extract = obj?["extract"] as? String
            return extract?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
