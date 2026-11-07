# Input: array of expression results; $fail_on: invalid, warning or never; $tz: display time zone.
# Output: workflow-command lines. GitHub shows at most 10 annotations of each level per step: the rest is in the
# report.
include "time";
def esc_data: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
def esc_prop: esc_data | gsub(":"; "%3A") | gsub(","; "%2C");
def cmd($level; $file; $line; $title; $msg):
  "::\($level) file=\($file | esc_prop)\(if $line then ",line=\($line)" else "" end),title=\($title | esc_prop)::\($msg | esc_data)";

(
  [ .[] | select(.status == "invalid" or .status == "failed")
    | {level: (if $fail_on == "never" then "warning" else "error" end), rank: 0, file, line,
       title: "Invalid cron expression", msg: "\(.expression): \(.reason)"} ]
  + [ .[] | select(.status == "checked") | . as $r | .warnings[]
    | {level: (if $fail_on == "warning" then "error" else "warning" end), rank: 1, file: $r.file, line: $r.line,
       title: "Cron warning", msg: "\($r.expression): \(.)"} ]
  + [ .[] | select(.status == "checked")
    | {level: "notice", rank: 2, file, line, title: "Cron: \(.expression)",
       msg: ((.description // "no description")
             + (if (.runs | length) > 0 then ". Next run: \(.runs[0] | at($tz))\(if $tz == "UTC" then " UTC" else " (\($tz))" end)" else "" end))} ]
)
| group_by(.level) | map(.[:10]) | flatten | sort_by(.rank)
| .[]
| cmd(.level; .file; .line; .title; .msg)
