import Foundation

/// A parsed note with frontmatter metadata and content
public struct Note: Sendable {
    public let relativePath: String
    public let title: String
    public let collection: String
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

    public init(
        relativePath: String,
        title: String,
        collection: String,
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
        self.collection = collection
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
