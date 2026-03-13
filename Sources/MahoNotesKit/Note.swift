import Foundation

/// A parsed note with frontmatter metadata and content
public struct Note: Sendable, Codable, Hashable {
    public static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.relativePath == rhs.relativePath && lhs.title == rhs.title && lhs.updated == rhs.updated
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(relativePath)
    }

    public let relativePath: String
    public let title: String
    public let tags: [String]
    public let created: String
    public let updated: String
    public let isPublic: Bool
    public let slug: String?
    public let author: String?
    public let draft: Bool
    public let order: Int?
    public let series: String?
    public let body: String

    /// Collection inferred from the first path component of relativePath
    public var collection: String {
        let components = relativePath.split(separator: "/")
        return components.count > 1 ? String(components[0]) : ""
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath, title, tags, created, updated, isPublic, slug
        case author, draft, order, series, body, collection
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(title, forKey: .title)
        try container.encode(collection, forKey: .collection)
        try container.encode(tags, forKey: .tags)
        try container.encode(created, forKey: .created)
        try container.encode(updated, forKey: .updated)
        try container.encode(isPublic, forKey: .isPublic)
        try container.encodeIfPresent(slug, forKey: .slug)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(draft, forKey: .draft)
        try container.encodeIfPresent(order, forKey: .order)
        try container.encodeIfPresent(series, forKey: .series)
        try container.encode(body, forKey: .body)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        title = try container.decode(String.self, forKey: .title)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        created = try container.decodeIfPresent(String.self, forKey: .created) ?? ""
        updated = try container.decodeIfPresent(String.self, forKey: .updated) ?? ""
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        order = try container.decodeIfPresent(Int.self, forKey: .order)
        series = try container.decodeIfPresent(String.self, forKey: .series)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }

    public init(
        relativePath: String,
        title: String,
        tags: [String],
        created: String,
        updated: String,
        isPublic: Bool,
        slug: String?,
        author: String?,
        draft: Bool,
        order: Int?,
        series: String?,
        body: String
    ) {
        self.relativePath = relativePath
        self.title = title
        self.tags = tags
        self.created = created
        self.updated = updated
        self.isPublic = isPublic
        self.slug = slug
        self.author = author
        self.draft = draft
        self.order = order
        self.series = series
        self.body = body
    }
}
