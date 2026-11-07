# Shared by report.jq and annotate.jq; run jq with TZ set to the display time zone.
# at($tz): a unix time as "Mon 09 Nov 2026 03:00", plus the UTC offset outside UTC. Not strflocaltime("%z"):
# jq gets the offset wrong inside a fall-back overlap, while localtime read back as UTC is exact.
def at($tz):
  . as $t | (localtime | mktime) as $w | (($w - $t) / 60) as $o
  | ($w | strftime("%a %d %b %Y %H:%M"))
    + (if $tz == "UTC" then ""
       else " " + (if $o < 0 then "-" else "+" end)
            + ((($o | fabs) / 60 | floor | tostring) | if length < 2 then "0" + . else . end) + ":"
            + ((($o | fabs) % 60 | tostring) | if length < 2 then "0" + . else . end) end);
