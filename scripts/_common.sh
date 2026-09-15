# Sourced by the other scripts. Not executable on its own.
#
# Loads scripts/.env and makes sure psql is reachable. Homebrew installs libpq
# keg-only, so on a fresh Mac psql exists but is not on PATH until you open a
# new shell -- this saves you the "command not found" on the first run.

if ! command -v psql >/dev/null 2>&1; then
  for d in /opt/homebrew/opt/libpq/bin /usr/local/opt/libpq/bin /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/psql" ] && export PATH="$d:$PATH" && break
  done
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not found. Install it with:  brew install libpq" >&2
  echo "then:  echo 'export PATH=\"/opt/homebrew/opt/libpq/bin:\$PATH\"' >> ~/.zshrc" >&2
  exit 1
fi

if [ -f scripts/.env ]; then
  set -a && . scripts/.env && set +a
fi
