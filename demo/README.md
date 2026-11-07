# Demo

`demo/nightly.yml` (a workflow) and `demo/backup.yaml` (a Kubernetes CronJob) are checked by
`.github/workflows/demo.yml` when a pull request changes them.

The comment and the annotations then show up on a real pull request. Only files under `demo/` are checked, and only on pull requests.
