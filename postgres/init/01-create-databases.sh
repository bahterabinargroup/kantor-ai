#!/bin/bash
# Dijalankan otomatis sekali saat volume Postgres masih kosong.
set -e
for db in n8n evolution; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE $db"
done
