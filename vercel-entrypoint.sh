#!/bin/sh
set -e

export ADDON_PORT="${PORT:-80}"

if [ -z "$ADDON_BASE_URL" ]; then
  if [ -n "$VERCEL_PROJECT_PRODUCTION_URL" ]; then
    export ADDON_BASE_URL="https://${VERCEL_PROJECT_PRODUCTION_URL}"
  elif [ -n "$VERCEL_URL" ]; then
    export ADDON_BASE_URL="https://${VERCEL_URL}"
  fi
fi

CONFIG_FILE="${CONFIG_PATH:-/tmp/data/config.json}"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Auto-detect postgres driver if DATABASE_URL is a Postgres DSN
if [ -z "$DATABASE_DRIVER" ] && [ -n "$DATABASE_URL" ]; then
  case "$DATABASE_URL" in
    postgres://*|postgresql://*)
      export DATABASE_DRIVER="postgres"
      ;;
  esac
fi

if [ "$DATABASE_DRIVER" = "postgres" ] && [ -n "$DATABASE_URL" ]; then
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "
    CREATE TABLE IF NOT EXISTS vercel_config (
      id TEXT PRIMARY KEY,
      content TEXT NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  " >/dev/null 2>&1 || echo "WARN: could not initialize vercel_config table"

  SAVED_B64=$(psql "$DATABASE_URL" -At -c "SELECT content FROM vercel_config WHERE id = 'default';" 2>/dev/null || true)
  if [ -n "$SAVED_B64" ]; then
    printf '%s' "$SAVED_B64" | base64 -d > "$CONFIG_FILE"
    echo "INFO: Restored config.json from Postgres to $CONFIG_FILE"
  fi

  sync_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    CUR_HASH=$(md5sum "$CONFIG_FILE" | awk '{print $1}')
    if [ "$CUR_HASH" != "$LAST_HASH" ]; then
      B64=$(base64 < "$CONFIG_FILE" | tr -d '\n')
      if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "
        INSERT INTO vercel_config (id, content, updated_at)
        VALUES ('default', '$B64', NOW())
        ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content, updated_at = NOW();
      " >/dev/null 2>&1; then
        LAST_HASH="$CUR_HASH"
      fi
    fi
  }

  LAST_HASH=""
  if [ -f "$CONFIG_FILE" ]; then
    LAST_HASH=$(md5sum "$CONFIG_FILE" | awk '{print $1}')
  fi

  ./streamnzb &
  APP_PID=$!

  cleanup() {
    sync_config
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    exit 0
  }
  trap cleanup TERM INT

  while kill -0 "$APP_PID" 2>/dev/null; do
    sleep 5 &
    wait $! 2>/dev/null || true
    sync_config
  done

  wait "$APP_PID"
  exit $?
else
  exec ./streamnzb
fi
