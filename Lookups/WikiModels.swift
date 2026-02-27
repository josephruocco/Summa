import Foundation

enum WikiStatus: String, Codable, Sendable {
    case ok
    case notFound
    case disambiguation
    case error
}

struct WikiResult: Codable, Sendable, Hashable {
    var status: WikiStatus
    var requested: String

    var title: String?
    var extract: String?

    var pageURL: String?
    var thumbnailURL: String?

    var debug: String? // optional extra info for you
}
