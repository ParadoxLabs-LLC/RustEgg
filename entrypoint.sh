#!/bin/bash
# Rust server entrypoint for Pterodactyl.
#
# On every start:
#   1. Validates FRAMEWORK (vanilla/oxide/carbon) and BRANCH (public/release/staging/aux01/aux02/aux03).
#   2. Updates the game through SteamCMD on the chosen branch. A branch or framework change forces a validate.
#   3. Installs or updates Oxide or Carbon for that branch, and removes leftovers from the other framework.
#   4. Downloads the enabled extensions (Discord, RustEdit, ChaosCode, PreventBlueprintWipes).
#   5. Builds the startup line from the egg and hands it to wrapper.js.

cd /home/container || exit 1

log()  { echo -e "\033[1;36m[egg]\033[0m $*"; }
warn() { echo -e "\033[1;33m[egg] WARNING:\033[0m $*"; }
fail() { echo -e "\033[1;31m[egg] ERROR:\033[0m $*"; exit 1; }

# Make internal Docker IP address available to processes.
INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}')
export INTERNAL_IP

FRAMEWORK="${FRAMEWORK:-vanilla}"
BRANCH="${BRANCH:-public}"
STATE_FILE=".egg_state"
MANAGED="RustDedicated_Data/Managed"

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
FORCE_VALIDATE=0

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

##################
# Update the game #
##################

if [ ! -x ./steamcmd/steamcmd.sh ]; then
    log "SteamCMD not found. Installing it..."
    mkdir -p ./steamcmd
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C ./steamcmd \
        || fail "Could not download SteamCMD."
fi

if [ "${AUTO_UPDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ] || [ ! -f ./RustDedicated ]; then
    STEAM_ARGS=(+force_install_dir /home/container +login anonymous +app_update 258550)
    if [ "${BRANCH}" != "public" ]; then
        STEAM_ARGS+=(-beta "${BRANCH}")
    fi
    if [ "${VALIDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ]; then
        STEAM_ARGS+=(validate)
    fi
    STEAM_ARGS+=(+quit)

    # A branch change back to public needs SteamCMD to forget the old beta key.
    if [ "${FORCE_VALIDATE}" = "1" ]; then
        rm -f steamapps/appmanifest_258550.acf
    fi

    log "Updating Rust (branch: ${BRANCH})..."
    STEAM_OK=0
    for attempt in 1 2 3; do
        if ./steamcmd/steamcmd.sh "${STEAM_ARGS[@]}"; then
            STEAM_OK=1
            break
        fi
        warn "SteamCMD failed (attempt ${attempt} of 3). Retrying in 10 seconds..."
        sleep 10
    done

    if [ "${STEAM_OK}" != "1" ]; then
        if [ -f ./RustDedicated ]; then
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

# Remove Oxide's own DLLs when Oxide is not the framework (extension DLLs for Carbon live elsewhere).
if [ "${FRAMEWORK}" != "oxide" ]; then
    rm -f "${MANAGED}"/Oxide.*.dll "${MANAGED}"/Oxide.References.dll.config
fi

if [ "${FRAMEWORK}" = "oxide" ]; then
    if [ "${FRAMEWORK_UPDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ] || [ ! -f "${MANAGED}/Oxide.Rust.dll" ]; then
        log "Installing Oxide for branch ${BRANCH}..."
        if curl -fsSL -o /tmp/oxide.zip "${OXIDE_URL}" && unzip -o -q /tmp/oxide.zip -d /home/container; then
            log "Oxide installed."
        elif [ -f "${MANAGED}/Oxide.Rust.dll" ]; then
            warn "Oxide download failed. Keeping the installed version."
        else
            fail "Oxide download failed and Oxide is not installed."
        fi
        rm -f /tmp/oxide.zip
    fi
elif [ "${FRAMEWORK}" = "carbon" ]; then
    if [ "${FRAMEWORK_UPDATE}" = "1" ] || [ "${FORCE_VALIDATE}" = "1" ] || [ ! -f carbon/managed/Carbon.Preloader.dll ]; then
        log "Installing Carbon for branch ${BRANCH}..."
        if curl -fsSL -o /tmp/carbon.tar.gz "${CARBON_URL}" && tar -xzf /tmp/carbon.tar.gz -C /home/container; then
            log "Carbon installed."
        elif [ -f carbon/managed/Carbon.Preloader.dll ]; then
            warn "Carbon download failed. Keeping the installed version."
        else
            fail "Carbon download failed and Carbon is not installed."
        fi
        rm -f /tmp/carbon.tar.gz
    fi
fi

##############
# Extensions #
##############

# Oxide-style extensions load from Managed with Oxide, and from carbon/extensions with Carbon.
EXT_DIR=""
[ "${FRAMEWORK}" = "oxide" ] && EXT_DIR="${MANAGED}"
[ "${FRAMEWORK}" = "carbon" ] && EXT_DIR="carbon/extensions"

# install_dll <enabled> <name> <url> <target dir>
# 1 = download the latest copy. 0 = remove the file so the toggle really turns it off.
install_dll() {
    local enabled="$1" name="$2" url="$3" dir="$4"

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
    local tmp="/tmp/${name}"
    if curl -fsSL --retry 2 -A "Mozilla/5.0" -o "${tmp}" "${url}" && [ "$(head -c 2 "${tmp}")" = "MZ" ]; then
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
install_dll "${CHAOS_EXT}"    Oxide.Ext.Chaos.dll    "https://oxide.chaoscode.io/Oxide.Ext.Chaos.dll" "${EXT_DIR}"
# Harmony mods load on every framework, including vanilla.
install_dll "${PREVENT_BP_WIPES}" Rust.PreventBlueprintWipes.dll "https://github.com/NinerAlpha/PreventBlueprintsWipe/releases/latest/download/Rust.PreventBlueprintWipes.dll" "HarmonyMods"

############################
# Build the startup line   #
############################

MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))

if [ "${LOG_FILE}" = "1" ]; then
    mkdir -p logs
    MODIFIED_STARTUP="${MODIFIED_STARTUP} -logfile logs/$(date +%Y-%m-%d_%H%M%S).log"
fi

if [ "${FRAMEWORK}" = "carbon" ]; then
    export DOORSTOP_ENABLED=1
    export DOORSTOP_TARGET_ASSEMBLY="$(pwd)/carbon/managed/Carbon.Preloader.dll"
    MODIFIED_STARTUP="LD_PRELOAD=$(pwd)/libdoorstop.so ${MODIFIED_STARTUP}"
fi

printf 'branch=%s\nframework=%s\n' "${BRANCH}" "${FRAMEWORK}" > "${STATE_FILE}"

log "Framework: ${FRAMEWORK} | Branch: ${BRANCH}"
echo ":/home/container$ $(echo "${MODIFIED_STARTUP}" | sed -E 's/(\+rcon\.password )("[^"]*"|[^ ]*)/\1"********"/')"

# Fix for Rust not starting
export LD_LIBRARY_PATH="$(pwd)/RustDedicated_Data/Plugins/x86_64:$(pwd)"

exec node /wrapper.js "${MODIFIED_STARTUP}"
