# PostgreSQL 17 → PostgreSQL 13 Rollback Runbook

## 1. Enter Downtime

- Enable maintenance mode.
- Stop application writes, workers, scheduled jobs, and consumers.
- Record rollback start time.

## 2. Prepare PostgreSQL 13

Set:

```bash
export TARGET_HOST="PG13_PUBLIC_IP"
export TARGET_PORT="5432"
export TARGET_USER="postgres"
export TARGET_PASSWORD="..."
export TARGET_DB="lego"
export PGPASSWORD="$TARGET_PASSWORD"
```

Verify:

```bash
psql \
  -h "$TARGET_HOST" \
  -p "$TARGET_PORT" \
  -U "$TARGET_USER" \
  -d "$TARGET_DB" \
  -c "SELECT version();"
```

## 3. Truncate All Tables in PostgreSQL 13

```bash
psql \
  -h "$TARGET_HOST" \
  -p "$TARGET_PORT" \
  -U "$TARGET_USER" \
  -d "$TARGET_DB" \
  <<'SQL'
DO $$
DECLARE
    sql TEXT;
BEGIN
    SELECT 'TRUNCATE TABLE ' ||
           string_agg(format('%I.%I', schemaname, tablename), ', ') ||
           ' CASCADE'
    INTO sql
    FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema');

    IF sql IS NOT NULL THEN
        EXECUTE sql;
    END IF;
END
$$;
SQL
```

## 4. Dump PostgreSQL 17 → GCS

```bash
export SOURCE_HOST="35.253.109.7"
export SOURCE_PORT="5432"
export SOURCE_USER="postgres"
export BUCKET_NAME="dev111111"
export DUMP_FILE="lego-data-only.sql"
export PGPASSWORD="Bachduong16!"

pg_dump \
  -h "$SOURCE_HOST" \
  -p "$SOURCE_PORT" \
  -U "$SOURCE_USER" \
  -d "lego" \
  --data-only \
  --no-owner \
  --no-acl \
  --verbose \
  | sed '/^SET transaction_timeout = /d' \
  | gcloud storage cp - "gs://$BUCKET_NAME/$DUMP_FILE"
```

Verify:

```bash
gcloud storage ls -L \
  "gs://$BUCKET_NAME/$DUMP_FILE"
```

## 5. Import via Cloud SQL UI

```text
Cloud SQL
→ PostgreSQL 13 instance
→ Import
→ SQL
→ Google Cloud Storage
→ lego-data-only.sql
→ Database: lego
→ Import
```

Wait for:

```text
STATUS: DONE
ERROR: -
```

## 6. Validate

Run:

```bash
./compare_pg17_pg13.sh
```

Review:

```text
migration-report/report.txt
```

Required checks:

```text
[ ] Schemas
[ ] Tables
[ ] Exact row counts
[ ] Columns
[ ] Indexes
[ ] Index properties
[ ] Constraints
[ ] Sequence definitions
[ ] Sequence state + MAX(id)
[ ] Extensions
[ ] Views
[ ] Materialized views
[ ] Triggers
```

## 7. Cutover to PostgreSQL 13

- Switch application connection to PG13.
- Start workers/jobs/consumers.
- Remove maintenance mode.
- Verify application reads and writes.

## 8. Cleanup

```bash
unset PGPASSWORD
```
