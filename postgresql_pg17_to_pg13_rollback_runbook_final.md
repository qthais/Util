
# Rollback Guideline – Digital Library

**Source Database:** PostgreSQL 17  
**Fallback Database:** PostgreSQL 13  
**Database Name:** `digitallibrabry`

## 1. Rollback Preparation

Initiate this procedure if the PostgreSQL 17 production environment does not meet the expected performance or stability requirements after the hypercare period.

Before starting, confirm that the PostgreSQL 13 Fallback Database is available and that the operator has the required database and GCS permissions.

## 2. Enter Maintenance Mode

1. Enable application maintenance mode.
2. Stop application writes, workers, scheduled jobs, and consumers to prevent further database modifications.
3. Record the rollback start time.

## 3. Export Data from PostgreSQL 17 to GCS

Run the following commands from the migration VM or an environment with PostgreSQL client tools and Google Cloud CLI installed.

Set the connection details and GCS bucket:

```bash
export SOURCE_HOST="PG17_HOST"
export SOURCE_PORT="5432"
export SOURCE_USER="postgres"
export SOURCE_DB="digitallibrabry"

export BUCKET_NAME="YOUR_GCS_BUCKET"
export DUMP_FILE="digitallibrabry-data-only.sql"

export PGPASSWORD="YOUR_SOURCE_PASSWORD"
```

Export the data-only dump and upload it to GCS:

```bash
pg_dump \
  -h "$SOURCE_HOST" \
  -p "$SOURCE_PORT" \
  -U "$SOURCE_USER" \
  -d "$SOURCE_DB" \
  --data-only \
  --no-owner \
  --no-acl \
  --verbose \
  | sed '/^SET transaction_timeout = /d' \
  | gcloud storage cp - "gs://$BUCKET_NAME/$DUMP_FILE"
```

Verify that the dump file exists in GCS:

```bash
gcloud storage ls -L \
  "gs://$BUCKET_NAME/$DUMP_FILE"
```

## 4. Prepare the PostgreSQL 13 Fallback Database

Connect to the PostgreSQL 13 instance and verify the target database:

```bash
export TARGET_HOST="PG13_HOST"
export TARGET_PORT="5432"
export TARGET_USER="postgres"
export TARGET_DB="digitallibrabry"

export PGPASSWORD="YOUR_TARGET_PASSWORD"

psql \
  -h "$TARGET_HOST" \
  -p "$TARGET_PORT" \
  -U "$TARGET_USER" \
  -d "$TARGET_DB" \
  -c "SELECT version();"
```

Confirm that the connection is to PostgreSQL 13 and the database is `digitallibrabry`.

Truncate all existing application tables before importing the latest data:

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
           string_agg(
               format('%I.%I', schemaname, tablename),
               ', '
           ) ||
           ' CASCADE'
    INTO sql
    FROM pg_tables
    WHERE schemaname NOT IN (
        'pg_catalog',
        'information_schema'
    );

    IF sql IS NOT NULL THEN
        EXECUTE sql;
    END IF;
END
$$;
SQL
```

**Important:** Confirm the target database before executing the truncate operation. This operation removes existing table data.

## 5. Import Data into PostgreSQL 13

1. Open Google Cloud Console and navigate to Cloud SQL.
2. Select the PostgreSQL 13 instance.
3. Navigate to **Import**.
4. Select the SQL import format and the GCS file:

   `gs://YOUR_GCS_BUCKET/digitallibrabry-data-only.sql`

5. Set the target database to `digitallibrabry`.
6. Start the import and wait for completion.

Verify that the import status is:

```text
STATUS: DONE
ERROR: -
```

Do not proceed with application cutover if the import fails.

## 6. Validate the Fallback Database

Run the database comparison script to verify the restored data against PostgreSQL 17:

```bash
./compare_pg17_pg13.sh
```

Review the generated report:

```text
migration-report/report.txt
```

Confirm the following checks before proceeding:

- [ ] Schemas and tables
- [ ] Exact row counts
- [ ] Columns and data types
- [ ] Indexes and index properties
- [ ] Constraints
- [ ] Sequence definitions and sequence states
- [ ] Sequence values against `MAX(id)`
- [ ] Extensions
- [ ] Views and materialized views
- [ ] Triggers

Resolve any discrepancies that affect application functionality or data integrity before switching the application.

## 7. Switch Application to PostgreSQL 13

1. Update the application database connection configuration to the PostgreSQL 13 Fallback Database.
2. Verify that the connection points to the correct instance and database, `digitallibrabry`.
3. Restart application services, workers, scheduled jobs, and consumers.
4. Verify application functionality and database read/write operations.
5. Disable maintenance mode.
6. Monitor application performance, error logs, and database connectivity.

## 8. Complete Rollback

- Confirm that the application is operating on PostgreSQL 13.
- Notify the relevant stakeholders that rollback is complete.
- Record the rollback completion time and validation results.
- Retain the PostgreSQL 17 database and migration dump until the rollback outcome has been reviewed and approved.

Clean up database credentials from the execution environment:

```bash
unset PGPASSWORD
```
