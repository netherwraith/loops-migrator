#!/usr/bin/env bash
# loops-migrator.sh
# Copyright (c) 2026 Oliver Pifferi, E-Mail: oliver@pifferi.io
# ---------------------
# Exports, verifies and re-publishes a portable Loops account backup.
# Dependencies: curl, jq, and either shasum or sha256sum.

set -o pipefail

SCRIPT_VERSION="0.2.0"
DEFAULT_SOURCE="${LOOPS_SOURCE:-https://loops.federalized.eu}"
REQUEST_DELAY="${REQUEST_DELAY:-0.5}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"

API_TOKEN=""
API_RESPONSE=""
API_HTTP_CODE="000"
DEBUG=0
METADATA_ONLY=0
ALLOW_HTTP=0
FORCE=0
RESTART=0
DRY_RUN=0
ASSUME_YES=0
ALLOW_SAME_INSTANCE=0
SKIP_THUMBNAILS=0
UPLOAD_UNCERTAIN=0

usage() {
    cat <<'EOF'
Loops Migrator — export, verify and re-publish Loops videos

Usage:
  ./loops-migrator.sh export [--source URL] [--token TOKEN | --token-file FILE]
                           [--output-dir DIR] [--metadata-only] [--restart]
                           [--force] [--debug]
  ./loops-migrator.sh check  [--source URL] [--token TOKEN | --token-file FILE]
  ./loops-migrator.sh verify --output-dir DIR
  ./loops-migrator.sh import --target URL --input-dir DIR
                           [--token TOKEN | --token-file FILE] [--dry-run]
                           [--skip-thumbnails] [--yes] [--debug]
  ./loops-migrator.sh --version

Options:
  --source URL       Loops instance (default: https://loops.federalized.eu)
  --target URL       Target Loops instance for import
  --token TOKEN      OAuth 2.0 bearer token
  --token-file FILE  Read the bearer token from a file
  --output-dir DIR   Backup directory (default: ./loops_backup_TIMESTAMP)
  --input-dir DIR    Existing backup directory to import
  --metadata-only    Export JSON metadata without downloading media
  --restart          Discard an unfinished .partial export and start again
  --force            Replace an existing final directory; the old one is retained
  --dry-run          Validate an import without uploading anything
  --skip-thumbnails  Import videos without custom thumbnails
  --yes              Skip the import confirmation prompt
  --allow-same-instance  Permit re-publishing to the original source instance
  --allow-http       Allow plain HTTP for a local/test instance
  --debug            Print request methods, URLs and response codes (never tokens)
  -h, --help         Show this help

The token can also be supplied through LOOPS_TOKEN or LOOPS_TOKEN_FILE.
Runtime tuning: REQUEST_DELAY, MAX_RETRIES, RETRY_BASE_DELAY,
CONNECT_TIMEOUT and REQUEST_TIMEOUT.
EOF
}

die() { echo "  x $*" >&2; exit 1; }
warn() { echo "  ! $*" >&2; }
rdelay() { sleep "$REQUEST_DELAY"; }

require_option_value() {
    [[ $# -ge 2 ]] || die "${1} requires a non-empty value."
    [[ -n "$2" && "$2" != --* ]] || die "${1} requires a non-empty value."
}

check_deps() {
    local missing=() command_name
    for command_name in curl jq; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
        missing+=("shasum/sha256sum")
    fi
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
}

validate_runtime_options() {
    [[ "$REQUEST_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "REQUEST_DELAY must be a non-negative number."
    [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] || die "MAX_RETRIES must be a non-negative integer."
    [[ "$RETRY_BASE_DELAY" =~ ^[0-9]+$ ]] || die "RETRY_BASE_DELAY must be a non-negative integer."
    [[ "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "CONNECT_TIMEOUT must be a positive integer."
    [[ "$REQUEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "REQUEST_TIMEOUT must be a positive integer."
}

normalise_source() {
    local source_url="${1%/}"
    if [[ "$ALLOW_HTTP" -eq 1 ]]; then
        [[ "$source_url" =~ ^https?://[^/]+$ ]] || die "Invalid instance URL: ${1}"
    else
        [[ "$source_url" =~ ^https://[^/]+$ ]] || die "Invalid HTTPS instance URL: ${1}"
    fi
    printf '%s' "$source_url"
}

normalise_output_dir() {
    local output_path="$1"
    [[ -n "$output_path" && "$output_path" != "/" ]] || die "Unsafe output directory: ${output_path:-empty}"
    if [[ "$output_path" != /* ]]; then
        output_path="$(pwd)/${output_path}"
    fi
    printf '%s' "${output_path%/}"
}

read_token_file() {
    local token_path="$1"
    [[ -f "$token_path" ]] || die "Token file not found: ${token_path}"
    API_TOKEN=$(tr -d '\r\n' <"$token_path")
    [[ -n "$API_TOKEN" ]] || die "Token file is empty: ${token_path}"
}

json_error_message() {
    jq -r '.message // .error.message // .error // .' <<<"$API_RESPONSE" 2>/dev/null || printf '%s' "$API_RESPONSE"
}

api_request() {
    local method="$1" request_url="$2" response_file headers_file http_code curl_rc
    local attempt=0 retry_delay retry_after

    while true; do
        response_file=$(mktemp)
        headers_file=$(mktemp)
        local curl_options=(-sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$REQUEST_TIMEOUT"
            -D "$headers_file" -o "$response_file" -w '%{http_code}' -X "$method"
            -H 'Accept: application/json')
        [[ -n "$API_TOKEN" ]] && curl_options+=(-H "Authorization: Bearer ${API_TOKEN}")
        [[ "$DEBUG" -eq 1 ]] && echo "  -> ${method} ${request_url}" >&2
        rdelay
        curl_rc=0
        http_code=$(curl "${curl_options[@]}" "$request_url") || curl_rc=$?
        API_RESPONSE=$(<"$response_file")
        API_HTTP_CODE="${http_code:-000}"
        retry_after=$(tr -d '\r' <"$headers_file" | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' | tail -n 1)
        rm -f "$response_file" "$headers_file"
        [[ "$DEBUG" -eq 1 ]] && echo "  <- HTTP ${API_HTTP_CODE}" >&2

        if [[ "$curl_rc" -eq 0 && "$API_HTTP_CODE" != 429 && ! "$API_HTTP_CODE" =~ ^5[0-9][0-9]$ ]]; then
            return 0
        fi
        if [[ "$attempt" -ge "$MAX_RETRIES" ]]; then
            [[ "$curl_rc" -eq 0 ]] && return 0
            die "Request failed after $((MAX_RETRIES + 1)) attempts: ${method} ${request_url} (curl ${curl_rc})"
        fi

        retry_delay=$((RETRY_BASE_DELAY * (2 ** attempt)))
        if [[ "$API_HTTP_CODE" == 429 && "$retry_after" =~ ^[0-9]+$ ]]; then
            retry_delay="$retry_after"
        fi
        attempt=$((attempt + 1))
        echo "  Retrying in ${retry_delay}s (attempt $((attempt + 1))/$((MAX_RETRIES + 1))) ..." >&2
        sleep "$retry_delay"
    done
}

require_api_success() {
    local context="$1"
    if [[ ! "$API_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        die "${context} failed (HTTP ${API_HTTP_CODE}): $(json_error_message)"
    fi
}

urlencode() {
    jq -rn --arg value "$1" '$value | @uri'
}

absolute_media_url() {
    local source="$1" media_url="$2" scheme
    case "$media_url" in
        https://*) printf '%s' "$media_url" ;;
        http://*)
            [[ "$ALLOW_HTTP" -eq 1 ]] || return 1
            printf '%s' "$media_url"
            ;;
        //*)
            scheme="${source%%:*}"
            printf '%s:%s' "$scheme" "$media_url"
            ;;
        /*) printf '%s%s' "$source" "$media_url" ;;
        *) return 1 ;;
    esac
}

safe_id() {
    local cleaned
    cleaned=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')
    [[ -n "$cleaned" ]] || return 1
    printf '%s' "$cleaned"
}

media_extension() {
    local media_url="$1" fallback="$2" clean_path extension
    clean_path="${media_url%%\?*}"
    clean_path="${clean_path%%\#*}"
    extension="${clean_path##*.}"
    extension=$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')
    case "$extension" in
        mp4|m4v|mov|webm|jpg|jpeg|png|webp|gif) printf '%s' "$extension" ;;
        *) printf '%s' "$fallback" ;;
    esac
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

file_size() {
    wc -c <"$1" | tr -d '[:space:]'
}

download_media() {
    local media_url="$1" destination="$2" label="$3"
    local partial_file="${destination}.part" headers_file http_code curl_rc content_type
    local attempt=0 retry_delay retry_after

    if [[ -s "$destination" ]]; then
        [[ "$DEBUG" -eq 1 ]] && echo "  Reusing ${label}: ${destination}" >&2
        DOWNLOAD_CONTENT_TYPE=""
        return 0
    fi

    mkdir -p "$(dirname "$destination")"
    while true; do
        headers_file=$(mktemp)
        [[ "$DEBUG" -eq 1 ]] && echo "  -> GET media ${media_url}" >&2
        rdelay
        curl_rc=0
        http_code=$(curl -sS -L --connect-timeout "$CONNECT_TIMEOUT" --max-time 0 \
            -D "$headers_file" -o "$partial_file" -w '%{http_code}' "$media_url") || curl_rc=$?
        retry_after=$(tr -d '\r' <"$headers_file" | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' | tail -n 1)
        content_type=$(tr -d '\r' <"$headers_file" | sed -n 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//p' | tail -n 1)
        rm -f "$headers_file"

        if [[ "$curl_rc" -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ && -s "$partial_file" ]]; then
            mv "$partial_file" "$destination"
            DOWNLOAD_CONTENT_TYPE="$content_type"
            return 0
        fi
        if [[ "$attempt" -ge "$MAX_RETRIES" || ( "$curl_rc" -eq 0 && "$http_code" != 429 && ! "$http_code" =~ ^5[0-9][0-9]$ ) ]]; then
            rm -f "$partial_file"
            warn "Could not download ${label} (HTTP ${http_code:-000}, curl ${curl_rc})."
            return 1
        fi

        retry_delay=$((RETRY_BASE_DELAY * (2 ** attempt)))
        if [[ "$http_code" == 429 && "$retry_after" =~ ^[0-9]+$ ]]; then
            retry_delay="$retry_after"
        fi
        attempt=$((attempt + 1))
        echo "  Retrying ${label} in ${retry_delay}s (attempt $((attempt + 1))/$((MAX_RETRIES + 1))) ..." >&2
        sleep "$retry_delay"
    done
}

file_metadata() {
    local relative_path="$1" source_url="$2" absolute_path="$3" content_type="$4"
    jq -nc --arg path "$relative_path" --arg url "$source_url" \
        --arg sha256 "$(sha256_file "$absolute_path")" \
        --argjson bytes "$(file_size "$absolute_path")" --arg content_type "$content_type" '
        {path:$path,source_url:$url,bytes:$bytes,sha256:$sha256}
        + if $content_type == "" then {} else {content_type:$content_type} end'
}

fetch_studio_posts() {
    local source="$1" records_file="$2" raw_pages_dir="$3"
    local cursor="" seen_cursors="" page=0 count next total_so_far=0 encoded request_url
    : >"$records_file"
    mkdir -p "$raw_pages_dir"

    while true; do
        page=$((page + 1))
        request_url="${source}/api/v1/studio/posts?limit=20&sort_field=created_at&sort_direction=desc&filter=all"
        if [[ -n "$cursor" ]]; then
            encoded=$(urlencode "$cursor")
            request_url="${request_url}&cursor=${encoded}"
        fi
        api_request GET "$request_url"
        require_api_success "Fetching Studio posts page ${page}"
        jq -e '(.data | type == "array") and
            ((.meta.next_cursor? == null) or (.meta.next_cursor? | type == "string"))' \
            <<<"$API_RESPONSE" >/dev/null || die "Studio page ${page} has an unexpected schema."
        printf '%s\n' "$API_RESPONSE" | jq . >"${raw_pages_dir}/page-$(printf '%04d' "$page").json"
        jq -c '.data[]' <<<"$API_RESPONSE" >>"$records_file"
        count=$(jq '.data | length' <<<"$API_RESPONSE")
        total_so_far=$((total_so_far + count))
        next=$(jq -r '.meta.next_cursor? // empty' <<<"$API_RESPONSE")

        [[ "$count" -eq 0 ]] && break
        if [[ -z "$next" ]]; then
            if [[ "$count" -lt 20 ]] || jq -e --argjson seen "$total_so_far" \
                '(.meta.total_videos? | tonumber?) as $total | $total != null and $seen >= $total' \
                <<<"$API_RESPONSE" >/dev/null; then
                break
            fi
            die "Studio returned a full page without a next cursor; refusing a possibly truncated backup."
        fi
        grep -qxF -- "$next" <<<"$seen_cursors" && die "Studio returned a repeated page cursor."
        seen_cursors="${seen_cursors}${next}"$'\n'
        cursor="$next"
    done
}

check_auth() {
    local source="$1"
    api_request GET "${source}/api/v1/account/info/self"
    require_api_success "Authentication check"
    jq -e '.data | type == "object"' <<<"$API_RESPONSE" >/dev/null || die "Account response has an unexpected schema."
    printf 'Authenticated as @%s (account %s) on %s.\n' \
        "$(jq -r '.data.username // "unknown"' <<<"$API_RESPONSE")" \
        "$(jq -r '.data.id // "unknown"' <<<"$API_RESPONSE")" "$source"
}

do_export() {
    local source="$1" output_dir="$2" work_dir
    work_dir="${output_dir}.partial"
    local timestamp previous_dir profile_file config_file studio_records posts_jsonl
    local total index=0 downloaded=0 missing=0 studio_item post_detail post_status post_id safe_post_id
    local video_url thumbnail_url absolute_url extension relative_path absolute_path content_type
    local video_meta thumbnail_meta files_meta record

    [[ -n "$API_TOKEN" ]] || die "Provide --token, --token-file, LOOPS_TOKEN or LOOPS_TOKEN_FILE."
    if [[ -e "$output_dir" && "$FORCE" -ne 1 ]]; then
        die "Output already exists: ${output_dir}. Choose another directory or use --force."
    fi
    if [[ "$RESTART" -eq 1 && -d "$work_dir" ]]; then
        rm -rf -- "$work_dir"
    fi
    mkdir -p "$work_dir/raw/studio-pages" "$work_dir/raw/posts" "$work_dir/videos" "$work_dir/thumbnails"
    profile_file="$work_dir/profile.json"
    config_file="$work_dir/instance.json"
    studio_records="$work_dir/raw/studio-posts.jsonl"
    posts_jsonl="$work_dir/posts.jsonl"

    echo "=== Loops backup ==="
    echo "Source:  ${source}"
    echo "Staging: ${work_dir}"
    echo ""

    api_request GET "${source}/api/v1/account/info/self"
    require_api_success "Fetching account profile"
    jq -e '.data | type == "object"' <<<"$API_RESPONSE" >/dev/null || die "Account response has an unexpected schema."
    printf '%s\n' "$API_RESPONSE" | jq . >"$profile_file"
    echo "  Account: @$(jq -r '.data.username // "unknown"' "$profile_file")"

    api_request GET "${source}/api/v1/config"
    require_api_success "Fetching instance configuration"
    printf '%s\n' "$API_RESPONSE" | jq . >"$config_file"

    echo "  Fetching Studio posts ..."
    fetch_studio_posts "$source" "$studio_records" "$work_dir/raw/studio-pages"
    total=$(wc -l <"$studio_records" | tr -d '[:space:]')
    : >"$posts_jsonl"
    echo "  Found ${total} uploaded posts."

    while IFS= read -r studio_item || [[ -n "$studio_item" ]]; do
        [[ -n "$studio_item" ]] || continue
        index=$((index + 1))
        post_id=$(jq -r '.id // empty' <<<"$studio_item")
        [[ -n "$post_id" ]] || die "Studio item ${index} has no ID."
        safe_post_id=$(safe_id "$post_id") || die "Unsafe post ID returned by server: ${post_id}"
        post_status=$(jq -r '.status // "unknown"' <<<"$studio_item")
        post_detail='null'

        printf '  [%s/%s] %s (%s)' "$index" "$total" "$post_id" "$post_status"
        if [[ "$post_status" == "published" ]]; then
            api_request GET "${source}/api/v1/video/$(urlencode "$post_id")"
            require_api_success "Fetching details for post ${post_id}"
            jq -e '.data | type == "object"' <<<"$API_RESPONSE" >/dev/null || die "Post ${post_id} detail has an unexpected schema."
            printf '%s\n' "$API_RESPONSE" | jq . >"$work_dir/raw/posts/${safe_post_id}.json"
            post_detail=$(jq -c '.data' <<<"$API_RESPONSE")
        fi

        video_meta='null'
        thumbnail_meta='null'
        if [[ "$METADATA_ONLY" -ne 1 ]]; then
            video_url=$(jq -r --argjson detail "$post_detail" '$detail.media.src_url // .media.src_url // empty' <<<"$studio_item")
            thumbnail_url=$(jq -r --argjson detail "$post_detail" '$detail.media.thumbnail // .media.thumbnail // empty' <<<"$studio_item")

            if [[ -n "$video_url" ]] && absolute_url=$(absolute_media_url "$source" "$video_url"); then
                extension=$(media_extension "$absolute_url" mp4)
                relative_path="videos/${safe_post_id}.${extension}"
                absolute_path="$work_dir/$relative_path"
                if download_media "$absolute_url" "$absolute_path" "video ${post_id}"; then
                    content_type="$DOWNLOAD_CONTENT_TYPE"
                    video_meta=$(file_metadata "$relative_path" "$absolute_url" "$absolute_path" "$content_type")
                    downloaded=$((downloaded + 1))
                    printf ' -> %s' "$relative_path"
                else
                    missing=$((missing + 1))
                fi
            else
                missing=$((missing + 1))
                printf ' -> no downloadable video'
            fi

            if [[ -n "$thumbnail_url" ]] && absolute_url=$(absolute_media_url "$source" "$thumbnail_url"); then
                extension=$(media_extension "$absolute_url" jpg)
                relative_path="thumbnails/${safe_post_id}.${extension}"
                absolute_path="$work_dir/$relative_path"
                if download_media "$absolute_url" "$absolute_path" "thumbnail ${post_id}"; then
                    content_type="$DOWNLOAD_CONTENT_TYPE"
                    thumbnail_meta=$(file_metadata "$relative_path" "$absolute_url" "$absolute_path" "$content_type")
                else
                    warn "Thumbnail unavailable for post ${post_id}."
                fi
            fi
        fi
        printf '\n'

        files_meta=$(jq -nc --argjson video "$video_meta" --argjson thumbnail "$thumbnail_meta" \
            '{video:$video,thumbnail:$thumbnail}')
        record=$(jq -nc --argjson studio "$studio_item" --argjson post "$post_detail" \
            --argjson files "$files_meta" '{id:($studio.id|tostring),studio:$studio,post:$post,files:$files}')
        printf '%s\n' "$record" >>"$posts_jsonl"
    done <"$studio_records"

    jq -s '.' "$posts_jsonl" >"$work_dir/posts.json"
    rm -f "$posts_jsonl"
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -n --arg format loops-migrator --arg version "$SCRIPT_VERSION" --arg exported_at "$timestamp" \
        --arg source "$source" --slurpfile account "$profile_file" --slurpfile instance "$config_file" \
        --argjson posts "$total" --argjson downloaded "$downloaded" --argjson missing "$missing" \
        --argjson metadata_only "$METADATA_ONLY" '
        {format:$format,format_version:1,tool_version:$version,exported_at:$exported_at,
         source_instance:$source,account:$account[0].data,instance:$instance[0].app,
         files:{posts:"posts.json",profile:"profile.json",instance:"instance.json"},
         counts:{posts:$posts,videos_downloaded:$downloaded,videos_without_local_copy:$missing},
         metadata_only:($metadata_only == 1)}' >"$work_dir/manifest.json"

    if [[ "$METADATA_ONLY" -ne 1 && "$missing" -gt 0 ]]; then
        die "Backup is incomplete: ${missing} of ${total} videos have no local copy. Partial data remains in ${work_dir}."
    fi

    if [[ -e "$output_dir" ]]; then
        previous_dir="${output_dir}.previous-$(date -u '+%Y%m%dT%H%M%SZ')"
        mv "$output_dir" "$previous_dir" || die "Could not retain existing backup as ${previous_dir}."
        echo "  Previous backup retained at ${previous_dir}"
    fi
    mv "$work_dir" "$output_dir" || die "Could not finalize backup directory."
    echo ""
    echo "Backup complete: ${output_dir}"
    echo "  Posts: ${total}; videos: ${downloaded}; missing: ${missing}"
}

do_verify() {
    local output_dir="$1" manifest posts
    manifest="$output_dir/manifest.json"
    posts="$output_dir/posts.json"
    local row relative_path expected_sha expected_bytes actual_sha actual_bytes checked=0 failed=0
    [[ -f "$manifest" && -f "$posts" ]] || die "Not a Loops backup directory: ${output_dir}"
    jq -e '.format == "loops-migrator" and .format_version == 1' "$manifest" >/dev/null || die "Unsupported manifest."
    jq -e 'type == "array"' "$posts" >/dev/null || die "Invalid posts.json."

    while IFS= read -r row; do
        relative_path=$(jq -r '.path' <<<"$row")
        expected_sha=$(jq -r '.sha256' <<<"$row")
        expected_bytes=$(jq -r '.bytes' <<<"$row")
        checked=$((checked + 1))
        case "$relative_path" in
            /*|..|../*|*/..|*/../*)
                warn "Missing or unsafe file: ${relative_path}"
                failed=$((failed + 1))
                continue
                ;;
        esac
        if [[ ! -f "$output_dir/$relative_path" ]]; then
            warn "Missing or unsafe file: ${relative_path}"
            failed=$((failed + 1))
            continue
        fi
        actual_sha=$(sha256_file "$output_dir/$relative_path")
        actual_bytes=$(file_size "$output_dir/$relative_path")
        if [[ "$actual_sha" != "$expected_sha" || "$actual_bytes" != "$expected_bytes" ]]; then
            warn "Integrity mismatch: ${relative_path}"
            failed=$((failed + 1))
        fi
    done < <(jq -c '.[] | .files | [.video,.thumbnail][] | select(. != null)' "$posts")

    echo "Verified ${checked} media files; ${failed} failures."
    [[ "$failed" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

import_key() {
    printf '%s\t%s' "$1" "$2"
}

is_post_imported() {
    local state_file="$1" target="$2" post_id="$3"
    [[ -f "$state_file" ]] && grep -qxF -- "$(import_key "$target" "$post_id")" "$state_file"
}

resolve_backup_file() {
    local backup_dir="$1" file_record="$2" label="$3"
    local relative_path expected_sha expected_bytes actual_sha actual_bytes backup_real file_dir_real
    jq -e 'type == "object" and (.path | type == "string") and
        (.sha256 | type == "string") and (.bytes | type == "number")' \
        <<<"$file_record" >/dev/null || { warn "Invalid ${label} record."; return 1; }
    relative_path=$(jq -r '.path' <<<"$file_record")
    case "$relative_path" in
        /*|..|../*|*/..|*/../*) warn "Unsafe ${label} path: ${relative_path}"; return 1 ;;
    esac
    [[ "$relative_path" != *$'\n'* && "$relative_path" != *$'\t'* ]] || {
        warn "Unsafe ${label} path."
        return 1
    }
    [[ -f "$backup_dir/$relative_path" ]] || { warn "Missing ${label}: ${relative_path}"; return 1; }
    [[ ! -L "$backup_dir/$relative_path" ]] || { warn "Refusing symlinked ${label}: ${relative_path}"; return 1; }
    backup_real=$(cd "$backup_dir" && pwd -P) || return 1
    file_dir_real=$(cd "$(dirname "$backup_dir/$relative_path")" && pwd -P) || return 1
    case "${file_dir_real}/" in
        "${backup_real}/"*) ;;
        *) warn "${label} resolves outside the backup: ${relative_path}"; return 1 ;;
    esac
    expected_sha=$(jq -r '.sha256' <<<"$file_record")
    expected_bytes=$(jq -r '.bytes' <<<"$file_record")
    actual_sha=$(sha256_file "$backup_dir/$relative_path")
    actual_bytes=$(file_size "$backup_dir/$relative_path")
    [[ "$actual_sha" == "$expected_sha" && "$actual_bytes" == "$expected_bytes" ]] || {
        warn "Integrity mismatch for ${label}: ${relative_path}"
        return 1
    }
    VERIFIED_PATH="$backup_dir/$relative_path"
}

prepare_import_item() {
    local backup_dir="$1" item="$2" video_record thumbnail_record extension allowed_formats max_mb max_bytes
    IMPORT_ID=$(jq -r '.id // empty' <<<"$item")
    [[ -n "$IMPORT_ID" ]] || { warn "Backup post has no ID."; return 1; }

    video_record=$(jq -c '.files.video // null' <<<"$item")
    [[ "$video_record" != null ]] || { warn "Post ${IMPORT_ID} has no local video."; return 1; }
    resolve_backup_file "$backup_dir" "$video_record" "video for post ${IMPORT_ID}" || return 1
    IMPORT_VIDEO_PATH="$VERIFIED_PATH"

    extension="${IMPORT_VIDEO_PATH##*.}"
    extension=$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')
    allowed_formats=$(jq -c '.media.allowed_video_formats // ["mp4"]' <<<"$IMPORT_TARGET_CONFIG")
    jq -e --arg extension "$extension" 'index($extension) != null' <<<"$allowed_formats" >/dev/null || {
        warn "Post ${IMPORT_ID} uses .${extension}; target accepts $(jq -r 'join(", ")' <<<"$allowed_formats")."
        return 1
    }
    max_mb=$(jq -r '.media.max_video_size // 40 | tonumber' <<<"$IMPORT_TARGET_CONFIG" 2>/dev/null) || return 1
    [[ "$max_mb" =~ ^[0-9]+([.][0-9]+)?$ ]] || { warn "Target returned an invalid video-size limit."; return 1; }
    max_bytes=$(awk -v mb="$max_mb" 'BEGIN { printf "%.0f", mb * 1024 * 1024 }')
    [[ "$(file_size "$IMPORT_VIDEO_PATH")" -ge 256000 ]] || {
        warn "Post ${IMPORT_ID} is smaller than the target minimum of 250 KB."
        return 1
    }
    [[ "$(file_size "$IMPORT_VIDEO_PATH")" -le "$max_bytes" ]] || {
        warn "Post ${IMPORT_ID} exceeds the target limit of ${max_mb} MB."
        return 1
    }

    IMPORT_THUMBNAIL_PATH=""
    thumbnail_record=$(jq -c '.files.thumbnail // null' <<<"$item")
    if [[ "$SKIP_THUMBNAILS" -ne 1 && "$thumbnail_record" != null ]]; then
        resolve_backup_file "$backup_dir" "$thumbnail_record" "thumbnail for post ${IMPORT_ID}" || return 1
        IMPORT_THUMBNAIL_PATH="$VERIFIED_PATH"
        [[ "$(file_size "$IMPORT_THUMBNAIL_PATH")" -le 5242880 ]] || {
            warn "Thumbnail for post ${IMPORT_ID} exceeds the target limit of 5 MB."
            return 1
        }
    fi

    IMPORT_DESCRIPTION=$(jq -r '.post.caption // .studio.caption // ""' <<<"$item")
    IMPORT_ALT_TEXT=$(jq -r '.post.media.alt_text // ""' <<<"$item")
    IMPORT_LANG=$(jq -r '.post.lang // ""' <<<"$item")
    [[ ${#IMPORT_DESCRIPTION} -le 200 ]] || { warn "Post ${IMPORT_ID} caption exceeds 200 characters."; return 1; }
    [[ ${#IMPORT_ALT_TEXT} -le 2000 ]] || { warn "Post ${IMPORT_ID} alt text exceeds 2000 characters."; return 1; }

    IMPORT_CAN_DOWNLOAD=$(jq -r 'if (.post.permissions.can_download // .studio.permissions.can_download // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_CAN_COMMENT=$(jq -r 'if (.post.permissions.can_comment // .studio.permissions.can_comment // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_CAN_DUET=$(jq -r 'if (.post.permissions.can_duet // .studio.permissions.can_duet // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_CAN_STITCH=$(jq -r 'if (.post.permissions.can_stitch // .studio.permissions.can_stitch // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_CAN_EMBED=$(jq -r 'if (.post.permissions.can_embed // .studio.permissions.can_embed // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_IS_SENSITIVE=$(jq -r 'if (.post.is_sensitive // .studio.is_sensitive // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_CONTAINS_AI=$(jq -r 'if (.post.meta.contains_ai // false) == true then "true" else "false" end' <<<"$item")
    IMPORT_CONTAINS_AD=$(jq -r 'if (.post.meta.contains_ad // false) == true then "true" else "false" end' <<<"$item")
}

api_upload_video() {
    local target="$1" video_path="$2" thumbnail_path="$3" description="$4" alt_text="$5" lang="$6"
    local can_download="$7" can_comment="$8" can_duet="$9" can_stitch="${10}" can_embed="${11}"
    local is_sensitive="${12}" contains_ai="${13}" contains_ad="${14}"
    local response_file headers_file http_code curl_rc retry_after retry_delay
    local attempt=0
    UPLOAD_UNCERTAIN=0

    while true; do
        response_file=$(mktemp)
        headers_file=$(mktemp)
        local curl_options=(-sS --connect-timeout "$CONNECT_TIMEOUT" --max-time 0
            -D "$headers_file" -o "$response_file" -w '%{http_code}'
            -H 'Accept: application/json' -H 'Expect:'
            -H "Authorization: Bearer ${API_TOKEN}"
            -F "video=@${video_path}"
            --form-string "description=${description}"
            --form-string "comment_state=$([[ "$can_comment" == true ]] && printf 4 || printf 0)"
            --form-string "can_download=${can_download}"
            --form-string "can_comment=${can_comment}"
            --form-string "can_duet=${can_duet}"
            --form-string "can_stitch=${can_stitch}"
            --form-string "can_embed=${can_embed}"
            --form-string "is_sensitive=${is_sensitive}"
            --form-string "contains_ai=${contains_ai}"
            --form-string "contains_ad=${contains_ad}")
        [[ -n "$thumbnail_path" ]] && curl_options+=(-F "thumbnail=@${thumbnail_path}")
        [[ -n "$alt_text" ]] && curl_options+=(--form-string "alt_text=${alt_text}")
        [[ -n "$lang" ]] && curl_options+=(--form-string "lang=${lang}")

        [[ "$DEBUG" -eq 1 ]] && echo "  -> POST ${target}/api/v1/studio/upload" >&2
        rdelay
        curl_rc=0
        http_code=$(curl "${curl_options[@]}" "${target}/api/v1/studio/upload") || curl_rc=$?
        API_RESPONSE=$(<"$response_file")
        API_HTTP_CODE="${http_code:-000}"
        retry_after=$(tr -d '\r' <"$headers_file" | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' | tail -n 1)
        rm -f "$response_file" "$headers_file"
        [[ "$DEBUG" -eq 1 ]] && echo "  <- HTTP ${API_HTTP_CODE}" >&2

        if [[ "$curl_rc" -eq 0 && "$API_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
            return 0
        fi
        if [[ "$curl_rc" -ne 0 && ! "$curl_rc" =~ ^(5|6|7|35)$ ]]; then
            UPLOAD_UNCERTAIN=1
            return 2
        fi
        if [[ "$curl_rc" -eq 0 && "$API_HTTP_CODE" != 429 ]]; then
            [[ "$API_HTTP_CODE" =~ ^5[0-9][0-9]$ ]] && UPLOAD_UNCERTAIN=1
            return 1
        fi
        if [[ "$attempt" -ge "$MAX_RETRIES" ]]; then
            return 1
        fi

        retry_delay=$((RETRY_BASE_DELAY * (2 ** attempt)))
        if [[ "$API_HTTP_CODE" == 429 && "$retry_after" =~ ^[0-9]+$ ]]; then
            retry_delay="$retry_after"
        fi
        attempt=$((attempt + 1))
        echo "  Retrying upload in ${retry_delay}s (attempt $((attempt + 1))/$((MAX_RETRIES + 1))) ..." >&2
        sleep "$retry_delay"
    done
}

write_pending_import() {
    local pending_file="$1" target="$2" post_id="$3" temporary_file
    temporary_file=$(mktemp "${pending_file}.XXXXXX")
    import_key "$target" "$post_id" >"$temporary_file"
    printf '\n' >>"$temporary_file"
    mv "$temporary_file" "$pending_file"
}

do_import() {
    local target="$1" backup_dir="$2" manifest posts state_file pending_file log_file
    manifest="$backup_dir/manifest.json"
    posts="$backup_dir/posts.json"
    state_file="$backup_dir/.imported_posts"
    pending_file="$backup_dir/.import_pending"
    log_file="$backup_dir/import-log.jsonl"
    local backup_source target_config account_name
    local item total index=0 candidate_count=0 skipped_count=0 imported_count=0 failed_count=0 upload_rc
    local receipt imported_at

    [[ -n "$API_TOKEN" ]] || die "Provide --token, --token-file, LOOPS_TOKEN or LOOPS_TOKEN_FILE."
    [[ -f "$manifest" && -f "$posts" ]] || die "Not a Loops backup directory: ${backup_dir}"
    jq -e '.format == "loops-migrator" and .format_version == 1' "$manifest" >/dev/null || die "Unsupported manifest."
    jq -e 'type == "array"' "$posts" >/dev/null || die "Invalid posts.json."
    if [[ -s "$pending_file" ]]; then
        die "An earlier upload has an uncertain outcome: $(<"$pending_file"). Inspect the target, then clear the marker manually."
    fi

    backup_source=$(jq -r '.source_instance // empty' "$manifest")
    if [[ "$ALLOW_SAME_INSTANCE" -ne 1 && "${backup_source%/}" == "$target" ]]; then
        die "Target equals the backup source. Use --allow-same-instance only if duplicate posts are intentional."
    fi

    api_request GET "${target}/api/v1/account/info/self"
    require_api_success "Authenticating against target"
    account_name=$(jq -r '.data.username // "unknown"' <<<"$API_RESPONSE")
    api_request GET "${target}/api/v1/config"
    require_api_success "Fetching target configuration"
    jq -e '.media | type == "object"' <<<"$API_RESPONSE" >/dev/null || die "Target configuration has no media limits."
    target_config="$API_RESPONSE"
    IMPORT_TARGET_CONFIG="$target_config"

    total=$(jq 'length' "$posts")
    echo "=== Loops import ==="
    echo "Backup: ${backup_dir}"
    echo "Target: ${target} (@${account_name})"
    echo "Posts:  ${total}"
    echo ""
    echo "  Validating media and metadata ..."
    while IFS= read -r item; do
        prepare_import_item "$backup_dir" "$item" || failed_count=$((failed_count + 1))
    done < <(jq -c 'reverse[]' "$posts")
    [[ "$failed_count" -eq 0 ]] || die "Import validation failed for ${failed_count} post(s). Nothing was uploaded."

    while IFS= read -r item; do
        IMPORT_ID=$(jq -r '.id' <<<"$item")
        if is_post_imported "$state_file" "$target" "$IMPORT_ID"; then
            skipped_count=$((skipped_count + 1))
        else
            candidate_count=$((candidate_count + 1))
        fi
    done < <(jq -c 'reverse[]' "$posts")

    echo "  ${candidate_count} post(s) will be re-published; ${skipped_count} already recorded for this target."
    echo "  Original IDs, URLs, timestamps and engagement cannot be restored."
    echo "  Successful uploads may federate as new posts."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Dry run complete: all ${total} post(s) passed local and target-limit validation."
        return 0
    fi
    if [[ "$ASSUME_YES" -ne 1 ]]; then
        [[ -t 0 ]] || die "Import needs confirmation. Re-run with --yes in non-interactive mode."
        read -r -p "Continue with re-publication? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Import cancelled."; return 0; }
    fi

    touch "$state_file" "$log_file"
    while IFS= read -r item; do
        index=$((index + 1))
        prepare_import_item "$backup_dir" "$item" || die "Post validation changed during import."
        if is_post_imported "$state_file" "$target" "$IMPORT_ID"; then
            echo "  [${index}/${total}] Skipped ${IMPORT_ID} (already imported)"
            continue
        fi
        printf '  [%s/%s] Uploading %s ... ' "$index" "$total" "$IMPORT_ID"
        write_pending_import "$pending_file" "$target" "$IMPORT_ID"
        upload_rc=0
        api_upload_video "$target" "$IMPORT_VIDEO_PATH" "$IMPORT_THUMBNAIL_PATH" \
            "$IMPORT_DESCRIPTION" "$IMPORT_ALT_TEXT" "$IMPORT_LANG" "$IMPORT_CAN_DOWNLOAD" \
            "$IMPORT_CAN_COMMENT" "$IMPORT_CAN_DUET" "$IMPORT_CAN_STITCH" "$IMPORT_CAN_EMBED" \
            "$IMPORT_IS_SENSITIVE" "$IMPORT_CONTAINS_AI" "$IMPORT_CONTAINS_AD" || upload_rc=$?
        if [[ "$upload_rc" -eq 0 ]]; then
            import_key "$target" "$IMPORT_ID" >>"$state_file"
            printf '\n' >>"$state_file"
            : >"$pending_file"
            imported_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            if jq -e . <<<"$API_RESPONSE" >/dev/null 2>&1; then
                receipt=$(jq -nc --arg target "$target" --arg source_id "$IMPORT_ID" \
                    --arg imported_at "$imported_at" --argjson response "$API_RESPONSE" \
                    '{target:$target,source_id:$source_id,imported_at:$imported_at,response:$response}')
            else
                receipt=$(jq -nc --arg target "$target" --arg source_id "$IMPORT_ID" \
                    --arg imported_at "$imported_at" --arg response "$API_RESPONSE" \
                    '{target:$target,source_id:$source_id,imported_at:$imported_at,response:$response}')
            fi
            printf '%s\n' "$receipt" >>"$log_file"
            imported_count=$((imported_count + 1))
            echo "uploaded; processing on target"
        else
            failed_count=$((failed_count + 1))
            if [[ "$UPLOAD_UNCERTAIN" -eq 1 ]]; then
                echo "outcome uncertain"
                die "Upload outcome for ${IMPORT_ID} is uncertain. The pending marker was retained to prevent an automatic duplicate."
            fi
            : >"$pending_file"
            echo "failed (HTTP ${API_HTTP_CODE}): $(json_error_message)"
            if [[ "$API_HTTP_CODE" == 401 || "$API_HTTP_CODE" == 403 ]]; then
                die "Target authorization failed or its upload policy rejected the account; stopping the import."
            fi
        fi
    done < <(jq -c 'reverse[]' "$posts")

    echo ""
    echo "Import complete: ${imported_count} uploaded, ${skipped_count} skipped, ${failed_count} failed."
    [[ "$failed_count" -eq 0 ]]
}

main() {
    local command_name="${1:-}" source="$DEFAULT_SOURCE" token="${LOOPS_TOKEN:-}"
    local token_file="${LOOPS_TOKEN_FILE:-}" output_dir="" input_dir="" target=""
    case "$command_name" in
        export|check|verify|import) shift ;;
        --version) echo "loops-migrator ${SCRIPT_VERSION}"; return 0 ;;
        -h|--help|'') usage; return 0 ;;
        *) usage >&2; return 1 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) require_option_value "$@"; source="$2"; shift 2 ;;
            --target) require_option_value "$@"; target="$2"; shift 2 ;;
            --token) require_option_value "$@"; token="$2"; shift 2 ;;
            --token-file) require_option_value "$@"; token_file="$2"; shift 2 ;;
            --output-dir) require_option_value "$@"; output_dir="$2"; shift 2 ;;
            --input-dir) require_option_value "$@"; input_dir="$2"; shift 2 ;;
            --metadata-only) METADATA_ONLY=1; shift ;;
            --allow-http) ALLOW_HTTP=1; shift ;;
            --force) FORCE=1; shift ;;
            --restart) RESTART=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --skip-thumbnails) SKIP_THUMBNAILS=1; shift ;;
            --allow-same-instance) ALLOW_SAME_INSTANCE=1; shift ;;
            --debug) DEBUG=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    check_deps
    validate_runtime_options
    if [[ -n "$token" && -n "$token_file" ]]; then
        die "Use either --token/LOOPS_TOKEN or --token-file/LOOPS_TOKEN_FILE, not both."
    fi
    API_TOKEN="$token"
    [[ -z "$token_file" ]] || read_token_file "$token_file"

    case "$command_name" in
        check)
            source=$(normalise_source "$source")
            [[ -n "$API_TOKEN" ]] || die "Provide a bearer token."
            check_auth "$source"
            ;;
        export)
            source=$(normalise_source "$source")
            [[ -n "$output_dir" ]] || output_dir="loops_backup_$(date -u '+%Y%m%dT%H%M%SZ')"
            output_dir=$(normalise_output_dir "$output_dir")
            do_export "$source" "$output_dir"
            ;;
        verify)
            [[ -n "$output_dir" ]] || die "verify requires --output-dir DIR."
            output_dir=$(normalise_output_dir "$output_dir")
            do_verify "$output_dir"
            ;;
        import)
            [[ -n "$target" ]] || die "import requires --target URL."
            [[ -n "$input_dir" ]] || die "import requires --input-dir DIR."
            target=$(normalise_source "$target")
            input_dir=$(normalise_output_dir "$input_dir")
            do_import "$target" "$input_dir"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
