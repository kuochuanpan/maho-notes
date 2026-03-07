# VaultStore — Unified Data Access Layer

> RFC: Replace scattered YAML read/write with a single `VaultStore` actor.
> Date: 2026-03-07
> Status: **Draft**

## Motivation

Currently, vault-related persistence is scattered across 6+ files with overlapping responsibilities:

| Data | Files that read/write it |
|------|-------------------------|
| `~/.maho/config.yaml` (global) | `Auth.swift`, `Config.swift`, `VaultRegistry.swift` |
| `~/.maho/vaults.yaml` (registry) | `VaultRegistry.swift`, `VaultInit.swift` |
| `iCloud .../config/vaults.yaml` | `VaultRegistry.swift` |
| `<vault>/maho.yaml` | `Config.swift`, `Collection.swift`, `Vault.swift`, `GitSync.swift`, `VaultInit.swift` |
| `<vault>/.maho/config.yaml` | `Config.swift` |
| `<vault>/.maho/sync-manifest.json` | `GitHubSyncManager.swift` |

### Known bugs from this design

1. **`VaultEntry.path` is dead data** — `resolvedPath(for:)` ignores `path` for `.icloud`, `.github`, `.device` types. The stored path diverges from the resolved path silently.

2. **Cloud sync ON/OFF leaves orphan data** — Turning OFF doesn't clean up iCloud registry or vault copies. Turning ON again triggers unnecessary merge.

3. **`vaults-cache.yaml` is write-only** — Written on save but never read by `loadRegistry()`. No offline fallback.

4. **GitHub vault paths differ by entry point** — CLI uses `~/.maho/vaults/`, App uses `resolveVaultRoot(.local)`, Kit's `cloneGitHubVault` uses caller-provided root. All three can diverge.

5. **No concurrency safety** — Multiple callers can read/write YAML simultaneously (App's SyncCoordinator + iCloudSyncManager + user edits).

6. **`loadCloudSyncMode` default inconsistency** — Returns `.off` but some doc comments say `.icloud`.

## Design

### VaultStore actor

```swift
/// Single source of truth for all vault-related persistence.
/// All YAML/JSON reads and writes go through this actor.
public actor VaultStore {
    
    /// Root directory for global config. Default: ~/.maho
    private let globalConfigDir: String
    
    public init(globalConfigDir: String = "~/.maho") {
        self.globalConfigDir = (globalConfigDir as NSString).expandingTildeInPath
    }
    
    // ══════════════════════════════════════════
    // MARK: - Registry (vaults.yaml)
    // ══════════════════════════════════════════
    
    /// Load vault registry. Priority: iCloud (if cloud ON) → local → cache.
    public func loadRegistry() throws -> VaultRegistry?
    
    /// Save vault registry (writes to correct location based on cloud mode).
    public func saveRegistry(_ registry: VaultRegistry) throws
    
    /// Load cached registry (offline fallback when iCloud unavailable).
    public func loadCachedRegistry() throws -> VaultRegistry?
    
    /// Register a new vault entry. Handles path storage correctly per type.
    public func registerVault(_ entry: VaultEntry) throws
    
    /// Unregister a vault by name.
    public func unregisterVault(named name: String) throws
    
    // ══════════════════════════════════════════
    // MARK: - Path Resolution
    // ══════════════════════════════════════════
    
    /// Canonical vault path. This is the ONLY place paths are resolved.
    /// For .local: uses entry.path (required, validated).
    /// For .icloud/.github/.device: derived from name + convention.
    public func resolvedPath(for entry: VaultEntry) -> String
    
    /// Vault root directory for a given storage type.
    public func vaultRoot(for type: VaultType) -> String
    
    // ══════════════════════════════════════════
    // MARK: - Global Config (~/.maho/config.yaml)
    // ══════════════════════════════════════════
    
    public func cloudSyncMode() -> CloudSyncMode
    public func setCloudSyncMode(_ mode: CloudSyncMode) throws
    
    public func globalAuthToken() -> String?
    public func setGlobalAuthToken(_ token: String) throws
    
    public func globalEmbedModel() -> String?
    public func setGlobalEmbedModel(_ model: String) throws
    
    // ══════════════════════════════════════════
    // MARK: - Per-Vault Config (maho.yaml)
    // ══════════════════════════════════════════
    
    /// Typed vault configuration (replaces [String: Any]).
    public func loadVaultConfig(at vaultPath: String) throws -> VaultConfig
    public func saveVaultConfig(_ config: VaultConfig, at vaultPath: String) throws
    
    // ══════════════════════════════════════════
    // MARK: - Per-Vault Device Config (.maho/config.yaml)
    // ══════════════════════════════════════════
    
    public func loadDeviceConfig(at vaultPath: String) throws -> DeviceConfig
    public func saveDeviceConfig(_ config: DeviceConfig, at vaultPath: String) throws
    
    // ══════════════════════════════════════════
    // MARK: - Cloud Migration
    // ══════════════════════════════════════════
    
    /// Migrate device vaults to iCloud. Returns updated registry.
    public func migrateToCloud(_ registry: VaultRegistry) throws -> VaultRegistry
    
    /// Migrate iCloud vaults back to device. Returns updated registry.
    public func migrateFromCloud(_ registry: VaultRegistry) throws -> VaultRegistry
    
    /// Clean up iCloud registry and stale copies when turning cloud sync OFF.
    public func cleanupCloudArtifacts() throws
}
```

### Typed Config Structs

Replace `[String: Any]` dictionaries with proper Codable structs:

```swift
/// Per-vault configuration (maho.yaml)
public struct VaultConfig: Codable, Sendable {
    public var author: Author?
    public var collections: [CollectionEntry]
    public var github: GitHubConfig?
    public var site: SiteConfig?
    
    public struct Author: Codable, Sendable {
        public var name: String
        public var url: String
    }
    
    public struct CollectionEntry: Codable, Sendable {
        public var id: String
        public var name: String
        public var icon: String?
        public var description: String?
    }
    
    public struct GitHubConfig: Codable, Sendable {
        public var repo: String
    }
    
    public struct SiteConfig: Codable, Sendable {
        public var domain: String?
        public var title: String?
        public var theme: String?
    }
}

/// Per-vault device config (.maho/config.yaml)
public struct DeviceConfig: Codable, Sendable {
    public var embed: EmbedConfig?
    public var auth: AuthConfig?
    
    public struct EmbedConfig: Codable, Sendable {
        public var model: String?
    }
    
    public struct AuthConfig: Codable, Sendable {
        public var githubToken: String?
        
        enum CodingKeys: String, CodingKey {
            case githubToken = "github_token"
        }
    }
}

/// Global config (~/.maho/config.yaml) — superset of DeviceConfig + sync
public struct GlobalConfig: Codable, Sendable {
    public var auth: DeviceConfig.AuthConfig?
    public var embed: DeviceConfig.EmbedConfig?
    public var sync: SyncConfig?
    
    public struct SyncConfig: Codable, Sendable {
        public var cloud: CloudSyncMode?
    }
}
```

### VaultEntry.path Fix

**Decision**: Drop `path` for `.icloud`, `.github`, `.device`. Only `.local` uses `path`.

```swift
public struct VaultEntry: Codable, Sendable {
    public let name: String
    public let type: VaultType
    public var github: String?      // owner/repo for .github type
    public var path: String?        // ONLY used for .local type
    public var access: VaultAccess
}
```

`VaultStore.registerVault()` validates:
- `.local` → `path` required, must exist
- `.icloud`/`.github`/`.device` → `path` ignored (set to nil)

### Cache Fallback

```
loadRegistry() priority:
  1. iCloud vaults.yaml (if cloud ON + file exists)
  2. ~/.maho/vaults.yaml (local)
  3. ~/.maho/vaults-cache.yaml (cache fallback, if cloud ON but iCloud unavailable)
```

## Migration Plan

### Phase 1: Build VaultStore (non-breaking)
- Create `VaultStore.swift` in MahoNotesKit
- Wrap existing free functions (`loadRegistry`, `saveRegistry`, `resolvedPath`, etc.)
- Add typed config structs (`VaultConfig`, `DeviceConfig`, `GlobalConfig`)
- Add cache read to `loadRegistry`
- Add `cleanupCloudArtifacts()`
- Write tests

### Phase 2: Adopt VaultStore
- `AppState` → use shared `VaultStore` instance
- CLI commands → use `VaultStore`
- `GitSync` / `GitHubSyncManager` → get vault config via `VaultStore`
- `Auth` → delegate token storage to `VaultStore`

### Phase 3: Remove Legacy
- Delete free functions (`loadRegistry`, `saveRegistry`, `resolvedPath(for:)`, etc.)
- Delete `Config` struct (replaced by typed structs + `VaultStore`)
- Clean up `VaultInit.swift` (only keep vault creation logic, no more registry writes)
- Audit: grep for direct YAML file access — should be zero outside `VaultStore`

## Files Affected

| File | Phase | Change |
|------|-------|--------|
| `VaultStore.swift` (new) | 1 | New actor |
| `VaultConfig.swift` (new) | 1 | Typed config structs |
| `VaultRegistry.swift` | 3 | Remove free functions, keep types |
| `Config.swift` | 3 | Delete (replaced by VaultStore) |
| `Auth.swift` | 2 | Delegate token storage |
| `VaultInit.swift` | 2-3 | Simplify, use VaultStore |
| `Collection.swift` | 2-3 | Use VaultConfig instead of raw YAML |
| `GitSync.swift` | 2 | Get config via VaultStore |
| `GitHubSyncManager.swift` | 2 | No change (owns sync-manifest.json) |
| `AppState.swift` | 2 | Use shared VaultStore |
| CLI commands | 2 | Use VaultStore |
