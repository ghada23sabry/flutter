#!/bin/sh
set -e

echo "Running database migrations..."
alembic upgrade head

echo "Seeding default tenant and user..."
python -m app.cli create-tenant \
  --name "Acme" \
  --slug acme \
  --email owner@acme.com \
  --password Test1234! \
  --store "Downtown" || echo "Tenant already exists, skipping seed."

echo "Starting uvicorn..."
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
