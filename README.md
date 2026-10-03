# RustEgg

Pterodactyl Docker image and egg for Rust dedicated servers.

Image: `ghcr.io/paradoxlabs-llc/rustegg:latest`
Egg: [`egg-paradox-rust.json`](egg-paradox-rust.json)

## Features

- **Game branches:** public, release, staging, aux01, aux02, aux03. Changing the branch forces a full validate on the next start.
- **Modding framework:** vanilla, oxide or carbon, with the framework build that matches the branch.
  - Oxide: public, release and staging.
  - Carbon: every branch.
  - Switching framework re-validates the game and removes the old framework's DLLs. Plugins are **not** moved between `oxide/` and `carbon/`.
- **Extensions, downloaded on every start when enabled:**
  - Discord (`Oxide.Ext.Discord`)
  - RustEdit (`Oxide.Ext.RustEdit`)
  - ChaosCode (`Oxide.Ext.Chaos`)
  - PreventBlueprintWipes (Harmony mod, works on vanilla too)

  Turning a toggle off removes that DLL on the next start. A failed download keeps the installed copy, and any file that is not a real DLL is rejected.
- **FPS Limit** variable, passed as `+fps.limit`.
- **Optional log file** in `logs/`.
- **Console filter** for Unity boot noise.

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

## Notes

- Every convar in **Additional Arguments** must start with `+`, for example `+server.pve true`.
- A `fps.limit` value saved in `server/<identity>/cfg/serverauto.cfg`, or set by a plugin, overrides the FPS Limit variable.
- Steam branch names change over time. If a branch disappears, SteamCMD fails and the server starts on its installed files.
