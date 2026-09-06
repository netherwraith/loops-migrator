#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/loops-migrator.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../loops-migrator.sh
source "$SCRIPT"

passed=0
failed=0

pass() { echo "ok - $1"; passed=$((passed + 1)); }
fail() { echo "not ok - $1"; failed=$((failed + 1)); }
run_test() { local name="$1"; shift; if ("$@"); then pass "$name"; else fail "$name"; fi; }

test_source_validation() {
    [[ "$(normalise_source 'https://loops.example/')" == 'https://loops.example' ]] &&
        ! (normalise_source 'http://loops.example' >/dev/null 2>&1)
}

test_relative_media_url() {
    [[ "$(absolute_media_url 'https://loops.example' '/storage/video.mp4')" == \
        'https://loops.example/storage/video.mp4' ]]
}

test_unsafe_media_scheme_rejected() {
    ! absolute_media_url 'https://loops.example' 'file:///etc/passwd' >/dev/null
}

test_extension_whitelist() {
    [[ "$(media_extension 'https://cdn.example/v/file.MP4?x=1' webm)" == mp4 ]] &&
        [[ "$(media_extension 'https://cdn.example/v/file.php?x=.mp4' jpg)" == jpg ]]
}

test_repeated_cursor_rejected() {
    local call_file="$TEST_TMP/calls" records="$TEST_TMP/records" raw="$TEST_TMP/raw" output
    printf '0\n' >"$call_file"
    api_request() {
        local calls
        calls=$(<"$call_file")
        printf '%s\n' "$((calls + 1))" >"$call_file"
        API_HTTP_CODE=200
        API_RESPONSE='{"data":[{"id":"1"}],"meta":{"next_cursor":"same","total_videos":99}}'
    }
    if output=$(fetch_studio_posts 'https://loops.example' "$records" "$raw" 2>&1); then
        return 1
    fi
    [[ "$output" == *'repeated page cursor'* ]]
}

test_full_page_without_cursor_rejected() {
    local records="$TEST_TMP/full-records" raw="$TEST_TMP/full-raw" page_json output
    page_json=$(jq -nc '{data:[range(0;20) | {id:(tostring)}],meta:{total_videos:21}}')
    api_request() { API_HTTP_CODE=200; API_RESPONSE="$page_json"; }
    if output=$(fetch_studio_posts 'https://loops.example' "$records" "$raw" 2>&1); then
        return 1
    fi
    [[ "$output" == *'possibly truncated backup'* ]]
}

test_verify_detects_tampering() {
    local backup="$TEST_TMP/backup" checksum output
    mkdir -p "$backup/videos"
    printf 'original' >"$backup/videos/1.mp4"
    checksum=$(sha256_file "$backup/videos/1.mp4")
    printf '%s\n' '{"format":"loops-migrator","format_version":1}' >"$backup/manifest.json"
    jq -n --arg sha "$checksum" '[{files:{video:{path:"videos/1.mp4",bytes:8,sha256:$sha},thumbnail:null}}]' >"$backup/posts.json"
    do_verify "$backup" >/dev/null
    printf 'changed' >"$backup/videos/1.mp4"
    if output=$(do_verify "$backup" 2>&1); then
        return 1
    fi
    [[ "$output" == *'Integrity mismatch'* ]]
}

test_missing_option_value_rejected() {
    local output
    output=$("$SCRIPT" export --source --token token 2>&1)
    [[ $? -ne 0 && "$output" == *'--source requires a non-empty value'* ]]
}

test_complete_export_builds_manifest() {
    local backup="$TEST_TMP/complete"
    (
        API_TOKEN='secret-not-for-export'
        REQUEST_DELAY=0
        api_request() {
            API_HTTP_CODE=200
            case "$2" in
                */account/info/self)
                    API_RESPONSE='{"data":{"id":"7","username":"alice"}}'
                    ;;
                */api/v1/config)
                    API_RESPONSE='{"app":{"software":"loops","version":"test"}}'
                    ;;
                */studio/posts*)
                    API_RESPONSE='{"data":[{"id":"42","status":"published","caption":"hello","media":{"src_url":"https://cdn.example/42.mp4","thumbnail":"https://cdn.example/42.jpg"}}],"meta":{"next_cursor":null,"total_videos":1}}'
                    ;;
                */video/42)
                    API_RESPONSE='{"data":{"id":"42","caption":"hello","lang":"en","media":{"src_url":"https://cdn.example/42.mp4","thumbnail":"https://cdn.example/42.jpg"}}}'
                    ;;
                *) return 1 ;;
            esac
        }
        download_media() {
            mkdir -p "$(dirname "$2")"
            printf 'fixture' >"$2"
            DOWNLOAD_CONTENT_TYPE='application/octet-stream'
        }
        do_export 'https://loops.example' "$backup" >/dev/null
    ) || return 1
    jq -e '.format == "loops-migrator" and .counts.posts == 1 and .counts.videos_downloaded == 1' \
        "$backup/manifest.json" >/dev/null &&
        jq -e '.[0].post.lang == "en" and .[0].files.video.sha256' "$backup/posts.json" >/dev/null &&
        [[ -s "$backup/videos/42.mp4" ]] &&
        ! rg -q 'secret-not-for-export' "$backup"
}

run_test 'source URL validation requires HTTPS' test_source_validation
run_test 'instance-relative media URL is resolved' test_relative_media_url
run_test 'unsafe media URL scheme is rejected' test_unsafe_media_scheme_rejected
run_test 'media extensions are whitelisted' test_extension_whitelist
run_test 'repeated pagination cursor is rejected' test_repeated_cursor_rejected
run_test 'full page without cursor is rejected' test_full_page_without_cursor_rejected
run_test 'verification detects changed files' test_verify_detects_tampering
run_test 'missing option value is rejected' test_missing_option_value_rejected
run_test 'complete export builds a token-free manifest' test_complete_export_builds_manifest

echo "${passed} passed, ${failed} failed"
[[ "$failed" -eq 0 ]]
