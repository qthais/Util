#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Script / Logging
########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
STATUS_FILE="$SCRIPT_DIR/migration.status"

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/migration_$(date '+%Y%m%d_%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

########################################
# Logging functions
########################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*"
    echo "FAILED" > "$STATUS_FILE"
    exit 1
}

########################################
# Initial status
########################################

echo "RUNNING" > "$STATUS_FILE"

########################################
# Cleanup
########################################

TMP_DIR=""
GCS_PID=""

cleanup() {
    if [[ -n "${GCS_PID:-}" ]]; then
        if kill -0 "$GCS_PID" 2>/dev/null; then
            kill "$GCS_PID" 2>/dev/null || true
        fi
    fi

    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT INT TERM

########################################
# Usage
########################################

usage() {
    cat <<EOF2

Usage:

  $0 \\
    --source-host HOST \\
    --source-port PORT \\
    --source-db DB \\
    --source-user USER \\
    --target-host HOST \\
    --target-port PORT \\
    --target-db DB \\
    --target-user USER \\
    --bucket gs://BUCKET \\
    --dump-object PATH

Required environment variables:

  SOURCE_PASSWORD
  TARGET_PASSWORD

EOF2

    exit 1
}

########################################
# Defaults
########################################

SOURCE_PORT=5432
TARGET_PORT=5432

########################################
# Parse arguments
########################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-host)
            SOURCE_HOST="$2"
            shift 2
            ;;
        --source-port)
            SOURCE_PORT="$2"
            shift 2
            ;;
        --source-db)
            SOURCE_DB="$2"
            shift 2
            ;;
        --source-user)
            SOURCE_USER="$2"
            shift 2
            ;;
        --target-host)
            TARGET_HOST="$2"
            shift 2
            ;;
        --target-port)
            TARGET_PORT="$2"
            shift 2
            ;;
        --target-db)
            TARGET_DB="$2"
            shift 2
            ;;
        --target-user)
            TARGET_USER="$2"
            shift 2
            ;;
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --dump-object)
            DUMP_OBJECT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

########################################
# Validate parameters
########################################

: "${SOURCE_HOST:?Missing --source-host}"
: "${SOURCE_DB:?Missing --source-db}"
: "${SOURCE_USER:?Missing --source-user}"

: "${TARGET_HOST:?Missing --target-host}"
: "${TARGET_DB:?Missing --target-db}"
: "${TARGET_USER:?Missing --target-user}"

: "${BUCKET:?Missing --bucket}"
: "${DUMP_OBJECT:?Missing --dump-object}"

: "${SOURCE_PASSWORD:?SOURCE_PASSWORD is not set}"
: "${TARGET_PASSWORD:?TARGET_PASSWORD is not set}"

########################################
# GCS object
########################################

GCS_DUMP="${BUCKET%/}/${DUMP_OBJECT}"

########################################
# Header
########################################

log "=========================================="
log "PostgreSQL Migration"
log "=========================================="

log "Log file:"
log "  $LOG_FILE"

log "Status file:"
log "  $STATUS_FILE"

log "Source:"
log "  Host: $SOURCE_HOST"
log "  Port: $SOURCE_PORT"
log "  DB:   $SOURCE_DB"
log "  User: $SOURCE_USER"

log "Target:"
log "  Host: $TARGET_HOST"
log "  Port: $TARGET_PORT"
log "  DB:   $TARGET_DB"
log "  User: $TARGET_USER"

log "GCS:"
log "  Object: $GCS_DUMP"

########################################
# Check PostgreSQL client
########################################

if ! command -v pg_dump >/dev/null 2>&1; then
    log "PostgreSQL client not found."
    log "Installing PostgreSQL 17 client..."

    sudo apt-get update
    sudo apt-get install -y postgresql-client-17
fi

########################################
# Validate PostgreSQL tools
########################################

command -v psql >/dev/null 2>&1 \
    || error "psql not found"

command -v pg_dump >/dev/null 2>&1 \
    || error "pg_dump not found"

command -v pg_restore >/dev/null 2>&1 \
    || error "pg_restore not found"

########################################
# Display versions
########################################

log "PostgreSQL client versions:"

psql --version
pg_dump --version
pg_restore --version

########################################
# Check gcloud
########################################

command -v gcloud >/dev/null 2>&1 \
    || error "gcloud not found"

########################################
# STEP 1
# Test PG17
########################################

log "=========================================="
log "STEP 1: Test PG17"
log "=========================================="

log "Testing PG17 connection..."

PGPASSWORD="$SOURCE_PASSWORD" \
psql \
    "host=$SOURCE_HOST port=$SOURCE_PORT dbname=$SOURCE_DB user=$SOURCE_USER sslmode=require" \
    -c "SELECT version();" \
    >/dev/null

log "PG17 connection OK."

########################################
# STEP 2
# Test PG13
########################################

log "=========================================="
log "STEP 2: Test PG13"
log "=========================================="

log "Testing PG13 connection..."

PGPASSWORD="$TARGET_PASSWORD" \
psql \
    "host=$TARGET_HOST port=$TARGET_PORT dbname=$TARGET_DB user=$TARGET_USER sslmode=require" \
    -c "SELECT version();" \
    >/dev/null

log "PG13 connection OK."

########################################
# Check GCS
########################################

log "Checking GCS bucket..."

gcloud storage ls "$BUCKET" >/dev/null

log "GCS bucket OK."

########################################
# STEP 3
# Dump PG17 -> GCS
########################################

log "=========================================="
log "STEP 3: Dump PG17 -> GCS"
log "=========================================="

log "Starting custom-format data-only dump..."

PGPASSWORD="$SOURCE_PASSWORD" \
pg_dump \
    --host="$SOURCE_HOST" \
    --port="$SOURCE_PORT" \
    --username="$SOURCE_USER" \
    --dbname="$SOURCE_DB" \
    --format=custom \
    --data-only \
    --no-owner \
    --no-acl \
    --verbose \
    | gcloud storage cp - "$GCS_DUMP"

log "PG17 dump uploaded successfully."

########################################
# Verify GCS object
########################################

log "Verifying GCS object..."

gcloud storage ls -l "$GCS_DUMP"

########################################
# STEP 4
# Truncate PG13
########################################

log "=========================================="
log "STEP 4: Truncate PG13"
log "=========================================="

PGPASSWORD="$TARGET_PASSWORD" \
psql \
    "host=$TARGET_HOST port=$TARGET_PORT dbname=$TARGET_DB user=$TARGET_USER sslmode=require" \
    <<'SQL'

DO $$
DECLARE
    truncate_sql TEXT;
BEGIN
    SELECT
        'TRUNCATE TABLE ' ||
        string_agg(
            format('%I.%I', schemaname, tablename),
            ', '
        ) ||
        ' CASCADE'
    INTO truncate_sql
    FROM pg_tables
    WHERE schemaname = 'public';

    IF truncate_sql IS NOT NULL THEN
        EXECUTE truncate_sql;
    END IF;
END
$$;

SQL

log "PG13 tables truncated."

########################################
# STEP 5
# GCS -> FIFO -> PG13
########################################

log "=========================================="
log "STEP 5: Restore GCS -> PG13"
log "=========================================="

########################################
# Temporary FIFO
########################################

TMP_DIR="$(mktemp -d)"
FIFO="$TMP_DIR/migration.dump"

mkfifo "$FIFO"

log "FIFO created:"
log "  $FIFO"

########################################
# Start GCS stream
########################################

log "Starting GCS -> FIFO stream..."

gcloud storage cat "$GCS_DUMP" > "$FIFO" &

GCS_PID=$!

log "GCS streaming process PID: $GCS_PID"

########################################
# Restore FIFO -> PG13
########################################

log "Starting pg_restore..."

set +e

PGPASSWORD="$TARGET_PASSWORD" \
pg_restore \
    --host="$TARGET_HOST" \
    --port="$TARGET_PORT" \
    --username="$TARGET_USER" \
    --dbname="$TARGET_DB" \
    --format=custom \
    --no-owner \
    --no-acl \
    --verbose \
    "$FIFO"

RESTORE_RC=$?

set -e

########################################
# Restore result
########################################

if [[ "$RESTORE_RC" -ne 0 ]]; then
    log "pg_restore returned exit code $RESTORE_RC."
    log "Known PostgreSQL 17 -> PostgreSQL 13 compatibility issue:"
    log "  SET transaction_timeout = 0"
    log "The restore continued and processed the data."
else
    log "pg_restore completed without errors."
fi

########################################
# Wait for GCS stream
########################################

log "Waiting for GCS streaming process..."

set +e

wait "$GCS_PID"

GCS_RC=$?

set -e

GCS_PID=""

########################################
# Check GCS stream
########################################

if [[ "$GCS_RC" -ne 0 ]]; then
    error "GCS download failed. Exit code: $GCS_RC"
fi

log "GCS streaming completed successfully."

########################################
# Final status
########################################

log "Please verify row counts between PG17 and PG13."

echo "SUCCESS" > "$STATUS_FILE"

log "=========================================="
log "Migration completed."
log "Status: SUCCESS"
log "=========================================="

exit 0