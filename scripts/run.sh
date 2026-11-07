#!/usr/bin/env bash
# Cadence GitHub Action: explain and check the cron expressions a pull request adds or changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERE/lib.sh"

PRICING="https://rapidapi.com/bytestay-bytestay-default/api/cadence-cron-expression-api/pricing"
MARKER="<!-- cadence-action -->"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RESULTS="$WORK/results.jsonl"
: > "$RESULTS"
mkdir -p "$WORK/cache"

output() { printf '%s=%s\n' "$1" "$2" >> "$OUT"; }
flag() { # flag NAME VALUE → validates a true/false input
  case "$2" in true|false) ;; *) echo "::error::$1 must be true or false (got '$2')."; exit 1;; esac
}
number() { # number NAME VALUE MAX
  if [[ ! $2 =~ ^[0-9]+$ ]] || (( $2 > $3 )); then echo "::error::$1 must be a whole number from 0 to $3."; exit 1; fi
}

# 1. Preflight
for tool in curl jq git yq; do
  command -v "$tool" >/dev/null || { echo "::error::Cadence needs $tool on the runner."; exit 1; }
done
yq --version 2>/dev/null | grep -q mikefarah || { echo "::error::Cadence needs mikefarah's yq (v4) on the runner."; exit 1; }
CHECK_ALL="${INPUT_CHECK_ALL:-false}"; flag check-all "$CHECK_ALL"
COMMENT="${INPUT_COMMENT:-true}"; flag comment "$COMMENT"
case "${INPUT_FAIL_ON:-invalid}" in invalid|warning|never) ;; *)
  echo "::error::fail-on must be invalid, warning or never."; exit 1;; esac
FAIL_ON="${INPUT_FAIL_ON:-invalid}"
case "${INPUT_ON_QUOTA_EXCEEDED:-warn}" in warn|fail) ;; *)
  echo "::error::on-quota-exceeded must be warn or fail."; exit 1;; esac
case "${INPUT_CRON_PATHS_DIALECT:-unix}" in unix|seconds|quartz|aws) ;; *)
  echo "::error::cron-paths-dialect must be unix, seconds, quartz or aws."; exit 1;; esac
MAX_REQ="${INPUT_MAX_REQUESTS:-15}"; number max-requests "$MAX_REQ" 1000
NEXT_RUNS="${INPUT_NEXT_RUNS:-3}"; number next-runs "$NEXT_RUNS" 20
MIN_INTERVAL="${INPUT_MIN_INTERVAL:-5}"; number min-interval "$MIN_INTERVAL" 1440
LOCALE="$(trim "${INPUT_LOCALE:-en}")"
[[ $LOCALE =~ ^(en|pt|es|fr|de|it|nl)([-_][A-Za-z]{2})?$ ]] || {
  echo "::error::locale must be one of en, pt, es, fr, de, it, nl (got '$LOCALE')."; exit 1; }
TIMEZONE="$(trim "${INPUT_TIMEZONE:-UTC}")"; [[ -z $TIMEZONE ]] && TIMEZONE=UTC
zone_known "$TIMEZONE" || { echo "::error::timezone: unknown time zone '$TIMEZONE' (use an IANA name such as Europe/Lisbon)."; exit 1; }
INPUT_CRON_PATHS_TIMEZONE="$(trim "${INPUT_CRON_PATHS_TIMEZONE:-UTC}")"
[[ -z $INPUT_CRON_PATHS_TIMEZONE ]] && INPUT_CRON_PATHS_TIMEZONE=UTC
export INPUT_CRON_PATHS_TIMEZONE

if [[ -z ${INPUT_RAPIDAPI_KEY:-} && -z ${CADENCE_AUTH_HEADER:-} ]]; then
  if [[ ${GITHUB_EVENT_NAME:-} == pull_request* ]]; then
    echo "::warning::Cadence skipped: no rapidapi-key. Pull requests from forks don't get repository secrets."
    output passed true; output requests-used 0
    exit 0
  fi
  echo "::error::rapidapi-key is empty. Subscribe to the Cadence API (free Basic plan) at $PRICING and store the key as a secret."
  exit 1
fi
[[ -n ${INPUT_RAPIDAPI_KEY:-} ]] && echo "::add-mask::$INPUT_RAPIDAPI_KEY"

PR=""
if [[ ${GITHUB_EVENT_NAME:-} == pull_request* && -f ${GITHUB_EVENT_PATH:-} ]]; then
  PR="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
fi
NOW="${CADENCE_NOW:-$(date +%s)}"
START="$(jq -rn --argjson t "$NOW" '$t | todate')"

# 2. What to compare against
BASE_REF=""
[[ $CHECK_ALL == true ]] || BASE_REF="$(base_sha)"
BASE_COMMIT=""
if [[ -n $BASE_REF ]]; then
  BASE_COMMIT="$(resolve_base "$BASE_REF")"
elif [[ $CHECK_ALL != true ]]; then
  echo "::notice::No base to compare against for this event (set base-ref): every cron expression found is checked."
fi

# 3. Up to three requests per new or changed expression: validate, explain, next
requests=0 quota="" stop=""
api() { # api ENDPOINT BODY_FILE → sets $code and leaves the response in $WORK/resp.json; retries once on 000/5xx
  code="$(call_api "$1" "$2" "$WORK/resp.json" "$WORK/headers.txt")"; requests=$((requests + 1))
  if [[ $code == 000 || $code =~ ^5 ]]; then
    sleep "${CADENCE_RETRY_DELAY:-5}"
    code="$(call_api "$1" "$2" "$WORK/resp.json" "$WORK/headers.txt")"; requests=$((requests + 1))
  fi
  local q; q="$(header_value "$WORK/headers.txt" x-ratelimit-requests-remaining)"; [[ -n $q ]] && quota="$q"
  return 0
}
# api_error RESULT_FILE: any status the caller didn't handle. Writes the result and may stop the run.
api_error() {
  local res="$1" detail
  case "$code" in
    401|403)
      detail="$(jq -r '.message // empty' "$WORK/resp.json" 2>/dev/null || true)"
      echo "::error::Cadence refused the key (HTTP $code${detail:+: $detail}). Subscribe (free Basic plan) at $PRICING."
      stop="key refused" ;;
    429)
      if [[ ${INPUT_ON_QUOTA_EXCEEDED:-warn} == fail ]]; then
        echo "::error::Cadence monthly quota exhausted. Upgrade at $PRICING."
        jq -cn '{status: "failed", reason: "quota exhausted (HTTP 429)"}' > "$res"; stop="quota exhausted"; return 0
      fi
      echo "::warning::Cadence monthly quota exhausted: the remaining expressions were not checked. Upgrade at $PRICING."
      stop="quota exhausted" ;;
    *)
      echo "::warning::Cadence API unavailable (HTTP $code): the remaining expressions were not checked. Your build is not failed because of it."
      stop="API unavailable" ;;
  esac
  jq -cn --arg r "$stop (HTTP $code)" '{status: "not_analysed", reason: $r}' > "$res"
}

transitions() { # transitions ZONE → cached dst_transitions
  local f; f="$WORK/cache/tz-$(printf '%s' "$1" | cksum | cut -d' ' -f1).json"
  [[ -f $f ]] || dst_transitions "$1" "$NOW" > "$f"
  cat "$f"
}

# check SOURCE DIALECT ZONE EXPRESSION RESULT_FILE → writes {status, reason, normalized, description, runs, warnings, note}
check() {
  local source="$1" dialect="$2" zone="$3" expr="$4" res="$5" pre need do_next=false msg
  pre="$(precheck "$source" "$expr")"
  if [[ -n $pre ]]; then
    jq -cn --arg s "${pre%%$'\t'*}" --arg r "${pre#*$'\t'}" '{status: $s, reason: $r}' > "$res"; return 0
  fi
  if [[ -n $stop ]]; then jq -cn --arg r "$stop" '{status: "not_analysed", reason: $r}' > "$res"; return 0; fi
  if (( NEXT_RUNS > 0 || MIN_INTERVAL > 0 )) || [[ $source == workflow ]]; then do_next=true; fi
  # validate first: an invalid expression needs no more; a valid one needs room for explain (and next) too
  need=1; [[ $do_next == true ]] && need=2
  if (( requests + 1 > MAX_REQ )); then
    jq -cn --arg r "max-requests ($MAX_REQ) reached" '{status: "not_analysed", reason: $r}' > "$res"; return 0
  fi

  jq -cn --arg e "$expr" --arg d "$dialect" '{expression: $e, dialect: $d}' > "$WORK/body.json"
  api validate "$WORK/body.json"
  if [[ $code != 200 ]]; then api_error "$res"; return 0; fi
  cp "$WORK/resp.json" "$WORK/validate.json"
  if [[ $(jq -r '.valid' "$WORK/validate.json") != true ]]; then
    jq -c '{status: "invalid", reason: (.error.message // "invalid expression")}' "$WORK/validate.json" > "$res"; return 0
  fi
  if [[ $(jq -r '.never_fires' "$WORK/validate.json") == true ]]; then
    jq -c '{status: "invalid", normalized, reason: "never runs: \(.never_fires_reason // "no date matches")"}' \
      "$WORK/validate.json" > "$res"; return 0
  fi

  if (( requests + need > MAX_REQ )); then
    jq -cn --arg r "valid, but max-requests ($MAX_REQ) reached before the explanation" '{status: "not_analysed", reason: $r}' > "$res"
    return 0
  fi
  jq -cn --arg e "$expr" --arg d "$dialect" --arg l "$LOCALE" '{expression: $e, dialect: $d, locale: $l}' > "$WORK/body.json"
  api explain "$WORK/body.json"
  if [[ $code == 200 ]]; then cp "$WORK/resp.json" "$WORK/explain.json"
  elif [[ $code == 422 ]]; then echo null > "$WORK/explain.json"
  else api_error "$res"; return 0; fi

  echo null > "$WORK/next.json"; msg=""
  if [[ $do_next == true && $(jq -r '.computable' "$WORK/validate.json") != false ]]; then
    jq -cn --arg e "$expr" --arg d "$dialect" --arg z "$zone" --arg s "$START" --argjson n "$NEXT_RUNS" \
      '{expression: $e, dialect: $d, timezone: $z, start: $s, count: ([$n, 10] | max)}' > "$WORK/body.json"
    api next "$WORK/body.json"
    if [[ $code == 200 ]]; then cp "$WORK/resp.json" "$WORK/next.json"
    elif [[ $code == 422 ]]; then
      msg="$(jq -r '.detail.message // (.detail | tostring)' "$WORK/resp.json" 2>/dev/null || echo "run times unavailable")"
      if [[ $(jq -r '.detail.error // empty' "$WORK/resp.json" 2>/dev/null) == unknown_timezone ]]; then
        jq -cn --arg r "$msg" '{status: "invalid", reason: $r}' > "$res"; return 0
      fi
    else api_error "$res"; return 0; fi
  elif [[ $do_next == true ]]; then
    msg="$(jq -r '"run times not computed: \(.unsupported // "unsupported feature")"' "$WORK/validate.json")"
  fi
  if [[ $(jq -r '.exhausted == true and (.runs | length) == 0' "$WORK/next.json") == true ]]; then
    jq -c '{status: "invalid", reason: "never runs again\(if .note then ": \(.note)" else "" end)"}' "$WORK/next.json" > "$res"
    return 0
  fi

  jq -n --slurpfile v "$WORK/validate.json" --slurpfile n "$WORK/next.json" --argjson t "$(transitions "$zone")" \
    --arg source "$source" --arg zone "$zone" --argjson mi "$MIN_INTERVAL" \
    '{validate: $v[0], next: $n[0], source: $source, zone: $zone, transitions: $t, min_interval: $mi}' \
    | jq -c -f "$HERE/warnings.jq" > "$WORK/warnings.json"
  jq -n --slurpfile v "$WORK/validate.json" --slurpfile x "$WORK/explain.json" --slurpfile n "$WORK/next.json" \
    --slurpfile w "$WORK/warnings.json" --arg note "$msg" --argjson count "$NEXT_RUNS" \
    '{status: "checked", normalized: $v[0].normalized, description: $x[0].description,
      runs: ($n[0].runs // [] | .[:$count] | map(.unix)), warnings: $w[0],
      note: (if $note != "" then $note else null end)}' > "$res"
}

while IFS=$'\t' read -r kind f; do
  [[ -z $f || ! -f $f ]] && continue
  extract "$kind" "$f" > "$WORK/head.jsonl"
  [[ -s $WORK/head.jsonl ]] || continue
  echo '[]' > "$WORK/base-keys.json"
  if [[ -n $BASE_REF ]]; then
    base="$WORK/base"; rm -f "$base"
    set +e; base_file "$BASE_COMMIT" "$BASE_REF" "$f" "$base"; rc=$?; set -e
    if [[ $rc -eq 0 ]]; then
      extract "$kind" "$base" | jq -s 'map("\(.dialect)|\(.zone)|\(.expression)")' > "$WORK/base-keys.json"
    elif [[ $rc -eq 2 ]]; then
      echo "::warning file=$f::Couldn't read the base version of this file: all its cron expressions are checked."
    fi
  fi
  while IFS= read -r cron; do
    key="$(jq -r '"\(.dialect)|\(.zone)|\(.expression)"' <<<"$cron")"
    if [[ $(jq --arg k "$key" 'index($k) != null' "$WORK/base-keys.json") == true ]]; then
      jq -c --arg file "$f" --arg kind "$kind" '. + {file: $file, kind: $kind, status: "unchanged"}' <<<"$cron" >> "$RESULTS"
      continue
    fi
    res="$WORK/cache/$(printf '%s|%s' "$kind" "$key" | cksum | cut -d' ' -f1).json"
    if [[ ! -f $res ]] || [[ $(jq -r '.status' "$res") == not_analysed && -z $stop ]]; then
      check "$kind" "$(jq -r '.dialect' <<<"$cron")" "$(jq -r '.zone' <<<"$cron")" "$(jq -r '.expression' <<<"$cron")" "$res"
    fi
    jq -c --arg file "$f" --arg kind "$kind" --slurpfile r "$res" '. + {file: $file, kind: $kind} + $r[0]' <<<"$cron" >> "$RESULTS"
  done < "$WORK/head.jsonl"
done < <(discover)

# 4. Pass or fail
invalid="$(jq -s '[.[] | select(.status == "invalid" or .status == "failed")] | length' "$RESULTS")"
warnings="$(jq -s '[.[] | select(.status == "checked") | .warnings | length] | add // 0' "$RESULTS")"
checked="$(jq -s '[.[] | select(.status == "checked" or .status == "invalid")] | length' "$RESULTS")"
passed=true
case "$FAIL_ON" in
  invalid) (( invalid == 0 )) || passed=false ;;
  warning) (( invalid == 0 && warnings == 0 )) || passed=false ;;
esac
[[ $stop == "key refused" ]] && passed=false
if [[ $FAIL_ON != never ]] && jq -se 'any(.[]; .status == "failed")' "$RESULTS" >/dev/null; then passed=false; fi

# 5. Annotations
TZ="$TIMEZONE" jq -L "$HERE" -s -r --arg fail_on "$FAIL_ON" --arg tz "$TIMEZONE" -f "$HERE/annotate.jq" "$RESULTS"

# 6. Report: job summary, and a pull request comment that is updated on every run
if [[ -n $quota && $quota =~ ^[0-9]+$ ]] && (( quota < 6 )); then
  echo "::warning::Only $quota Cadence requests left this month. Plans: $PRICING"
fi
head_sha="${GITHUB_SHA:-}"
[[ -n $PR ]] && head_sha="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
jq -s --argjson passed "$passed" --arg fail_on "$FAIL_ON" --arg requests "$requests" --arg quota "$quota" \
  --arg tz "$TIMEZONE" --argjson next_runs "$NEXT_RUNS" \
  --arg blob "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/blob/$head_sha" --arg pr "$PR" \
  '{results: ., passed: $passed, fail_on: $fail_on, requests: $requests, quota: $quota, tz: $tz,
    next_runs: $next_runs, blob: $blob, pr: $pr}' "$RESULTS" > "$WORK/report-input.json"
TZ="$TIMEZONE" jq -L "$HERE" -r -f "$HERE/report.jq" "$WORK/report-input.json" > "$WORK/report.md"
cat "$WORK/report.md" >> "$SUMMARY"

comment_url=""
if [[ $COMMENT == true && -n $PR ]]; then
  existing=""
  for page in 1 2 3 4 5 6 7 8 9 10; do
    [[ $(gh_api GET "repos/${GITHUB_REPOSITORY:-}/issues/$PR/comments?per_page=100&page=$page" "$WORK/comments.json") == 200 ]] || break
    existing="$(jq -r --arg m "$MARKER" 'map(select(.body | contains($m))) | first | .id // empty' "$WORK/comments.json")"
    [[ -n $existing || $(jq 'length' "$WORK/comments.json") -lt 100 ]] && break
  done
  worth="$(jq -s 'any(.[]; .status != "unchanged")' "$RESULTS")"
  if [[ -n $existing || $worth == true ]]; then
    { printf '%s\n' "$MARKER"; cat "$WORK/report.md"; } | jq -Rs '{body: .}' > "$WORK/comment.json"
    if [[ -n $existing ]]; then
      code="$(gh_api PATCH "repos/${GITHUB_REPOSITORY:-}/issues/comments/$existing" "$WORK/comment-resp.json" "$WORK/comment.json")"
    else
      code="$(gh_api POST "repos/${GITHUB_REPOSITORY:-}/issues/$PR/comments" "$WORK/comment-resp.json" "$WORK/comment.json")"
    fi
    if [[ $code =~ ^2 ]]; then
      comment_url="$(jq -r '.html_url // empty' "$WORK/comment-resp.json")"
    else
      echo "::notice::Couldn't comment on the pull request (HTTP $code): give the job \`pull-requests: write\`. The report is in the job summary."
    fi
  fi
fi

# 7. Outputs and exit code
output passed "$passed"
output expressions-checked "$checked"
output invalid "$invalid"
output warnings "$warnings"
output requests-used "$requests"
output quota-remaining "$quota"
output comment-url "$comment_url"
echo "Cadence: $checked expression(s) checked, $invalid invalid, $warnings warning(s), $requests request(s), passed=$passed${quota:+, $quota left this month}"
if [[ $passed != true ]]; then
  # say why, instead of leaving only GitHub's generic "Process completed with exit code 1"
  why=()
  (( invalid > 0 )) && why+=("$invalid invalid cron expression(s)")
  [[ $FAIL_ON == warning ]] && (( warnings > 0 )) && why+=("$warnings warning(s) with fail-on: warning")
  [[ $stop == "key refused" ]] && why+=("the API key was refused")
  if (( ${#why[@]} > 0 )); then
    msg="$(IFS=';'; echo "${why[*]}")"
    echo "::error title=Cadence check failed::${msg//;/; }. The report lists every expression."
  fi
fi
[[ $passed == true ]]
