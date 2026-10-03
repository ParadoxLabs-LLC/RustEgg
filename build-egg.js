// Builds egg-paradox-rust.json for the Paradox Rust image.
// Usage: node build-egg.js <image name>
const fs = require('fs');
const image = process.argv[2] || 'ghcr.io/paradoxlabs-llc/rustegg:latest';

const startup = [
  './RustDedicated -batchmode',
  '+server.port {{SERVER_PORT}} +server.queryport {{QUERY_PORT}}',
  '+server.identity \\"{{SERVER_IDENTITY}}\\"',
  '+rcon.port {{RCON_PORT}} +rcon.web true +rcon.password \\"{{RCON_PASS}}\\"',
  '+server.hostname \\"{{HOSTNAME}}\\" +server.level \\"{{LEVEL}}\\" +server.description \\"{{DESCRIPTION}}\\"',
  '+server.url \\"{{SERVER_URL}}\\" +server.headerimage \\"{{SERVER_IMG}}\\" +server.logoimage \\"{{SERVER_LOGO}}\\"',
  '+server.maxplayers {{MAX_PLAYERS}} +server.saveinterval {{SAVEINTERVAL}}',
  '+app.port {{APP_PORT}} +fps.limit {{FPS_LIMIT}}',
  '$( [ "${REQUIRE_TPM_SECURE_BOOT}" = "1" ] && printf %s "+server.useServerWideRequiredSystemConfig true" )',
  '$( [ -n "${APP_PUBLIC_IP}" ] && printf %s "+app.publicip ${APP_PUBLIC_IP}" )',
  '$( [ -n "${SERVER_TAGS}" ] && printf %s "+server.tags \\"${SERVER_TAGS}\\"" )',
  '$( [ -n "${GAMEMODE}" ] && printf %s "+server.gamemode ${GAMEMODE}" )',
  '$( [ -z "${MAP_URL}" ] && printf %s "+server.worldsize \\"{{WORLD_SIZE}}\\" +server.seed \\"{{WORLD_SEED}}\\"" || printf %s "+server.levelurl \\"{{MAP_URL}}\\"" )',
  '{{ADDITIONAL_ARGS}}',
].join(' ');

const install = [
  '#!/bin/bash',
  '# SteamCMD install for Rust. Server files: /mnt/server',
  'SRCDS_APPID=258550',
  '',
  'cd /tmp',
  'mkdir -p /mnt/server/steamcmd /mnt/server/steamapps',
  'curl -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz',
  'tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd',
  'cd /mnt/server/steamcmd',
  '',
  '# SteamCMD fails otherwise, even as root. Ownership is fixed after install.',
  'chown -R root:root /mnt',
  'export HOME=/mnt/server',
  '',
  '# Warm up SteamCMD first; its first run often fails with "Missing configuration".',
  './steamcmd.sh +login anonymous +quit || true',
  '',
  '# Always name the branch. Without -beta, SteamCMD stays on the last beta used.',
  './steamcmd.sh +force_install_dir /mnt/server +login anonymous +app_update ${SRCDS_APPID} -beta "${BRANCH:-public}" validate +quit',
  '',
  'mkdir -p /mnt/server/.steam/sdk32 /mnt/server/.steam/sdk64',
  'cp -v linux32/steamclient.so ../.steam/sdk32/steamclient.so',
  'cp -v linux64/steamclient.so ../.steam/sdk64/steamclient.so',
  '',
  '# Remember the installed branch so the first start does not re-validate.',
  'printf \'branch=%s\\n\' "${BRANCH:-public}" > /mnt/server/.egg_state',
  'echo "Install complete."',
].join('\n');

const v = (name, description, env_variable, default_value, rules, user_editable = true) =>
  ({ name, description, env_variable, default_value, user_viewable: true, user_editable, rules, field_type: 'text' });

const egg = {
  _comment: 'DO NOT EDIT: FILE GENERATED AUTOMATICALLY BY PTERODACTYL PANEL - PTERODACTYL.IO',
  meta: { version: 'PTDL_v2', update_url: null },
  exported_at: new Date().toISOString().replace(/\.\d+Z$/, '+00:00'),
  name: 'Rust (Paradox)',
  author: 'support@pterodactyl.io',
  description: 'Rust dedicated server. Supports the public and staging branches, Oxide or Carbon with the matching build for each branch, and automatic Discord, RustEdit and ChaosCode downloads.',
  features: ['steam_disk_space'],
  docker_images: { 'Paradox Rust': image },
  file_denylist: [],
  startup,
  config: {
    files: '{}',
    startup: '{\r\n    "done": "Server startup complete"\r\n}',
    logs: '{}',
    stop: 'quit',
  },
  scripts: { installation: { script: install, container: 'ghcr.io/pterodactyl/installers:debian', entrypoint: 'bash' } },
  variables: [
    v('Server Name', 'The name of your server in the public server list.', 'HOSTNAME', 'A Rust Server', 'required|string|max:60'),
    v('Description', 'The description under your server title. Commonly used for rules & info. Use \\n for newlines.', 'DESCRIPTION', 'A Rust server', 'required|string'),
    v('URL', 'The URL for your server. This is what comes up when clicking the "Visit Website" button.', 'SERVER_URL', '', 'nullable|url'),
    v('Server Image', 'The header image for the top of your server listing.', 'SERVER_IMG', '', 'nullable|url'),
    v('Server Logo', 'The circular server logo for the Rust+ app.', 'SERVER_LOGO', '', 'nullable|url'),
    v('Server Tags', 'Comma-separated server browser tags with no spaces, for example: weekly,NA,vanilla. Full list: https://wiki.facepunch.com/rust/server-browser-tags. Leave blank for none.', 'SERVER_TAGS', 'vanilla', 'nullable|string|regex:/^[\\w,]*$/|max:128'),
    v('Gamemode', 'Rust gamemode: vanilla, survival, softcore, hardcore, weapontest or primitive. Leave blank for the game default.', 'GAMEMODE', 'vanilla', 'nullable|in:vanilla,survival,softcore,hardcore,weapontest,primitive'),
    v('Max Players', 'The maximum amount of players allowed in the server at once.', 'MAX_PLAYERS', '40', 'required|integer|min:1|max:1000'),
    v('FPS Limit', 'Server frame cap (+fps.limit). Rust default is 256. A value in server/<identity>/cfg/serverauto.cfg or set by a plugin can override this.', 'FPS_LIMIT', '256', 'required|integer|min:10|max:1000'),
    v('Level', 'The world file for Rust to use.', 'LEVEL', 'Procedural Map', 'required|string|max:20'),
    v('World Size', 'The world size for a procedural map.', 'WORLD_SIZE', '3000', 'required|integer|min:1000|max:6000'),
    v('World Seed', 'The seed for a procedural map.', 'WORLD_SEED', '', 'nullable|string'),
    v('Custom Map URL', 'Overwrites the map with the one from the direct download URL. Invalid URLs will cause the server to crash.', 'MAP_URL', '', 'nullable|url'),
    v('Save Interval', 'Sets the server’s auto-save interval in seconds.', 'SAVEINTERVAL', '60', 'required|integer'),
    v('Server Identity', 'Folder under server/ that holds the save, config and player data. Changing it starts a fresh save.', 'SERVER_IDENTITY', 'rust', 'required|string|regex:/^[\\w.-]+$/|max:64'),
    v('Additional Arguments', 'Extra startup convars. Every convar must start with a +, for example: +server.pve true. Values without a + are ignored by the server.', 'ADDITIONAL_ARGS', '', 'nullable|string'),

    v('Branch', 'Rust game branch: public (normal) or staging (Facepunch test branch). Oxide and Carbon are installed in the matching build. Changing branch re-validates the game on the next start. Saves may not carry over between branches.', 'BRANCH', 'public', 'required|in:public,staging'),
    v('Modding Framework', 'vanilla, oxide or carbon. Switching re-validates the game on the next start and removes the old framework\'s DLLs. Switching between oxide and carbon copies plugins, configs and data across once; the old folder is kept.', 'FRAMEWORK', 'vanilla', 'required|in:vanilla,oxide,carbon'),
    v('Auto Update', 'Update the game through SteamCMD on every start. 1 = on, 0 = off.', 'AUTO_UPDATE', '1', 'required|boolean'),
    v('Validate Game Files', 'Run a full SteamCMD validate on every start. Slower. 1 = on, 0 = off.', 'VALIDATE', '0', 'required|boolean'),
    v('Framework Update', 'Download the latest Oxide/Carbon on every start. 1 = on, 0 = keep the installed version. On wipe day Oxide can be released before or after the Rust update; if the server crashes after a wipe, set this to 0 until both match.', 'FRAMEWORK_UPDATE', '1', 'required|boolean'),
    v('Discord Extension', 'Oxide.Ext.Discord. 1 = install and keep updated, 0 = remove (also removes a copy you installed by hand). Needs oxide or carbon.', 'DISCORD_EXT', '0', 'required|boolean'),
    v('RustEdit Extension', 'Oxide.Ext.RustEdit, needed by many RustEdit custom maps. 1 = install and keep updated, 0 = remove (also removes a copy you installed by hand). Needs oxide or carbon.', 'RUSTEDIT_EXT', '0', 'required|boolean'),
    v('ChaosCode Extension', 'Oxide.Ext.Chaos, used by ChaosCode plugins. 1 = install and keep updated, 0 = remove (also removes a copy you installed by hand). Needs oxide or carbon.', 'CHAOS_EXT', '0', 'required|boolean'),
    v('Require TPM + Secure Boot', 'Only allow players whose PC has TPM 2.0 and Secure Boot on. Marks the server as Secure in the server list. 1 = on, 0 = off.', 'REQUIRE_TPM_SECURE_BOOT', '0', 'required|boolean'),

    v('Log File', 'Also save the console output to logs/<date>.log, one file per start. 1 = on, 0 = off.', 'LOG_FILE', '0', 'required|boolean'),

    v('Query Port', 'Server Query Port. Can\'t be the same as Game\'s primary port.', 'QUERY_PORT', '27017', 'required|integer', false),
    v('RCON Port', 'Port for RCON connections.', 'RCON_PORT', '28016', 'required|integer', false),
    v('RCON Password', 'RCON access password. Letters, numbers, dot, dash and underscore only.', 'RCON_PASS', '', 'required|regex:/^[\\w.-]*$/|min:8|max:64'),
    v('App Port', 'Port for the Rust+ App. -1 to disable.', 'APP_PORT', '28082', 'required|integer', false),
    v('App Public IP', 'Public IP for the Rust+ app. Leave blank unless you have read https://wiki.facepunch.com/rust/rust-companion-server', 'APP_PUBLIC_IP', '', 'nullable|ip', false),
  ],
};

fs.writeFileSync(__dirname + '/egg-paradox-rust.json', JSON.stringify(egg, null, 4) + '\n');
console.log('Wrote egg-paradox-rust.json for image ' + image);
