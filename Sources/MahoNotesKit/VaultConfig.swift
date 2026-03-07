import Foundation

// MARK: - Per-Vault Configuration (maho.yaml)

/// Typed representation of a vault's `maho.yaml` configuration file.
///
/// Replaces the untyped `[String: Any]` dictionary with Codable structs,
/// enabling compile-time safety and better documentation of the config schema.
public struct VaultConfig: Codable, Sendable, Equatable {
    public var author: Author?
    public var collections: [CollectionEntry]?
    public var github: GitHubConfig?
    public var site: SiteConfig?

    public init(
        author: Author? = nil,
        collections: [CollectionEntry]? = nil,
        github: GitHubConfig? = nil,
        site: SiteConfig? = nil
    ) {
        self.author = author
        self.collections = collections
        self.github = github
        self.site = site
    }

    public struct Author: Codable, Sendable, Equatable {
        public var name: String
        public var url: String?

        public init(name: String, url: String? = nil) {
            self.name = name
            self.url = url
        }
    }

    /// A collection entry as stored in maho.yaml.
    /// Mirrors the fields of `Collection` but with optional icon/description
    /// to match YAML where those fields may be omitted.
    public struct CollectionEntry: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var icon: String?
        public var description: String?

        public init(id: String, name: String, icon: String? = nil, description: String? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.description = description
        }
    }

    public struct GitHubConfig: Codable, Sendable, Equatable {
        public var repo: String

        public init(repo: String) {
            self.repo = repo
        }
    }

    public struct SiteConfig: Codable, Sendable, Equatable {
        public var domain: String?
        public var title: String?
        public var theme: String?

        public init(domain: String? = nil, title: String? = nil, theme: String? = nil) {
            self.domain = domain
            self.title = title
            self.theme = theme
        }
    }
}

// MARK: - Per-Vault Device Configuration (.maho/config.yaml)

/// Typed representation of a vault's `.maho/config.yaml` device-level configuration.
///
/// This file is local to each device and is not synced. It stores
/// device-specific settings like embedding model preferences and auth tokens.
public struct DeviceConfig: Codable, Sendable, Equatable {
    public var embed: EmbedConfig?
    public var auth: AuthConfig?

    public init(embed: EmbedConfig? = nil, auth: AuthConfig? = nil) {
        self.embed = embed
        self.auth = auth
    }

    public struct EmbedConfig: Codable, Sendable, Equatable {
        public var model: String?

        public init(model: String? = nil) {
            self.model = model
        }
    }

    public struct AuthConfig: Codable, Sendable, Equatable {
        public var githubToken: String?

        public init(githubToken: String? = nil) {
            self.githubToken = githubToken
        }

        enum CodingKeys: String, CodingKey {
            case githubToken = "github_token"
        }
    }
}

// MARK: - Global Configuration (~/.maho/config.yaml)

/// Typed representation of the global `~/.maho/config.yaml` configuration file.
///
/// A superset of `DeviceConfig` with additional sync settings.
/// This file applies across all vaults on the device.
public struct GlobalConfig: Codable, Sendable, Equatable {
    public var auth: DeviceConfig.AuthConfig?
    public var embed: DeviceConfig.EmbedConfig?
    public var sync: SyncConfig?

    public init(
        auth: DeviceConfig.AuthConfig? = nil,
        embed: DeviceConfig.EmbedConfig? = nil,
        sync: SyncConfig? = nil
    ) {
        self.auth = auth
        self.embed = embed
        self.sync = sync
    }

    public struct SyncConfig: Codable, Sendable, Equatable {
        public var cloud: CloudSyncMode?

        public init(cloud: CloudSyncMode? = nil) {
            self.cloud = cloud
        }
    }
}
