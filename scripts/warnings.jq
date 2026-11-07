# Input: {validate, next, source, zone, transitions, min_interval}.
#   validate: the /v1/cron/validate response; next: the /v1/cron/next response or null;
#   transitions: [{t, o1, o2}] from dst_transitions (offsets in minutes east of UTC).
# Output: the warnings for one expression, as an array of strings.
def fmt_wall: strftime("%a %d %b %Y");
def hm: strftime("%H:%M");
def dur($s):
  if $s < 60 then "\($s) second\(if $s == 1 then "" else "s" end)"
  elif $s % 3600 == 0 then "\($s / 3600) hour\(if $s == 3600 then "" else "s" end)"
  else "\($s / 60 | floor) minute\(if $s < 120 then "" else "s" end)" end;

. as $in
| ($in.validate.fields // [] | map({key: .field, value: .}) | from_entries) as $f
| ($in.validate.dialect // "unix") as $dialect

# the wall times that a DST change skips (gap) or repeats (overlap), checked against the expression's fields
| def dow_values: $f.day_of_week.values | map(if $dialect == "quartz" or $dialect == "aws" then . - 1 else . % 7 end);
  def day_ok($w):
    ($w | strftime("%d") | tonumber) as $d | ($w | strftime("%w") | tonumber) as $wd
    | ($w | strftime("%m") | tonumber) as $m
    | ($f.month.values | index($m)) != null
      and (if $f.day_of_month.any and $f.day_of_week.any then true
           elif $f.day_of_month.any then (dow_values | index($wd)) != null
           elif $f.day_of_week.any then ($f.day_of_month.values | index($d)) != null
           else ($f.day_of_month.values | index($d)) != null or (dow_values | index($wd)) != null end);
  def fires_at($w):
    ($f.hour.values | index($w | strftime("%H") | tonumber)) != null
    and ($f.minute.values | index($w | strftime("%M") | tonumber)) != null
    and day_ok($w);
  def dst_warnings:
    if ($f | length) == 0 or $f.hour.any
       or any($f.minute, $f.hour, $f.day_of_month, $f.month, $f.day_of_week; .values == null) then []
    else [ $in.transitions[]
      | (if .o2 > .o1 then {kind: "gap", start: (.t + .o1 * 60), len: (.o2 - .o1)}
         else {kind: "overlap", start: (.t + .o2 * 60), len: (.o1 - .o2)} end) as $x
      | [range(0; $x.len) | $x.start + . * 60 | select(fires_at(.))] | first // empty
      | if $x.kind == "gap" then
          "The \(hm) run falls in the DST gap on \(fmt_wall) (\($in.zone)): that time doesn't exist, and schedulers differ on skipping or moving the run."
        else
          "The \(hm) run falls in the DST overlap on \(fmt_wall) (\($in.zone)): that time happens twice, and schedulers differ on running once or twice."
        end ] end;

  # the shortest interval between the next runs
  def interval:
    ($in.next.runs // [] | map(.unix)) as $u
    | if ($u | length) < 2 then null else [range(1; $u | length) as $i | $u[$i] - $u[$i - 1]] | min end;

  ($in.validate.warnings // [] | map(sub("^(?<a>.)"; "\(.a | ascii_upcase)") + "."))
  + (interval as $i
     | if $i == null then []
       elif $in.source == "workflow" and $i < 300 then
         ["Runs as often as every \(dur($i)), but GitHub runs scheduled workflows at most once every 5 minutes."]
       elif $in.min_interval > 0 and $i < $in.min_interval * 60 then
         ["Runs as often as every \(dur($i)), more often than `min-interval` (\(dur($in.min_interval * 60)))."]
       else [] end)
  + dst_warnings
  + (if $in.next.exhausted == true and ($in.next.runs | length) > 0 then
       ["No runs after \($in.next.runs[-1].utc)\(if $in.next.note then ": \($in.next.note)" else "" end)."]
     else [] end)
