# Changelog

All notable changes to Loops Migrator are documented in this file.

## [0.3.1] - 2026-09-06

### Fixed

- Send `redirect_uris` as the JSON array required by the current Loops app-registration endpoint, fixing HTTP 422 during `auth`.

[0.3.1]: https://github.com/netherwraith/loops-migrator/releases/tag/v0.3.1

## [0.3] - 2026-09-06

### Added

- Interactive `auth` command that registers an OAuth client, opens the authorization page, exchanges the returned code and verifies the resulting account access.
- Read-only authorization by default and optional `--write` access for import tokens.
- Automatic secure token-file creation with mode `0600`, atomic writes and overwrite protection.
- `--no-browser` support for headless systems and `--client-name` customization.
- OAuth state validation when a complete redirected URL is pasted instead of a bare authorization code.
- Regression coverage for OAuth payloads, secret-free output and token overwrite protection.

### Changed

- Corrected the documented Loops OAuth scopes to the official `read` and `write` scopes.
- Updated authentication instructions to use the automated flow.

[0.3]: https://github.com/netherwraith/loops-migrator/releases/tag/v0.3

## [0.2] - 2026-09-06

### Added

- Best-effort import through the Loops Studio upload endpoint.
- Restoration of captions, alt text, language, sensitivity and AI/ad labels, plus supported interaction permissions.
- Oldest-first upload order to retain relative chronology.
- Dry-run validation of backup integrity, video formats, file-size limits and metadata lengths.
- Target-scoped `.imported_posts` resume state and JSONL upload receipts.
- Optional thumbnail skipping and explicit same-instance override.
- A pending-upload marker that blocks automatic continuation after an ambiguous network or server failure, reducing duplicate risk.
- Regression coverage for dry-run isolation, metadata mapping, upload order, resume scoping and uncertain outcomes.

### Changed

- Clarified that import creates new posts and cannot restore original IDs, URLs, timestamps, engagement, federation identity or bit-identical video quality.
- Upload retries are deliberately conservative: definite rate limits and pre-connection failures are retried, while uncertain outcomes stop for manual inspection.

[0.2]: https://github.com/netherwraith/loops-migrator/releases/tag/v0.2

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
