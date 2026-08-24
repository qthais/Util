#!/usr/bin/env bash

# Migrate the ES 6 native-realm security feature to ES 9
# through temporary ES 7 and ES 8 clusters.
#
# Flow:
#
#   ES6
#     .security-6
#       |
#       | snapshot
#       v
#   ES7
#     restore .security-6
#     migrate security
#     snapshot migrated security index
#       |
#       v
#   ES8
#     restore ES7 security index
#     migrate security
#     snapshot security feature-state
#       |
#       v
#   ES9
#     restore security feature-state
#     migrate security
#
# ES7 and ES8 must share the same snapshot repository path.

set -Eeuo pipefail


usage() {
  cat <<'EOF'
Usage:
  ./migrate-security-users.sh \
    ES6_USER ES6_PASS ES6_URL \
    ES9_USER ES9_PASS ES9_URL

Required arguments:
  ES6_USER  ES 6 administrator username
  ES6_PASS  ES 6 administrator password
  ES6_URL   ES 6 endpoint, e.g. http://localhost:9206

  ES9_USER  ES 9 administrator username
  ES9_PASS  ES 9 administrator password
  ES9_URL   ES 9 endpoint, e.g. http://localhost:9209

Optional environment variables:
  ES7_URL             ES 7 endpoint
                      default: http://localhost:9207

  ES8_URL             ES 8 endpoint
                      default: http://localhost:9208

  SNAPSHOT_REPOSITORY repository name
                      default: migration_repo

  SNAPSHOT_LOCATION   snapshot repository path
                      default: /snapshots

  MIGRATION_RUN_ID    snapshot suffix
                      default: UTC timestamp

  MIGRATION_TIMEOUT   migration polling timeout in seconds
                      default: 300

  CURL_MAX_TIME       maximum duration of normal curl request
                      default: 60
EOF
}


if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi


if (( $# != 6 )); then
  usage >&2
  exit 64
fi


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ES6_USER=$1
ES6_PASS=$2
ES6_URL=${3%/}

ES9_USER=$4
ES9_PASS=$5
ES9_URL=${6%/}

ES7_URL=${ES7_URL:-http://localhost:9207}
ES8_URL=${ES8_URL:-http://localhost:9208}

ES7_URL=${ES7_URL%/}
ES8_URL=${ES8_URL%/}

SNAPSHOT_REPOSITORY=${SNAPSHOT_REPOSITORY:-migration_repo}
SNAPSHOT_LOCATION=${SNAPSHOT_LOCATION:-/snapshots}

MIGRATION_RUN_ID=${MIGRATION_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}

MIGRATION_TIMEOUT=${MIGRATION_TIMEOUT:-300}
CURL_MAX_TIME=${CURL_MAX_TIME:-60}


ES6_SNAPSHOT="es6_security_${MIGRATION_RUN_ID}"
ES7_SNAPSHOT="es7_security_${MIGRATION_RUN_ID}"
ES8_SNAPSHOT="es8_security_${MIGRATION_RUN_ID}"


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

curl_json() {
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time "$CURL_MAX_TIME" \
    "$@"
}


request() {
  local description=$1
  local response

  shift

  if ! response=$(curl_json "$@"); then
    printf '\nERROR: %s failed.\n' "$description" >&2
    printf 'Elasticsearch response:\n%s\n' "$response" >&2
    return 1
  fi

  printf '%s\n' "$response"
}


# ---------------------------------------------------------------------------
# Cluster checks
# ---------------------------------------------------------------------------

require_cluster() {
  local label=$1
  local url=$2
  local credentials=${3:-}
  local response

  if [[ -n "$credentials" ]]; then
    if ! response=$(curl_json -u "$credentials" "$url"); then
      printf '\nERROR: connection or authentication failed for %s (%s).\n' \
        "$label" "$url" >&2
      printf '%s\n' "$response" >&2
      return 1
    fi
  else
    if ! response=$(curl_json "$url"); then
      printf '\nERROR: connection failed for %s (%s).\n' \
        "$label" "$url" >&2
      printf '%s\n' "$response" >&2
      return 1
    fi
  fi

  if [[ "$response" != *'"cluster_name"'* ]]; then
    printf 'ERROR: %s did not return an Elasticsearch root response.\n' \
      "$label" >&2
    exit 1
  fi

  printf '%s\n' "$response"
}


# ---------------------------------------------------------------------------
# Snapshot repository
# ---------------------------------------------------------------------------

register_repository() {
  local url=$1
  local credentials=${2:-}
  local args=()

  [[ -n "$credentials" ]] && args=(-u "$credentials")

  request "registering snapshot repository on $url" \
    "${args[@]}" \
    -X PUT \
    "$url/_snapshot/$SNAPSHOT_REPOSITORY" \
    -H 'Content-Type: application/json' \
    -d "{
      \"type\": \"fs\",
      \"settings\": {
        \"location\": \"$SNAPSHOT_LOCATION\"
      }
    }"
}


unregister_repository() {
  local url=$1
  local credentials=${2:-}
  local args=()
  local response

  [[ -n "$credentials" ]] && args=(-u "$credentials")

  if ! response=$(curl_json \
      "${args[@]}" \
      -X DELETE \
      "$url/_snapshot/$SNAPSHOT_REPOSITORY" \
      2>&1); then

    if [[ "$response" != *'repository_missing_exception'* ]]; then
      printf '\nERROR: unregistering repository on %s failed.\n' \
        "$url" >&2
      printf '%s\n' "$response" >&2
      return 1
    fi

    return 0
  fi

  printf '%s\n' "$response"
}


refresh_repository() {
  local url=$1
  local credentials=${2:-}

  unregister_repository "$url" "$credentials"
  register_repository "$url" "$credentials"
}


# ---------------------------------------------------------------------------
# Migration API helpers
# ---------------------------------------------------------------------------

response=$(curl -sS "http://localhost:9207/_migration/system_features?pretty")

security_status_from_response() {
  local response=$1

  printf '%s\n' "$response" |
    sed -n '/"feature_name"[[:space:]]*:[[:space:]]*"security"/,/^[[:space:]]*},/p' |
    sed -n 's/.*"migration_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

security_status_from_response "$response"

security_migration_status() {
  local url=$1
  local credentials=${2:-}
  local response

  if [[ -n "$credentials" ]]; then
    response=$(curl_json \
      -u "$credentials" \
      "$url/_migration/system_features")
  else
    response=$(curl_json \
      "$url/_migration/system_features")
  fi

  security_status_from_response "$response"
}


security_index_from_response() {
  local response=$1

  printf '%s\n' "$response" |
    sed -n '/"feature_name"[[:space:]]*:[[:space:]]*"security"/,/^[[:space:]]*},/p' |
    sed -n 's/.*"index"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}


security_index() {
  local url=$1
  local credentials=${2:-}
  local response

  if [[ -n "$credentials" ]]; then
    response=$(curl_json \
      -u "$credentials" \
      "$url/_migration/system_features")
  else
    response=$(curl_json \
      "$url/_migration/system_features")
  fi

  security_index_from_response "$response"
}


# ---------------------------------------------------------------------------
# Start security migration
#
# Return codes:
#
#   0 = migration started / accepted
#   2 = Elasticsearch says there is nothing to migrate
#   1+ = actual request failure
# ---------------------------------------------------------------------------

start_security_migration() {
  local label=$1
  local url=$2
  local credentials=${3:-}

  local args=()
  local response
  local exit_code

  [[ -n "$credentials" ]] && args=(-u "$credentials")

  set +e

  response=$(
    curl \
      --fail-with-body \
      --silent \
      --show-error \
      --connect-timeout 10 \
      --max-time 15 \
      "${args[@]}" \
      -X POST \
      "$url/_migration/system_features" \
      2>&1
  )

  exit_code=$?

  set -e

  if (( exit_code == 0 )); then
    printf '%s\n' "$response"

    if [[ "$response" == *'"accepted":false'* ]] &&
       [[ "$response" == *'No system indices require migration'* ]]; then
      return 2
    fi

    return 0
  fi

  # curl timeout:
  # Elasticsearch may have accepted/completed the migration even though
  # the HTTP request itself timed out.
  if (( exit_code == 28 )); then
    printf '  %s migration trigger timed out; checking migration status.\n' \
      "$label"
    return 0
  fi

  printf '\nERROR: starting %s security migration failed.\n' \
    "$label" >&2
  printf '%s\n' "$response" >&2

  return "$exit_code"
}


wait_for_security_migration() {
  local label=$1
  local url=$2
  local credentials=${3:-}

  local started=$SECONDS
  local response
  local status
  local previous_status=''

  while (( SECONDS - started < MIGRATION_TIMEOUT )); do

    if [[ -n "$credentials" ]]; then
      response=$(curl_json \
        -u "$credentials" \
        "$url/_migration/system_features")
    else
      response=$(curl_json \
        "$url/_migration/system_features")
    fi

    status=$(security_status_from_response "$response")

    if [[ "$status" != "$previous_status" ]]; then
      printf '  %s security migration status: %s\n' \
        "$label" \
        "${status:-not reported}"

      printf '%s\n' "$response"

      previous_status=$status
    fi

    case "$status" in
      NO_MIGRATION_NEEDED)
        return 0
        ;;

      MIGRATION_NEEDED)
        sleep 2
        ;;

      *)
        sleep 2
        ;;
    esac
  done

  printf '\nERROR: %s security migration did not finish within %s seconds.\n' \
    "$label" "$MIGRATION_TIMEOUT" >&2

  printf 'Last response:\n%s\n' "$response" >&2

  return 1
}


migrate_security() {
  local label=$1
  local url=$2
  local credentials=${3:-}

  local status
  local result

  status=$(security_migration_status "$url" "$credentials")

  case "$status" in

    NO_MIGRATION_NEEDED)
      printf '%s security migration is not needed; continuing.\n' "$label"
      return 0
      ;;

    MIGRATION_NEEDED)
      printf 'Migrating the security feature on %s...\n' "$label"

      set +e
      start_security_migration "$label" "$url" "$credentials"
      result=$?
      set -e

      case "$result" in
        0)
          wait_for_security_migration "$label" "$url" "$credentials"
          ;;

        2)
          printf '%s has no system indices requiring migration; continuing.\n' \
            "$label"
          ;;

        *)
          printf 'ERROR: %s security migration failed.\n' "$label" >&2
          return "$result"
          ;;
      esac
      ;;

    *)
      printf 'ERROR: unexpected %s security migration status: %s\n' \
        "$label" \
        "${status:-not reported}" >&2
      return 1
      ;;
  esac
}


# ---------------------------------------------------------------------------
# Connectivity
# ---------------------------------------------------------------------------

printf 'Checking cluster connectivity...\n'

require_cluster ES6 "$ES6_URL" "$ES6_USER:$ES6_PASS"
require_cluster ES7 "$ES7_URL"
require_cluster ES8 "$ES8_URL"
require_cluster ES9 "$ES9_URL" "$ES9_USER:$ES9_PASS"


# ---------------------------------------------------------------------------
# ES6
# ---------------------------------------------------------------------------

printf '\nRegistering the shared snapshot repository on ES 6...\n'

register_repository \
  "$ES6_URL" \
  "$ES6_USER:$ES6_PASS"


printf '\nCreating ES 6 security snapshot %s...\n' \
  "$ES6_SNAPSHOT"

request \
  'creating the ES 6 security snapshot' \
  -u "$ES6_USER:$ES6_PASS" \
  -X PUT \
  "$ES6_URL/_snapshot/$SNAPSHOT_REPOSITORY/$ES6_SNAPSHOT?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": ".security-6",
    "include_global_state": false
  }'


# ---------------------------------------------------------------------------
# ES7
# ---------------------------------------------------------------------------

printf '\nRefreshing the shared snapshot repository on ES 7...\n'

refresh_repository "$ES7_URL"


printf '\nRestoring the ES 6 security index into ES 7...\n'

request \
  'restoring the ES 6 security snapshot into ES 7' \
  -X POST \
  "$ES7_URL/_snapshot/$SNAPSHOT_REPOSITORY/$ES6_SNAPSHOT/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": ".security-6",
    "include_global_state": false
  }'


printf '\nMigrating security on ES 7...\n'

migrate_security ES7 "$ES7_URL"


# Get the actual security index after migration.
ES7_SECURITY_INDEX=$(security_index "$ES7_URL")

if [[ -z "$ES7_SECURITY_INDEX" ]]; then
  printf '\nERROR: ES 7 did not report a security index after migration.\n' >&2

  printf 'Migration API response:\n' >&2
  curl_json "$ES7_URL/_migration/system_features?pretty" >&2

  exit 1
fi

printf 'ES 7 security index: %s\n' \
  "$ES7_SECURITY_INDEX"


printf '\nCreating ES 7 security snapshot %s...\n' \
  "$ES7_SNAPSHOT"

request \
  'creating the ES 7 security snapshot' \
  -X PUT \
  "$ES7_URL/_snapshot/$SNAPSHOT_REPOSITORY/$ES7_SNAPSHOT?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d "{
    \"indices\": \"$ES7_SECURITY_INDEX\",
    \"include_global_state\": false
  }"


# ---------------------------------------------------------------------------
# ES8
# ---------------------------------------------------------------------------

printf '\nRefreshing the shared snapshot repository on ES 8...\n'

refresh_repository "$ES8_URL"


printf '\nRestoring the ES 7 security index into ES 8...\n'

request \
  'restoring the ES 7 security snapshot into ES 8' \
  -X POST \
  "$ES8_URL/_snapshot/$SNAPSHOT_REPOSITORY/$ES7_SNAPSHOT/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d "{
    \"indices\": \"$ES7_SECURITY_INDEX\",
    \"include_global_state\": false
  }"


printf '\nMigrating security on ES 8...\n'

migrate_security ES8 "$ES8_URL"


printf '\nCreating ES 8 security feature-state snapshot %s...\n' \
  "$ES8_SNAPSHOT"

request \
  'creating the ES 8 security feature-state snapshot' \
  -X PUT \
  "$ES8_URL/_snapshot/$SNAPSHOT_REPOSITORY/$ES8_SNAPSHOT?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{
    "feature_states": [
      "security"
    ],
    "include_global_state": false
  }'


# ---------------------------------------------------------------------------
# ES9
# ---------------------------------------------------------------------------

printf '\nRefreshing the shared snapshot repository on ES 9...\n'

refresh_repository \
  "$ES9_URL" \
  "$ES9_USER:$ES9_PASS"


printf '\nRestoring the ES 8 security feature state into ES 9...\n'

request \
  'restoring the ES 8 security feature state into ES 9' \
  -u "$ES9_USER:$ES9_PASS" \
  -X POST \
  "$ES9_URL/_snapshot/$SNAPSHOT_REPOSITORY/$ES8_SNAPSHOT/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "-*",
    "feature_states": [
      "security"
    ],
    "include_global_state": false
  }'


printf '\nMigrating security on ES 9...\n'

migrate_security \
  ES9 \
  "$ES9_URL" \
  "$ES9_USER:$ES9_PASS"


# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\nMigration completed successfully.\n'

printf '\nValidate a migrated user with:\n'

printf 'curl -sS -u %%q %%q\n' \
  '<username>:<password>' \
  "$ES9_URL/_security/_authenticate?pretty"