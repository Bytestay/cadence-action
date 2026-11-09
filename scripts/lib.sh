#!/usr/bin/env bash
# Functions used by run.sh; sourced by the bats tests too.

CADENCE_HOST="cadence-cron-expression-api.p.rapidapi.com"
API_MARKET_URL="https://prod.api.market/api/v1/bytestay/cadence"
ZERO_SHA="0000000000000000000000000000000000000000"
ZONEINFO="${CADENCE_ZONEINFO:-/usr/share/zoneinfo}"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# glob_match PATH PATTERN: shell-style pattern; a leading "**/" also matches at the repository root.
glob_match() {
  local path="$1" pattern="$2"
  # Explicit ifs: bash 3.2 (macOS runners) with `set -e` exits on a failed `[[ ]] && return` at the end of a block.
  # shellcheck disable=SC2053 # the right-hand side is a pattern on purpose
  if [[ $path == $pattern ]]; then return 0; fi
  if [[ $pattern == '**/'* ]]; then
    # shellcheck disable=SC2053
    if [[ $path == ${pattern#'**/'} ]]; then return 0; fi
  fi
  # "/**/" also matches no folder at all: k8s/**/cronjob.yaml matches k8s/cronjob.yaml
  if [[ $pattern == *'/**/'* ]]; then
    local slash=/ zero
    zero="${pattern//\/\*\*\//$slash}" # a variable: escaping "/" in the replacement differs between bash versions
    # shellcheck disable=SC2053
    if [[ $path == $zero ]]; then return 0; fi
  fi
  return 1
}

# matches_any PATH "glob1,glob2,…"
matches_any() {
  local path="$1" list="$2" p pats=()
  # read, not `for p in $list`: an unquoted list would also be expanded against the files on disk
  IFS=',' read -r -a pats <<<"$list"
  for p in ${pats[@]+"${pats[@]}"}; do
    p="$(trim "$p")"
    if [[ -n $p ]] && glob_match "$path" "$p"; then return 0; fi
  done
  return 1
}

# file_kind PATH → workflow, file, cronjob or nothing (the first input whose globs match wins)
file_kind() {
  local f="$1"
  if matches_any "$f" "${INPUT_EXCLUDE_PATHS:-}"; then return 0; fi
  if matches_any "$f" "${INPUT_WORKFLOW_PATHS:-}"; then echo workflow; return 0; fi
  if matches_any "$f" "${INPUT_CRON_PATHS:-}"; then echo file; return 0; fi
  if matches_any "$f" "${INPUT_CRONJOB_PATHS:-}"; then echo cronjob; fi
  return 0
}

# discover: "KIND<TAB>PATH" for every tracked file one of the path inputs matches
discover() {
  local f kind
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    kind="$(file_kind "$f")"
    if [[ -n $kind ]]; then printf '%s\t%s\n' "$kind" "$f"; fi
  done < <(git ls-files 2>/dev/null)
}

# extract KIND FILE → one JSON object per cron expression: {expression, line, zone, name, dialect}.
# A file yq can't parse (a Helm template, say) gives nothing.
extract() {
  local kind="$1" file="$2"
  [[ -f $file ]] || return 0
  case "$kind" in
    workflow)
      yq -o json -I0 'select(.on | tag == "!!map") | .on.schedule[]? | select(tag == "!!map" and has("cron"))
        | {"expression": (.cron | tostring), "line": (.cron | line)}' "$file" 2>/dev/null \
        | jq -c '. + {zone: "UTC", name: "", dialect: "unix"}' 2>/dev/null || true ;;
    cronjob)
      grep -q 'CronJob' "$file" 2>/dev/null || return 0
      yq -o json -I0 'select(tag == "!!map" and .kind == "CronJob" and (.spec.schedule | tag) == "!!str")
        | {"expression": .spec.schedule, "line": (.spec.schedule | line), "zone": (.spec.timeZone // ""),
           "name": (.metadata.name // "")}' "$file" 2>/dev/null \
        | jq -c '. + {dialect: "unix"} | if .zone == "" then .zone = "UTC" | .zone_default = true else . end' \
          2>/dev/null || true ;;
    file)
      case "$file" in
        *.yml|*.yaml|*.json)
          local keys
          keys="$(jq -rn --arg k "${INPUT_CRON_KEYS:-cron,schedule}" \
            '$k | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(. != "")) | join("|")')"
          [[ -z $keys ]] && return 0
          KEYS="^($keys)$" yq -o json -I0 '.. | select(tag == "!!str" and ((key // "") | tostring | test(strenv(KEYS))))
            | {"expression": ., "line": line}' "$file" 2>/dev/null ;;
        *) crontab_lines "$file" ;;
      esac | jq -c --arg zone "${INPUT_CRON_PATHS_TIMEZONE:-UTC}" --arg dialect "${INPUT_CRON_PATHS_DIALECT:-unix}" '
        . + {zone: $zone, name: "",
             dialect: (if (.expression | test("^\\s*cron\\(")) then "aws" else $dialect end)}' 2>/dev/null || true ;;
  esac
}

# crontab_lines FILE → {expression, line} for every schedule line of a crontab (comments, blank lines and
# VAR=value lines skipped; @shortcuts kept; the command after the five fields dropped)
crontab_lines() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next }
    { if ($1 ~ /^@/) e = $1; else if (NF >= 5) e = $1 " " $2 " " $3 " " $4 " " $5; else e = $0
      gsub(/\\/, "\\\\", e); gsub(/"/, "\\\"", e)
      printf "{\"expression\":\"%s\",\"line\":%d}\n", e, NR }' "$1" 2>/dev/null
}

# precheck SOURCE EXPRESSION → empty when the expression should go to the API, else "invalid<TAB>why" or
# "skipped<TAB>why" (no request spent)
precheck() {
  local source="$1" e
  e="$(trim "$2")"
  if [[ -z $e ]]; then printf 'invalid\tthe expression is empty'; return 0; fi
  if [[ $e == *'{{'* || $e == *'${'* ]]; then printf 'skipped\ta template, not a literal expression'; return 0; fi
  if [[ $e == rate\(* ]]; then printf 'skipped\ta rate() expression, not cron'; return 0; fi
  if [[ $source == workflow && $e == @* ]]; then
    printf 'invalid\tGitHub Actions schedules take five fields; shortcuts like %s are not supported' "${e%% *}"
    return 0
  fi
  if [[ $source == cronjob && $e =~ ^(CRON_)?TZ= ]]; then
    printf 'invalid\tKubernetes rejects TZ or CRON_TZ in the schedule; set spec.timeZone instead'
    return 0
  fi
  return 0
}

# zone_known NAME → 0 when the runner's zoneinfo has NAME (or there is no zoneinfo to check against)
zone_known() {
  [[ $1 == UTC ]] && return 0
  [[ -d $ZONEINFO ]] || return 0
  [[ $1 != *..* && -f $ZONEINFO/$1 ]]
}

# dst_transitions ZONE NOW → JSON array of {t, o1, o2}: the offset changes (minutes east of UTC) in the year
# after NOW, found in 30-minute steps with jq's localtime and TZ
dst_transitions() {
  if [[ $1 == UTC ]] || ! zone_known "$1"; then echo '[]'; return 0; fi
  TZ="$1" jq -nc --argjson now "$(( $2 / 1800 * 1800 ))" '
    # not strflocaltime("%z"): jq gets it wrong inside a fall-back overlap; localtime read back as UTC is exact
    def off: ((localtime | mktime) - .) / 60;
    [range(0; 366 * 48) | $now + . * 1800 | {t: ., o: off}] as $s
    | [range(1; $s | length) as $i | select($s[$i - 1].o != $s[$i].o) | {t: $s[$i].t, o1: $s[$i - 1].o, o2: $s[$i].o}]' \
    2>/dev/null || echo '[]'
}

# gh_api METHOD PATH OUT [JSON_FILE] → prints the HTTP status ("000" when the request itself failed)
gh_api() {
  local method="$1" path="$2" out="$3" data="${4:-}" code args=()
  [[ -n $data ]] && args=(-H "Content-Type: application/json" --data-binary "@$data")
  code="$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN:-}" -H "Accept: application/vnd.github+json" \
    ${args[@]+"${args[@]}"} "${GITHUB_API_URL:-https://api.github.com}/$path" 2>/dev/null)" || code="000"
  printf '%s' "${code:-000}"
}

# base_sha → the commit to compare against: the base-ref input, else the pull request base, else the push's
# previous commit. Empty when there is none (a new branch, or an event without a diff).
base_sha() {
  local ev="${GITHUB_EVENT_PATH:-}" sha=""
  if [[ -n ${INPUT_BASE_REF:-} ]]; then printf '%s' "$INPUT_BASE_REF"; return 0; fi
  [[ -f $ev ]] || return 0
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request*) sha="$(jq -r '.pull_request.base.sha // empty' "$ev")" ;;
    push|merge_group) sha="$(jq -r '.before // .merge_group.base_sha // empty' "$ev")" ;;
  esac
  [[ $sha == "$ZERO_SHA" ]] && sha=""
  printf '%s' "$sha"
}

# resolve_base REF → the local commit for REF, fetching it (depth 1) when the checkout doesn't have it.
# Empty when it can't be fetched (base_file then falls back to the GitHub API).
resolve_base() {
  local ref="$1"
  if git rev-parse -q --verify "$ref^{commit}" 2>/dev/null; then return 0; fi
  if git fetch -q --no-tags --depth=1 origin "$ref" 2>/dev/null; then
    git rev-parse -q --verify "FETCH_HEAD^{commit}" 2>/dev/null || true
  fi
  return 0
}

# base_file COMMIT REF PATH OUT → 0 found, 1 not in the base (a new file), 2 couldn't be read
base_file() {
  local commit="$1" ref="$2" path="$3" out="$4" code enc
  if [[ -n $commit ]]; then
    if git cat-file -e "$commit:$path" 2>/dev/null; then git show "$commit:$path" > "$out" && return 0; return 2; fi
    return 1
  fi
  enc="$(jq -rn --arg p "$path" '$p | split("/") | map(@uri) | join("/")')"
  code="$(gh_api GET "repos/${GITHUB_REPOSITORY:-}/contents/$enc?ref=$(jq -rn --arg r "$ref" '$r | @uri')" "$out.json")"
  case "$code" in
    200) jq -er '.content' "$out.json" 2>/dev/null | base64 -d > "$out" 2>/dev/null && return 0; return 2 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

# call_api ENDPOINT BODY_FILE OUT HEADERS → prints the HTTP status ("000" when the request itself failed)
call_api() {
  local endpoint="$1" body="$2" out="$3" headers="$4" code
  local base="https://$CADENCE_HOST" auth=(-H "X-RapidAPI-Key: ${INPUT_RAPIDAPI_KEY:-}" -H "X-RapidAPI-Host: $CADENCE_HOST")
  if [[ ${MARKET:-} == api.market ]]; then base="$API_MARKET_URL"; auth=(-H "x-api-market-key: ${INPUT_API_MARKET_KEY:-}"); fi
  local url="${CADENCE_API_URL:-$base}/v1/cron/$endpoint"
  # CADENCE_API_URL / CADENCE_AUTH_HEADER let the tests and maintainers call the API directly
  [[ -n ${CADENCE_AUTH_HEADER:-} ]] && auth=(-H "$CADENCE_AUTH_HEADER")
  code="$(curl -sS --max-time 30 -o "$out" -D "$headers" -w '%{http_code}' \
    -X POST "$url" "${auth[@]}" -H "Content-Type: application/json" --data-binary "@$body" 2>/dev/null)" || code="000"
  printf '%s' "${code:-000}"
}

# header_value HEADERS_FILE NAME (case-insensitive) → value or empty
header_value() { awk -v n="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" -F': *' \
  'tolower($1) == n { sub(/\r$/, "", $2); v = $2 } END { if (v != "") print v }' "$1" 2>/dev/null; }
