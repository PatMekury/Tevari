# Tevari backend source

This directory contains the source-only Firebase backend used by Tevari:

- [`functions/src/index.js`](functions/src/index.js) — Gloo OAuth and structured guidance, YouVersion licensed Scripture retrieval, Firebase-authenticated endpoints, and the private Cloud Run narration proxy.
- [`functions/package.json`](functions/package.json) — Node 22 Functions tooling and deploy scripts.
- [`firebase.json`](firebase.json) — Firebase project configuration.

No `.env` files, OAuth secrets, YouVersion keys, service-account credentials, or Cloud Run credentials are stored here. Configure those as Firebase/Google Cloud secrets and parameters as described in the [replication guide](../docs/REPLICATION_AND_DEPLOYMENT.md).

This directory is the GitHub-reviewable source mirror of the deployed backend. Before deploying from any separate local Functions working directory, synchronize and review the source so the deployed implementation matches this copy.
