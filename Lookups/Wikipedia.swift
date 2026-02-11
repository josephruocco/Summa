import Foundation

enum Wikipedia {
    static func summary(_ term: String) async -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No term." }

        // Wikipedia REST expects page titles; spaces commonly work better as underscores
        let title = trimmed.replacingOccurrences(of: " ", with: "_")

        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else {
            return "Bad URL for term: \(trimmed)"
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ScreenGlossMVP/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            guard code == 200 else {
                // useful debug
                let body = String(data: data, encoding: .utf8) ?? ""
                print("WIKI HTTP \(code) term=\(trimmed) url=\(url.absoluteString) body=\(body)")
                return "No Wikipedia summary (HTTP \(code))."
            }

            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let extract = (obj?["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let extract, !extract.isEmpty {
                return extract
            } else {
                print("WIKI 200 but no extract term=\(trimmed) url=\(url.absoluteString)")
                return "No summary text found."
            }
        } catch {
            print("WIKI ERROR term=\(trimmed) err=\(error)")
            return "Wikipedia lookup failed: \(error.localizedDescription)"
        }
    }
}
