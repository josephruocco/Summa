import Foundation

// The annotation result type rendered in the overlay tooltip. Retained
// independently of the (legacy, being removed) Wikipedia resolver because the
// premium annotator seeds these directly: setPremiumHighlights stores a
// WikiResult whose `gloss` carries the editorial note, and the tooltip renders
// it. Only `status`, `requested`, `title`, `pageURL`, and `gloss` are used by
// the premium path; the rest remain for compatibility while the resolver is
// still present.
enum WikiStatus: String, Codable, Sendable {
    case ok
    case notFound
    case disambiguation
    case error
    case suppressed
}

struct WikiResult: Codable, Sendable, Hashable {
    var status: WikiStatus
    var requested: String
    var title: String?
    var extract: String?
    var pageURL: String?
    var thumbnailURL: String?
    var debug: String?
    var score: Double?
    // Editorial note from the annotation planner. When present, the overlay
    // renders this instead of a Wikipedia extract.
    var gloss: String? = nil
}
