# Recorded responses

- `validate__*.json`, `explain__*.json`, `next__*.json`: real responses from the Cadence API 0.2.1 for the
  expressions in `expressions.tsv`, recorded with `../record.sh` (the file name ends with the HTTP status).
- `rapidapi_401.json`, `rapidapi_403.json`, `rapidapi_429.json`: the bodies RapidAPI's gateway returns for an
  invalid key, a key not subscribed to the API, and an exhausted quota (written by hand in RapidAPI's format).
