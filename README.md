# Loops Migrator

`loops-migrator.sh` exports your Loops profile, uploaded videos, thumbnails, and associated post metadata, then supports re-publishing that backup to another compatible Loops instance. It was designed for my own instance but accepts any compatible Loops server.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

This script was initially created for my own purpose and is in no way officially connected to [Loops](https://joinloops.org), the Loops developers or the operators of any instance. Use this script at your own risk!

Version 0.3.1 targets the API behavior of Loops `1.0.0-beta.14`. Export and verification are read-only; import uses the authenticated Studio upload endpoint.

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
- Re-publishes backed-up videos and supported metadata to another Loops instance
- Imports oldest posts first, with dry-run, confirmation and target-scoped resume support
- Stops automatic retries when an upload outcome is uncertain to avoid duplicate posts

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

The migrator automates client registration, opens the Loops authorization page, exchanges the displayed code and stores the resulting token with owner-only permissions:

```bash
./loops-migrator.sh auth \
  --source https://your.loops.tld \
  --token-file ~/.config/loops-migrator-token
```

Sign in to Loops in the browser, approve access, then paste the displayed authorization code into the terminal. If no supported browser opener is available, the command prints the URL instead; `--no-browser` forces that behavior.

The default authorization requests the official `read` scope and is sufficient for exports. To create a separate token for importing into a target instance, repeat the flow against that instance with write access:

```bash
./loops-migrator.sh auth \
  --source https://new-loops-instance.example \
  --token-file ~/.config/loops-migrator-target-token \
  --write
```

This requests `read write`. Existing token files are not overwritten unless `--force` is supplied. Use `--client-name NAME` to change the name shown on the Loops authorization page.

If `--token-file` is omitted, `auth` writes to `~/.config/loops-migrator-token`.

Under the hood, the command follows the official flow: it registers a client with `POST /api/v1/apps`, authorizes it through `/oauth/authorize`, and exchanges the returned code at `/oauth/token`.

Never put a token into a committed config file or shell history. A permission-restricted token file is the preferred method. To check an existing token:

```bash
printf '%s' 'YOUR_ACCESS_TOKEN' > ~/.config/loops-migrator-token
chmod 600 ~/.config/loops-migrator-token

./loops-migrator.sh check \
  --source https://your.loops.tld \
  --token-file ~/.config/loops-migrator-token
```

You can also use `LOOPS_TOKEN_FILE`, `LOOPS_TOKEN`, or `--token`. The token is used only for API calls to the selected instance. It is never saved in the backup and is never sent to media/CDN hosts.

## Create a backup

```bash
chmod +x loops-migrator.sh

./loops-migrator.sh export \
  --source https://your.loops.tld \
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

## Import a backup

Import is a controlled re-publication of the exported videos. Run a dry-run first:

```bash
./loops-migrator.sh import \
  --target https://new-loops-instance.example \
  --token-file ~/.config/loops-target-token \
  --input-dir ./loops_backup \
  --dry-run
```

If validation succeeds, perform the import:

```bash
./loops-migrator.sh import \
  --target https://new-loops-instance.example \
  --token-file ~/.config/loops-target-token \
  --input-dir ./loops_backup
```

The script verifies every video and thumbnail against its recorded size and SHA-256 checksum before asking for confirmation. Posts are uploaded oldest first so their relative order is retained. In non-interactive environments, add `--yes`.

Supported metadata is mapped back to the Studio upload request:

- Caption/description and alt text
- Language
- Sensitive-content, AI and advertising labels
- Comment, download, duet, stitch and embed permissions, subject to target-account policy
- Custom thumbnail, when accepted by the target

Use `--skip-thumbnails` if exported thumbnails do not satisfy the target's current dimensions or format rules. Importing into the original source instance is rejected by default because it creates duplicates; `--allow-same-instance` overrides that protection explicitly.

### Import resume and uncertain uploads

Successful uploads are recorded by target instance and source post ID in `.imported_posts` inside the backup. Re-running the import skips only posts already recorded for that same target. `import-log.jsonl` retains the accepted upload responses. Neither file contains a bearer token.

Before every upload, the script writes `.import_pending`. It clears that marker only after a definite success or failure. If the connection breaks after the server may have accepted the video, the marker remains and the import stops instead of blindly creating a duplicate. Inspect the target Studio first. If the post exists, add the target/source pair to `.imported_posts`; if it does not, clear `.import_pending` and retry.

From inside the backup directory, resolve that state explicitly:

```bash
# The post exists on the target: record it as imported, then clear the marker.
cat .import_pending >> .imported_posts
: > .import_pending

# Or, only when the post does not exist on the target: permit a new upload attempt.
: > .import_pending
```

### What import cannot restore

Loops does not currently expose a lossless restore endpoint. Imported videos are new posts, not continuations of the original ActivityPub objects. The following cannot be preserved:

- Original database IDs, public URLs and ActivityPub identities
- Original publication timestamps or edit history
- Likes, comments, shares, views and bookmarks
- Existing federation delivery and interaction relationships
- Pinned order and all server-internal processing state
- Bit-identical video quality: Loops exposes the optimized video, which the target processes again

The target may enforce different upload formats, file-size limits, daily quotas, account permissions and moderation rules. Custom thumbnails currently need to be JPEG, PNG or WebP, no larger than 5 MB, and exactly 1080 x 1920 pixels. Successful API acceptance means that processing was queued; it does not guarantee that asynchronous transcoding will finish. Imported posts may federate immediately after processing. There is no quiet/local-only import mode in the current Loops upload API.

## Retry and timeout settings

Read-only requests and media downloads retry transport failures, HTTP 429 and HTTP 5xx responses with bounded exponential backoff. A numeric `Retry-After` response header takes precedence. Uploads automatically retry only rate limits and failures that occurred before a connection was established. Ambiguous timeouts and server errors stop the import to avoid duplicate posts.

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
- Import uses `POST /api/v1/studio/upload` and is a best-effort re-publication, not a lossless restore.
- Likes, shares, comments, and view counts are snapshots. Their underlying user interactions are not exported.
- Deleted posts cannot be retrieved through these endpoints.
- Media URLs must be absolute HTTPS URLs or instance-relative URLs. Plain HTTP is rejected unless `--allow-http` is explicitly used for a local/test server.

## Typical Backup Workflow

```text
Source instance        Local backup                 Target instance
──────────────         ────────────                 ───────────────
1. Verify token  ───►  Authenticated export
2. Studio posts  ───►  posts.json + raw responses
3. Media files   ───►  videos/ + thumbnails/
                       4. Verify checksums
                       5. Dry-run target limits
                       6. Re-publish oldest first ─► New Loops posts
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
