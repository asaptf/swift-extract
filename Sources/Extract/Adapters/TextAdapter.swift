import Foundation

enum TextAdapter {
    static func ingest(_ text: String) -> ExtractedDocument {
        ExtractedDocument(text: text, sourceDescription: "text")
    }
}
