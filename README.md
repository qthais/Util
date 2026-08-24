# Migrate native users from Elasticsearch 6 to Elasticsearch 9

This runbook migrates users held in the ES 6 native realm (`.security-6`) to
ES 9. A security index cannot be restored directly across these major versions,
so the migration uses the temporary ES 7 and ES 8 clusters to upgrade the
`security` system feature at each hop.

The commands below are the clean, reproducible version of the successful
session captured in [curl.txt](curl.txt). Run them from a Bash-compatible
shell (Git Bash or WSL). The compose file starts four isolated single-node
clusters and mounts the same `./snapshots` directory at `/snapshots` in each.

## Prerequisites

- Docker and Docker Compose are available.
- The source ES 6 cluster's `elastic` credentials are known. For the local
  compose environment shown here, the credentials used in the recorded run are
  `elastic` / `elastic`.
- Do **not** run this against an ES 9 cluster whose users/security state must
  be retained. Restoring the `security` feature replaces its security state.

Start the temporary clusters:

```bash
cd migrate
docker compose up -d
```

Set endpoints and credentials:

```bash
export ES6_URL='http://localhost:9206'
export ES7_URL='http://localhost:9207'
export ES8_URL='http://localhost:9208'
export ES9_URL='http://localhost:9209'

export ES6_USER='elastic'
export ES6_PASS='elastic'
export ES9_USER='elastic'
export ES9_PASS='elastic'
```

Wait until all endpoints respond. ES 6 and ES 9 require authentication; ES 7
and ES 8 have security disabled in this temporary compose setup.

```bash
curl -sS -u "$ES6_USER:$ES6_PASS" "$ES6_URL"
curl -sS "$ES7_URL"
curl -sS "$ES8_URL"
curl -sS -u "$ES9_USER:$ES9_PASS" "$ES9_URL"
```

Expected response: each command returns the cluster root JSON and reports the
matching version: `6.8.23`, `7.17.29`, `8.18.0`, or `9.2.3`.

## 1. Snapshot the ES 6 security index

Confirm the source security index and, optionally, a source user:

```bash
curl -sS -u "$ES6_USER:$ES6_PASS" "$ES6_URL/_cat/indices/.security*?v"
curl -sS -u "$ES6_USER:$ES6_PASS" "$ES6_URL/_security/user/<username>?pretty"
```

Expected response: `.security-6` is `green`/`open`; the user request returns a
JSON object keyed by `<username>`.

Register and verify the shared filesystem repository:

```bash
curl -sS -u "$ES6_USER:$ES6_PASS" -X PUT "$ES6_URL/_snapshot/migration_repo" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/snapshots"}}'

curl -sS -u "$ES6_USER:$ES6_PASS" -X POST \
  "$ES6_URL/_snapshot/migration_repo/_verify?pretty"
```

Expected responses: `{"acknowledged":true}` then a `nodes` object containing
`es6`.

Create the ES 6 snapshot:

```bash
curl -sS -u "$ES6_USER:$ES6_PASS" -X PUT \
  "$ES6_URL/_snapshot/migration_repo/es6_security_01?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":".security-6","include_global_state":false}'
```

Expected response: `snapshot.state` is `SUCCESS`, `snapshot.indices` contains
`.security-6`, and all shards are successful.

## 2. Restore and migrate on ES 7

Register the same repository on ES 7, then restore the ES 6 snapshot:

```bash
curl -sS -X PUT "$ES7_URL/_snapshot/migration_repo" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/snapshots"}}'

curl -sS -X POST \
  "$ES7_URL/_snapshot/migration_repo/es6_security_01/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":".security-6","include_global_state":false,"include_aliases":false}'
```

Expected responses: `{"acknowledged":true}` and a restore response with one
successful shard for `.security-6`.

Check the system-feature migration, start it, then check again:

```bash
curl -sS "$ES7_URL/_migration/system_features?pretty"
curl -sS -X POST "$ES7_URL/_migration/system_features"
curl -sS "$ES7_URL/_migration/system_features?pretty"
```

Before the POST, the `security` feature reports `MIGRATION_NEEDED` and
`.security-6` at version `6.8.23`. The POST returns
`{"accepted":true,"features":[{"feature_name":"security"}]}`. Afterwards,
`security` reports `NO_MIGRATION_NEEDED` and the generated index is
`.security-6-reindexed-for-8` at version `7.17.29`.

Snapshot that generated index:

```bash
curl -sS -X PUT \
  "$ES7_URL/_snapshot/migration_repo/es7_security_01?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":".security-6-reindexed-for-8","include_global_state":false}'
```

Expected response: `snapshot.state` is `SUCCESS` with one successful shard.

## 3. Restore and migrate on ES 8

```bash
curl -sS -X PUT "$ES8_URL/_snapshot/migration_repo" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/snapshots"}}'

curl -sS -X POST \
  "$ES8_URL/_snapshot/migration_repo/es7_security_01/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":".security-6-reindexed-for-8","include_global_state":false,"include_aliases":false}'

curl -sS "$ES8_URL/_migration/system_features?pretty"
curl -sS -X POST "$ES8_URL/_migration/system_features"
curl -sS "$ES8_URL/_migration/system_features?pretty"
```

Expected results: restore succeeds with one shard. Before migration, `security`
is `MIGRATION_NEEDED` at `7.17.29-8.0.0`; after it, `security` is
`NO_MIGRATION_NEEDED` and the generated index is
`.security-6-reindexed-for-8-reindexed-for-9` at version `8.18.0`.

Create a feature-state snapshot. `feature_states` is important: it preserves
the security system-feature metadata required by ES 9.

```bash
curl -sS -X PUT \
  "$ES8_URL/_snapshot/migration_repo/es8_security_01?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"feature_states":["security"],"include_global_state":false}'
```

Expected response: `snapshot.state` is `SUCCESS` and
`snapshot.feature_states` includes `security`.

## 4. Restore and migrate on ES 9

Register the repository and restore only the security feature state. The
`"indices":"-*"` selection prevents unrelated indices in the ES 8 snapshot
from being restored.

```bash
curl -sS -u "$ES9_USER:$ES9_PASS" -X PUT \
  "$ES9_URL/_snapshot/migration_repo" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/snapshots"}}'

curl -sS -u "$ES9_USER:$ES9_PASS" -X POST \
  "$ES9_URL/_snapshot/migration_repo/es8_security_01/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":"-*","feature_states":["security"],"include_global_state":false,"include_aliases":false}'

curl -sS -u "$ES9_USER:$ES9_PASS" "$ES9_URL/_migration/system_features?pretty"
curl -sS -u "$ES9_USER:$ES9_PASS" -X POST "$ES9_URL/_migration/system_features"
curl -sS -u "$ES9_USER:$ES9_PASS" "$ES9_URL/_migration/system_features?pretty"
```

Expected results: the restore reports the migrated security index with one
successful shard. Initially ES 9 reports `security: MIGRATION_NEEDED` for the
8.x feature index. The POST is accepted; the final check reports
`security: NO_MIGRATION_NEEDED` and an index ending in
`-reindexed-for-10` at the ES 9 version.

## 5. Validate migrated users

Authenticate using a migrated native user. This is the definitive check that
the password hash and user document survived the migration.

```bash
curl -sS -u '<username>:<password>' \
  "$ES9_URL/_security/_authenticate?pretty"
```

Expected response: `username`, `roles`, `enabled: true`, and both
`authentication_realm.type` and `lookup_realm.type` set to `native`.

You can also inspect the completed security migration:

```bash
curl -sS -u "$ES9_USER:$ES9_PASS" "$ES9_URL/_cat/indices/.security*?v"
curl -sS -u "$ES9_USER:$ES9_PASS" "$ES9_URL/_migration/system_features?pretty"
```

The final migration-status response must be `NO_MIGRATION_NEEDED` globally and
for the `security` feature.

## Important notes

- `POST /_migration/system_features` takes **no request body**. A body such as
  `{"features":["security"]}` returns HTTP 400.
- Restore intermediate snapshots with `include_aliases: false`. The recorded
  direct restore that retained the `.security` alias failed because its hidden
  flag differed from the target cluster's existing security alias.
- `GET /_migration/system_features` does not work on ES 6 (it returns HTTP 405);
  that endpoint is used from ES 7 onward.
- Keep the `snapshots` directory until ES 9 validation is complete. Once the
  users have been verified, the temporary containers and their local Docker
  volumes can be removed according to your normal cleanup policy.
