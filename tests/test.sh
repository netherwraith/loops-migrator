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

test_auth_flow_registers_exchanges_and_saves_token() {
    local token_file="$TEST_TMP/auth-token" call_file="$TEST_TMP/oauth-calls"
    local registration_file="$TEST_TMP/registration.json" exchange_file="$TEST_TMP/exchange.json"
    local checked_file="$TEST_TMP/auth-checked" output mode
    printf '0\n' >"$call_file"
    output=$( (
        REQUEST_DELAY=0
        AUTH_WRITE=1
        NO_BROWSER=1
        FORCE=0
        oauth_post() {
            local count
            count=$(<"$call_file")
            count=$((count + 1))
            printf '%s\n' "$count" >"$call_file"
            API_HTTP_CODE=200
            if [[ "$count" -eq 1 ]]; then
                printf '%s\n' "$2" >"$registration_file"
                API_RESPONSE='{"client_id":"client-id","client_secret":"client-secret"}'
            else
                printf '%s\n' "$2" >"$exchange_file"
                API_RESPONSE='{"access_token":"access-token","token_type":"Bearer"}'
            fi
        }
        check_auth() {
            [[ "$1" == 'https://loops.example' && "$API_TOKEN" == 'access-token' ]] || return 1
            touch "$checked_file"
        }
        do_auth 'https://loops.example' "$token_file" 'Loops Migrator Test' <<<'authorization-code'
    ) 2>&1) || return 1
    mode=$(stat -f '%Lp' "$token_file" 2>/dev/null || stat -c '%a' "$token_file")
    [[ "$(<"$token_file")" == 'access-token' ]] &&
        [[ "$mode" == 600 ]] &&
        [[ -e "$checked_file" ]] &&
        jq -e '.client_name == "Loops Migrator Test" and .redirect_uris == "urn:ietf:wg:oauth:2.0:oob" and .scopes == "read write"' "$registration_file" >/dev/null &&
        jq -e '.grant_type == "authorization_code" and .code == "authorization-code" and .scope == "read write"' "$exchange_file" >/dev/null &&
        [[ "$output" == *'/oauth/authorize?'* ]] &&
        [[ "$output" != *'client-secret'* && "$output" != *'access-token'* ]]
}

test_auth_refuses_existing_token_without_force() {
    local token_file="$TEST_TMP/existing-token" output
    printf 'old-token\n' >"$token_file"
    if output=$( (
        AUTH_WRITE=0
        FORCE=0
        do_auth 'https://loops.example' "$token_file" 'Loops Migrator'
    ) 2>&1); then
        return 1
    fi
    [[ "$output" == *'Token file already exists'* ]] && [[ "$(<"$token_file")" == 'old-token' ]]
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
        ! grep -R -q -- 'secret-not-for-export' "$backup"
}

make_import_fixture() {
    local backup="$1" video_one video_two sha_one sha_two bytes_one bytes_two
    mkdir -p "$backup/videos"
    video_one="$backup/videos/1.mp4"
    video_two="$backup/videos/2.mp4"
    dd if=/dev/zero of="$video_one" bs=1000 count=300 2>/dev/null
    dd if=/dev/zero of="$video_two" bs=1000 count=300 2>/dev/null
    sha_one=$(sha256_file "$video_one")
    sha_two=$(sha256_file "$video_two")
    bytes_one=$(file_size "$video_one")
    bytes_two=$(file_size "$video_two")
    printf '%s\n' '{"format":"loops-migrator","format_version":1,"source_instance":"https://source.example"}' >"$backup/manifest.json"
    jq -n --arg sha_one "$sha_one" --arg sha_two "$sha_two" \
        --argjson bytes_one "$bytes_one" --argjson bytes_two "$bytes_two" '[
        {id:"2",studio:{caption:"newest"},post:null,
         files:{video:{path:"videos/2.mp4",bytes:$bytes_two,sha256:$sha_two},thumbnail:null}},
        {id:"1",studio:{caption:"oldest",permissions:{can_comment:true}},
         post:{caption:"oldest",lang:"en",is_sensitive:true,
               media:{alt_text:"description"},
               permissions:{can_download:true,can_comment:true,can_duet:false,can_stitch:true,can_embed:false},
               meta:{contains_ai:true,contains_ad:false}},
         files:{video:{path:"videos/1.mp4",bytes:$bytes_one,sha256:$sha_one},thumbnail:null}}
    ]' >"$backup/posts.json"
}

mock_import_api() {
    API_HTTP_CODE=200
    case "$2" in
        */api/v1/config) API_RESPONSE='{"media":{"max_video_size":40,"allowed_video_formats":["mp4"]}}' ;;
        *) API_RESPONSE='{"data":{"id":"9","username":"target-user"}}' ;;
    esac
}

test_import_dry_run_has_no_side_effects() {
    local backup="$TEST_TMP/import-dry" upload_marker="$TEST_TMP/uploaded"
    make_import_fixture "$backup"
    (
        API_TOKEN=token
        REQUEST_DELAY=0
        DRY_RUN=1
        api_request() { mock_import_api "$@"; }
        api_upload_video() { touch "$upload_marker"; }
        do_import 'https://target.example' "$backup" >/dev/null
    ) || return 1
    [[ ! -e "$backup/.imported_posts" && ! -e "$backup/.import_pending" && ! -e "$upload_marker" ]]
}

test_import_preserves_metadata_and_oldest_first() {
    local backup="$TEST_TMP/import-complete" upload_log="$TEST_TMP/upload-log"
    make_import_fixture "$backup"
    (
        API_TOKEN=token
        REQUEST_DELAY=0
        ASSUME_YES=1
        api_request() { mock_import_api "$@"; }
        api_upload_video() {
            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$(basename "$2")" "$4" "$5" "$6" "$7" "$8" "${12}" >>"$upload_log"
            API_HTTP_CODE=200
            API_RESPONSE='{"data":[],"error":{"code":"ok"}}'
            UPLOAD_UNCERTAIN=0
        }
        do_import 'https://target.example' "$backup" >/dev/null
    ) || return 1
    [[ "$(sed -n '1p' "$upload_log")" == '1.mp4|oldest|description|en|true|true|true' ]] &&
        [[ "$(sed -n '2p' "$upload_log")" == '2.mp4|newest|||false|false|false' ]] &&
        [[ "$(wc -l <"$backup/.imported_posts" | tr -d '[:space:]')" -eq 2 ]] &&
        [[ "$(wc -l <"$backup/import-log.jsonl" | tr -d '[:space:]')" -eq 2 ]] &&
        [[ ! -s "$backup/.import_pending" ]]
}

test_import_resume_is_target_scoped() {
    local state_file="$TEST_TMP/state"
    import_key 'https://one.example' 42 >"$state_file"
    printf '\n' >>"$state_file"
    is_post_imported "$state_file" 'https://one.example' 42 &&
        ! is_post_imported "$state_file" 'https://two.example' 42
}

test_same_instance_import_is_rejected() {
    local backup="$TEST_TMP/same-instance" output
    make_import_fixture "$backup"
    if output=$(API_TOKEN=token do_import 'https://source.example' "$backup" 2>&1); then
        return 1
    fi
    [[ "$output" == *'Target equals the backup source'* ]]
}

test_uncertain_upload_retains_pending_marker() {
    local backup="$TEST_TMP/uncertain" output
    make_import_fixture "$backup"
    if output=$( (
        API_TOKEN=token
        REQUEST_DELAY=0
        ASSUME_YES=1
        api_request() { mock_import_api "$@"; }
        api_upload_video() {
            API_HTTP_CODE=000
            API_RESPONSE=''
            UPLOAD_UNCERTAIN=1
            return 2
        }
        do_import 'https://target.example' "$backup"
    ) 2>&1); then
        return 1
    fi
    [[ "$output" == *'outcome for 1 is uncertain'* ]] &&
        grep -qxF "$(import_key 'https://target.example' 1)" "$backup/.import_pending"
}

test_symlinked_backup_path_is_rejected() {
    local backup="$TEST_TMP/symlink-backup" outside="$TEST_TMP/outside" record
    mkdir -p "$backup" "$outside"
    printf 'private' >"$outside/file.mp4"
    ln -s "$outside" "$backup/videos"
    record=$(jq -nc --arg sha "$(sha256_file "$outside/file.mp4")" \
        --argjson bytes "$(file_size "$outside/file.mp4")" \
        '{path:"videos/file.mp4",sha256:$sha,bytes:$bytes}')
    ! resolve_backup_file "$backup" "$record" video >/dev/null 2>&1
}

test_upload_retries_rate_limit() {
    local video="$TEST_TMP/upload.mp4" counter_file="$TEST_TMP/upload-count"
    dd if=/dev/zero of="$video" bs=1000 count=300 2>/dev/null
    printf '0\n' >"$counter_file"
    (
        API_TOKEN=token
        REQUEST_DELAY=0
        MAX_RETRIES=2
        RETRY_BASE_DELAY=0
        sleep() { :; }
        curl() {
            local output_file='' header_file='' previous='' argument count
            for argument in "$@"; do
                [[ "$previous" == '-o' ]] && output_file="$argument"
                [[ "$previous" == '-D' ]] && header_file="$argument"
                previous="$argument"
            done
            count=$(<"$counter_file")
            count=$((count + 1))
            printf '%s\n' "$count" >"$counter_file"
            if [[ "$count" -eq 1 ]]; then
                printf 'Retry-After: 0\r\n' >"$header_file"
                printf '{"message":"slow down"}' >"$output_file"
                printf '429'
            else
                : >"$header_file"
                printf '{"ok":true}' >"$output_file"
                printf '200'
            fi
        }
        api_upload_video 'https://target.example' "$video" '' caption '' en \
            false true false false false false false false
    ) >/dev/null 2>&1 || return 1
    [[ "$(<"$counter_file")" -eq 2 ]]
}

test_upload_timeout_is_not_retried() {
    local video="$TEST_TMP/timeout.mp4" counter_file="$TEST_TMP/timeout-count"
    dd if=/dev/zero of="$video" bs=1000 count=300 2>/dev/null
    printf '0\n' >"$counter_file"
    (
        API_TOKEN=token
        REQUEST_DELAY=0
        curl() {
            local count
            count=$(<"$counter_file")
            printf '%s\n' "$((count + 1))" >"$counter_file"
            return 28
        }
        api_upload_video 'https://target.example' "$video" '' caption '' en \
            false true false false false false false false
        return 1
    ) >/dev/null 2>&1
    [[ "$(<"$counter_file")" -eq 1 ]]
}

run_test 'source URL validation requires HTTPS' test_source_validation
run_test 'instance-relative media URL is resolved' test_relative_media_url
run_test 'unsafe media URL scheme is rejected' test_unsafe_media_scheme_rejected
run_test 'media extensions are whitelisted' test_extension_whitelist
run_test 'repeated pagination cursor is rejected' test_repeated_cursor_rejected
run_test 'full page without cursor is rejected' test_full_page_without_cursor_rejected
run_test 'verification detects changed files' test_verify_detects_tampering
run_test 'missing option value is rejected' test_missing_option_value_rejected
run_test 'OAuth flow registers, exchanges and securely saves a token' test_auth_flow_registers_exchanges_and_saves_token
run_test 'OAuth flow refuses to overwrite a token without force' test_auth_refuses_existing_token_without_force
run_test 'complete export builds a token-free manifest' test_complete_export_builds_manifest
run_test 'import dry run has no side effects' test_import_dry_run_has_no_side_effects
run_test 'import preserves metadata and uploads oldest first' test_import_preserves_metadata_and_oldest_first
run_test 'import resume state is scoped to target' test_import_resume_is_target_scoped
run_test 'same-instance import is rejected by default' test_same_instance_import_is_rejected
run_test 'uncertain upload retains duplicate-prevention marker' test_uncertain_upload_retains_pending_marker
run_test 'symlinked backup paths are rejected' test_symlinked_backup_path_is_rejected
run_test 'upload retries a definite rate limit' test_upload_retries_rate_limit
run_test 'upload timeout is not blindly retried' test_upload_timeout_is_not_retried

echo "${passed} passed, ${failed} failed"
[[ "$failed" -eq 0 ]]
