#!/usr/bin/env bats
# Unit tests: run.sh in a real git repository, against a fake curl that answers with real recorded API responses.

ROOT="$BATS_TEST_DIRNAME/.."
FIX="$ROOT/tests/fixtures"

commit() { git -C "$REPO" add -A && git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "$1" && git -C "$REPO" rev-parse HEAD; }

setup() {
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock" REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$MOCK_DIR" "$REPO"
  cp -R "$FIX/repo/." "$REPO/"
  git -C "$REPO" init -q
  BASE="$(commit base)"
  HEAD="$BASE"
  echo '{"message":"Internal Server Error"}' > "$MOCK_DIR/body_503"
  cp "$ROOT/tests/responses/rapidapi_401.json" "$MOCK_DIR/body_401"
  cp "$ROOT/tests/responses/rapidapi_403.json" "$MOCK_DIR/body_403"
  cp "$ROOT/tests/responses/rapidapi_429.json" "$MOCK_DIR/body_429"
  export PATH="$ROOT/tests/bin:$PATH"
  export INPUT_RAPIDAPI_KEY=test-key INPUT_API_MARKET_KEY="" INPUT_BASE_REF="" INPUT_CHECK_ALL=false INPUT_FAIL_ON=invalid
  export INPUT_COMMENT=true INPUT_MAX_REQUESTS=15 INPUT_ON_QUOTA_EXCEEDED=warn INPUT_GITHUB_TOKEN=gh-token
  export INPUT_WORKFLOW_PATHS=".github/workflows/*.yml,.github/workflows/*.yaml"
  export INPUT_CRONJOB_PATHS="**/*.yaml,**/*.yml" INPUT_CRON_PATHS="" INPUT_CRON_KEYS="cron,schedule"
  export INPUT_CRON_PATHS_DIALECT=unix INPUT_CRON_PATHS_TIMEZONE=UTC
  export INPUT_EXCLUDE_PATHS="**/node_modules/**,**/vendor/**"
  export INPUT_TIMEZONE=UTC INPUT_LOCALE=en INPUT_NEXT_RUNS=3 INPUT_MIN_INTERVAL=5
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export GITHUB_REPOSITORY=acme/app GITHUB_API_URL=https://api.github.com GITHUB_SERVER_URL=https://github.com
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  export CADENCE_RETRY_DELAY=0 CADENCE_RATE_DELAY=0 CADENCE_NOW=1794268800 # 2026-11-10T00:00:00Z, the start of the recorded responses
  unset CADENCE_API_URL CADENCE_AUTH_HEADER
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
}

pr_event() {
  export GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$HEAD"
  jq -n --arg base "$BASE" --arg head "$HEAD" '{pull_request: {number: 7, base: {sha: $base}, head: {sha: $head}}}' \
    > "$GITHUB_EVENT_PATH"
}

change() { # the pull request: four schedules in the workflow (one unchanged) and the CronJob moved to SUN
  cp "$FIX/nightly-head.yml" "$REPO/.github/workflows/nightly.yml"
  cp "$FIX/backup-head.yaml" "$REPO/k8s/backup.yaml"
  HEAD="$(commit head)"
  pr_event
}

workflow() { # workflow CRON… → a pull request that sets these schedules in a new workflow
  {
    echo "on:"; echo "  schedule:"
    for c in "$@"; do echo "    - cron: \"$c\""; done
    echo "jobs: {}"
  } > "$REPO/.github/workflows/new.yml"
  HEAD="$(commit new-workflow)"
  pr_event
}

run_action() { cd "$REPO" && run "$ROOT/scripts/run.sh"; }
out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }
requests() { grep -vc '^unrecorded' "$MOCK_DIR/requests.log" 2>/dev/null || echo 0; }
comment_body() { jq -r '.body' "$MOCK_DIR/gh_$1.json"; }

# ---------- helpers ----------

@test "discovery: each kind of file, excludes, and unquoted lists never glob the disk" {
  source "$ROOT/scripts/lib.sh"
  cd "$REPO"
  mkdir -p node_modules/x && cp k8s/backup.yaml node_modules/x/
  touch '*.yaml' && git add -A
  export INPUT_CRON_PATHS="ops/crontab"
  run discover
  [ "$status" -eq 0 ]
  [[ $output == *$'workflow\t.github/workflows/nightly.yml'* ]]
  [[ $output == *$'cronjob\tk8s/backup.yaml'* ]]
  [[ $output == *$'file\tops/crontab'* ]]
  [[ $output != *node_modules* ]]
  [[ $output != *README* ]]
  [[ $(grep -c . <<<"$output") -eq 4 ]] # the file literally named "*.yaml" is a CronJob candidate too, nothing else
}

@test "glob_match: a leading **/ matches at the root, /**/ matches zero folders" {
  source "$ROOT/scripts/lib.sh"
  glob_match "backup.yaml" "**/*.yaml"
  glob_match "k8s/jobs/backup.yaml" "**/*.yaml"
  glob_match "k8s/backup.yaml" "k8s/**/*.yaml"
  ! glob_match "k8s/backup.json" "**/*.yaml" || false
}

@test "extract: workflow schedules with their lines, other triggers ignored" {
  source "$ROOT/scripts/lib.sh"
  run extract workflow "$FIX/nightly-head.yml"
  [ "$status" -eq 0 ]
  [ "$(jq -sc 'map([.expression, .line, .zone])' <<<"$output")" = '[["0 3 * * 1-5",4,"UTC"],["*/2 * * * *",5,"UTC"],["0 12 30 2 *",6,"UTC"],["61 * * * *",7,"UTC"]]' ]
  printf 'on: push\n' > "$BATS_TEST_TMPDIR/a.yml"
  printf 'on: [push, pull_request]\n' > "$BATS_TEST_TMPDIR/b.yml"
  printf 'on:\n  schedule: oops\n' > "$BATS_TEST_TMPDIR/c.yml"
  [ -z "$(extract workflow "$BATS_TEST_TMPDIR/a.yml")" ]
  [ -z "$(extract workflow "$BATS_TEST_TMPDIR/b.yml")" ]
  [ -z "$(extract workflow "$BATS_TEST_TMPDIR/c.yml")" ]
}

@test "extract: CronJobs in multi-document files, timeZone or the UTC default, Helm templates skipped" {
  source "$ROOT/scripts/lib.sh"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: settings}\ndata: {schedule: "* * * * *"}\n---\n'
    printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: report\nspec:\n  schedule: "@daily"\n---\n'
    cat "$FIX/repo/k8s/backup.yaml"
  } > "$BATS_TEST_TMPDIR/multi.yaml"
  run extract cronjob "$BATS_TEST_TMPDIR/multi.yaml"
  [ "$status" -eq 0 ]
  [ "$(jq -sc 'map([.expression, .zone, .name, (.zone_default // false)])' <<<"$output")" = '[["@daily","UTC","report",true],["30 1 * * 0","Europe/Lisbon","backup",false]]' ]
  printf 'kind: CronJob\nspec:\n  schedule: {{ .Values.schedule }}\n' > "$BATS_TEST_TMPDIR/helm.yaml"
  [ -z "$(extract cronjob "$BATS_TEST_TMPDIR/helm.yaml")" ]
}

@test "extract: other files by key (YAML/JSON) or as a crontab, aws detected by cron(…)" {
  source "$ROOT/scripts/lib.sh"
  printf 'functions:\n  nightly:\n    events:\n      - schedule: cron(0 18 ? * MON-FRI *)\n  hourly:\n    cron: "0 * * * *"\n    name: schedule\n' > "$BATS_TEST_TMPDIR/serverless.yml"
  run extract file "$BATS_TEST_TMPDIR/serverless.yml"
  [ "$(jq -sc 'map([.expression, .line, .dialect])' <<<"$output")" = '[["cron(0 18 ? * MON-FRI *)",4,"aws"],["0 * * * *",6,"unix"]]' ]
  INPUT_CRON_PATHS_DIALECT=seconds INPUT_CRON_PATHS_TIMEZONE=Europe/Lisbon run extract file "$FIX/repo/ops/crontab"
  [ "$(jq -sc 'map([.expression, .line, .dialect, .zone])' <<<"$output")" = '[["15 4 * * *",3,"seconds","Europe/Lisbon"]]' ]
  printf '@reboot /bin/true\n# 1 2 3 4 5 x\nMAILTO=""\n*/5 * * * * root run "it"\n' > "$BATS_TEST_TMPDIR/crontab"
  run extract file "$BATS_TEST_TMPDIR/crontab"
  [ "$(jq -sc 'map([.expression, .line])' <<<"$output")" = '[["@reboot",1],["*/5 * * * *",4]]' ]
}

@test "precheck: GitHub shortcuts, Kubernetes TZ=, templates and rate() cost no request" {
  source "$ROOT/scripts/lib.sh"
  [[ $(precheck workflow "@daily") == invalid$'\t'*"shortcuts like @daily"* ]]
  [ -z "$(precheck cronjob "@daily")" ]
  [[ $(precheck cronjob "CRON_TZ=Europe/Lisbon 0 3 * * *") == invalid$'\t'*"spec.timeZone"* ]]
  [[ $(precheck file '{{ .Values.cron }}') == skipped$'\t'* ]]
  [[ $(precheck file 'rate(5 minutes)') == skipped$'\t'* ]]
  [[ $(precheck file '  ') == invalid$'\t'* ]]
  [ -z "$(precheck workflow "0 3 * * 1-5")" ]
}

@test "dst_transitions: the two changes of the coming year, none for UTC or an unknown zone" {
  source "$ROOT/scripts/lib.sh"
  [ "$(dst_transitions Europe/Lisbon 1794268800)" = '[{"t":1806195600,"o1":0,"o2":60},{"t":1824944400,"o1":60,"o2":0}]' ]
  [ "$(dst_transitions America/New_York 1794268800 | jq -c 'map([.o1, .o2])')" = '[[-300,-240],[-240,-300]]' ]
  [ "$(dst_transitions UTC 1794268800)" = '[]' ]
  [ "$(dst_transitions Mars/Base 1794268800)" = '[]' ]
}

# ---------- run.sh ----------

@test "pull request: only new or changed expressions are checked, with a report, annotations and outputs" {
  change
  run_action
  [ "$status" -eq 1 ] # two invalid expressions
  [ "$(out passed)" = false ]
  [ "$(out expressions-checked)" = 4 ]
  [ "$(out invalid)" = 2 ]
  [ "$(out warnings)" = 3 ]
  [ "$(out requests-used)" = 8 ] # 3 + 1 (never fires) + 1 (invalid) + 3; the unchanged 0 3 * * 1-5 costs nothing
  [ "$(requests)" = 8 ]
  ! grep -q unrecorded "$MOCK_DIR/requests.log" || false
  ! grep -q '"0 3 \* \* 1-5"' "$MOCK_DIR/requests.log" || false
  [[ $output == *"::error file=.github/workflows/nightly.yml,line=7,title=Invalid cron expression::61 * * * *: minute: 61 is out of range 0-59"* ]]
  [[ $output == *"::error file=.github/workflows/nightly.yml,line=6,title=Invalid cron expression::0 12 30 2 *: never runs: day-of-month 30 never occurs in FEB"* ]]
  [[ $output == *"::warning file=.github/workflows/nightly.yml,line=5,title=Cron warning::*/2 * * * *: Runs as often as every 2 minutes, but GitHub runs scheduled workflows at most once every 5 minutes."* ]]
  [[ $output == *"::warning file=k8s/backup.yaml,line=6,title=Cron warning::30 1 * * SUN: The 01:30 run falls in the DST gap on Sun 28 Mar 2027 (Europe/Lisbon)"* ]]
  [[ $output == *"DST overlap on Sun 31 Oct 2027 (Europe/Lisbon)"* ]]
  [[ $output == *"::notice file=k8s/backup.yaml,line=6,title=Cron%3A 30 1 * * SUN::At 01:30, only on Sunday. Next run: Sun 15 Nov 2026 01:30 UTC"* ]]
  [[ $output == *"::error title=Cadence check failed::2 invalid cron expression(s)."* ]]
  grep -q '^## Cadence ❌' "$GITHUB_STEP_SUMMARY"
  grep -qF '4 cron expressions checked · 2 invalid · 3 warnings' "$GITHUB_STEP_SUMMARY"
  grep -qF "| ⚠️ | [\`.github/workflows/nightly.yml:5\`](https://github.com/acme/app/blob/$HEAD/.github/workflows/nightly.yml#L5) | \`*/2 * * * *\`<br>UTC (GitHub) | Every 2 minutes | Tue 10 Nov 2026 00:02<br>Tue 10 Nov 2026 00:04<br>Tue 10 Nov 2026 00:06 |" "$GITHUB_STEP_SUMMARY"
  grep -qF '| ❌ |' "$GITHUB_STEP_SUMMARY"
  grep -qF '<br>`backup` | `30 1 * * SUN`<br>Europe/Lisbon | At 01:30, only on Sunday |' "$GITHUB_STEP_SUMMARY"
  grep -qF 'GitHub runs workflow schedules in UTC' "$GITHUB_STEP_SUMMARY"
  grep -qF '1 unchanged expression skipped · requests used: 8' "$GITHUB_STEP_SUMMARY"
  [[ $(comment_body post) == "<!-- cadence-action -->"* ]]
  [ "$(out comment-url)" = "https://github.com/acme/app/pull/7#issuecomment-99" ]
}

@test "the comment is updated in place on the next run" {
  change
  jq -n '[{id: 5, body: "unrelated"}, {id: 42, body: "<!-- cadence-action -->\nold"}]' > "$MOCK_DIR/gh_comments.json"
  run_action
  grep -q '^PATCH repos/acme/app/issues/comments/42$' "$MOCK_DIR/github.log"
  ! grep -q '^POST ' "$MOCK_DIR/github.log" || false
  [[ $(comment_body patch) == *"## Cadence ❌"* ]]
}

@test "timezone shows the runs in another zone, with the offset" {
  change
  export INPUT_TIMEZONE=Europe/Lisbon INPUT_COMMENT=false
  run_action
  grep -qF '| Next runs (Europe/Lisbon) |' "$GITHUB_STEP_SUMMARY"
  grep -qF 'Tue 10 Nov 2026 00:02 +00:00' "$GITHUB_STEP_SUMMARY"
  [[ $output == *"Next run: Sun 15 Nov 2026 01:30 +00:00 (Europe/Lisbon)"* ]]
  export INPUT_TIMEZONE=America/New_York
  run_action
  grep -qF 'Mon 09 Nov 2026 19:02 -05:00' "$GITHUB_STEP_SUMMARY"
}

@test "fail-on: never passes with invalid expressions (warnings only), warning fails on a warning" {
  change
  export INPUT_FAIL_ON=never
  run_action
  [ "$status" -eq 0 ]
  [ "$(out passed)" = true ]
  [[ $output == *"::warning file=.github/workflows/nightly.yml,line=7,title=Invalid cron expression::"* ]]
  ! grep -qF 'Invalid expressions fail this check' "$GITHUB_STEP_SUMMARY" || false
}

@test "fail-on: warning fails when a check has a warning" {
  workflow "*/2 * * * *"
  export INPUT_FAIL_ON=warning
  run_action
  [ "$status" -eq 1 ]
  [ "$(out warnings)" = 1 ]
  [[ $output == *"::error file=.github/workflows/new.yml,line=3,title=Cron warning::"* ]]
  [[ $output == *"1 warning(s) with fail-on: warning"* ]]
  grep -qF 'Warnings fail this check (`fail-on: warning`).' "$GITHUB_STEP_SUMMARY"
}

@test "a valid change passes, and the same expression twice costs one set of requests" {
  workflow "0 6 * * *" "0 7 * * *" "0 6 * * *"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out passed)" = true ]
  [ "$(out expressions-checked)" = 3 ]
  [ "$(out requests-used)" = 6 ]
  grep -qF '3 cron expressions checked · 0 invalid · 0 warnings' "$GITHUB_STEP_SUMMARY"
  grep -q '^## Cadence ✅' "$GITHUB_STEP_SUMMARY"
}

@test "nothing changed: no request and no comment" {
  echo "more" >> "$REPO/README.md"
  HEAD="$(commit readme)"; pr_event
  run_action
  [ "$status" -eq 0 ]
  [ "$(out requests-used)" = 0 ]
  [ "$(out expressions-checked)" = 0 ]
  [ ! -f "$MOCK_DIR/requests.log" ]
  ! grep -q '^POST ' "$MOCK_DIR/github.log" || false
  grep -qF 'No cron expression changed in this pull request.' "$GITHUB_STEP_SUMMARY"
}

@test "a GitHub shortcut is invalid without a request" {
  workflow "@daily"
  run_action
  [ "$status" -eq 1 ]
  [ "$(out requests-used)" = 0 ]
  grep -qF '**Invalid:** GitHub Actions schedules take five fields; shortcuts like @daily are not supported' "$GITHUB_STEP_SUMMARY"
}

@test "max-requests: expressions over the cap are listed as not checked" {
  change
  export INPUT_MAX_REQUESTS=4
  run_action
  [ "$(out requests-used)" = 4 ] # */2 uses 3, 0 12 30 2 * one (never runs); then no room for 61 * * * *
  [ "$(out invalid)" = 1 ]
  grep -qF 'Not checked: max-requests (4) reached' "$GITHUB_STEP_SUMMARY"
  grep -qF '| ⏭️ |' "$GITHUB_STEP_SUMMARY"
}

@test "no base to compare with (workflow_dispatch): every expression is checked" {
  export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$HEAD" INPUT_CRON_PATHS="ops/crontab"
  echo '{}' > "$GITHUB_EVENT_PATH"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"No base to compare against"* ]]
  [ "$(out expressions-checked)" = 3 ]
  [ "$(out warnings)" = 2 ] # the DST gap and overlap of the CronJob
  [ ! -f "$MOCK_DIR/github.log" ] # no pull request: no comment
}

@test "a CronJob with an unknown timeZone is invalid; quartz LW has no run times" {
  sed -i.bak 's|Europe/Lisbon|Mars/Base|; s|"30 1 \* \* 0"|"0 3 * * *"|' "$REPO/k8s/backup.yaml" && rm "$REPO/k8s/backup.yaml.bak"
  printf 'jobs:\n  - cron: "0 0 12 LW * ?"\n' > "$REPO/ops/quartz.yaml"
  HEAD="$(commit tz)"; pr_event
  export INPUT_CRON_PATHS="ops/*.yaml" INPUT_CRON_PATHS_DIALECT=quartz
  run_action
  [ "$status" -eq 1 ]
  grep -qF "**Invalid:** unknown time zone 'Mars/Base'" "$GITHUB_STEP_SUMMARY"
  grep -qF "'LW' (last weekday of the month) is valid syntax but not supported for run-time computation" "$GITHUB_STEP_SUMMARY" \
    || grep -qF "run times not computed" "$GITHUB_STEP_SUMMARY"
  [ "$(out invalid)" = 1 ]
}

@test "aws expressions in other files are detected and checked" {
  printf 'events:\n  - schedule: cron(0 18 ? * MON-FRI *)\n' > "$REPO/ops/serverless.yml"
  HEAD="$(commit aws)"; pr_event
  export INPUT_CRON_PATHS="ops/serverless.yml"
  run_action
  [ "$status" -eq 0 ]
  grep -q '"dialect":"aws"' "$MOCK_DIR/requests.log"
  grep -qF 'At 06:00 PM, Monday through Friday' "$GITHUB_STEP_SUMMARY" || grep -qF 'At 18:00, Monday through Friday' "$GITHUB_STEP_SUMMARY"
}

@test "the base version comes from the GitHub API when the commit can't be fetched" {
  change
  export INPUT_BASE_REF=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$MOCK_DIR/contents/.github/workflows" "$MOCK_DIR/contents/k8s"
  cp "$FIX/repo/.github/workflows/nightly.yml" "$MOCK_DIR/contents/.github/workflows/"
  cp "$FIX/repo/k8s/backup.yaml" "$MOCK_DIR/contents/k8s/"
  run_action
  grep -q '^GET repos/acme/app/contents/.github/workflows/nightly.yml?ref=0123456789abcdef0123456789abcdef01234567$' "$MOCK_DIR/github.log"
  [ "$(out expressions-checked)" = 4 ]
}

# ---------- errors ----------

@test "key refused (401/403): error with the subscribe link, step fails" {
  workflow "0 6 * * *"
  echo 403 > "$MOCK_DIR/status_validate"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"Cadence refused the key (HTTP 403: You are not subscribed to this API.)"* ]]
  [[ $output == *"rapidapi.com/bytestay-bytestay-default/api/cadence-cron-expression-api/pricing"* ]]
  [[ $output == *"the API key was refused"* ]]
}

@test "quota exhausted (429): a warning by default, a failure with on-quota-exceeded: fail" {
  workflow "0 6 * * *"
  echo 429 > "$MOCK_DIR/status_validate"
  echo 0 > "$MOCK_DIR/quota"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning::Cadence monthly quota exhausted"* ]]
  [ "$(out quota-remaining)" = 0 ]
  export INPUT_ON_QUOTA_EXCEEDED=fail
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::Cadence monthly quota exhausted"* ]]
}

@test "rate limit (429 without quota): retried, then checked" {
  workflow "0 6 * * *"
  echo '{"message":"Too many requests"}' > "$MOCK_DIR/body_429"
  printf '429\n429\n200\n' > "$MOCK_DIR/status_validate"
  echo 9 > "$MOCK_DIR/quota"
  run_action
  [ "$status" -eq 0 ]
  [[ $output != *"quota exhausted"* ]]
  [[ $output != *"rate limit"* ]]
  [ "$(grep -c 'Not checked' "$GITHUB_STEP_SUMMARY")" = 0 ]
}

@test "rate limit that doesn't clear: a warning, not a quota error, and the build passes" {
  workflow "0 6 * * *"
  echo '{"message":"Too many requests"}' > "$MOCK_DIR/body_429"
  echo 429 > "$MOCK_DIR/status_validate"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out requests-used)" = 4 ]
  [[ $output == *"::warning::Cadence rate limit (HTTP 429) after 3 retries"* ]]
  [[ $output != *"quota exhausted"* ]]
  grep -q 'Not checked: rate limited' "$GITHUB_STEP_SUMMARY"
}

@test "API down: one retry, then a warning and the build passes" {
  workflow "0 6 * * *" "0 7 * * *"
  printf '503\n503\n' > "$MOCK_DIR/status_validate"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out requests-used)" = 2 ]
  [[ $output == *"Cadence API unavailable (HTTP 503)"* ]]
  [ "$(grep -c 'Not checked: API unavailable' "$GITHUB_STEP_SUMMARY")" = 2 ]
}

@test "the quota header is reported, with a warning when it runs low" {
  workflow "0 6 * * *"
  echo 4 > "$MOCK_DIR/quota"
  run_action
  [ "$(out quota-remaining)" = 4 ]
  [[ $output == *"Only 4 Cadence requests left this month"* ]]
  grep -qF 'quota left this month: 4' "$GITHUB_STEP_SUMMARY"
}

@test "no permission to comment: a notice, the report stays in the summary" {
  workflow "0 6 * * *"
  echo 403 > "$MOCK_DIR/gh_comment_status"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"Couldn't comment on the pull request (HTTP 403)"* ]]
  [ "$(out comment-url)" = "" ]
}

@test "a fork pull request without a key is skipped; elsewhere a missing key fails" {
  workflow "0 6 * * *"
  export INPUT_RAPIDAPI_KEY=""
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"Cadence skipped: no rapidapi-key or api-market-key"* ]]
  export GITHUB_EVENT_NAME=push
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"No API key: set rapidapi-key or api-market-key"* ]]
  [[ $output == *"api.market/store/bytestay/cadence"* ]]
}

@test "the key is masked and sent as RapidAPI headers" {
  workflow "0 6 * * *"
  run_action
  [[ $output == *"::add-mask::test-key"* ]]
  grep -qx 'https://cadence-cron-expression-api.p.rapidapi.com/v1/cron/validate' "$MOCK_DIR/cadence_calls.log"
  grep -qx 'X-RapidAPI-Key: test-key' "$MOCK_DIR/cadence_calls.log"
  ! grep -qi 'x-api-market-key' "$MOCK_DIR/cadence_calls.log" || false
}

@test "an api-market-key is masked and sent to the API.market gateway" {
  workflow "0 6 * * *"
  export INPUT_RAPIDAPI_KEY="" INPUT_API_MARKET_KEY=am-key
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::add-mask::am-key"* ]]
  grep -qx 'https://prod.api.market/api/v1/bytestay/cadence/v1/cron/validate' "$MOCK_DIR/cadence_calls.log"
  grep -qx 'x-api-market-key: am-key' "$MOCK_DIR/cadence_calls.log"
  ! grep -qi 'rapidapi' "$MOCK_DIR/cadence_calls.log" || false
  [ "$(grep -c 'Not checked' "$GITHUB_STEP_SUMMARY")" = 0 ]
}

@test "API.market errors point to the API.market store" {
  workflow "0 6 * * *"
  export INPUT_RAPIDAPI_KEY="" INPUT_API_MARKET_KEY=am-key
  echo '{"message":"Invalid x-api-market-key or x-magicapi-key defined in headers"}' > "$MOCK_DIR/body_400"
  echo 400 > "$MOCK_DIR/status_validate"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"Cadence refused the key (HTTP 400: Invalid x-api-market-key"* ]]
  [[ $output == *"https://api.market/store/bytestay/cadence"* ]]
}

@test "both keys set: fails early" {
  workflow "0 6 * * *"
  INPUT_API_MARKET_KEY=am-key run_action
  [ "$status" -eq 1 ]
  [[ $output == *"Set rapidapi-key or api-market-key, not both."* ]]
  [ ! -f "$MOCK_DIR/requests.log" ]
}

@test "bad inputs fail early with a clear message" {
  workflow "0 6 * * *"
  INPUT_FAIL_ON=sometimes run_action
  [ "$status" -eq 1 ]; [[ $output == *"fail-on must be invalid, warning or never"* ]]
  INPUT_TIMEZONE=Mars/Base run_action
  [ "$status" -eq 1 ]; [[ $output == *"unknown time zone 'Mars/Base'"* ]]
  INPUT_LOCALE=xx run_action
  [ "$status" -eq 1 ]; [[ $output == *"locale must be one of"* ]]
  INPUT_NEXT_RUNS=50 run_action
  [ "$status" -eq 1 ]; [[ $output == *"next-runs must be a whole number from 0 to 20"* ]]
  INPUT_CRON_PATHS_DIALECT=vixie run_action
  [ "$status" -eq 1 ]; [[ $output == *"cron-paths-dialect must be"* ]]
  [ ! -f "$MOCK_DIR/requests.log" ]
}
