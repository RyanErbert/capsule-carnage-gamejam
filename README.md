# Capsule Carnage

Reverse tag, in Godot 4.6.3. Server (socket.io, in `server/`) is deployed at
https://capsule-carnage-gamejam.onrender.com — download the game, hit JOIN,
and you're playing multiplayer instantly. Free tier: first join after a quiet
spell takes ~60 s while Render wakes the server.

The full web game ("Cube Fight!") has been ported: movement/chain camera,
reverse-tag scoring, pedestals + inventory, grapple/pads/teleporters,
machinegun/rockets/mines + coins, the build system, god mode, chat, menus,
and SFX. `PORT_BLUEPRINT.md` maps every system back to the web source.

## Controls

| Input | Action |
|---|---|
| WASD / arrows | Move (camera-relative) |
| Space | Hold to charge jump, release to fire (holds up to 4x) |
| Shift | Sprint (4 s stamina) |
| Mouse | Camera; scroll = chain length (or build reach while building) |
| Left click | Use active item (slot 1) |
| 2 / 3 | Swap that slot into slot 1 |
| R | Rotate build ghost 90° |
| T | Chat (`/vote yes`, `/vote no`, `/end`, `/help`) |
| Tab | Hold for scoreboard |
| Esc | Pause menu (resume / vote end game / quit) |
| ~ | God mode: fly (Space/E up, Shift/Q down), give items, place pedestals |
| F9 | Update your game (git pull) when the version banner says you're behind |
| F10 | Trigger a server redeploy when the banner says the server is behind |

## Version sync

The game sends its git hash on join; if it doesn't match the server you get a
banner naming who's behind. Both of us pushing to `main` keeps everyone on
the same build — the server auto-deploys from this repo.

## Dev

- Run the server locally: `cd server && npm install && npm start`, then
  launch the game with `FRIENDSLOP_SERVER=ws://localhost:3001`.
- `FRIENDSLOP_AUTOJOIN=1` skips the menu (headless testing).
- The spectator dashboard (overhead map, scoreboard, chat, diagnostics)
  is the server's web page — open the server URL in a browser.
