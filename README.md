# Loops Migrator

`loops-migrator.sh` exports your Loops profile, uploaded videos, thumbnails, and the associated post metadata. It is designed for `loops.federalized.eu` but accepts any compatible Loops instance.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

This script was initially created for my own purpose and is in no way officially connected to [Loops](https://joinloops.org), the Loops developers or the operators of any instance. Use this script at your own risk!

Version 0.1 targets the API behavior of Loops `1.0.0-beta.14` and uses only documented/read-only endpoints.

## Features

- Exports the authenticated account profile and instance configuration
- Exports all uploaded Studio posts with complete cursor pagination
- Enriches published posts with captions, alt text, language, tags, mentions, permissions and labels
- Downloads source videos and thumbnails without forwarding the bearer token to media hosts
- Stores raw API responses alongside a normalized manifest
- Records byte sizes and SHA-256 checksums for every downloaded media file
- Resumes interrupted downloads from a retained partial export
- Retries rate-limited, transient server and transport failures with exponential backoff
- Verifies finished backups for missing or modified files
- Supports metadata-only exports for posts that are still processing

## Requirements

- Bash 3.2 or newer
- `curl`
- `jq`
- `shasum` (macOS) or `sha256sum` (Linux)

On macOS, only `jq` normally needs to be installed:

```bash
brew install jq
```

## Authentication

Loops uses OAuth 2.0 bearer tokens. Tokens are instance-specific secrets; a token issued by one Loops server does not authenticate against another.

The official flow is:

1. Register a client with `POST /api/v1/apps`.
2. Authorize it through `/oauth/authorize`.
3. Exchange the returned code at `/oauth/token`.
4. Pass the resulting access token to this script.

The client needs read access. Never put a token into a committed config file or shell history. A permission-restricted token file is the preferred method:

```bash
printf '%s' 'YOUR_ACCESS_TOKEN' > ~/.config/loops-migrator-token
chmod 600 ~/.config/loops-migrator-token

./loops-migrator.sh check \
  --source https://loops.federalized.eu \
  --token-file ~/.config/loops-migrator-token
```

You can also use `LOOPS_TOKEN_FILE`, `LOOPS_TOKEN`, or `--token`. The token is used only for API calls to the selected instance. It is never saved in the backup and is never sent to media/CDN hosts.

## Create a backup

```bash
chmod +x loops-migrator.sh

./loops-migrator.sh export \
  --source https://loops.federalized.eu \
  --token-file ~/.config/loops-migrator-token \
  --output-dir ./loops_backup
```

If no output directory is supplied, a timestamped directory is created. An interrupted run remains in `<output-dir>.partial`; repeating the same command reuses already downloaded non-empty media files. Use `--restart` to discard that partial run.

The script refuses to replace an existing completed backup. `--force` retains the old backup as `<output-dir>.previous-TIMESTAMP` before finalizing the new one.

For a JSON-only archive:

```bash
./loops-migrator.sh export \
  --token-file ~/.config/loops-migrator-token \
  --output-dir ./loops_metadata \
  --metadata-only
```

## Backup contents

```text
loops_backup/
  manifest.json                 backup version, account, instance and counts
  profile.json                  raw authenticated account response
  instance.json                 raw instance configuration
  posts.json                    normalized index of Studio and detailed post data
  videos/<post-id>.<ext>        downloaded source videos
  thumbnails/<post-id>.<ext>    downloaded thumbnails
  raw/studio-pages/*.json       unmodified paginated Studio responses
  raw/studio-posts.jsonl        one unmodified Studio item per line
  raw/posts/<post-id>.json      unmodified detailed post responses
```

Each local media entry in `posts.json` records its source URL, byte size, and SHA-256 checksum. Captions/status messages are retained both in the Studio object and, for published posts, in the richer `post` object. That object also contains fields exposed by Loops such as alt text, language, tags, mentions, sensitivity, permissions, dimensions, duration, AI/ad labels, and counters.

Processing items are included in metadata. Loops may not expose a downloadable source URL until processing is complete. A normal media backup therefore stops as incomplete if any listed post has no downloadable video; the `.partial` directory remains available for a later retry. `--metadata-only` intentionally allows those entries.

## Verify a backup

```bash
./loops-migrator.sh verify --output-dir ./loops_backup
```

Verification recalculates every recorded size and SHA-256 checksum. It exits non-zero for missing, altered, or unsafe file paths.

## Retry and timeout settings

Transport failures, HTTP 429, and HTTP 5xx responses use bounded exponential retries. A numeric `Retry-After` response header takes precedence.

```bash
MAX_RETRIES=5 RETRY_BASE_DELAY=2 REQUEST_DELAY=1 \
  ./loops-migrator.sh export \
  --token-file ~/.config/loops-migrator-token \
  --output-dir ./loops_backup
```

Defaults:

- `REQUEST_DELAY=0.5`
- `MAX_RETRIES=3` (plus the first attempt)
- `RETRY_BASE_DELAY=1`
- `CONNECT_TIMEOUT=15`
- `REQUEST_TIMEOUT=180` for API requests; media downloads have no total-time cap

Use `--debug` to show request URLs and HTTP status codes. Authorization headers and token values are never printed.

## API notes and limitations

- Uploaded posts are enumerated through `GET /api/v1/studio/posts` using its opaque cursor and maximum page size of 20.
- Published posts are enriched through `GET /api/v1/video/{id}`.
- Profile and instance data come from `GET /api/v1/account/info/self` and `GET /api/v1/config`.
- The export is a backup, not a re-import tool. Loops currently exposes uploads but no lossless restore endpoint for all server-side state.
- Likes, shares, comments, and view counts are snapshots. Their underlying user interactions are not exported.
- Deleted posts cannot be retrieved through these endpoints.
- Media URLs must be absolute HTTPS URLs or instance-relative URLs. Plain HTTP is rejected unless `--allow-http` is explicitly used for a local/test server.

## Typical Backup Workflow

```text
Loops instance                         Local backup
──────────────                         ────────────
1. Verify OAuth token  ─────────────►  Authenticated account check
2. Fetch Studio posts  ─────────────►  Raw pages and posts.json
3. Fetch post details  ─────────────►  Captions and complete metadata
4. Download media      ─────────────►  videos/ and thumbnails/
5. Verify checksums    ─────────────►  Integrity result
```

## Tests

```bash
bash tests/test.sh
```

## License

MIT — see [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=netherwraith%2Floops-migrator&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=netherwraith/loops-migrator&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=netherwraith/loops-migrator&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=netherwraith/loops-migrator&type=date&legend=top-left" />
 </picture>
</a>
