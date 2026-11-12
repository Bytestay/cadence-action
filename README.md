# Cadence GitHub Action

[![CI](https://github.com/bytestay/cadence-action/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/bytestay/cadence-action/actions/workflows/ci.yml)
[![E2E](https://github.com/bytestay/cadence-action/actions/workflows/e2e.yml/badge.svg?branch=main)](https://github.com/bytestay/cadence-action/actions/workflows/e2e.yml)
[![Release](https://img.shields.io/github/v/release/bytestay/cadence-action)](https://github.com/bytestay/cadence-action/releases)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-cadence-blue?logo=github)](https://github.com/marketplace/actions/bytestay-cadence-cron-expression-check)
[![License: MIT](https://img.shields.io/github/license/bytestay/cadence-action)](LICENSE)

Know what a **cron schedule** really does before you merge it. For every schedule a pull request adds or changes, you get:

- a plain-English explanation: `30 1 * * 1-5` is "At 01:30, Monday through Friday";
- the next runs, in the time zone you choose;
- an error when the expression is invalid or can never run (`0 12 30 2 *`);
- warnings for runs that fall in a daylight-saving gap or overlap, and for schedules that run too often.

It reads schedules from:

- GitHub workflows (`on.schedule[].cron`);
- Kubernetes CronJobs (`spec.schedule`, in the zone of `spec.timeZone`);
- any other file you point it at: YAML and JSON keys, or crontabs.

It calls the [Cadence API](https://cadence.bytestay.pt) with **your own key**, from RapidAPI or API.market.

- The free plan is 15 requests a month on RapidAPI, and a 7-day trial of 15 calls on API.market.
- One new or changed expression is up to three requests.

```yaml
name: cadence
on:
  pull_request:
permissions:
  contents: read
  pull-requests: write
jobs:
  cron:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: bytestay/cadence-action@v1
        with:
          rapidapi-key: ${{ secrets.RAPIDAPI_KEY }}
          timezone: Europe/Lisbon
```

1. Subscribe to the [Cadence API on RapidAPI](https://rapidapi.com/bytestay-bytestay-default/api/cadence-cron-expression-api). Basic is $0 with a hard limit, so it never runs up a bill.
2. Add your RapidAPI key as the repository secret `RAPIDAPI_KEY`.
3. Add the workflow above.

### With an API.market key

Subscribe to [Cadence on API.market](https://api.market/store/bytestay/cadence) instead (the Free plan is a $0 trial: 15 calls for 7 days). Then store the key as `API_MARKET_KEY` and pass it as `api-market-key`:

```yaml
      - uses: bytestay/cadence-action@v1
        with:
          api-market-key: ${{ secrets.API_MARKET_KEY }}
          timezone: Europe/Lisbon
```

Set one key, not both. The action calls the marketplace the key belongs to.

## What you get

- **A pull request comment**, one per pull request and updated in place, with a table:

  | | Where | Expression | Meaning | Next runs (Europe/Lisbon) | Warnings |
  |---|---|---|---|---|---|
  | ✅ | `.github/workflows/nightly.yml:4` | `0 3 * * 1-5`<br>UTC (GitHub) | At 03:00, Monday through Friday | Tue 10 Nov 2026 03:00 +00:00<br>Wed 11 Nov 2026 03:00 +00:00 | |
  | ⚠️ | `k8s/backup.yaml:6`<br>`backup` | `30 1 * * SUN`<br>Europe/Lisbon | At 01:30, only on Sunday | Sun 15 Nov 2026 01:30 +00:00<br>Sun 22 Nov 2026 01:30 +00:00 | The 01:30 run falls in the DST gap on Sun 28 Mar 2027 (Europe/Lisbon): that time doesn't exist, and schedulers differ on skipping or moving the run. |
  | ❌ | `.github/workflows/sync.yml:5` | `61 * * * *`<br>UTC (GitHub) | **Invalid:** minute: 61 is out of range 0-59 | | |

- **Annotations** on the line of each schedule:
  - invalid expressions as errors;
  - warnings as warnings;
  - the explanation and the next run as a notice.
- **The same report in the job summary**, also when the job can't comment.
- **A pass/fail result:** the step fails on invalid expressions. `fail-on` makes it stricter or only report.

## What it warns about

- **Daylight saving time:** a run at a wall-clock time that is skipped (spring forward) or happens twice (fall back) in the next 12 months.
  - Only for expressions with a fixed hour, in a zone with DST.
  - Schedulers disagree on what to do then, so the warning says when it happens.
- **Too frequent:**
  - a workflow that asks for runs less than 5 minutes apart, because GitHub runs schedules at most every 5 minutes;
  - anything else that runs more often than `min-interval` (5 minutes by default).
- **Day-of-month and day-of-week both set** (`0 0 1 * MON`): cron runs when either matches, not both.
- **No more runs** after a date, when a year field has ended.

These are errors, not warnings:

- an invalid expression, with the field to blame;
- an expression that never runs, like 30 February;
- `@daily` and other shortcuts in a workflow, which GitHub doesn't support;
- `TZ=` or `CRON_TZ=` in a CronJob schedule, which Kubernetes rejects;
- an unknown `spec.timeZone`.

## Inputs

| input | default | meaning |
|---|---|---|
| `rapidapi-key` | *empty* | your RapidAPI key; set this or `api-market-key` |
| `api-market-key` | *empty* | your API.market key; set this or `rapidapi-key` |
| `workflow-paths` | `.github/workflows/*.yml,.github/workflows/*.yaml` | workflows, read at `on.schedule[].cron`; empty to disable |
| `cronjob-paths` | `**/*.yaml,**/*.yml` | Kubernetes manifests, read at `spec.schedule` of each CronJob; empty to disable |
| `cron-paths` | *empty* | other files: YAML and JSON are read at `cron-keys`, anything else as a crontab |
| `cron-keys` | `cron,schedule` | keys whose string values are cron expressions, in `cron-paths` |
| `cron-paths-dialect` | `unix` | `unix`, `seconds`, `quartz` or `aws`, for `cron-paths`; `cron(…)` values are always `aws` |
| `cron-paths-timezone` | `UTC` | the time zone `cron-paths` schedules run in |
| `exclude-paths` | `**/node_modules/**,**/vendor/**` | comma-separated globs to skip |
| `timezone` | `UTC` | the time zone to show the next runs in |
| `locale` | `en` | language of the explanations: `en`, `pt`, `es`, `fr`, `de`, `it` or `nl` |
| `next-runs` | `3` | next runs shown per expression, 0 to 20 |
| `min-interval` | `5` | warn when runs are closer than this many minutes; `0` to disable |
| `fail-on` | `invalid` | `invalid`, `warning` (also fail on warnings) or `never` (only report) |
| `check-all` | `false` | check every expression found, not only new or changed ones |
| `base-ref` | *empty* | what to compare with: default the pull request's base, or the previous commit on a push |
| `comment` | `true` | post the report as a pull request comment |
| `max-requests` | `15` | cap per run; expressions over it are listed as not checked |
| `on-quota-exceeded` | `warn` | `warn` or `fail` when the monthly quota runs out |
| `github-token` | `${{ github.token }}` | reads the base version, and comments |

Expressions run in:

- UTC, for workflows (GitHub's rule);
- `spec.timeZone`, for CronJobs, or UTC without it (the controller's zone, usually UTC);
- `cron-paths-timezone`, for other files.

`timezone` only changes how the next runs are shown.

## Outputs

| output | meaning |
|---|---|
| `passed` | `true` when the check passed |
| `expressions-checked` | new or changed expressions checked |
| `invalid` | invalid expressions, including ones that never run |
| `warnings` | warnings across all expressions |
| `requests-used` | API requests used by this run |
| `quota-remaining` | requests left this month, from the `x-ratelimit-requests-remaining` header; empty when the marketplace doesn't send it |
| `comment-url` | the pull request comment, empty when none was posted |

To use an output in a later step, give this step an `id` and read `steps.<id>.outputs.warnings`.

## Saving requests

Each new or changed expression costs up to three requests:

1. `validate`;
2. `explain`, for the plain-English text;
3. `next`, for the run times and the frequency check.

An invalid expression stops after the first one.

These cost nothing:

- expressions the pull request didn't touch, compared locally with the base version;
- the same expression twice in one run;
- the daylight-saving check, which runs on the runner;
- templates (`{{ .Values.schedule }}`), `rate()` expressions, and the errors listed above for workflows and CronJobs.

Workflow schedules rarely change, so a pull request usually costs nothing or three requests.

## Other files

Point `cron-paths` at the files, and set the dialect and time zone they use:

```yaml
      - uses: bytestay/cadence-action@v1
        with:
          rapidapi-key: ${{ secrets.RAPIDAPI_KEY }}
          cron-paths: "serverless.yml,deploy/crontab"
          cron-paths-timezone: Europe/Lisbon
```

- YAML and JSON files: every string under a key in `cron-keys` is an expression.
- Any other file is a crontab:
  - each schedule line gives its first five fields, or its `@shortcut`;
  - comments and `VAR=value` lines are skipped.
- `cron(…)` values (AWS EventBridge) are always read as `aws`; `rate(…)` values are skipped.

## When something goes wrong

| situation | what the action does |
|---|---|
| no key on a pull request from a fork (forks don't get secrets) | warning, step passes |
| key invalid or not subscribed (401/403) | error with the subscribe link, step fails |
| quota exhausted (429) | `on-quota-exceeded: warn` gives a warning and the step passes; `fail` fails it |
| API down or timing out | one retry, then a warning: **your build is never failed because of us** |
| a file yq can't parse, such as a Helm template | skipped |
| no permission to comment | a notice; the report is in the job summary |

Use `on: pull_request`, not `pull_request_target`:

- with `pull_request_target`, a pull request from a fork would run with your secrets;
- skipping fork pull requests is the safe default.

## Privacy

- Only the cron expressions are sent to the Cadence API, with their dialect and time zone.
- Nothing else from your files leaves the runner, nothing is stored, and expressions are never logged.
- Your key is masked in the logs.

See the [privacy policy](https://cadence.bytestay.pt/privacy.html).

## Limits

- The daylight-saving check looks 12 months ahead and skips expressions that use `L`, `W` or `#`.
- Quartz `L-n`, `LW` and `nW` past the 28th are valid, but Cadence doesn't compute their run times, and the report says so.
- The runner needs `bash`, `curl`, `jq`, `git` and [yq](https://github.com/mikefarah/yq). GitHub-hosted runners have all five.

## Contributing

Issues and pull requests are welcome: see the [contributing guide](https://github.com/bytestay/.github/blob/main/CONTRIBUTING.md).

To work on the action:

```bash
bats tests/                                 # unit tests (curl is faked with recorded responses, no key needed)
shellcheck -x scripts/*.sh tests/bin/curl tests/record.sh
actionlint
```

`tests/record.sh` records the API responses again.

The end-to-end test (`.github/workflows/e2e.yml`) runs the action against the real API monthly, with the `RAPIDAPI_KEY` secret.

## Licence

MIT.

Cadence itself is a paid API with a free plan, run by [ByteStay](https://bytestay.pt).
