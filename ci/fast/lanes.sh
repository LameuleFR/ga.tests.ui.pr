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
  # The build warmed the cache on localhost:8002: module caches hold absolute links to it (the
  # ps_mainmenu menu sends every visitor of another lane to the shop of lane 0). Same-length
  # rewrite, as for the database dump.
  if [ "$HTTPS_HOST_PORT" != 8002 ]; then
    grep -rlZF 'localhost:8002' "$CACHE_DIR" | xargs -0 -r sed -i "s/localhost:8002/localhost:${HTTPS_HOST_PORT}/g"
    echo "lane $K: cache rewrite to localhost:${HTTPS_HOST_PORT}: $(grep -rlF 'localhost:8002' "$CACHE_DIR" | wc -l) files still" \
      "with localhost:8002, $(grep -rlF "localhost:${HTTPS_HOST_PORT}" "$CACHE_DIR" | wc -l) with localhost:${HTTPS_HOST_PORT}" >> "$RESULTS/lane-$K-rewrite.log"
  fi
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

report_stats() { jq -r '"\(.stats.passes // 0)\t\(.stats.failures // 0)\t\(.stats.pending // 0)\t\(.stats.skipped // 0)"' "$1" 2>/dev/null || printf -- '-\t-\t-\t-'; }
# lane, campaign, status, minutes, first run passes/failures/pending/skipped, the same for the last
# rerun, rerun kind, rerun seconds
NO_RUN=$(printf -- '-\t-\t-\t-')

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
    # First run only: the loaded spec files for the coverage guard and the rerun order, and the skip
    # of the steps after a failure (the rerun reports every failure of the files it runs).
    if [ "$name" = run ]; then
      export EXTRA_TEST_PARAMS="--file $CI_FAST_DIR/record-files.js"
      [ "${RERUN_FAILED:-1}" = 1 ] && EXTRA_TEST_PARAMS="$EXTRA_TEST_PARAMS --file $CI_FAST_DIR/skip-after-failure.js"
    fi
    if [ $# -gt 0 ]; then
      # Explicit spec files (relative to tests/UI, quoted): loaded as given, in this order.
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
  local campaigns=$2 rc status whole t0 t1 slug fresh actual intended first last prefix specs total rerun_kind rerun_s
  [ -n "$campaigns" ] || return 0
  IFS=',' read -ra CAMPS <<< "$campaigns"

  log "preparing (${campaigns})"
  if ! prepare_lane > "$RESULTS/lane-$K-prepare.log" 2>&1; then
    for c in "${CAMPS[@]}"; do printf '%s\t%s\tsetup-failed\t0\t%s\t%s\t-\t-\n' "$K" "$c" "$NO_RUN" "$NO_RUN" >> "$RESULTS/lane-$K.tsv"; done
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
      printf '%s\t%s\tsetup-failed\t0\t%s\t%s\t-\t-\n' "$K" "$CAMPAIGN" "$NO_RUN" "$NO_RUN" >> "$RESULTS/lane-$K.tsv"
      continue
    fi
    if in_list needs_keycloak "$CAMPAIGN"; then
      timeout 300 bash -c 'until curl -s -o /dev/null http://localhost:8003/; do sleep 3; done'
    fi
    rm -rf "$DIR/tests/UI/reports" "$DIR/tests/UI/screenshots"
    # The spec files the campaign must run, in load order (see campaign-specs.js).
    mkdir -p "$RESULTS/$slug"
    actual="$RESULTS/$slug/specs-actual.txt"; intended="$RESULTS/$slug/specs-intended.txt"
    node "$CI_FAST_DIR/campaign-specs.js" "$DIR/tests/UI" "$CONF" "$CAMPAIGN" "$actual" "$intended" > "$RESULTS/$slug/specs.log" 2>&1 \
      || rm -f "$actual" "$intended"
    log "running $CAMPAIGN"
    run_mocha run > "$RESULTS/lane-$K-$slug.log" 2>&1
    rc=$?
    status=$([ $rc = 0 ] && echo passed || echo failed)
    first=$(report_stats "$DIR/tests/UI/reports/run.json")
    rerun_kind=-; rerun_s=-

    # Coverage guard: every spec file of the campaign must have been loaded by the first run.
    node "$CI_FAST_DIR/spec-order.js" coverage "$DIR/tests/UI/reports/run.json" "$actual" "$intended" "$DIR/tests/UI" \
      "$DIR/tests/UI/reports/run-files.json" > "$RESULTS/$slug/coverage.txt" 2>&1
    case $? in
      0) ;;
      1) status=missing-specs
         echo "::error::$CAMPAIGN: the first run did not load every spec file of the campaign: $(grep -c '^coverage error' "$RESULTS/$slug/coverage.txt") error(s), see the coverage lines of the job log" ;;
      *) echo "::warning::$CAMPAIGN: spec file coverage not fully checked: $(grep -m1 '^coverage warning' "$RESULTS/$slug/coverage.txt")" ;;
    esac

    if [ $status = failed ] && [ "${RERUN_FAILED:-1}" = 1 ]; then
      # The verdict rerun replays the campaign from its first spec file up to the last failed one,
      # in the order of the first run, so that a failure caused by what earlier files left behind
      # shows again. Whole campaign when the failed files or their order are not certain.
      specs=()
      prefix=$(node "$CI_FAST_DIR/spec-order.js" prefix "$DIR/tests/UI/reports/run.json" "$actual" "$DIR/tests/UI" \
        "$DIR/tests/UI/reports/run-files.json" 2>> "$RESULTS/lane-$K-$slug.log")
      if [ $? = 0 ] && [ -n "$prefix" ]; then
        mapfile -t specs <<< "$prefix"
      fi
      total=$(cat "$actual" 2>/dev/null | grep -c .)
      if [ ${#specs[@]} = 0 ]; then
        whole=2; rerun_kind=whole
      elif [ ${#specs[@]} = "$total" ]; then
        whole=1; rerun_kind="whole-list-$total"
      else
        whole=0; rerun_kind="prefix-${#specs[@]}/$total"
      fi
      collect "$RESULTS/$slug/first-run"
      log "$CAMPAIGN failed, rerunning on a fresh shop: $rerun_kind"
      t1=$SECONDS
      if start_stack "$([ $fresh = 1 ] && echo fresh || echo installed)" >> "$RESULTS/lane-$K-setup.log" 2>&1; then
        rm -rf "$DIR/tests/UI/reports" "$DIR/tests/UI/screenshots"
        if [ $whole = 2 ]; then
          run_mocha rerun >> "$RESULTS/lane-$K-$slug.log" 2>&1
        else
          run_mocha rerun "${specs[@]}" >> "$RESULTS/lane-$K-$slug.log" 2>&1
        fi
        [ $? = 0 ] && status=flaky
      fi
      rerun_s=$((SECONDS - t1))
      # Last attempt, as a retry of pr_test_one: the whole campaign once more.
      if [ $status = failed ] && [ $whole = 0 ]; then
        collect "$RESULTS/$slug/prefix-rerun"
        log "$CAMPAIGN still failing, rerunning the whole campaign on a fresh shop"
        t1=$SECONDS
        if start_stack "$([ $fresh = 1 ] && echo fresh || echo installed)" >> "$RESULTS/lane-$K-setup.log" 2>&1; then
          rm -rf "$DIR/tests/UI/reports" "$DIR/tests/UI/screenshots"
          run_mocha rerun >> "$RESULTS/lane-$K-$slug.log" 2>&1 && status=flaky
        fi
        rerun_kind="$rerun_kind+whole"; rerun_s="$rerun_s+$((SECONDS - t1))"
      fi
    fi

    collect "$RESULTS/$slug"
    last=$NO_RUN
    [ -f "$DIR/tests/UI/reports/rerun.json" ] && last=$(report_stats "$DIR/tests/UI/reports/rerun.json")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$K" "$CAMPAIGN" "$status" "$(( (SECONDS - t0) / 60 ))" "$first" "$last" "$rerun_kind" "$rerun_s" >> "$RESULTS/lane-$K.tsv"
    log "$CAMPAIGN $status in $(( (SECONDS - t0) / 60 )) min (first run $first, rerun $rerun_kind $last)"
  done
  dc rm -s -f > /dev/null 2>&1
}

# The shop image is built once (in background by an earlier step); every lane reuses it.
while pgrep -f "docker compose -p psimage" > /dev/null; do sleep 2; done
lane_env 0
if ! docker image inspect ps-ci-shop:local > /dev/null 2>&1; then
  LANE_DIR="$ROOT/pristine" dc build prestashop-git > "$RESULTS/image-build.log" 2>&1 || { echo "Image build failed"; tail -50 "$RESULTS/image-build.log"; exit 1; }
fi

echo "--- build host in the warmed cache: $(grep -rlF 'localhost:8002' "$ROOT/pristine/var/cache" | wc -l) files," \
  "e.g. $(grep -rlF 'localhost:8002' "$ROOT/pristine/var/cache" | sed "s|$ROOT/pristine/||" | awk 'NR <= 3' | tr '\n' ' ')"

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
# Counts of the first run (the coverage of the campaign) and of the last rerun, side by side.
{
  echo "| Lane | Campaign | Result | Minutes | First run: passing / failing / pending / skipped | Rerun | Rerun: passing / failing / pending / skipped |"
  echo "|---|---|---|---|---|---|---|"
  awk -F'\t' '{icon = ($3 == "passed") ? "✅" : ($3 == "flaky") ? "🟡 flaky (passed on rerun)" : "❌ " $3;
               rerun = ($13 == "-") ? "" : $13 " (" $14 " s)";
               last = ($9 == "-") ? "" : $9 " / " $10 " / " $11 " / " $12;
               printf "| %s | `%s` | %s | %s | %s / %s / %s / %s | %s | %s |\n", $1, $2, icon, $4, $5, $6, $7, $8, rerun, last}' "$RESULTS/summary.tsv"
} > "$RESULTS/summary.md"
cat "$RESULTS/summary.md"

# Diagnostics in the job log, so that a run can be analysed without downloading its artifacts.
echo "--- shell of npm scripts: sh = $(readlink -f "$(command -v sh)"), npm script-shell = $(npm config get script-shell 2>/dev/null)"
awk -F'\t' '{printf "--- %s: %s, first run %s passing / %s failing / %s pending / %s skipped", $2, $3, $5, $6, $7, $8;
             if ($13 != "-") printf "; rerun %s in %s s: %s passing / %s failing / %s pending / %s skipped", $13, $14, $9, $10, $11, $12;
             printf "\n"}' "$RESULTS/summary.tsv"
for d in "$RESULTS"/*/; do
  c=$(basename "$d")
  [ -f "$d/coverage.txt" ] && sed "s/^/--- $c: /" "$d/coverage.txt"
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
    # Start time of the request (shop time zone), to match it with what the other lanes were doing.
    awk -v c="$c" '$NF > 20000000 {printf "--- %s: slow request %ds %s %s at %s\n", c, $NF / 1000000, $3, substr($4, 1, 90), substr($1, 14) " " substr($2, 1, 5)}' "$timing"
    # The 3 slowest requests whatever their duration, to measure the margin below the test timeouts
    awk '{printf "%d\t%s\t%s\t%s\n", $NF, $3, substr($4, 1, 90), substr($1, 14) " " substr($2, 1, 5)}' "$timing" | sort -rn | awk 'NR <= 3' \
      | awk -F'\t' -v c="$c" '{printf "--- %s: slowest %.1fs %s %s at %s\n", c, $1 / 1000000, $2, $3, $4}'
  done
done
sort "$RESULTS"/lane-*-rewrite.log 2>/dev/null | uniq -c | awk '{n = $1; sub(/^ *[0-9]+ /, ""); printf "--- %s (%d syncs)\n", $0, n}'
echo "--- runner: $(nproc) CPUs, $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"
awk 'NR > 2 && $1 ~ /^[0-9]+$/ {n++; r += $1; id += $15; wa += $16; st += $17; if ($1 > m) m = $1}
     END {if (n) printf "--- CPU: run queue avg %.1f / max %d, idle %.0f%%, iowait %.0f%%, steal %.0f%%\n", r / n, m, id / n, wa / n, st / n}' /tmp/mon/vmstat.log 2>/dev/null
echo "--- /dev/shm: $(df -h /dev/shm | tail -1)"
du -sh /dev/shm/ps-cache-* 2>/dev/null | sed 's/^/--- cache size: /'

expected=0; for l in "${LANES[@]}"; do IFS=',' read -ra cs <<< "$l"; expected=$((expected + ${#cs[@]})); done
got=$(wc -l < "$RESULTS/summary.tsv")
[ "$got" = "$expected" ] || { echo "::error::$got results for $expected campaigns"; exit 1; }
awk -F'\t' '$3 != "passed" && $3 != "flaky" {bad = 1} END {exit bad}' "$RESULTS/summary.tsv"
