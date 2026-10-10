import SwiftUI
import UniformTypeIdentifiers

/// Colors for treemap tiles: files by what kind of content they hold, folders in quiet greys, so the eye
/// goes to the files that take the space.
enum TreemapPalette {
    enum Category: CaseIterable {
        case image, video, audio, archive, document, code, application, other
    }

    /// Many items too small to draw, as one faint tile.
    static let remainder = Color.primary.opacity(0.07)

    /// A folder whose contents are laid out inside it: barely there, alternating by depth so nesting shows.
    /// A folder drawn as one tile (too small, or not entered): neutral and translucent, unlike any file.
    static func container(depth: Int, subdivided: Bool) -> Color {
        subdivided ? Color.primary.opacity(depth.isMultiple(of: 2) ? 0.035 : 0.06) : Color.primary.opacity(0.13)
    }

    static func color(forFileNamed name: String, kind: ScanTree.Kind) -> Color {
        guard kind == .file else { return Color.primary.opacity(0.1) }
        return color(for: category(ofFileNamed: name))
    }

    static func color(for category: Category) -> Color {
        switch category {
        case .image: Color.teal.opacity(0.75)
        case .video: Color.purple.opacity(0.7)
        case .audio: Color.pink.opacity(0.7)
        case .archive: Color.orange.opacity(0.75)
        case .document: Color.blue.opacity(0.7)
        case .code: Color.green.opacity(0.65)
        case .application: Color.indigo.opacity(0.75)
        // Files of unknown kind are the most common: a calm steel, clearly a file, not a folder.
        case .other: Color(hue: 0.6, saturation: 0.16, brightness: 0.64)
        }
    }

    private static var categories: [String: Category] = [:]

    /// The category of a file by its name extension, looked up once per extension.
    static func category(ofFileNamed name: String) -> Category {
        let dot = name.lastIndex(of: ".")
        guard let dot, dot != name.startIndex else { return .other }
        let fileExtension = name[name.index(after: dot)...].lowercased()
        if let known = categories[fileExtension] { return known }
        let category = UTType(filenameExtension: fileExtension).map(category(of:)) ?? .other
        categories[fileExtension] = category
        return category
    }

    private static func category(of type: UTType) -> Category {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
            || type.conforms(to: .script) || type.conforms(to: .propertyList) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) || type.conforms(to: .font) { return .document }
        if type.conforms(to: .executable) || type.conforms(to: .bundle) || type.conforms(to: .unixExecutable) { return .application }
        return .other
    }
}
