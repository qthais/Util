#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================
# Configuration
# ============================================================

SOURCE_HOST="${SOURCE_HOST:?SOURCE_HOST is required}"
SOURCE_PORT="${SOURCE_PORT:-5432}"
SOURCE_USER="${SOURCE_USER:?SOURCE_USER is required}"
SOURCE_PASSWORD="${SOURCE_PASSWORD:?SOURCE_PASSWORD is required}"
SOURCE_DB="${SOURCE_DB:-lego}"

TARGET_HOST="${TARGET_HOST:?TARGET_HOST is required}"
TARGET_PORT="${TARGET_PORT:-5432}"
TARGET_USER="${TARGET_USER:?TARGET_USER is required}"
TARGET_PASSWORD="${TARGET_PASSWORD:?TARGET_PASSWORD is required}"
TARGET_DB="${TARGET_DB:-lego}"

REPORT_DIR="${REPORT_DIR:-migration-report}"

mkdir -p \
    "$REPORT_DIR/source" \
    "$REPORT_DIR/target"

SOURCE_CONN="host=$SOURCE_HOST port=$SOURCE_PORT user=$SOURCE_USER dbname=$SOURCE_DB sslmode=require"
TARGET_CONN="host=$TARGET_HOST port=$TARGET_PORT user=$TARGET_USER dbname=$TARGET_DB sslmode=require"

# ============================================================
# Helpers
# ============================================================

run_source() {
    PGPASSWORD="$SOURCE_PASSWORD" \
    psql "$SOURCE_CONN" \
        -X \
        -v ON_ERROR_STOP=1 \
        "$@"
}

run_target() {
    PGPASSWORD="$TARGET_PASSWORD" \
    psql "$TARGET_CONN" \
        -X \
        -v ON_ERROR_STOP=1 \
        "$@"
}

run_source_query() {
    run_source -At -F $'\t' -c "$1"
}

run_target_query() {
    run_target -At -F $'\t' -c "$1"
}

# ============================================================
# 1. Connectivity
# ============================================================

echo "Checking source PostgreSQL..."

if ! run_source -c "SELECT version();" >/dev/null; then
    echo "ERROR: Cannot connect to source PostgreSQL."
    exit 1
fi

echo "Checking target PostgreSQL..."

if ! run_target -c "SELECT version();" >/dev/null; then
    echo "ERROR: Cannot connect to target PostgreSQL."
    exit 1
fi

echo "Connections OK."
echo

# ============================================================
# 2. Database information
# ============================================================

echo "Collecting database information..."

DATABASE_QUERY="
SELECT
    current_database(),
    current_setting('server_version'),
    current_setting('server_version_num'),
    pg_database_size(current_database()),
    pg_size_pretty(pg_database_size(current_database()));
"

run_source_query "$DATABASE_QUERY" \
    > "$REPORT_DIR/source/database.tsv"

run_target_query "$DATABASE_QUERY" \
    > "$REPORT_DIR/target/database.tsv"

# ============================================================
# 3. Schemas
# ============================================================

echo "Collecting schemas..."

SCHEMA_QUERY="
SELECT
    nspname
FROM pg_namespace
WHERE nspname NOT IN ('pg_catalog', 'information_schema')
  AND nspname NOT LIKE 'pg_toast%'
ORDER BY nspname;
"

run_source_query "$SCHEMA_QUERY" \
    > "$REPORT_DIR/source/schemas.tsv"

run_target_query "$SCHEMA_QUERY" \
    > "$REPORT_DIR/target/schemas.tsv"

# ============================================================
# 4. Tables
# ============================================================

echo "Collecting tables..."

TABLE_QUERY="
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned_table'
    END AS relation_type
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
"

run_source_query "$TABLE_QUERY" \
    > "$REPORT_DIR/source/tables.tsv"

run_target_query "$TABLE_QUERY" \
    > "$REPORT_DIR/target/tables.tsv"

# ============================================================
# 5. Exact row counts
# ============================================================

echo "Counting rows. This may take some time..."

COUNT_QUERY="
SELECT format(
    'SELECT %L AS table_name, COUNT(*)::bigint AS row_count FROM %I.%I;',
    n.nspname || '.' || c.relname,
    n.nspname,
    c.relname
)
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
"

{
    run_source -At -F $'\t' <<SQL
$COUNT_QUERY
\gexec
SQL
} > "$REPORT_DIR/source/counts.tsv"

{
    run_target -At -F $'\t' <<SQL
$COUNT_QUERY
\gexec
SQL
} > "$REPORT_DIR/target/counts.tsv"

# ============================================================
# 6. Table sizes
# ============================================================

echo "Collecting table sizes..."

TABLE_SIZE_QUERY="
SELECT
    n.nspname,
    c.relname,
    pg_relation_size(c.oid) AS table_bytes,
    pg_table_size(c.oid) AS table_total_bytes,
    pg_indexes_size(c.oid) AS index_bytes,
    pg_total_relation_size(c.oid) AS total_bytes
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
"

run_source_query "$TABLE_SIZE_QUERY" \
    > "$REPORT_DIR/source/table_sizes.tsv"

run_target_query "$TABLE_SIZE_QUERY" \
    > "$REPORT_DIR/target/table_sizes.tsv"

# ============================================================
# 7. Columns / schema
# ============================================================

echo "Collecting columns..."

COLUMN_QUERY="
SELECT
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    data_type,
    udt_schema,
    udt_name,
    is_nullable,
    column_default,
    is_identity,
    identity_generation,
    is_generated
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
  AND table_schema NOT LIKE 'pg_toast%'
ORDER BY table_schema, table_name, ordinal_position;
"

run_source_query "$COLUMN_QUERY" \
    > "$REPORT_DIR/source/columns.tsv"

run_target_query "$COLUMN_QUERY" \
    > "$REPORT_DIR/target/columns.tsv"

# ============================================================
# 8. Indexes
# ============================================================

echo "Collecting indexes..."

INDEX_QUERY="
SELECT
    schemaname,
    tablename,
    indexname,
    tablespace,
    indexdef
FROM pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
ORDER BY schemaname, tablename, indexname;
"

run_source_query "$INDEX_QUERY" \
    > "$REPORT_DIR/source/indexes.tsv"

run_target_query "$INDEX_QUERY" \
    > "$REPORT_DIR/target/indexes.tsv"

# ============================================================
# 9. Index properties + size
# ============================================================

echo "Collecting index properties..."

INDEX_PROPERTY_QUERY="
SELECT
    ns.nspname AS schema_name,
    tbl.relname AS table_name,
    idx.relname AS index_name,
    i.indisunique,
    i.indisprimary,
    i.indisexclusion,
    i.indisclustered,
    i.indisvalid,
    i.indisready,
    pg_relation_size(idx.oid) AS size_bytes
FROM pg_index i
JOIN pg_class idx
  ON idx.oid = i.indexrelid
JOIN pg_class tbl
  ON tbl.oid = i.indrelid
JOIN pg_namespace ns
  ON ns.oid = tbl.relnamespace
WHERE ns.nspname NOT IN ('pg_catalog', 'information_schema')
  AND ns.nspname NOT LIKE 'pg_toast%'
ORDER BY ns.nspname, tbl.relname, idx.relname;
"

run_source_query "$INDEX_PROPERTY_QUERY" \
    > "$REPORT_DIR/source/index_properties.tsv"

run_target_query "$INDEX_PROPERTY_QUERY" \
    > "$REPORT_DIR/target/index_properties.tsv"

# ============================================================
# 10. Constraints
# ============================================================

echo "Collecting constraints..."

CONSTRAINT_QUERY="
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    con.conname,
    con.contype,
    con.condeferrable,
    con.condeferred,
    con.convalidated,
    pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint con
JOIN pg_class c
  ON c.oid = con.conrelid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname, con.conname;
"

run_source_query "$CONSTRAINT_QUERY" \
    > "$REPORT_DIR/source/constraints.tsv"

run_target_query "$CONSTRAINT_QUERY" \
    > "$REPORT_DIR/target/constraints.tsv"

# ============================================================
# 11. Sequence definitions
# ============================================================

echo "Collecting sequence definitions..."

SEQUENCE_QUERY="
SELECT
    schemaname,
    sequencename,
    sequenceowner,
    data_type,
    start_value,
    min_value,
    max_value,
    increment_by,
    cycle,
    cache_size,
    last_value
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, sequencename;
"

run_source_query "$SEQUENCE_QUERY" \
    > "$REPORT_DIR/source/sequences.tsv"

run_target_query "$SEQUENCE_QUERY" \
    > "$REPORT_DIR/target/sequences.tsv"

# ============================================================
# 12. Sequence state
#
# Checks:
#   - sequence
#   - table
#   - column
#   - last_value
#   - is_called
#   - MAX(column)
#
# Only sequences with a dependency to a table column are included.
# Unowned sequences are still checked by the regular sequences.tsv
# comparison above.
# ============================================================

echo "Collecting sequence states..."

SEQUENCE_STATE_QUERY="
SELECT format(
    'SELECT %L AS schema_name,
            %L AS sequence_name,
            %L AS table_name,
            %L AS column_name,
            last_value::text AS last_value,
            is_called::text AS is_called,
            (SELECT MAX(%I)::text FROM %I.%I) AS max_value
     FROM %I.%I;',
    ns.nspname,
    s.relname,
    tn.nspname || '.' || t.relname,
    a.attname,
    a.attname,
    tn.nspname,
    t.relname,
    ns.nspname,
    s.relname
)
FROM pg_class s
JOIN pg_namespace ns
  ON ns.oid = s.relnamespace
JOIN pg_depend d
  ON d.objid = s.oid
 AND d.deptype IN ('a', 'i')
JOIN pg_class t
  ON t.oid = d.refobjid
JOIN pg_namespace tn
  ON tn.oid = t.relnamespace
JOIN pg_attribute a
  ON a.attrelid = t.oid
 AND a.attnum = d.refobjsubid
WHERE s.relkind = 'S'
  AND t.relkind IN ('r', 'p')
  AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
  AND tn.nspname NOT IN ('pg_catalog', 'information_schema')
  AND ns.nspname NOT LIKE 'pg_toast%'
  AND tn.nspname NOT LIKE 'pg_toast%'
ORDER BY ns.nspname, s.relname;
"

{
    run_source -At -F $'\t' <<SQL
$SEQUENCE_STATE_QUERY
\gexec
SQL
} > "$REPORT_DIR/source/sequence_state.tsv"

{
    run_target -At -F $'\t' <<SQL
$SEQUENCE_STATE_QUERY
\gexec
SQL
} > "$REPORT_DIR/target/sequence_state.tsv"

# ============================================================
# 13. Extensions
# ============================================================

echo "Collecting extensions..."

EXTENSION_QUERY="
SELECT
    extname,
    extversion
FROM pg_extension
WHERE extname <> 'plpgsql'
ORDER BY extname;
"

run_source_query "$EXTENSION_QUERY" \
    > "$REPORT_DIR/source/extensions.tsv"

run_target_query "$EXTENSION_QUERY" \
    > "$REPORT_DIR/target/extensions.tsv"

# ============================================================
# 14. Views
# ============================================================

echo "Collecting views..."

VIEW_QUERY="
SELECT
    schemaname,
    viewname,
    definition
FROM pg_views
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
ORDER BY schemaname, viewname;
"

run_source_query "$VIEW_QUERY" \
    > "$REPORT_DIR/source/views.tsv"

run_target_query "$VIEW_QUERY" \
    > "$REPORT_DIR/target/views.tsv"

# ============================================================
# 15. Materialized views
# ============================================================

echo "Collecting materialized views..."

MATVIEW_QUERY="
SELECT
    schemaname,
    matviewname,
    ispopulated
FROM pg_matviews
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg_toast%'
ORDER BY schemaname, matviewname;
"

run_source_query "$MATVIEW_QUERY" \
    > "$REPORT_DIR/source/materialized_views.tsv"

run_target_query "$MATVIEW_QUERY" \
    > "$REPORT_DIR/target/materialized_views.tsv"

# ============================================================
# 16. Triggers
# ============================================================

echo "Collecting triggers..."

TRIGGER_QUERY="
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    t.tgname AS trigger_name,
    t.tgenabled,
    pg_get_triggerdef(t.oid, true) AS definition
FROM pg_trigger t
JOIN pg_class c
  ON c.oid = t.tgrelid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname, t.tgname;
"

run_source_query "$TRIGGER_QUERY" \
    > "$REPORT_DIR/source/triggers.tsv"

run_target_query "$TRIGGER_QUERY" \
    > "$REPORT_DIR/target/triggers.tsv"

# ============================================================
# 17. Sections
# ============================================================

SECTIONS=(
    "schemas"
    "tables"
    "counts"
    "table_sizes"
    "columns"
    "indexes"
    "index_properties"
    "constraints"
    "sequences"
    "sequence_state"
    "extensions"
    "views"
    "materialized_views"
    "triggers"
)

# ============================================================
# 18. Generate individual diff files
# ============================================================

echo
echo "Generating diff files..."

for section in "${SECTIONS[@]}"; do

    diff -u \
        "$REPORT_DIR/source/$section.tsv" \
        "$REPORT_DIR/target/$section.tsv" \
        > "$REPORT_DIR/${section}.diff" || true

done

# ============================================================
# 19. Generate report
# ============================================================

REPORT="$REPORT_DIR/report.txt"

{
    echo "============================================================"
    echo " PostgreSQL Migration Comparison Report"
    echo "============================================================"
    echo
    echo "Source : $SOURCE_HOST:$SOURCE_PORT/$SOURCE_DB"
    echo "Target : $TARGET_HOST:$TARGET_PORT/$TARGET_DB"
    echo
    echo "Generated: $(date)"
    echo

    echo "============================================================"
    echo " DATABASE"
    echo "============================================================"
    echo

    echo "SOURCE:"
    cat "$REPORT_DIR/source/database.tsv"

    echo
    echo "TARGET:"
    cat "$REPORT_DIR/target/database.tsv"

    echo

    echo "============================================================"
    echo " SUMMARY"
    echo "============================================================"

    TOTAL=0
    DIFFERENT=0

    for section in "${SECTIONS[@]}"; do

        TOTAL=$((TOTAL + 1))

        if diff -q \
            "$REPORT_DIR/source/$section.tsv" \
            "$REPORT_DIR/target/$section.tsv" \
            >/dev/null 2>&1; then

            echo "PASS        $section"

        else

            echo "DIFFERENT   $section"
            DIFFERENT=$((DIFFERENT + 1))

        fi

    done

    echo
    echo "Sections checked : $TOTAL"
    echo "Different        : $DIFFERENT"

    echo

    echo "============================================================"
    echo " DETAILED DIFFERENCES"
    echo "============================================================"

    for section in "${SECTIONS[@]}"; do

        echo
        echo "------------------------------------------------------------"
        echo " DIFFERENCE: $section"
        echo "------------------------------------------------------------"

        if diff -u \
            "$REPORT_DIR/source/$section.tsv" \
            "$REPORT_DIR/target/$section.tsv"; then

            echo "NO DIFFERENCES"

        else

            echo

        fi

    done

} > "$REPORT"

# ============================================================
# 20. Print final summary to terminal
# ============================================================

echo
echo "============================================================"
echo " Comparison completed"
echo "============================================================"
echo
echo "Report:"
echo "  $REPORT"
echo

echo "Summary:"

TOTAL=0
DIFFERENT=0

for section in "${SECTIONS[@]}"; do

    TOTAL=$((TOTAL + 1))

    if diff -q \
        "$REPORT_DIR/source/$section.tsv" \
        "$REPORT_DIR/target/$section.tsv" \
        >/dev/null 2>&1; then

        printf "  %-22s PASS\n" "$section"

    else

        printf "  %-22s DIFFERENT\n" "$section"
        DIFFERENT=$((DIFFERENT + 1))

    fi

done

echo
echo "Sections checked : $TOTAL"
echo "Different        : $DIFFERENT"
echo
echo "Detailed report:"
echo "  $REPORT"
echo