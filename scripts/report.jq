# Input: {results, passed, fail_on, requests, quota, tz, next_runs, blob, pr}; run jq with TZ set to .tz.
# Output: Markdown for the job summary and the pull request comment.
include "time";
def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
def icon: if .status == "invalid" or .status == "failed" then "❌"
  elif .status == "checked" then (if (.warnings | length) > 0 then "⚠️" else "✅" end) else "⏭️" end;
def where($blob): "[`\(.file):\(.line)`](\($blob)/\(.file | @uri | gsub("%2F"; "/"))#L\(.line))"
  + (if (.name // "") != "" then "<br>`\(.name | cell)`" else "" end);
def zone: if .kind == "workflow" then "UTC (GitHub)" elif .zone_default then "UTC (no `timeZone`)" else .zone end;

. as $r
| ([.results[] | select(.status != "unchanged")]) as $rows
| ([.results[] | select(.status == "unchanged")]) as $unchanged
| ([$rows[] | select(.status == "invalid" or .status == "failed")] | length) as $invalid
| ([$rows[] | select(.status == "checked") | .warnings | length] | add // 0) as $warnings
| ([$rows[] | select(.status == "checked" or .status == "invalid")] | length) as $checked
| "## Cadence \(if .passed then "✅" else "❌" end)\n",
  (if ($rows | length) == 0 then
    "No cron expression changed\(if .pr != "" then " in this pull request" else "" end).\n"
  else
    "\(plural($checked; "cron expression")) checked · \($invalid) invalid · \(plural($warnings; "warning"))\n",
    "| | Where | Expression | Meaning | Next runs (\($r.tz)) | Warnings |",
    "|---|---|---|---|---|---|",
    ($rows[] |
      "| \(icon) | \(where($r.blob)) | `\(.expression | cell)`<br>\(zone | cell) | "
      + (if .status == "checked" then (.description // "" | cell)
         elif .status == "invalid" or .status == "failed" then "**Invalid:** \(.reason | cell)"
         else "Not checked: \(.reason | cell)" end)
      + " | "
      + (if .status == "checked" then
           ((.runs // []) | map(at($r.tz)) | join("<br>")) + (if .note then (.note | cell) else "" end)
         else "" end)
      + " | "
      + (if .status == "checked" then (.warnings | map(cell) | join("<br>")) else "" end)
      + " |"),
    "",
    (if any($rows[]; .kind == "workflow") then
      "GitHub runs workflow schedules in UTC, and runs at the start of an hour are often delayed.\n"
    else empty end),
    (if $invalid > 0 and $r.fail_on != "never" then "Invalid expressions fail this check.\n"
     elif $warnings > 0 and $r.fail_on == "warning" then "Warnings fail this check (`fail-on: warning`).\n"
     else empty end)
  end),
  "<sub>\(if ($unchanged | length) > 0 then "\(plural($unchanged | length; "unchanged expression")) skipped · " else "" end)requests used: \(.requests)"
  + (if .quota != "" then " · quota left this month: \(.quota)" else "" end)
  + " · [Cadence](https://cadence.bytestay.pt) by ByteStay</sub>"
