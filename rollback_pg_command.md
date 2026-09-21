thaiallb63@dev01:~/postgres-migration$ nohup env \
  SOURCE_PASSWORD='Bachduong16!' \
  TARGET_PASSWORD='Bachduong16!' \
  ./migrate.sh \
    --source-host 34.67.189.72 \
    --source-port 5432 \
    --source-db pagila \
    --source-user postgres \
    --target-host 136.116.214.95 \
    --target-port 5432 \
    --target-db pagila \
    --target-user postgres \
    --bucket gs://my-project-postgres-migration-lab \
    --dump-object postgres-migration/pagila-data.dump \
  > /dev/null 2>&1 &
[1] 2957
thaiallb63@dev01:~/postgres-migration$ pgrep -af migrate.sh
2957 bash ./migrate.sh --source-host 34.67.189.72 --source-port 5432 --source-db pagila --source-user postgres --target-host 136.116.214.95 --target-port 5432 --target-db pagila --target-user postgres --bucket gs://my-project-postgres-migration-lab --dump-object postgres-migration/pagila-data.dump
thaiallb63@dev01:~/postgres-migration$ tail -f "$(ls -t ~/postgres-migration/logs/*.log | head -1)"
[2026-09-21 17:15:16] Known PostgreSQL 17 -> PostgreSQL 13 compatibility issue:
[2026-09-21 17:15:16]   SET transaction_timeout = 0
[2026-09-21 17:15:16] The restore continued and processed the data.
[2026-09-21 17:15:16] Waiting for GCS streaming process...
[2026-09-21 17:15:16] GCS streaming completed successfully.
[2026-09-21 17:15:16] Please verify row counts between PG17 and PG13.
[2026-09-21 17:15:16] ==========================================
[2026-09-21 17:15:16] Migration completed.
[2026-09-21 17:15:16] Status: SUCCESS
[2026-09-21 17:15:16] ==========================================
