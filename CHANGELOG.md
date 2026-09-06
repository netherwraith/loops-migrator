# Changelog

All notable changes to Loops Migrator are documented in this file.

## [0.1] - 2026-09-06

### Added

- Export of the authenticated account profile and Loops instance configuration.
- Complete cursor-paginated export of uploaded Studio posts.
- Detailed metadata for published posts, including captions, alt text, language, tags, mentions, permissions, dimensions, duration, sensitivity and AI/ad labels.
- Download of source videos and thumbnails with SHA-256 checksums and byte sizes.
- Raw API response archive and normalized JSON manifest.
- Resumable partial exports, metadata-only mode and integrity verification.
- Configurable retries for HTTP 429, HTTP 5xx and transient curl failures, including `Retry-After` support.
- Bearer-token authentication through a direct option, environment variable or permission-restricted token file.
- Dependency-light regression suite for Bash 3.2 and newer.

### Security

- Bearer tokens are never written to export files or forwarded to media/CDN hosts.
- Plain HTTP and unsafe local media schemes are rejected by default.
- Existing completed backups are never overwritten silently.

[0.1]: https://github.com/netherwraith/loops-migrator/releases/tag/v0.1
