#!/usr/bin/env bash
# Creates the read-only superset_ro database role and writes the SQLAlchemy URI
# that Preset/Superset needs.
#
# The password is generated here rather than chosen -- it is only ever pasted
# between two machines, so there is no reason for it to be memorable, and a
# generated one cannot be a password you use somewhere else.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/_common.sh
: "${DATABASE_URL:?run scripts/set_password.sh first}"

# Generated in python: `tr < /dev/urandom | head -c` takes a SIGPIPE when head
# closes the pipe, which `set -o pipefail` turns into a failed script.
PW=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))")

EXISTS=$(psql "$DATABASE_URL" -Atc "SELECT 1 FROM pg_roles WHERE rolname='superset_ro';")
if [ "$EXISTS" = "1" ]; then
  echo ">> role exists, rotating password"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "ALTER ROLE superset_ro WITH LOGIN PASSWORD '$PW';"
else
  echo ">> creating role superset_ro"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "CREATE ROLE superset_ro LOGIN PASSWORD '$PW';"
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f sql/13_superset_role.sql

# Build the URI against the POOLED endpoint -- Superset opens a connection per
# concurrent chart, which is exactly what the pooler is for.
HOST=$(python3 -c "
import os,sys
from urllib.parse import urlsplit
u=urlsplit(os.environ['DATABASE_URL'])
h=u.hostname.replace('-pooler','')
l=h.split('.'); l[0]+='-pooler'
print('.'.join(l))
")
python3 - "$PW" "$HOST" <<'PY' > scripts/.superset_uri
import sys
from urllib.parse import quote
pw, host = sys.argv[1], sys.argv[2]
print(f"postgresql+psycopg2://superset_ro:{quote(pw, safe='')}@{host}:5432/neondb?sslmode=require")
PY
chmod 600 scripts/.superset_uri

echo
echo ">> verifying the role can read mart and NOTHING else"
URI_PW="$PW"
TEST_URL="postgresql://superset_ro:${URI_PW}@${HOST}/neondb?sslmode=require"
psql "$TEST_URL" -Atc "SELECT 'mart.bi_sales    -> ' || count(*) FROM mart.bi_sales;"
psql "$TEST_URL" -Atc "SELECT 'mart.bi_orders   -> ' || count(*) FROM mart.bi_orders;"
psql "$TEST_URL" -Atc "SELECT 'mart.bi_customer -> ' || count(*) FROM mart.bi_customer;"
if psql "$TEST_URL" -Atc "SELECT count(*) FROM raw.customers;" >/dev/null 2>&1; then
  echo "!! WARNING: superset_ro can read raw.customers -- it should not" >&2
else
  echo "raw.customers    -> correctly denied"
fi
if psql "$TEST_URL" -Atc "CREATE TABLE mart._x(i int);" >/dev/null 2>&1; then
  echo "!! WARNING: superset_ro can create tables -- it should not" >&2
else
  echo "write access     -> correctly denied"
fi

echo
echo "Connection URI written to scripts/.superset_uri (gitignored, mode 600)."
echo "Open it, copy the line, paste into Preset. Do not paste it into chat."
