#!/bin/bash
# Rust server entrypoint for Pterodactyl.
#
# On every start:
#   1. Validates FRAMEWORK (vanilla/oxide/carbon) and BRANCH (public/release/staging/aux01/aux02/aux03).
#   2. Updates the game through SteamCMD on the chosen branch. A branch or framework change forces a validate,
#      and the server will not start if that validate fails.
#   3. Installs or updates Oxide or Carbon for that branch, removes the other framework's DLLs, and copies
#      plugins/configs/data across once when switching between Oxide and Carbon (nothing is deleted).
#   4. Downloads the enabled extensions (Discord, RustEdit, ChaosCode, PreventBlueprintWipes).
#   5. Builds the startup line from the egg and hands it to wrapper.js.

cd /home/container || exit 1

log()  { echo -e "\033[1;36m[egg]\033[0m $*"; }
warn() { echo -e "\033[1;33m[egg] WARNING:\033[0m $*"; }
fail() { echo -e "\033[1;31m[egg] ERROR:\033[0m $*"; exit 1; }

[ "${EGG_DEBUG}" = "1" ] && set -x

# Make internal Docker IP address available to processes.
INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Accept the Pine Hosting variable name too, so servers moved from the Pine egg keep their branch.
BRANCH="${BRANCH:-${SRCDS_BETAID:-public}}"
FRAMEWORK="${FRAMEWORK:-vanilla}"
STATE_FILE=".egg_state"
MANAGED="RustDedicated_Data/Managed"
# Wings mounts /tmp as a small tmpfs, so large downloads go to the server volume.
DL_DIR=".egg_tmp"

##########################
# Validate the variables #
##########################

case "${FRAMEWORK}" in
    vanilla|oxide|carbon) ;;
    *) fail "Modding Framework '${FRAMEWORK}' is not valid. Use vanilla, oxide or carbon." ;;
esac

case "${BRANCH}" in
    public|release|staging|aux01|aux02|aux03) ;;
    *) fail "Branch '${BRANCH}' is not valid. Use public, release, staging, aux01, aux02 or aux03." ;;
esac

# Pick the framework build that matches the game branch.
OXIDE_URL=""
CARBON_URL=""
if [ "${FRAMEWORK}" = "oxide" ]; then
    case "${BRANCH}" in
        public|release) OXIDE_URL="https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip" ;;
        staging)        OXIDE_URL="https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip" ;;
        *) fail "Oxide has no build for the '${BRANCH}' branch. Switch the Modding Framework to carbon or vanilla, or the Branch to public or staging." ;;
    esac
elif [ "${FRAMEWORK}" = "carbon" ]; then
    case "${BRANCH}" in
        public|release) CARBON_URL="https://github.com/CarbonCommunity/Carbon.Core/releases/download/production_build/Carbon.Linux.Release.tar.gz" ;;
        *)              CARBON_URL="https://github.com/CarbonCommunity/Carbon/releases/download/rustbeta_${BRANCH}_build/Carbon.Linux.Debug.tar.gz" ;;
    esac
fi

#################################################
# Detect branch / framework changes since last  #
#################################################

PREV_BRANCH=$(sed -n 's/^branch=//p' "${STATE_FILE}" 2>/dev/null)
PREV_FRAMEWORK=$(sed -n 's/^framework=//p' "${STATE_FILE}" 2>/dev/null)
PENDING_VALIDATE=$(sed -n 's/^pending_validate=//p' "${STATE_FILE}" 2>/dev/null)
FORCE_VALIDATE=0

if [ "${PENDING_VALIDATE}" = "1" ]; then
    warn "The last required validate did not finish. Running it again."
    FORCE_VALIDATE=1
fi

if [ -n "${PREV_BRANCH}" ] && [ "${PREV_BRANCH}" != "${BRANCH}" ]; then
    warn "Branch changed from ${PREV_BRANCH} to ${BRANCH}. Forcing a full validate. Saves from one branch may not load on another."
    FORCE_VALIDATE=1
fi

if [ -n "${PREV_FRAMEWORK}" ] && [ "${PREV_FRAMEWORK}" != "${FRAMEWORK}" ]; then
    warn "Modding Framework changed from ${PREV_FRAMEWORK} to ${FRAMEWORK}. Forcing a full validate to restore clean game files."
    FORCE_VALIDATE=1
fi

# Oxide patches the game's own DLLs. If Oxide is installed but no longer wanted, the game files must be restored.
if [ "${FRAMEWORK}" != "oxide" ] && [ -f "${MANAGED}/Oxide.Core.dll" ]; then
    warn "Oxide files found but Modding Framework is ${FRAMEWORK}. Forcing a full validate to remove them."
    FORCE_VALIDATE=1
fi

# Record a required validate before doing it, so a crash or failure mid-way repeats it next start.
if [ "${FORCE_VALIDATE}" = "1" ]; then
    printf 'branch=%s\nframework=%s\npending_validate=1\n' "${PREV_BRANCH:-${BRANCH}}" "${PREV_FRAMEWORK:-${FRAMEWORK}}" > "${STATE_FILE}"
fi

##################
# Update the game #
##################

if [ ! -x ./steamcmd/steamcmd.sh ]; then
    log "SteamCMD not found. Installing it..."
    mkdir -p ./steamcmd
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C ./steamcmd \
        || fail "Could not download SteamCMD."
fi

STEAM_RAN=0
if [ "${AUTO_UPDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ] || [ ! -f ./RustDedicated ]; then
    # Always name the branch. Without -beta, SteamCMD stays on the last beta used (Facepunch wiki).
    STEAM_ARGS=(+force_install_dir /home/container +login anonymous +app_update 258550 -beta "${BRANCH}")
    if [ "${VALIDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ]; then
        STEAM_ARGS+=(validate)
    fi
    STEAM_ARGS+=(+quit)

    log "Updating Rust (branch: ${BRANCH})..."
    for attempt in 1 2 3; do
        if ./steamcmd/steamcmd.sh "${STEAM_ARGS[@]}"; then
            STEAM_RAN=1
            break
        fi
        warn "SteamCMD failed (attempt ${attempt} of 3). Retrying in $((attempt * 10)) seconds..."
        sleep $((attempt * 10))
    done

    if [ "${STEAM_RAN}" != "1" ]; then
        if [ "${FORCE_VALIDATE}" = "1" ]; then
            fail "The required validate (branch or framework change) failed. Not starting with mismatched game files. Restart to try again."
        elif [ -f ./RustDedicated ]; then
            warn "SteamCMD update failed. Starting with the files already installed."
        else
            fail "SteamCMD could not download Rust and no server files are installed."
        fi
    fi

    mkdir -p .steam/sdk32 .steam/sdk64
    cp -f steamcmd/linux32/steamclient.so .steam/sdk32/steamclient.so 2>/dev/null
    cp -f steamcmd/linux64/steamclient.so .steam/sdk64/steamclient.so 2>/dev/null
else
    log "Auto Update is off. Skipping the game update."
fi

[ -f ./RustDedicated ] && chmod +x ./RustDedicated

#############################
# Install / clean framework #
#############################

mkdir -p "${DL_DIR}"

# Remove Oxide's own DLLs when Oxide is not the framework (extension DLLs for Carbon live elsewhere).
if [ "${FRAMEWORK}" != "oxide" ]; then
    rm -f "${MANAGED}"/Oxide.*.dll "${MANAGED}"/Oxide.References.dll.config
fi

if [ "${FRAMEWORK}" = "oxide" ]; then
    # The Oxide zip is kept so it can be reapplied after a game update without downloading a newer Oxide.
    # That way Framework Update = 0 really pins the Oxide version (useful on wipe day).
    OXIDE_CACHE=".egg_cache/oxide-${BRANCH}.zip"
    mkdir -p .egg_cache
    OXIDE_FRESH=0
    if [ "${FRAMEWORK_UPDATE}" = "1" ] || [ ! -s "${OXIDE_CACHE}" ]; then
        log "Downloading Oxide for branch ${BRANCH}..."
        if curl -fsSL -o "${DL_DIR}/oxide.zip" "${OXIDE_URL}" && unzip -tq "${DL_DIR}/oxide.zip" >/dev/null; then
            mv -f "${DL_DIR}/oxide.zip" "${OXIDE_CACHE}"
            OXIDE_FRESH=1
        elif [ -s "${OXIDE_CACHE}" ]; then
            warn "Oxide download failed. Using the last downloaded version."
        else
            fail "Oxide download failed and no copy is available. Restart to try again, or switch to vanilla."
        fi
    fi

    # A SteamCMD run can restore the unpatched game DLLs, so Oxide is reapplied after every update.
    if [ "${OXIDE_FRESH}" = "1" ] || [ "${STEAM_RAN}" = "1" ] || [ ! -f "${MANAGED}/Oxide.Rust.dll" ]; then
        unzip -o -q "${OXIDE_CACHE}" -d . || fail "Could not unpack Oxide."
        log "Oxide applied."
    fi
elif [ "${FRAMEWORK}" = "carbon" ]; then
    if [ "${FRAMEWORK_UPDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ] || [ ! -f carbon/managed/Carbon.Preloader.dll ]; then
        log "Installing Carbon for branch ${BRANCH}..."
        if curl -fsSL -o "${DL_DIR}/carbon.tar.gz" "${CARBON_URL}" && tar -xzf "${DL_DIR}/carbon.tar.gz" -C .; then
            log "Carbon installed."
        elif [ -f carbon/managed/Carbon.Preloader.dll ]; then
            warn "Carbon download failed. Keeping the installed version."
        else
            fail "Carbon download failed and Carbon is not installed."
        fi
        rm -f "${DL_DIR}/carbon.tar.gz"
    fi
    [ -f carbon/managed/Carbon.Preloader.dll ] && [ -f libdoorstop.so ] \
        || fail "Carbon files are incomplete (carbon/managed/Carbon.Preloader.dll or libdoorstop.so missing). Restart to reinstall Carbon."
fi

###########################################
# Copy plugins between Oxide and Carbon   #
###########################################

# Copies once per direction, never overwrites, never deletes. The old folder stays as a backup.
migrate_framework() {
    local from="$1" to="$2" marker="$2/.migrated_from_$1" pairs src dst p
    [ -d "${from}" ] && [ ! -f "${marker}" ] || return 0

    if [ "${to}" = "carbon" ]; then
        pairs="plugins:plugins data:data lang:lang config:configs"
    else
        pairs="plugins:plugins data:data lang:lang configs:config"
    fi

    log "Copying plugins, configs and data from ${from}/ to ${to}/ (existing files are kept)..."
    for p in ${pairs}; do
        src="${from}/${p%%:*}"
        dst="${to}/${p##*:}"
        [ -d "${src}" ] || continue
        mkdir -p "${dst}"
        if ! cp -a -n "${src}/." "${dst}/"; then
            warn "Copying ${src} failed. Nothing was removed. Check disk space and copy the rest by hand."
            return 0
        fi
    done
    date > "${marker}"
    log "Copy done. ${from}/ was left untouched as a backup. Plugins written for one framework may need updates on the other."
}

case "${PREV_FRAMEWORK}:${FRAMEWORK}" in
    oxide:carbon) migrate_framework oxide carbon ;;
    carbon:oxide) migrate_framework carbon oxide ;;
esac

##############
# Extensions #
##############

# Oxide-style extensions load from Managed with Oxide, and from carbon/extensions with Carbon.
EXT_DIR=""
[ "${FRAMEWORK}" = "oxide" ] && EXT_DIR="${MANAGED}"
[ "${FRAMEWORK}" = "carbon" ] && EXT_DIR="carbon/extensions"

# install_dll <enabled> <name> <url> <target dir> [user agent]
# 1 = download the latest copy. 0 = remove the file so the toggle really turns it off.
install_dll() {
    local enabled="$1" name="$2" url="$3" dir="$4" agent="${5:-Mozilla/5.0}"

    if [ -z "${dir}" ]; then
        [ "${enabled}" = "1" ] && warn "${name} skipped: it needs Modding Framework oxide or carbon."
        return 0
    fi

    if [ "${enabled}" != "1" ]; then
        if [ -f "${dir}/${name}" ]; then
            rm -f "${dir}/${name}"
            log "${name} turned off. Removed it."
        fi
        return 0
    fi

    mkdir -p "${dir}"
    local tmp="${DL_DIR}/${name}"
    if curl -fsSL --retry 2 -A "${agent}" -o "${tmp}" "${url}" && [ "$(head -c 2 "${tmp}")" = "MZ" ]; then
        mv -f "${tmp}" "${dir}/${name}"
        log "${name} updated."
    else
        rm -f "${tmp}"
        if [ -f "${dir}/${name}" ]; then
            warn "${name} download failed. Keeping the installed copy."
        else
            warn "${name} download failed and it is not installed."
        fi
    fi
}

# Clean extension copies left in the other framework's folder.
if [ "${FRAMEWORK}" = "carbon" ]; then
    rm -f "${MANAGED}"/Oxide.Ext.*.dll
elif [ -d carbon/extensions ]; then
    rm -f carbon/extensions/Oxide.Ext.Discord.dll carbon/extensions/Oxide.Ext.RustEdit.dll carbon/extensions/Oxide.Ext.Chaos.dll
fi

install_dll "${DISCORD_EXT}"  Oxide.Ext.Discord.dll  "https://umod.org/extensions/discord/download" "${EXT_DIR}"
install_dll "${RUSTEDIT_EXT}" Oxide.Ext.RustEdit.dll "https://github.com/k1lly0u/Oxide.Ext.RustEdit/raw/master/Oxide.Ext.RustEdit.dll" "${EXT_DIR}"
install_dll "${CHAOS_EXT}"    Oxide.Ext.Chaos.dll    "https://oxide.chaoscode.io/Oxide.Ext.Chaos.dll" "${EXT_DIR}" "Oxide.Ext.Chaos/1.0"
# Harmony mods load on every framework, including vanilla.
install_dll "${PREVENT_BP_WIPES}" Rust.PreventBlueprintWipes.dll "https://github.com/NinerAlpha/PreventBlueprintsWipe/releases/latest/download/Rust.PreventBlueprintWipes.dll" "HarmonyMods"

rm -rf "${DL_DIR}"

############################
# Build the startup line   #
############################

[ -n "${STARTUP}" ] || fail "STARTUP is empty. Check the egg's startup command."

# Free-text values pass through eval and then a shell. Strip characters that would break the
# arguments or run commands, and turn off globbing so * stays literal.
set -f
for v in HOSTNAME DESCRIPTION SERVER_URL SERVER_IMG SERVER_LOGO WORLD_SEED MAP_URL SERVER_TAGS; do
    val="${!v}"
    val="${val//\"/\'}"
    val="${val//\`/}"
    val="${val//\$/}"
    while [ "${val%\\}" != "${val}" ]; do val="${val%\\}"; done
    export "${v}=${val}"
done

MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))
set +f

if [ "${LOG_FILE}" = "1" ]; then
    mkdir -p logs
    find logs -name '*.log' -mtime +7 -delete 2>/dev/null
    MODIFIED_STARTUP="${MODIFIED_STARTUP} -logfile logs/$(date +%Y-%m-%d_%H%M%S).log"
fi

if [ "${FRAMEWORK}" = "carbon" ]; then
    if [ -f carbon/tools/environment.sh ]; then
        # Carbon's own launch setup (doorstop, LD_PRELOAD, library path). wrapper.js runs this in bash.
        MODIFIED_STARTUP=". ./carbon/tools/environment.sh && ${MODIFIED_STARTUP}"
    else
        export TERM=xterm DOORSTOP_ENABLED=1
        export DOORSTOP_TARGET_ASSEMBLY="$(pwd)/carbon/managed/Carbon.Preloader.dll"
        MODIFIED_STARTUP="LD_PRELOAD=$(pwd)/libdoorstop.so ${MODIFIED_STARTUP}"
    fi
fi

printf 'branch=%s\nframework=%s\n' "${BRANCH}" "${FRAMEWORK}" > "${STATE_FILE}"

log "Framework: ${FRAMEWORK} | Branch: ${BRANCH}"
echo ":/home/container$ $(echo "${MODIFIED_STARTUP}" | sed -E 's/(\+rcon\.password )("[^"]*"|[^ ]*)/\1"********"/')"

# Fix for Rust not starting
export LD_LIBRARY_PATH="$(pwd)/RustDedicated_Data/Plugins/x86_64:$(pwd)"

exec node /wrapper.js "${MODIFIED_STARTUP}"
