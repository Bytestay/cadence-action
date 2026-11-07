#!/usr/bin/env bash
# Records real Cadence API responses for the expressions in tests/responses/expressions.tsv
# (dialect, time zone, expression), as the action would ask for them with CADENCE_NOW=1794268800.
# Files are named ENDPOINT__KEY.STATUS.json, KEY = cksum of "dialect|zone|expression" (zone empty for validate and
# explain); tests/bin/curl finds them the same way.
# Usage: CADENCE_API_URL=https://cadence-api.bytestay.pt CADENCE_AUTH_HEADER="Authorization: Bearer …" tests/record.sh
set -euo pipefail
cd "$(dirname "$0")/responses"
START="2026-11-10T00:00:00Z"
key() { printf '%s|%s|%s' "$1" "$2" "$3" | cksum | cut -d' ' -f1; }
post() { # post ENDPOINT BODY KEY
  local code
  code="$(curl -sS -o "$1__$3.json" -w '%{http_code}' -X POST "$CADENCE_API_URL/v1/cron/$1" \
    -H "$CADENCE_AUTH_HEADER" -H "Content-Type: application/json" --data-binary "$2")"
  mv "$1__$3.json" "$1__$3.$code.json"
  jq -S . "$1__$3.$code.json" > "$1__$3.tmp" && mv "$1__$3.tmp" "$1__$3.$code.json"
}
rm -f validate__* explain__* next__*
while IFS=$'\t' read -r dialect zone expr; do
  [[ -z $expr || $dialect == \#* ]] && continue
  k="$(key "$dialect" "" "$expr")" # validate and explain don't take a time zone
  post validate "$(jq -cn --arg e "$expr" --arg d "$dialect" '{expression: $e, dialect: $d}')" "$k"
  post explain "$(jq -cn --arg e "$expr" --arg d "$dialect" '{expression: $e, dialect: $d, locale: "en"}')" "$k"
  k="$(key "$dialect" "$zone" "$expr")"
  post next "$(jq -cn --arg e "$expr" --arg d "$dialect" --arg z "$zone" --arg s "$START" \
    '{expression: $e, dialect: $d, timezone: $z, start: $s, count: 10}')" "$k"
done < expressions.tsv
