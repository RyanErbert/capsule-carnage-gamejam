# FRIENDSLOP-WEB → GODOT 4 PORT BLUEPRINT

Source files:
- `friendslop-web/public/game.js` (5,403 lines)
- `friendslop-web/server.js` (672 lines)
- `friendslop-web/public/index.html` (507 lines)

Stack: Three.js r128 (CDN) + cannon.js 0.6.2 (CDN) + GLTFLoader + socket.io 4.7.4 + Express. No build step. Game name in UI: **"Cube Fight!"**, `GAME_VERSION = 'ALPHA 0.1.01'` (game.js:1).

Target: `friendslop-mania` — "Capsule Carnage", Godot 4.6, `gl_compatibility` renderer, main scene `res://Scenes/testworld.tscn`, func_godot plugin, existing `res://Player/player.tscn` (`CharacterBody3D` + `player.gd`).

---

## 1. GAMEPLAY SYSTEMS INVENTORY (game.js)

### 1.1 Global tunables (game.js:1–68)
```js
MOVE_FORCE       = 60     // horizontal force, walking
SPRINT_FORCE     = 120    // horizontal force, sprinting
MAX_SPEED        = 9      // walk speed cap (units/s)
SPRINT_SPEED     = 18     // sprint speed cap
JUMP_IMPULSE     = 8      // base jump velocity.y
JOYSTICK_DEADZONE= 0.15
TAG_DISTANCE     = 1.5
TAG_COOLDOWN     = 4      // seconds (client mirror; server is authoritative)
SPRINT_DURATION  = 4      // seconds of stamina
SPRINT_REFILL_TIME = 6    // seconds to refill from empty (rate = 4/6 = 0.667/s)
JUMP_CD_AT_FULL  = 5      // declared, unused
```
Physics world (game.js:428–454): `world.gravity = (0, -20, 0)`, `NaiveBroadphase`, `solver.iterations = 10`. Contact materials: ground↔player `friction 0.7 / restitution 0.1`; player↔player `friction 0.3 / restitution 0.2` (dead code — see §3.6). Fixed step `PHYSICS_STEP = 1/60` with `maxSubSteps = 3` (game.js:4894, 4927). `PLAYER_RADIUS = 0.5` (game.js:457).

### 1.2 Renderer / scene setup (game.js:72–212)
- `PerspectiveCamera(60°, aspect, 0.1, 1000)`.
- Procedural sky: 1×256 canvas vertical gradient `#0a0a2e → #1a1a4e → #2d4a7a → #5a7faa → #8ab4d4` used as `scene.background` (game.js:115–127).
- `DirectionalLight(0xfff4e0, 1.5)` at (100,200,80), shadow map 2048², ortho box ±60, near 10 far 400, `normalBias 0.05`, `bias -0.0004`. **The sun is re-parented to the camera every frame** (game.js:5354–5355) — a moving shadow cascade hack.
- `HemisphereLight(0x87ceeb, 0x553322, 0.6)` + `AmbientLight(0xffffff, 0.3)` + an unlit `SphereGeometry(8)` sun billboard.
- Graphics settings persisted to `localStorage['gfxSettings']`: resolution `perf 0.75x / balanced 1.0x / sharp min(dpr,2)`, shadows `off / medium 1024 / high 2048`, toneMapping ACES @ exposure 1.1.

### 1.3 Level loading (game.js:380–426, 3–54)
`loadGameLevel(filename)` GLTF-loads `/levels/<file>`, sets cast+receive shadow on every mesh, applies max anisotropy, and pushes **every mesh into `levelMeshes[]`** — the raycast collision set. Fallback on error: a 5000×5000 green plane. Hardcoded `LEVEL_SPAWN_POINTS` per level (duplicated verbatim in server.js:54–102): level_1 = 12 points, level_2 = 14, level_3 = 15.

### 1.4 Player movement
See §3.

### 1.5 Camera (`updateCamera`, game.js:3358–3376, 3639–3706)
"Ball on a chain" third-person:
```js
BASE_CHAIN_LENGTH = 10   // scroll wheel, clamp 2..20; also [ and ] keys ±0.5
camHeight = chainLength * 0.58
camYaw = PI, camPitch = 0.4, CAM_PITCH_MIN/MAX = ∓1.4
MOUSE_SENSITIVITY = 0.003   (right-mouse drag only; no pointer lock)
CAM_DRAG_SPEED = 1.8, CAM_TURN_BOOST = 1.5, MOUSE_IDLE_DELAY = 0.6
```
Auto-follow: when `speed > 1.5` and mouse idle > 0.6 s, `camYaw` lerps toward `atan2(vx,vz)+PI` at rate `CAM_DRAG_SPEED * (1 + min(1, |diff|/(PI/2)) * 1.5) * delta`. Chain extends by `max(0, speed - MAX_SPEED) * 0.4` while sprinting. Position lerp `1 - exp(-6*delta)`, damped by `(1 - speedFactor*0.4)` where `speedFactor = speed/SPRINT_SPEED`. LookAt target lerps at `1 - exp(-15*delta)` toward `playerPos + (0,1,0)`. Camera wall collision: raycast from lookAt point to desired pos, pull in to `max(0.5, hitDist - 0.3)`.

### 1.6 Particle system (game.js:619–758)
Custom GPU `THREE.Points`, `MAX_PARTICLES = 2000`, additive blending, per-particle gravity.
- `spawnExplosion(x,y,z,isMine)` (686–706): 30 particles @ speed 12 (mine: 20 @ 8), orange-red ramp (mine: pure red), size 4–7 (mine 3–6), life 0.3–0.8 s, gravity −3; plus 8-particle gray smoke ring speed 3–5, size 5–8, life 0.6–1.0, gravity −1.
- `spawnTrailParticle` (708–718): rocket exhaust, color (1.0, 0.65, 0.2), alpha 0.8, size 2–3, life 0.2–0.3, gravity 0, 80% chance/frame/rocket.
- Teleporter idle VFX (5125–5137): 3 cyan-white sparks/frame/pad, upward v 2.8–5.6.

### 1.7 Audio (game.js:1012–1065)
`/music/background.mp3` looped, **volume starts at 0** — PageUp/PageDown ±0.1 while debug HUD open. `boostSound` = `/sound/boost.wav` @ 0.4. `jumpSounds[4]` @ 0.5. `bombSounds[6]` @ 2.0. `playWorldSound`: linear rolloff `base * (1 - dist/50)`, `MAX_SOUND_DIST = 50`.

### 1.8 Inventory (game.js:600–602, 760–991)
`MAX_INVENTORY = 3`; `inventory[]` of `{type, ammo}`; **slot 0 is active**. Digit2/Digit3 or clicking a slot calls `swapToFirst(index)`. Item→color: green `grapple, launch_pad, boost_pad, teleporter`; red `machinegun, rocket, mines`; yellow `block, wall, ramp, platform, bridge_gun`.
Ammo on pedestal pickup (game.js:4050): `machinegun 100, rocket 3, bridge_gun 3, wall 3, ramp 3, platform 3`, everything else `0` (0 = single-use, consumed via `shiftInventory`). Starting-weapon ammo (game.js:3908): `machinegun 100, rocket 3, mines 3, grapple 5`. `infiniteAmmo` sets `Infinity`.

### 1.9 Oddball / reverse-tag scoring (game.js:1007–1010, 3306–3318, 3708–3851)
Holder ("IT") gains **1 point/second** (server tick). Holder auto-tags on proximity `< TAG_DISTANCE 1.5` when cooldown expired. Holder gets back-face outline hull ×1.15 strobing gold; leader gets 👑 crown sprite + gold score sprite; sprites distance-scale `s = clamp(dist*0.15, 2, 6)`.

### 1.10 Fall respawn (game.js:5242–5256)
`airTime` accumulates while not grounded **and** `velocity.y < 0`; at `airTime > 10 s` → teleport to `randomSpawn()`, zero velocity. No death, no health, no kill plane.

### 1.11 Inactivity (game.js:1067–1216)
Client: 5 min timeout, red banner at 30 s remaining, then `returnToMenu()`. Server mirrors with `INACTIVITY_LIMIT = 5min`, swept every 30 s → `kicked` + disconnect.

### 1.12 `returnToMenu()` teardown (game.js:1086–1192)
Full state wipe + `socket.disconnect(); socket.connect();` for a fresh id.

---

## 2. NETWORK PROTOCOL

Transport: socket.io over Express (port 3001). Plus REST: `GET /api/levels`, `GET /api/models`, `GET /api/game-state` → `{playerCount, activeLevel, levelLocked, players:[{name,color,score}]}`.

### 2.2 Client → Server
| Event | Payload | Server behavior |
|---|---|---|
| `selectLevel` | `"level_2.glb"` | Ignored if `levelLocked`; else broadcast `levelChanged` (server.js:241) |
| `ready` | `{type, name, shape, skinColor, skinImage, model}` | Creates player at `randomSpawn()`, locks lobby, replies 8 snapshot events, broadcasts `newPlayer` + join msg, cancels vote, picks holder if none (252) |
| `playerMoved` | `{x,y,z,qx,qy,qz,qw,smoothing,godmode}` | Rebroadcast verbatim with `id` (293). Sent every frame, unthrottled (game.js:5334) |
| `jump` / `sprintStart` | — | → `playerJumped(id)` / `playerSprintStart(id)` (SFX only) |
| `godmodeEnter` | — | If sender is holder, transfer IT to random other + 4s CD (313) |
| `tagPlayer` | `targetId` | Only if sender is holder & CD expired (325) |
| `godmodeGive` | `"rocket"` | Echo `itemPickedUp` to sender (335) |
| `placePedestal` | `{id,x,y,z,ry,type}` green/red/yellow | → `pedestalPlaced` (339) |
| `removePedestal` | `id` | → `pedestalRemoved` (541) |
| `placeTeleporter` | `{a:{x,y,z}, b:{x,y,z}}` | → `teleporterPlaced` (346). **No remove event** |
| `placeBuild` | `{type,x,y,z,ry,rx,length?}` | Server assigns id → `buildPlaced` (351) |
| `removeBuild` | `id` | → `buildRemoved` (357) |
| `placeChannel` | `{id, nodes:[{x,y,z}]≥2, radius}` | Clamp 64 nodes, radius default 2.5 → `channelPlaced` (365) |
| `removeChannel` | `id` | → `channelRemoved` (376) |
| `placeModel` | `{id, model, x,y,z, ry}` | Validates `.glb` → `modelPlaced` (384) |
| `removeModel` | `id` | → `modelRemoved` (396) |
| `placePad` | `{x,y,z,type:'launch_pad'\|'boost_pad',dx,dz}` | Server id → `padPlaced` (404). **No remove event** |
| `placeMine` | `{x,y,z}` | Server id → `minePlaced` (502) |
| `triggerMine` | `id` | → `mineTriggered` + `explosion{type:'mine'}` (508) |
| `fireMachinegun` | `{start, velocity}` | Echo to all as `machinegunFired` with `owner` (410) |
| `machinegunHit` | `{targetId, dir}` | Victim loses `min(score,2)`, coins spawn, `applyImpulse{force:25}` (414) |
| `fireRocket` | `{start, velocity}` | Echo as `rocketFired` (443) |
| `triggerExplosion` | `{x,y,z}` | `explosion` + radial score loss + coins (447) |
| `pickupItem` | `pedestalId` | Respawn timer green 10s / red 20s / yellow 15s (517) |
| `collectCoin` | `coinId` | FCFS: `scores[sender] += value` (531) |
| `chat` | text | Trim+slice 200 → `chatMessage` (549) |
| `startEndVote` | — | Voters snapshot, initiator=yes, 30s timer (562) |
| `castVote` | bool | Re-tally (577) |

### 2.3 Server → Client
`spectatorPlayers` (on connect, powers menu birdseye), `currentPlayers {players, selfId}`, `newPlayer`, `playerMoved`, `playerDisconnected`, `playerJumped`, `playerSprintStart`, `holderChanged`, `tagCooldown(4000)`, `scores` (full map), `levelChanged`, `lobbyLocked`, `kicked`, `gameEnded`, `chatMessage`, `systemMessage`, `currentPedestals/pedestalPlaced/pedestalRemoved/pedestalsUpdated`, `currentTeleporters/teleporterPlaced`, `currentPads/padPlaced`, `currentBuilds/buildPlaced/buildRemoved`, `currentModels/modelPlaced/modelRemoved`, `currentChannels/channelPlaced/channelRemoved`, `currentMines/minePlaced/mineTriggered`, `itemPickedUp`, `machinegunFired/rocketFired`, `applyImpulse`, `explosion`, `coinsDropped`, `coinCollected`.

### 2.4 Authority split
**Server owns:** roster + last transform, scores, holder + tag CD, all placed-object registries, pedestal timers, level + lock, vote, inactivity, id generation.
**Client owns (zero validation):** all player physics/collision, hit detection (attacker's client emits `machinegunHit`/`triggerExplosion`), mine triggers, coin/pedestal pickup proximity, teleporter/pad activation, ammo, `infiniteAmmo`, respawn. **Trivially cheatable — decide whether the port moves authority server-side.**
**Never synced:** ammo, inventory, stamina, jump charge, godmode spawn-point edits.

### 2.5 Server console commands (server.js:614–672)
stdin: `kick <name|id>`, `list`, `spawn <item> <name|id>`.

---

## 3. PLAYER PHYSICS (exact)

### 3.1 Body
`createPlayerBody(shape, isLocal)` (game.js:3076–3088): `mass = isLocal ? 1 : 0`, `linearDamping 0.1`, `angularDamping 0.05` box/roundcube, `0.6` sphere/cylinder. Shapes (2958–2983): `roundcube` → if `smoothing < 0.75` `Box(halfExtent s)`, `s = 0.5*(1 - smoothing*0.3)`; else `Sphere(r)`, `r = 0.5*(0.85 + smoothing*0.15)`. Default `roundcubeSmoothing = 0.25` → half-extent **0.4625**. `sphere` → Sphere(0.5), `cylinder` → Cylinder(0.5,0.5,1,16).

### 3.2 Acceleration & friction
No explicit friction term; deceleration = linearDamping 0.1 + ground contact friction 0.7 + hard velocity clamp.
`force = sprinting ? 120 : 60`, applied camera-relative at body center, Y=0.
Speed cap (3202–3230): `speedCapCurrent` lerps toward `sprinting ? 18 : 9` at `min(1, 2.5*delta)`; if `!isGrappling && hSpeed > cap` renormalize horizontal velocity. **Grappling bypasses cap.** The soft cap is what lets explosions/boost pads launch past normal speed and decay back — do not replace with hard clamp.

### 3.3 Sprint
Drains 1.0/s from 4.0; at 0 → exhausted until fully refilled (0.667/s). **Ball morph** (3090–3140): while sprinting `sprintMorphT` 0→1 at 3/s; `roundcubeSmoothing = 0.25 + 0.75*t`; geometry re-lerped each frame; at smoothing 0.75 the cannon body is swapped Box→Sphere (preserving state) — this makes sprinting "roll".

### 3.4 Jump — charge system
`CHARGE_RATE = 3, MAX_CHARGE_MULT = 4, COYOTE_TIME = 0.28, JUMP_BUFFER_TIME = 0.25`.
Space held charges 1→4 at 3/s (only when CD ≤ 0). Fires on **release**: `velocity.y = 8 * jumpCharge` (max 32), then `jumpCooldownTimer = jumpCharge` seconds. Airborne release sets buffer 0.25s; buffered jump on landing fires flat `8` with 1s CD. `canJump = (now - lastGroundedTime) < 0.28`.

### 3.5 Ground / wall / ceiling — raycast, not AABB
**No static colliders for the level.** Collision via `THREE.Raycaster` against `levelMeshes` + a single infinite `CANNON.Plane` teleported under the player each frame.
`updateGroundPlane` (480–519): down-ray from `y+2`, far 50; first hit with `point.y <= p.y + 0.05`; plane y = surfaceY (−1000 if none); un-embed only if `0.35 < (surfaceY + 0.5 - p.y) < 1.2`; `rayGrounded = (p.y - surfaceY) < 0.7`.
`resolveWallCollisions` (521–568): 8 horizontal rays length 0.55, push out + cancel velocity along dir; ceiling = 5 up-rays from `y+0.3`, reach 1.0, clamp `p.y = hitY - 0.6`. Both skip `userData.thinPlatform` (bridges).
Frame order (4915–4929): `handleMovement` → pending impulses → `updateGroundPlane` → `world.step(1/60, delta, 3)` → `resolveWallCollisions` → `syncMeshToBody`.
`GROUP_GROUNDPLANE = 2`: coins mask out the tracking plane and do their own down-raycast.

### 3.6 Landing on players — NOT IMPLEMENTED
README advertises it but `remoteBodies`/`outlineMeshes` (579–580) are never written. Remote players are pure visuals lerped at 0.3/frame (5260–5309). Player↔player interactions: tag < 1.5, machinegun hit sphere 1.5, rocket fuse 1.2, explosion radius. **Solid players would be new behavior, not a port.**

### 3.7 Visual offset math (3321–3356, 5267)
Mesh lifted by `(0.5 - s) + outlineLift` where outlineLift = 0.075 when IT hull visible. Local sync lerp 0.45; remotes 0.3. `physHalfFromSmoothing(sm)` reconstructs offset for remotes from networked `smoothing`.

---

## 4. BUILDING / ITEMS / PREFABS

### 4.1 Pedestals (game.js:1218–1232, 1394–1422, 5224–5240; server.js:106–127)
Model `/prefabs/item_ped.glb` + procedural `OctahedronGeometry(0.3)` crystal at y 1.2 colored by type, spins 2 rad/s, bobs `sin(t*0.003 + x)*0.1`. Visible only when `currentItem != null`. Pickup: proximity < 1.8, requires inventory < 3 and !godmode. Server rolls random item from category on respawn timer: **green 10 s, red 20 s, yellow 15 s**. Categories: green `grapple, launch_pad, boost_pad, teleporter`; red `machinegun, rocket, mines`; yellow `block, wall, ramp, platform, bridge_gun`.

### 4.2 Build blocks (game.js:1978–2049, 3384–3416, 4099–4152, 4968–5059)
**4-unit voxel grid**, snap `cell = floor(target/4)*4 + 2`.
| Type | Mesh | Physics |
|---|---|---|
| block | Box 4×4×4 | Box(2,2,2) |
| wall | Box 4×4×1, offset −2 along facing axis | Box(2,2,0.5) |
| ramp | right wedge 4×4×4 | ConvexPolyhedron 6 verts/5 faces |
| platform | Box 4×1×4, `finalY -= 1.5` | Box(2,0.5,2) |
| bridge | Box 4×0.2×length (≤100) | none — `thinPlatform`, ground-ray only |
Material `0xaaaaaa` roughness 0.8 DoubleSide; bridge holographic `0x00ffff` 0.6. `R` rotates 90° steps. Scroll = `buildPlacementDistance` (16, 4..100) or `buildPlaneY` ±4 in godmode. Raycast against level+builds, offset 0.1 along normal. Drag-build: mousedown locks axis, places on cell change. Overlap rejection → red ghost. Grid viz: 9³ points at 4u + `GridHelper(400,100)`, fade `1 - smoothstep(50,150,dist)`.

### 4.3 Bridge gun (901–914, 5060–5087)
Fires from `pos + (0,-0.4,0)` to aim point, length ≤ 100. `placeBuild{type:'bridge', midpoint, ry, rx, length}`.

### 4.4 Channels — swept half-pipe (1475–1645, 4161–4236)
`CHANNEL_RADIUS 2.5, FACETS 12, MAX_RELAX 0.6`, post radius 0.35.
1. `relaxChannelAnchors`: interior points lerp toward neighbor midpoint by `clamp((angle - PI/7)/(PI*0.6),0,1)*0.6`.
2. `CatmullRomCurve3(centripetal, 0.5)`; `N = clamp(ceil(len/1.5), 2, 260)` rings.
3. 13 verts sweeping −PI/2..+PI/2, opening faces world-up (no banking).
4. One cannon body per slice, 12 oriented `Box(segLen/2, width/2, 0.15)` panels.
5. Posts: down-ray from anchor, top at `a.y - r*0.15`, fallback 14, skip < 0.25.
Authoring: click nodes, scroll ±0.5 height, Enter finish, Backspace undo, Esc cancel.

### 4.5 Placeable models (1424–1691, 3564–3586)
Godmode-only, from `/api/models`. Ghost blue-tinted; R/scroll rotates π/8. Requires flatness `normal·up >= 0.85`. Placed models join `levelMeshes` (raycast-collidable, no bodies).

### 4.6 Pads (872–880, 4079–4097, 5313–5331)
Box 1.2×0.1×1.2, `0x44ff44` emissive. Place ≤ 10 from player. Trigger radius 1.5:
- launch_pad: if `vy < 16` → `vy = 32` + jump SFX.
- boost_pad: if `hSpeed < 27` → `velocity = (dx*45, 5, dz*45)`, cap raised to 45.

### 4.7 Teleporters (881–895, 4057–4077, 5103–5120)
Two-click placement (first click = ghost, no consume). `CylinderGeometry(0.8,0.8,0.2,16)`, `0x33ccff`. Trigger 1.5, dest +1.5 Y, cooldown 1.5 s.

### 4.8 Grapple (865–871, 3232–3247, 4932–4943)
Velocity **set directly** to `dir * 40` (all axes), cap bypassed. Release when dist < 2, Space, or jump buffer. Green line drawn.

---

## 5. PROJECTILES & EXPLOSIONS

### 5.1 Aiming (809–852, 937–953)
Raycast from camera through mouse NDC (mobile: center) vs `levelMeshes`; hit beyond 15u → aim at it, else `origin + dir*150`. Direction from `playerPos + (0,0.4,0)`. Lock-on: nearest remote with projected dist ∈ [2,80] and perpendicular < 3.0.

### 5.2 Machinegun (955–991, 5140–5158)
`setInterval` 80 ms (12.5 rps). Spread ±0.02/axis renormalized. Muzzle `origin + dir*2.0`, **speed 200**, life 2 s. CCD raycast `speed*delta + 0.1`; `y < 0` kills. Hit sphere 1.5; only owner emits `machinegunHit`. Damage `min(score,2)`; coins launch `vx = dir.x*14 + cos(a)*horiz`, `vy = max(dir.y*16,8) + rand*16`, horiz 6..28. Knockback 25: receiver does `y += 0.1` then adds `dir*25`, raises cap.

### 5.3 Rocket (915–929, 4275–4287, 5160–5188)
Speed **60**, cooldown **2 s**, muzzle `origin + dir*2.5`, life 5 s, gravity **−8** (world is −20; debug arc draws −20 — known mismatch). Detonation: level ray, down-ray 0.5, `y < 0`, proximity 1.2 to non-owner, or expiry. Only owner emits `triggerExplosion`.

### 5.4 Mines (872–875, 4315–4326, 5193–5196)
`Cylinder(0.4,0.4,0.1,12)` red. Place ≤ 10. Trigger within **1.2** (no owner immunity, no arming delay).

### 5.5 Explosions (server.js:447–500; game.js:4289–4313)
Score damage: <1 → 100%, <2 → 50%, <4 → 25%, <6 → 12.5%, <8 → 6.25%; `ceil(score*pct)`; coin visuals capped 15, last coin carries remainder. Client knockback (queued `pendingImpulses`, applied top of next frame with `popY` ground-unstick):
- Rocket: radius 8, `dir.y = max(0.5, dir.y+1.0)` renorm, `force = (8-dist)*7`, popY 1.5.
- Mine: radius 6, `dir.y = max(0.3, dir.y+0.4)`, `force = (6-dist)*9`, popY 1.0.

### 5.6 Coins (4328–4353, 5198–5222; server.js:207–216)
Client cannon `Cylinder(0.3,0.3,0.1,8)` mass 1, mask `~GROUP_GROUNDPLANE`, own down-raycast with `vy *= -0.3` bounce, `vx,vz *= 0.6`. `collectTimer 1.0 s`, pickup radius 1.5, timer 999 after emit. Server despawns after 15 s.

---

## 6. UI SCREENS

### 6.1 Main menu (index.html:428–498, game.js:2082–2656)
2×2 grid: PLAYER (name max 16, random default from `['Blockhead','Squarold','Edgelord','Hexahedron','Rhombert','Squaredward']`, live WebGL cube preview, color picker, character None/Rat `/players/rat.glb`), GAME SETTINGS (type Reverse Tag [CTF/DM disabled], score limit 1000 [unused], starting weapon none/machinegun/rocket/mines/grapple, infinite ammo), MAP (carousel with live rotating 3D preview per level, emits `selectLevel`), PLAYERS (`/api/game-state` polled 4 s). Pixel title "CUBE FIGHT!" in 04b_03 with flickering shadows. Lobby lock disables settings when game in progress.

### 6.2 Menu birdseye spectator (4839–4891)
When players exist: camera orbits focused player `dist 16, height 10, angle t*0.2`, cycles targets every 6 s, `1-exp(-1.5*delta)` smoothing.

### 6.3 In-game HUD
Tip text fades after 10 s. Inventory top-left: slot 0 @ 80px, others 50px, category-color borders, ammo red (∞ blue). Meters 180×10 bottom-center: SPRINT (green/red exhausted), JUMP (charge `(c-1)/3` green, cooldown red drain). `#leader-display` top center 👑. Toast 1.5 s. Red inactivity banner.

### 6.4 Scoreboard (hold Tab)
Sorted desc; `[IT]` red for holder, 👑 gold for leader.

### 6.5 Chat (289–378)
`T` opens (deferred focus). Bottom-right, max 8 rows, fade 9 s. System msgs gold italic. `/vote yes|no`, `/vote`, `/end`, `/endgame`, `/help`. keydown stopPropagation.

### 6.6 Escape menu (214–287)
RESOLUTION / SHADOWS / ENHANCED COLOR cycles, VOTE END GAME, RESUME.

### 6.7 Vote system (server.js:135–174, 562–585)
Voters = `readyIds` snapshot, initiator auto-yes, threshold `floor(n/2)+1`, passes early, fails early when `yes + undecided < needed`, 30 s timer. New joiner kills vote. Pass → `endGame()`: zero scores, clear holder/readyIds, unlock lobby, `gameEnded`.

### 6.8 Godmode (F4) (1218–1345, 1347–1392, 4367–4394)
Enter: mass 0, free-fly YXZ cam, `buildPlaneY = round(camY/4)*4 - 4`, spawn markers + tool menu, emits `godmodeEnter` (server hands off IT). Exit: body 5u in front of cam, mass 1. Fly WASD + Space/E up + Q/Shift down @ 40; arrows rotate. Tools: pedestals (4 kinds), Build Block/Wall/Ramp/Platform/Bridge/Teleporter/Channel/Delete, MODELS list; GIVE TO PLAYER grid (12 items → `godmodeGive`). Blue ghost / red illegal / red delete highlight. Undo stack 15 (Ctrl+Z). Remotes see godmode players as 30% ghosts (via `godmode` flag).

### 6.9 Debug HUD (backtick) (4396–4837)
Green terminal panel (FPS, speed/cap, vel, pos, state, sprint, charge, aim, item, target, projectile counts, tag CD, score, chain, smoothing, music vol) + gizmos: axis gimbal, aim line, spread cone (3 rings @ CONE_LENGTH 30), rocket arc (30 samples, 3 s, gravity −20), hit marker ring, DOM crosshair, cyan front arrow. Keys: `,`/`.` smoothing ±0.05, PgUp/PgDn music.

### 6.10 Mobile (2692–2877)
UA/touch detect. 120px joystick (r 50, deadzone 0.15), 80px JUMP, TAB/CON/GOD bar. **Double-tap joystick = sprint.** DeviceOrientation tilt (`gamma` X, `beta-30` Z, deadzone 3°, full 25°) additive with joystick. Single-drag cam 0.005. Tap = use item; hold = machinegun.

---

## 7. ASSETS

| Path | Files | Refs |
|---|---|---|
| levels/ | level_1..3.glb | game.js:395, 2610; server.js:23 |
| models/ | building_1..5, cactus, grass, tree_1 (.glb) + buildings.blend | game.js:1650; server.js:32 |
| players/ | rat.glb (`Armature\|idle`, `Armature\|walk` clips) | game.js:2240, 3029 |
| prefabs/ | item_ped.glb | game.js:1223 |
| music/ | background.mp3 (2.4 MB) | game.js:1013 |
| sound/ | boost.wav, jump_1..4.wav, bomb_1..6.wav (~19.9 MB total) | game.js:1019–1037 |
| fonts | 04B_03__.TTF | index.html:8 |

Rat handling (3029–3057): scale `(0.7/maxDim)*1.5`, recentered, Y offset `-bottom*scale - 1.2`, `ratPivot` yaw-lerps toward `atan2(vx,vz)` at `delta*10`; walk `timeScale = max(0.5, speed/9)`; crossfade 0.2 s @ speed 1.5.

**Levels have no collision geometry** — collision is the render mesh via raycast. The Godot project's func_godot/TrenchBroom pipeline replaces this outright.

---

## 8. GODOT 4 MAPPING

### 8.1 Unit scale — decide first
Web: 1-unit cube player, speeds 9–18, gravity 20. Recommended: keep web numbers 1:1 (1u = 1m, capsule r 0.5), set func_godot map scale to match.

### 8.2 Player
`CharacterBody3D` + capsule/sphere r 0.5. Delete `updateGroundPlane`/`resolveWallCollisions` — use real static colliders + `move_and_slide()`. `floor_snap_length` 0/0.3, `is_on_floor()`, `get_last_slide_collision()`.
```gdscript
const MOVE_ACCEL := 60.0
const SPRINT_ACCEL := 120.0
const MAX_SPEED := 9.0
const SPRINT_SPEED := 18.0
const JUMP_IMPULSE := 8.0
const CHARGE_RATE := 3.0
const MAX_CHARGE_MULT := 4.0
const COYOTE_TIME := 0.28
const JUMP_BUFFER := 0.25
const SPRINT_DURATION := 4.0
const SPRINT_REFILL := 6.0
const LINEAR_DAMPING := 0.1   # velocity *= exp(-0.1*delta)
const GRAVITY := 20.0
```
Keep the **soft** speed cap (lerp at 2.5/s, renormalize when over, skip while grappling). Jump charge/coyote/buffer port verbatim.
**Ball morph:** ShaderMaterial `mix(pos, normalize(pos)*0.5, smoothing)` uniform; swap CollisionShape3D Box↔Sphere at 0.75; sync `smoothing` float.

### 8.3 Camera
`Player > CameraPivot(Node3D) > SpringArm3D > Camera3D` (margin 0.3 = wall collision for free). Port yaw auto-follow constants unchanged. `spring_length = clamp(base + max(0, speed-9)*0.4, 2, 20)`. NOTE: web uses right-drag look (free cursor, NDC aim rays); existing player.gd uses MOUSE_MODE_CAPTURED — pick deliberately; build/aim needs a cursor or a center crosshair.

### 8.4 Networking
**Path A (recommended): keep Node server, `WebSocketPeer` in Godot** with JSON envelope `{"e": "...", "d": {...}}`; strip socket.io → bare `ws`. All 40 events port 1:1; REST → `HTTPRequest`. Preserves lobby/vote/pedestal logic with zero rewrite.
**Path B: Godot high-level multiplayer.** ENet (or WebSocketMultiplayerPeer) + headless Godot server; `MultiplayerSynchronizer` for transform+`smoothing`+`godmode` @ ~20 Hz; `@rpc("any_peer", "call_local", "reliable")` for placement/chat/vote; unreliable for fire cosmetics; one `sync_world_state` RPC replaces the 8 `current*` snapshots.
Either way preserve the two-phase connect (`spectatorPlayers`) → `ready` handshake — it powers the menu spectator and game-info panel.

### 8.5 System mapping table
| Web | Godot |
|---|---|
| levelMeshes raycast | func_godot StaticBody3D + trimesh (delete the hacks) |
| Spawn arrays ×2 | func_godot `info_player_start` → Marker3D group "spawn" |
| Pedestals | Area3D r 1.8 + item_ped.glb + crystal; server Timer respawn |
| Build blocks | Pooled StaticBody3D scenes; ramp = ConvexPolygonShape3D; snap floor(p/4)*4+2 |
| Bridge thinPlatform | separate collision layer or `one_way_collision` |
| Channels | Path3D + CSGPolygon3D (PATH mode, interval 1.5, 12-seg half-circle) baked + trimesh; keep `relaxChannelAnchors` |
| Models | MeshInstance3D + create_trimesh_collision(); MultiMesh for grass |
| Particles | GPUParticles3D scenes (explosion/mine/smoke/trail/sparks); verify GL Compat, else CPUParticles3D |
| Bullets | data array + intersect_ray + MultiMesh tracers (no nodes @ speed 200) |
| Rockets | Area3D + trail; manual `vy -= 8*delta` |
| Coins | RigidBody3D + Area3D pickup 1.5 (delete down-raycast hack) |
| Pads/teleporters/mines | Area3D + cooldown Timer |
| Grapple | velocity override + line mesh |
| Explosion dmg | server distance loop verbatim |
| Knockback | apply top of `_physics_process` before move_and_slide; keep popY |
| UI | Control scenes; Label3D for names/crowns; ProgressBar meters; RichTextLabel+LineEdit chat |
| Level previews | SubViewport per card |
| Pixel font | TTF, antialiasing None, subpixel Disabled |
| Sky | WorldEnvironment ProceduralSkyMaterial (#0a0a2e → #8ab4d4) |
| Camera-follow sun | plain DirectionalLight3D (delete hack) |
| Outline hull | next_pass material `grow 0.075` + cull_front |
| Positional audio | AudioStreamPlayer3D max_distance 50 linear; WAV→OGG |
| Music | AudioStreamPlayer + Music bus + volume slider (fix start-at-0 bug) |
| Settings | ConfigFile user://settings.cfg; scaling_3d_scale; ACES exposure 1.1 |
| Godmode | separate Camera3D + fly controller; disable CollisionShape3D |
| Mobile | TouchScreenButton + virtual stick; Input.get_accelerometer() |

### 8.6 Port order
1. Player physics + camera vs existing func_godot map (the feel)
2. Network: ready/playerMoved/playerDisconnected + remote ghosts
3. Oddball scoring + tag + holder visuals (the game loop)
4. Pedestals + inventory + cheap items (grapple, pads, teleporter)
5. Weapons + explosions + coins
6. Build system
7. Menus, chat, vote, godmode

### 8.7 Known bugs / port decisions
- Players are non-solid despite README (remoteBodies dead code) — decide.
- scoreLimit/gameType collected but never used — no win condition except vote.
- JUMP_CD_AT_FULL unused.
- Music starts at volume 0 (only PageUp in debug HUD raises it).
- placeTeleporter/placePad have no remove events.
- Godmode spawn edits local-only, never persisted.
- Client-authoritative damage (attacker emits hits) — cheatable.
- Rocket gravity −8 vs world −20; debug arc uses −20 (mismatch).
- playerMoved unthrottled at render framerate.
