# RustEgg

Pterodactyl Docker image and egg for Rust dedicated servers.

Image: `ghcr.io/paradoxlabs-llc/rustegg:latest`
Egg: [`egg-paradox-rust.json`](egg-paradox-rust.json)

## Features

- **Game branches:** public and staging. Changing the branch forces a full validate on the next start.
- **Modding framework:** vanilla, oxide or carbon, with the framework build that matches the branch.
  - Switching framework re-validates the game and removes the old framework's DLLs.
  - Switching between Oxide and Carbon copies plugins, configs, data and lang across once. Existing files are kept and the old folder is never deleted.
  - If a required validate fails, the server does not start with mismatched files, and the next start tries again.
  - Framework Update = 0 pins the last downloaded Oxide, which is reapplied after game updates.
- **Extensions, downloaded on every start when enabled:**
  - Discord (`Oxide.Ext.Discord`)
  - RustEdit (`Oxide.Ext.RustEdit`)
  - ChaosCode (`Oxide.Ext.Chaos`)

  Turning a toggle off removes that DLL on the next start. A failed download keeps the installed copy, and any file that is not a real DLL is rejected.
- **FPS Limit** variable, passed as `+fps.limit`.
- **Require TPM + Secure Boot** toggle (`server.useServerWideRequiredSystemConfig`).
- **Pine Hosting compatibility:** `SRCDS_BETAID` is accepted as the branch.
- **Optional log file** in `logs/`.
- **Console filter** for Unity boot noise, line by line.
- **Wrapper:** streams game output (no buffer limit), reconnects when RCON drops instead of killing the server, and saves on SIGTERM.

## Install

1. Make the package public, once: GitHub → ParadoxLabs-LLC → Packages → `rustegg` → Package settings → Change visibility → Public. Wings cannot pull a private image without registry credentials.
2. In the panel, go to Admin → Nests → Import Egg and upload `egg-paradox-rust.json`.
3. To move an existing server, change its egg under Admin → Servers → *server* → Startup, then restart it. The first start re-validates the game files.

## Build

GitHub Actions builds and pushes the image on every push to `main`, weekly, and on manual run (Actions → Build image → Run workflow).

To build locally:

```bash
docker build -t ghcr.io/paradoxlabs-llc/rustegg:latest .
```

To regenerate the egg after changing `build-egg.js`:

```bash
node build-egg.js ghcr.io/paradoxlabs-llc/rustegg:latest
```

## Tests

`.github/workflows/test.yml` builds the image and boots a real server the way Wings does: install script in `ghcr.io/pterodactyl/installers:debian`, then the image as uid 988 with a 100 MB `/tmp`. It runs vanilla/public, oxide/public with all extensions, and carbon/staging. Run it from Actions → Test server boot.

## Notes

- Every convar in **Additional Arguments** must start with `+`, for example `+server.pve true`.
- A `fps.limit` value saved in `server/<identity>/cfg/serverauto.cfg`, or set by a plugin, overrides the FPS Limit variable.
- On wipe day Oxide can be released before or after the Rust update. If a server crashes after a wipe, set Framework Update to 0 until both match.
