#!/bin/bash
# Boots a real Rust server from the egg the way Pterodactyl Wings would, and checks it.
#
# Usage: tests/run-server.sh <image> <NAME=value overrides...>
#
# 1. Runs the egg's install script in Pterodactyl's installer image (like a panel install).
# 2. Starts the image as uid 988 with a 100 MB /tmp tmpfs and the egg's variables (like Wings).
# 3. Waits for "Server startup complete" and checks the log for framework/extension errors.
# 4. Stops the container with SIGTERM and checks that Rust saved and quit.

set -uo pipefail

# Report a failure as a GitHub annotation (readable without opening the job log).
annotate() {  # annotate <title> [file with details]
    local body="$1"
    [ -n "${2:-}" ] && body="${body}%0A$(tail -n 40 "$2" | sed 's/%/%25/g' | tr -d '\r' | awk '{printf "%s%%0A", $0}')"
    echo "::error title=${TEST_NAME:-boot}::${body}"
}

IMAGE="$1"; shift
EGG="egg-paradox-rust.json"
WORK="$(pwd)/.test-server"
NAME="rust-test"
BOOT_TIMEOUT=$((45 * 60))

mkdir -p "${WORK}/server"

# Egg defaults, then the test overrides.
declare -A VARS
while IFS=$'\t' read -r k v; do VARS["$k"]="$v"; done < <(jq -r '.variables[] | [.env_variable, .default_value] | @tsv' "${EGG}")
VARS[RCON_PASS]="testpass123"
VARS[WORLD_SIZE]="1000"
VARS[WORLD_SEED]="12345"
VARS[HOSTNAME]="CI test server"
for kv in "$@"; do VARS["${kv%%=*}"]="${kv#*=}"; done

# Values Wings adds itself.
VARS[SERVER_PORT]="28015"
VARS[SERVER_IP]="0.0.0.0"
VARS[SERVER_MEMORY]="12288"
VARS[P_SERVER_LOCATION]="ci"
VARS[TZ]="UTC"
VARS[STARTUP]="$(jq -r '.startup' "${EGG}")"

ENV_FILE="${WORK}/env.list"
: > "${ENV_FILE}"
for k in "${!VARS[@]}"; do printf '%s=%s\n' "$k" "${VARS[$k]}" >> "${ENV_FILE}"; done

echo "::group::Install script"
jq -r '.scripts.installation.script' "${EGG}" > "${WORK}/install.sh"
docker run --rm --env-file "${ENV_FILE}" \
    -v "${WORK}/server:/mnt/server" -v "${WORK}/install.sh:/mnt/install/install.sh:ro" \
    ghcr.io/pterodactyl/installers:debian bash /mnt/install/install.sh > "${WORK}/install.log" 2>&1
rc=$?
cat "${WORK}/install.log"
[ ${rc} -eq 0 ] || { annotate "Install script failed" "${WORK}/install.log"; exit 1; }
sudo chown -R 988:988 "${WORK}/server"
echo "::endgroup::"

echo "Starting ${IMAGE} with: $*"
docker rm -f "${NAME}" >/dev/null 2>&1
docker run -d --name "${NAME}" --user 988:988 \
    --env-file "${ENV_FILE}" \
    --tmpfs /tmp:rw,exec,size=100m \
    -v "${WORK}/server:/home/container" -w /home/container \
    -i "${IMAGE}" >/dev/null || exit 1

start=$(date +%s)
while true; do
    docker logs "${NAME}" > "${WORK}/server.log" 2>&1
    if grep -q "Server startup complete" "${WORK}/server.log"; then
        echo "Server booted in $(( $(date +%s) - start )) seconds."
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" != "true" ]; then
        echo "Container stopped before the server finished booting."
        docker logs "${NAME}" > "${WORK}/server.log" 2>&1
        tail -n 150 "${WORK}/server.log"
        annotate "Container stopped before boot finished" "${WORK}/server.log"
        exit 1
    fi
    if [ $(( $(date +%s) - start )) -gt ${BOOT_TIMEOUT} ]; then
        echo "Timed out waiting for the server to boot."
        docker logs "${NAME}" > "${WORK}/server.log" 2>&1
        tail -n 150 "${WORK}/server.log"
        annotate "Timed out waiting for boot" "${WORK}/server.log"
        exit 1
    fi
    sleep 20
done

# Give RCON and plugins a moment, then collect the log.
sleep 60
docker logs "${NAME}" > "${WORK}/server.log" 2>&1

fail=0
check() {  # check <description> <grep -E pattern> [absent]
    if grep -qE "$2" "${WORK}/server.log"; then
        [ "${3:-}" = "absent" ] && { echo "FAIL: $1"; annotate "FAIL: $1: $(grep -E "$2" "${WORK}/server.log" | head -3 | tr '
' ' ')"; fail=1; } || echo "PASS: $1"
    else
        [ "${3:-}" = "absent" ] && echo "PASS: $1" || { echo "FAIL: $1"; annotate "FAIL: $1" "${WORK}/server.log"; fail=1; }
    fi
}

check "startup line has -batchmode" "RustDedicated -batchmode"
check "wrapper connected to RCON" "Connected to RCON"
check "no -logfile reaches Rust" "RustDedicated -batchmode.* -logfile" absent
check "no egg errors" "\[egg\] ERROR" absent
check "no download failures" "download failed" absent
case "${VARS[FRAMEWORK]}" in
    oxide)  check "Oxide loaded" "Loading Oxide Core|Oxide.Rust|Loaded extension Rust" ;;
    carbon)  # Ignore the egg's own "Installing Carbon" lines; only output from the game counts.
        if grep -v '\[egg\]' "${WORK}/server.log" | grep -q "Carbon"; then echo "PASS: Carbon loaded"
        else echo "FAIL: Carbon loaded"; annotate "FAIL: Carbon loaded" "${WORK}/server.log"; fail=1; fi ;;
esac
[ "${VARS[DISCORD_EXT]}" = "1" ]  && check "Discord extension installed" "Oxide.Ext.Discord.dll updated"
[ "${VARS[RUSTEDIT_EXT]}" = "1" ] && check "RustEdit extension installed" "Oxide.Ext.RustEdit.dll updated"
[ "${VARS[CHAOS_EXT]}" = "1" ]    && check "ChaosCode extension installed" "Oxide.Ext.Chaos.dll updated"

# Every console line must show once (the old -logfile path printed RCON lines twice).
n=$(grep -c "Server startup complete" "${WORK}/server.log")
if [ "${n}" = "1" ]; then echo "PASS: console lines not doubled"
else echo "FAIL: 'Server startup complete' shown ${n} times"; annotate "FAIL: console lines doubled (${n}x)"; fail=1; fi

if [ "${VARS[LOG_FILE]}" = "1" ]; then
    if sudo grep -qs "Server startup complete" "${WORK}"/server/logs/*.log; then echo "PASS: log file written"
    else echo "FAIL: log file written"; annotate "FAIL: logs/<date>.log missing or empty"; fail=1; fi
fi

echo "Stopping with SIGTERM (Wings kill path)..."
docker stop -t 120 "${NAME}" >/dev/null
docker logs "${NAME}" > "${WORK}/server.log" 2>&1
check "server saved on stop" "Saving complete|Saved [0-9,]+ ents|Server shutdown|Quitting"
echo "Container exit code: $(docker inspect -f '{{.State.ExitCode}}' "${NAME}")"
[ ${fail} -eq 0 ] && echo "::notice title=${TEST_NAME:-boot}::All checks passed. Boot log tail:%0A$(grep -E '\[egg\]|Server startup complete|Connected to RCON' "${WORK}/server.log" | tail -n 25 | tr -d '\r' | awk '{printf "%s%%0A", $0}')"

exit ${fail}
