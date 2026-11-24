#!/usr/bin/env bash
# Install the shop once, warm its caches, and export sources + SQL dump for the test jobs.
# Run from $ROOT with the PR sources (composer + assets built) in $ROOT/pristine.
# Env: DB_SERVER, PHP_VERSION, NODE_VERSION, PS_DEV_MODE, CI_FAST_DIR.
set -euo pipefail

ROOT=${ROOT:-$PWD}
COMPOSE_SRC="$ROOT/pristine/docker-compose.yml"
[ "$DB_SERVER" = mariadb ] && COMPOSE_SRC="$ROOT/pristine/docker-compose.mariadb.yml"
DB_IMAGE=$(awk -v svc="  $DB_SERVER:" '$0 == svc {f=1; next} f && /image:/ {gsub(/["\x27]/, "", $2); print $2; exit}' "$COMPOSE_SRC")
if [ "$DB_SERVER" = mysql ]; then
  DB_IMAGE=${DB_IMAGE:-mysql:8.4}; DUMP=mysqldump
  DB_FLAGS="--skip-log-bin --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=OFF --innodb-flush-method=fsync --innodb-use-native-aio=OFF --performance-schema=OFF --innodb-buffer-pool-size=1G"
else
  DB_IMAGE=${DB_IMAGE:-mariadb:11.4}; DUMP=mariadb-dump
  DB_FLAGS="--innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0 --innodb-use-native-aio=0 --innodb-buffer-pool-size=1G"
fi
export DB_IMAGE DB_FLAGS DB_SERVER PHP_VERSION NODE_VERSION CI_FAST_DIR
export USER_ID=$(id -u) GROUP_ID=$(id -g)
# Same ports as lane 0 of the test jobs: the dump holds localhost:8002, rewritten per lane.
export LANE_DIR="$ROOT/pristine" DB_DATADIR=/dev/shm/ps-db-build
export HTTP_HOST_PORT=8001 HTTPS_HOST_PORT=8002 NETWORK_NAME=ps-build DB_HOST_PORT=127.0.0.1:0
export PS_INSTALL_AUTO=1
dc() { docker compose -p psbuild -f "$CI_FAST_DIR/docker-compose.ci.yml" "$@"; }

sudo rm -rf "$DB_DATADIR" && mkdir -p "$DB_DATADIR"
dc up -d --wait db
dc up -d prestashop-git
echo "Waiting for the installed shop"
# Apache only starts once the shop is installed: the first answer is the single direct visit that
# pr_test_one leaves in the database too. The dashboard tests read the first three connections,
# so every other probe uses a crawler user agent, for which the shop logs no connection.
timeout 900 bash -c 'until [ "$(curl -sk -L -o /dev/null -w "%{http_code}" https://localhost:8002/en/)" = 200 ]; do
  if ! docker compose -p psbuild -f "$CI_FAST_DIR/docker-compose.ci.yml" ps --status running prestashop-git | grep -q prestashop-git; then exit 1; fi
  sleep 3; done' || { dc logs --no-color prestashop-git | tail -100; exit 1; }

# Build every kernel's prod cache now, once, instead of in the first test of every job.
# As www-data: root-owned cache files would break the cache clears done by module actions.
warmups=""
for app in admin front admin-api; do
  t0=$(date +%s.%N)
  dc exec -T -u www-data prestashop-git php -d memory_limit=-1 bin/console cache:warmup --env=prod --no-debug --app-id=$app \
    || echo "::warning::cache warmup failed for $app"
  warmups="$warmups, $app $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')s"
done
# Runner speed at a glance: the same warmups are what module actions redo in the test jobs.
echo "--- build: $(nproc) CPUs, $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo), cache warmup${warmups#,}"
# Front and back office pages once, to fill the Smarty/asset caches the same way for everyone.
curl -sk -A Googlebot -o /dev/null https://localhost:8002/en/ || true
curl -sk -A Googlebot -o /dev/null https://localhost:8002/admin-dev/ || true

mkdir -p "$ROOT/shop-artifacts"
dc exec -T db $DUMP -uroot -pprestashop --single-transaction --skip-dump-date prestashop > "$ROOT/shop-artifacts/db_dump.sql"

# Where the build host is written: the test jobs rewrite it in the dump, the warmed cache and
# .htaccess only. Anything else would send the browser of another lane to the shop of lane 0.
host_re='localhost(:|%3A)8002'
t0=$SECONDS
files=$(cd "$ROOT/pristine" && find . \( -path ./var/cache -o -name node_modules -o -name vendor -o -name tests -o -name .git \) -prune \
  -o -type f -print0 | xargs -0 grep -lIE "$host_re" 2>/dev/null || true)
echo "--- build host outside var/cache: $(printf '%s' "$files" | grep -c .) files ($((SECONDS - t0)) s), e.g. $(printf '%s\n' "$files" | awk 'NR <= 5' | tr '\n' ' ')"
echo "--- build host in the SQL dump: $(grep -cE "$host_re" "$ROOT/shop-artifacts/db_dump.sql" || true) lines," \
  "$(grep -oE "$host_re" "$ROOT/shop-artifacts/db_dump.sql" | wc -l) occurrences"
dc rm -s -f
sudo rm -rf "$DB_DATADIR"

# Sources for the test jobs. Kept: vendor, built assets, warmed prod cache, install-dev (sanity
# installs the shop) and tests/UI. Left out: what the test jobs rebuild or never read.
tar -C "$ROOT/pristine" --zstd -cf "$ROOT/shop-artifacts/sources.tar.zst" \
  --exclude=./.git \
  --exclude='./admin-dev/themes/new-theme/node_modules' \
  --exclude='./admin-dev/themes/default/node_modules' \
  --exclude='./themes/classic/_dev/node_modules' \
  --exclude='./themes/hummingbird/node_modules' \
  --exclude='./themes/node_modules' \
  --exclude='./tests/UI/node_modules' \
  --exclude='./tests/Unit' --exclude='./tests/Integration' --exclude='./tests/Resources' \
  --exclude='./var/cache/dev' --exclude='./var/logs/*' \
  --exclude='./.docker/ssl.key' --exclude='./.docker/ssl.crt' \
  .
ls -lh "$ROOT/shop-artifacts"
du -sh "$ROOT/pristine/var/cache"/* || true
