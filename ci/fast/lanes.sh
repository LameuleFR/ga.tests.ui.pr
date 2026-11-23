#!/usr/bin/env bash
# Run the campaigns of one job on N isolated shops at once (one "lane" per shop).
#
#   lanes.sh "<lane0 campaigns>;<lane1 campaigns>;..."   (campaigns of a lane separated by ',')
#
# Expects in $ROOT: pristine/ (prebuilt shop sources, tests/UI/node_modules installed) and
# shop-artifacts/db_dump.sql. Env: DB_SERVER, PS_VERSION, PHP_VERSION, NODE_VERSION,
# CI_FAST_DIR, RERUN_FAILED (1/0), KEYCLOAK (true/false), CLIENT_ID_API, CLIENT_SECRET_API.
#
# Lane k: compose project ps$k, ports 80k1/80k2, network ps-net-$k (lane 0: prestashop-network,
# port 8002 and 3306, which a few tests and keycloak hard-code), SMTP sink port 1026+k,
# database datadir in /dev/shm. A lane resets its shop (sources + database, a few seconds)
# before the next campaign only when the previous one failed or reinstalled the shop.
set -uo pipefail

ROOT=${ROOT:-$PWD}
CONF="$CI_FAST_DIR/campaigns.json"
RESULTS="$ROOT/results"
mkdir -p "$RESULTS"
IFS=';' read -ra LANES <<< "$1"

COMPOSE_SRC="$ROOT/pristine/docker-compose.yml"
[ "$DB_SERVER" = mariadb ] && COMPOSE_SRC="$ROOT/pristine/docker-compose.mariadb.yml"
# Same database image as the PrestaShop version under test.
DB_IMAGE=$(awk -v svc="  $DB_SERVER:" '$0 == svc {f=1; next} f && /image:/ {gsub(/["\x27]/, "", $2); print $2; exit}' "$COMPOSE_SRC")
if [ "$DB_SERVER" = mysql ]; then
  DB_IMAGE=${DB_IMAGE:-mysql:8.4}
  DB_FLAGS="--skip-log-bin --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=OFF --innodb-flush-method=fsync --innodb-use-native-aio=OFF --performance-schema=OFF --innodb-buffer-pool-size=1G"
else
  DB_IMAGE=${DB_IMAGE:-mariadb:11.4}
  DB_FLAGS="--innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0 --innodb-use-native-aio=0 --innodb-buffer-pool-size=1G"
fi
export DB_IMAGE DB_FLAGS DB_SERVER CI_FAST_DIR PHP_VERSION NODE_VERSION
export USER_ID=$(id -u) GROUP_ID=$(id -g)
DB_CLI=$([ "$DB_SERVER" = mysql ] && echo mysql || echo mariadb)

in_list() { jq -e --arg c "$2" --arg k "$1" '.[$k] | index($c) != null' "$CONF" > /dev/null; }
split_glob() { jq -r --arg c "$1" '[.splits[] | to_entries[] | select(.key == $c) | .value][0] // empty' "$CONF"; }
log() { echo "[$(date +%T)] lane $K: $*"; }

lane_env() {
  K=$1
  P="ps$K"
  DIR="$ROOT/lanes/$P"
  DATADIR="/dev/shm/ps-db-$K"
  SNAPSHOT="/dev/shm/ps-db-$K.pristine"
  export LANE_DIR="$DIR" DB_DATADIR="$DATADIR" CACHE_DIR="/dev/shm/ps-cache-$K"
  export HTTP_HOST_PORT="80${K}1" HTTPS_HOST_PORT="80${K}2"
  if [ "$K" = 0 ]; then
    export NETWORK_NAME=prestashop-network DB_HOST_PORT=3306
  else
    export NETWORK_NAME="ps-net-$K" DB_HOST_PORT=127.0.0.1:0
  fi
  local u="https://localhost:${HTTPS_HOST_PORT}/"
  export URL_FO="$u" URL_BO="${u}admin-dev/" URL_API="${u}admin-api/" URL_INSTALL="${u}install-dev/"
  export SMTP_PORT=$((1026 + K)) SMTP_SERVER=172.17.0.1
}

dc() { docker compose -p "$P" -f "$CI_FAST_DIR/docker-compose.ci.yml" "$@"; }
db_exec() { dc exec -T db "$DB_CLI" -uroot -pprestashop "$@"; }

sync_sources() {
  mkdir -p "$DIR"
  rsync -a --delete --exclude /tests/UI/node_modules --exclude /tests/UI/.env --exclude /var/cache "$ROOT/pristine/" "$DIR/"
  # var/cache is mounted from RAM: the cache clears of BO actions time out on a slow runner disk.
  mkdir -p "$DIR/var/cache" "$CACHE_DIR"
  rsync -a --delete "$ROOT/pristine/var/cache/" "$CACHE_DIR/"
  # Real per-lane copy: the test library resolves the shop root from its own location.
  [ -d "$DIR/tests/UI/node_modules" ] || cp -al "$ROOT/pristine/tests/UI/node_modules" "$DIR/tests/UI/node_modules"
  cp "$DIR/tests/UI/.env.ci" "$DIR/tests/UI/.env"
  # The rewrite rules of the installed shop (images, friendly URLs) only match its own host.
  if [ -f "$DIR/.htaccess" ]; then
    sed -i "s/localhost:8002/localhost:${HTTPS_HOST_PORT}/g" "$DIR/.htaccess"
  fi
}

# Installed shop database for this lane, kept as a datadir snapshot in RAM for fast resets.
prepare_lane() {
  sync_sources
  sudo rm -rf "$DATADIR" "$SNAPSHOT" && mkdir -p "$DATADIR"
  dc up -d --wait db || return 1
  sed "s/localhost:8002/localhost:${HTTPS_HOST_PORT}/g" "$ROOT/shop-artifacts/db_dump.sql" | db_exec prestashop || return 1
  dc stop db > /dev/null || return 1
  sudo cp -a "$DATADIR" "$SNAPSHOT"
}

# mode: installed (snapshot of the installed shop) or fresh (empty database, installer to run).
start_stack() {
  local mode=$1 ping
  dc rm -s -f > /dev/null 2>&1
  sync_sources
  sudo rm -rf "$DATADIR"
  if [ "$mode" = fresh ]; then
    mkdir -p "$DATADIR"
    # Back to sources that were never installed: no settings, no compiled container, no rewrite rules.
    rm -f "$DIR/app/config/parameters.php" "$DIR/app/config/parameters.yml" "$DIR/.htaccess"
    rm -rf "$CACHE_DIR"/*
    export PS_INSTALL_AUTO=0
    ping="${URL_INSTALL}"
  else
    sudo cp -a "$SNAPSHOT" "$DATADIR"
    export PS_INSTALL_AUTO=0
    ping="${URL_FO}en/"
  fi
  dc up -d --wait db || return 1
  dc up -d --no-build prestashop-git || return 1
  # Crawler user agent: no connection logged, see build-shop.sh.
  timeout 300 bash -c "until [ \"\$(curl -sk -L -A Googlebot -o /dev/null -w '%{http_code}' '$ping')\" = 200 ]; do sleep 2; done" || return 1
  if [ "$mode" = installed ] && in_list needs_api_client "$CAMPAIGN"; then
    dc exec -T -u www-data prestashop-git php bin/console prestashop:api-client create "$CLIENT_ID_API" --all-scopes \
      --name='Test client' --description='Test client with all scopes' --timeout=3600 --secret="$CLIENT_SECRET_API" || return 1
  fi
}

report_stats() { jq -r '"\(.stats.passes // 0)\t\(.stats.failures // 0)\t\(.stats.pending // 0)"' "$1" 2>/dev/null || printf '0\t0\t0'; }

collect() {   # $1 = result dir of the campaign
  mkdir -p "$1"
  cp -r "$DIR/tests/UI/reports/." "$1/" 2>/dev/null
  [ -d "$DIR/tests/UI/screenshots" ] && cp -r "$DIR/tests/UI/screenshots" "$1/" 2>/dev/null
  cp -r "$DIR/var/logs" "$1/var-logs" 2>/dev/null
  dc logs --no-color > "$1/docker.log" 2>&1
}

run_mocha() {   # $1 = report name, rest = spec files (none: the whole campaign)
  local name=$1; shift
  (
    cd "$DIR/tests/UI" || exit 1
    export MOCHAWESOME_REPORTDIR="$DIR/tests/UI/reports" MOCHAWESOME_REPORTFILENAME="$name"
    export NODE_EXTRA_CA_CERTS="$(mkcert -CAROOT)/rootCA.pem"
    # First run only: the rerun reports every failure of the files it runs.
    if [ "$name" = run ] && [ "${RERUN_FAILED:-1}" = 1 ]; then
      export EXTRA_TEST_PARAMS="--file $CI_FAST_DIR/skip-after-failure.js"
    fi
    if [ $# -gt 0 ]; then
      timeout 75m npx ts-mocha --file utils/setup.ts "$@"
    elif [ -n "$GLOB" ]; then
      TEST_PATH="$GLOB" timeout 75m npm run test:specific
    else
      timeout 75m npm run "test:$CAMPAIGN"
    fi
  )
}

run_lane() {
  lane_env "$1"
  local campaigns=$2 rc status files whole t0 slug fresh
  [ -n "$campaigns" ] || return 0
  IFS=',' read -ra CAMPS <<< "$campaigns"

  log "preparing (${campaigns})"
  if ! prepare_lane > "$RESULTS/lane-$K-prepare.log" 2>&1; then
    for c in "${CAMPS[@]}"; do printf '%s\t%s\tsetup-failed\t0\t0\t0\t0\n' "$K" "$c" >> "$RESULTS/lane-$K.tsv"; done
    return 1
  fi

  for CAMPAIGN in "${CAMPS[@]}"; do
    slug=${CAMPAIGN//:/-}
    GLOB=$(split_glob "$CAMPAIGN")
    fresh=0; in_list fresh_install "$CAMPAIGN" && fresh=1
    t0=$SECONDS
    # Every campaign starts on a pristine shop, as in pr_test_one: campaigns leave orders, carts,
    # subscriptions... behind them, and a reset only takes about 10 seconds.
    log "starting shop for $CAMPAIGN"
    if ! start_stack "$([ $fresh = 1 ] && echo fresh || echo installed)" >> "$RESULTS/lane-$K-setup.log" 2>&1; then
      printf '%s\t%s\tsetup-failed\t0\t0\t0\t0\n' "$K" "$CAMPAIGN" >> "$RESULTS/lane-$K.tsv"
      continue
    fi
    if in_list needs_keycloak "$CAMPAIGN"; then
      timeout 300 bash -c 'until curl -s -o /dev/null http://localhost:8003/; do sleep 3; done'
    fi
    rm -rf "$DIR/tests/UI/reports" "$DIR/tests/UI/screenshots"
    log "running $CAMPAIGN"
    run_mocha run > "$RESULTS/lane-$K-$slug.log" 2>&1
    rc=$?
    status=$([ $rc = 0 ] && echo passed || echo failed)

    if [ $rc != 0 ] && [ "${RERUN_FAILED:-1}" = 1 ]; then
      files=$(node "$CI_FAST_DIR/failed-specs.js" "$DIR/tests/UI/reports/run.json")
      whole=$?
      collect "$RESULTS/$slug/first-run"
      log "$CAMPAIGN failed, rerunning $([ $whole = 0 ] && echo "$(echo "$files" | grep -c .) spec file(s)" || echo 'the whole campaign') on a fresh shop"
      if start_stack "$([ $fresh = 1 ] && echo fresh || echo installed)" >> "$RESULTS/lane-$K-setup.log" 2>&1; then
        rm -rf "$DIR/tests/UI/reports" "$DIR/tests/UI/screenshots"
        if [ $whole = 0 ] && [ -n "$files" ]; then
          mapfile -t specs <<< "$files"
          run_mocha rerun "${specs[@]}" >> "$RESULTS/lane-$K-$slug.log" 2>&1
        else
          whole=2
          run_mocha rerun >> "$RESULTS/lane-$K-$slug.log" 2>&1
        fi
        [ $? = 0 ] && status=flaky
      fi
      # A spec file may depend on the files run before it: before reporting a failure, rerun the
      # whole campaign once, which is what a retry of pr_test_one does.
      if [ $status = failed ] && [ $whole = 0 ]; then
        collect "$RESULTS/$slug/files-rerun"
        log "$CAMPAIGN still failing, rerunning the whole campaign on a fresh shop"
        if start_stack "$([ $fresh = 1 ] && echo fresh || echo installed)" >> "$RESULTS/lane-$K-setup.log" 2>&1; then
          rm -rf "$DIR/tests/UI/reports" "$DIR/tests/UI/screenshots"
          run_mocha rerun >> "$RESULTS/lane-$K-$slug.log" 2>&1 && status=flaky
        fi
      fi
    fi

    collect "$RESULTS/$slug"
    local report="$DIR/tests/UI/reports/run.json"
    [ -f "$DIR/tests/UI/reports/rerun.json" ] && report="$DIR/tests/UI/reports/rerun.json"
    printf '%s\t%s\t%s\t%s\t%s\n' "$K" "$CAMPAIGN" "$status" "$(( (SECONDS - t0) / 60 ))" "$(report_stats "$report")" >> "$RESULTS/lane-$K.tsv"
    log "$CAMPAIGN $status in $(( (SECONDS - t0) / 60 )) min"
  done
  dc rm -s -f > /dev/null 2>&1
}

# The shop image is built once (in background by an earlier step); every lane reuses it.
while pgrep -f "docker compose -p psimage" > /dev/null; do sleep 2; done
lane_env 0
if ! docker image inspect ps-ci-shop:local > /dev/null 2>&1; then
  LANE_DIR="$ROOT/pristine" dc build prestashop-git > "$RESULTS/image-build.log" 2>&1 || { echo "Image build failed"; tail -50 "$RESULTS/image-build.log"; exit 1; }
fi

pids=()
for k in "${!LANES[@]}"; do
  run_lane "$k" "${LANES[$k]}" &
  pids+=($!)
  if [ "$k" = 0 ] && [ "${KEYCLOAK:-false}" = true ]; then
    ( timeout 600 bash -c 'until docker network inspect prestashop-network > /dev/null 2>&1; do sleep 2; done' \
      && USER_ID=$(id -u) GROUP_ID=$(id -g) docker compose -f "$ROOT/keycloak_connector_demo/docker-compose-ui.yml" up -d \
    ) > "$RESULTS/keycloak.log" 2>&1 &
  fi
  sleep 10   # stagger the database loads and ts-node start-ups
done
for p in "${pids[@]}"; do wait "$p"; done

cat "$RESULTS"/lane-*.tsv > "$RESULTS/summary.tsv" 2>/dev/null
{
  echo "| Lane | Campaign | Result | Minutes | Passing | Failing | Pending |"
  echo "|---|---|---|---|---|---|---|"
  awk -F'\t' '{icon = ($3 == "passed") ? "✅" : ($3 == "flaky") ? "🟡 flaky (passed on rerun)" : "❌ " $3;
               printf "| %s | `%s` | %s | %s | %s | %s | %s |\n", $1, $2, icon, $4, $5, $6, $7}' "$RESULTS/summary.tsv"
} > "$RESULTS/summary.md"
cat "$RESULTS/summary.md"

# Diagnostics in the job log, so that a run can be analysed without downloading its artifacts.
for d in "$RESULTS"/*/; do
  c=$(basename "$d")
  if [ -f "$d/first-run/run.json" ]; then
    echo "--- $c: failures of the first run"
    node "$CI_FAST_DIR/print-failures.js" "$d/first-run/run.json"
  fi
  final="$d/rerun.json"; [ -f "$final" ] || final="$d/run.json"
  if [ -f "$final" ] && [ "$(jq -r '.stats.failures // 0' "$final")" != 0 ]; then
    echo "--- $c: failures of the final report"
    node "$CI_FAST_DIR/print-failures.js" "$final"
  fi
  for timing in "$d/first-run/var-logs/apache-timing.log" "$d/var-logs/apache-timing.log"; do
    [ -f "$timing" ] || continue
    awk -v c="$c" '$NF > 20000000 {printf "--- %s: slow request %ds %s %s\n", c, $NF / 1000000, $3, substr($4, 1, 90)}' "$timing"
    # The 3 slowest requests whatever their duration, to measure the margin below the test timeouts
    awk '{printf "%d\t%s\t%s\n", $NF, $3, substr($4, 1, 90)}' "$timing" | sort -rn | awk 'NR <= 3' \
      | awk -F'\t' -v c="$c" '{printf "--- %s: slowest %.1fs %s %s\n", c, $1 / 1000000, $2, $3}'
  done
done
echo "--- runner: $(nproc) CPUs, $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"
awk 'NR > 2 && $1 ~ /^[0-9]+$/ {n++; r += $1; id += $15; wa += $16; st += $17; if ($1 > m) m = $1}
     END {if (n) printf "--- CPU: run queue avg %.1f / max %d, idle %.0f%%, iowait %.0f%%, steal %.0f%%\n", r / n, m, id / n, wa / n, st / n}' /tmp/mon/vmstat.log 2>/dev/null
echo "--- /dev/shm: $(df -h /dev/shm | tail -1)"
du -sh /dev/shm/ps-cache-* 2>/dev/null | sed 's/^/--- cache size: /'

expected=0; for l in "${LANES[@]}"; do IFS=',' read -ra cs <<< "$l"; expected=$((expected + ${#cs[@]})); done
got=$(wc -l < "$RESULTS/summary.tsv")
[ "$got" = "$expected" ] || { echo "::error::$got results for $expected campaigns"; exit 1; }
awk -F'\t' '$3 != "passed" && $3 != "flaky" {bad = 1} END {exit bad}' "$RESULTS/summary.tsv"
