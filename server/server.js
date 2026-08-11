const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');
const readline = require('readline');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.use(express.static(path.join(__dirname, 'public')));
app.use('/levels', express.static(path.join(__dirname, 'levels')));
app.use('/music', express.static(path.join(__dirname, 'music')));
app.use('/sound', express.static(path.join(__dirname, 'sound')));
app.use('/prefabs', express.static(path.join(__dirname, 'prefabs')));
app.use('/players', express.static(path.join(__dirname, 'players')));
app.use('/models', express.static(path.join(__dirname, 'models')));

let activeLevel = 'level_1.glb';
let levelLocked = false;

// Build hash for client version checks. Render provides RENDER_GIT_COMMIT;
// locally we read the repo's .git (server/ lives one level below repo root).
function readGitCommit() {
  if (process.env.RENDER_GIT_COMMIT) return process.env.RENDER_GIT_COMMIT.slice(0, 7);
  try {
    const gitDir = path.join(__dirname, '..', '.git');
    const head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
    if (!head.startsWith('ref: ')) return head.slice(0, 7);
    const ref = head.slice(5);
    const refPath = path.join(gitDir, ...ref.split('/'));
    if (fs.existsSync(refPath)) return fs.readFileSync(refPath, 'utf8').trim().slice(0, 7);
    const packed = fs.readFileSync(path.join(gitDir, 'packed-refs'), 'utf8');
    for (const line of packed.split('\n')) {
      if (line.endsWith(' ' + ref)) return line.split(' ')[0].slice(0, 7);
    }
  } catch (e) { /* not running from a clone */ }
  return '';
}
const SERVER_BUILD = readGitCommit();
if (SERVER_BUILD) console.log(`Server build: ${SERVER_BUILD}`);
const STARTED_AT = Date.now();

app.get('/api/levels', (req, res) => {
  try {
    const files = fs.readdirSync(path.join(__dirname, 'levels')).filter(f => f.endsWith('.glb'));
    res.json(files);
  } catch (e) {
    res.json(['level_1.glb']);
  }
});

app.get('/api/models', (req, res) => {
  try {
    const files = fs.readdirSync(path.join(__dirname, 'models')).filter(f => f.endsWith('.glb'));
    res.json(files);
  } catch (e) {
    res.json([]);
  }
});

app.get('/api/game-state', (req, res) => {
  const playerList = [...readyIds]
    .filter(id => players[id])
    .map(id => ({ name: players[id].name, color: players[id].skinColor, score: scores[id] || 0 }))
    .sort((a, b) => b.score - a.score);
  res.json({ playerCount: readyIds.size, activeLevel, levelLocked, players: playerList });
});

const players = {};
const readyIds = new Set();
const COLORS = ['#ff4444', '#4488ff', '#44cc44', '#ffcc00'];
let colorIndex = 0;

const LEVEL_SPAWN_POINTS = {
  'level_1.glb': [
    { x: -39.64, y: 0.53, z: -31.33 },
    { x: -78.69, y: 0.53, z: -61.07 },
    { x: -57.51, y: 7.10, z: -60.48 },
    { x: -2.64, y: 0.53, z: -255.53 },
    { x: -46.90, y: 0.53, z: -309.56 },
    { x: -49.36, y: 0.46, z: -193.42 },
    { x: 46.60, y: 15.12, z: -173.82 },
    { x: 22.30, y: 0.53, z: -89.89 },
    { x: -81.11, y: 3.84, z: -464.15 },
    { x: -76.45, y: 0.53, z: -383.61 },
    { x: -60.66, y: 10.85, z: -160.14 },
    { x: -15.82, y: 35.39, z: -24.13 },
  ],
  'level_2.glb': [
    { x: -4.43, y: 161.88, z: -21.1 },
    { x: -5.72, y: 160.66, z: -3.36 },
    { x: 22.12, y: 168.59, z: 3.8 },
    { x: 24.99, y: 160.97, z: 3.07 },
    { x: -27.36, y: 161.88, z: 3.34 },
    { x: -27.66, y: 149.69, z: -28.19 },
    { x: -4.56, y: 145.73, z: -17.8 },
    { x: -4.86, y: 154.87, z: 1.14 },
    { x: 12.11, y: 160.05, z: 22.92 },
    { x: 37.7, y: 163.56, z: 20.13 },
    { x: 37.88, y: 163.56, z: -5.22 },
    { x: -34.88, y: 161.88, z: 18.03 },
    { x: 16.88, y: 151.22, z: 22.6 },
    { x: 13.89, y: 155.79, z: -3.39 },
  ],
  'level_3.glb': [
    { x: -81.52, y: -15.48, z: 22.12 },
    { x: -140.34, y: -18.29, z: 7.88 },
    { x: -145.72, y: 14.5, z: -21.92 },
    { x: -120.18, y: -23.09, z: -61.03 },
    { x: -156.08, y: -0.11, z: -116.92 },
    { x: -136.33, y: -15.51, z: -128.25 },
    { x: -91.79, y: -13.65, z: -107.49 },
    { x: -91.7, y: -17.65, z: -72.68 },
    { x: -184.28, y: -15.48, z: 52.21 },
    { x: -179.75, y: -15.48, z: 40.45 },
    { x: -174.78, y: -15.48, z: 50.9 },
    { x: -117.39, y: -15.6, z: 87.12 },
    { x: -91.7, y: -15.58, z: -26.09 },
    { x: -196.07, y: -15.48, z: -84.23 },
    { x: -169.17, y: -16.3, z: -6.25 },
  ],
};
function getSpawnPoints() { return LEVEL_SPAWN_POINTS[activeLevel] || LEVEL_SPAWN_POINTS['level_1.glb']; }
function randomSpawn() { const pts = getSpawnPoints(); return pts[Math.floor(Math.random() * pts.length)]; }

// --- Creative-level terrain state (Godot client) ---
// The painted pixel grid (32 ints, one bitmask per row) plus every brush
// stroke since, replayed to late joiners so everyone sculpts the same world.
// creativeLayers: 4 paintable layers, bottom to top — ground (default solid;
// erased = pit), main, +1, +2. Each layer is 32 uint32 row bitmasks, bit
// (31-col) = filled. Bedrock below the ground layer is implicit/uneditable.
let creativeLayers = null;   // [4][32] after normLayers
let terrainEdits = [];
let paintLayers = null;  // in-progress editor canvas, live-synced between painters

// --- Spawn zones ---
// Each painter can claim a spawn pixel in the editor. The block around it is
// a DEADZONE (unpaintable, unsculptable) so the ground their respawns land on
// stays predictable — respawn placement itself is client-side, scattered
// procedurally inside the zone. No default zone: with nothing claimed there
// are no deadzones and everyone uses the map's scattered spawn points.
const DEADZONE_R = 10;              // meters (max-norm), ~a 5x5 pixel block
const ZONE_SEPARATION = 5;          // pixels between two players' spawn pixels

const spawnZones = {};              // socket.id -> [r, c]

function zoneList() {
  return Object.values(spawnZones);
}
function homeWorlds() {
  return zoneList().map(h => ({ x: -64 + h[1] * 4 + 2, z: -64 + h[0] * 4 + 2 }));
}
function inDeadzone(r, c) {
  return zoneList().some(h => Math.abs(r - h[0]) <= 2 && Math.abs(c - h[1]) <= 2);
}

// Highest painted layer at a pixel (-1 = pit), and the world Y its surface
// meshes out at: 8 m slabs stacked over bedrock, surface ~1 m into the slab.
function pixelTop(r, c) {
  if (!creativeLayers) return 0;
  const bit = 31 - c;
  let top = -1;
  for (let li = 0; li < 4; li++) if ((creativeLayers[li][r] >>> bit) & 1) top = li;
  return top;
}
function surfaceY(top) { return top < 0 ? -7 : top * 8 + 1; }

function normLayers(g) {
  if (!g || !Array.isArray(g.layers) || g.layers.length !== 4) return null;
  const out = [];
  for (const rows of g.layers) {
    if (!Array.isArray(rows) || rows.length === 0 || rows.length > 64) return null;
    out.push(rows.slice(0, 64).map(n => Number(n) >>> 0));
  }
  return out;
}

// --- Global game settings (server-authoritative, alert on change) ---
// These belong to the GAMEMODE: they're chosen in the lobby and frozen once a
// game is live. Build mode is the exception - changing them live is its point.
const MODES = ['slayer', 'sandbox', 'build'];
const gameSettings = {
  mode: 'slayer',            // 'slayer' | 'sandbox' | 'build'
  slayer: true,              // derived from mode; coins are health (start 100)
  infiniteAmmo: true,        // default ON per Ryan
  selfAssign: true,          // creative: players may spawn items for themselves
  pedestals: true,           // auto item pedestals when a map generates
  speedScale: 0.7,           // movement tuning
  jumpScale: 0.58,           // ~1/3 of web jump HEIGHT (velocity scales by sqrt)
  gravityScale: 1.0
};

// --- Slayer: coins ARE health. Players spawn with 100, damage sheds coins,
// zero triggers a death explosion (clients carve + scorch) and a respawn
// countdown, after which the server restores 100.
const SLAYER_START = 100;
const RESPAWN_MS = 4000;
const deadUntil = {};   // socket.id -> timestamp while dead

// --- God-mode drones ---
// While a player flies their drone the client reports its position in
// playerMoved ({drone:{x,y,z}}), which makes it a shootable target: 3 bullet
// hits (or one nearby blast) pop it, the view snaps back to the body, and the
// owner pays 10 health — but a popped drone can never kill you.
const DRONE_HP = 30;
const DRONE_LOSS = 10;

function damageDrone(id, dmg) {
  const p = players[id];
  if (!p || !p.drone) return;
  p.droneHp = (typeof p.droneHp === 'number' ? p.droneHp : DRONE_HP) - dmg;
  if (p.droneHp > 0) {
    io.emit('droneHealth', { id, hp: p.droneHp });
    return;
  }
  const at = p.drone;
  p.drone = null;
  delete p.droneHp;
  io.emit('droneDestroyed', { id, x: at.x, y: at.y, z: at.z });
  io.emit('explosion', { x: at.x, y: at.y, z: at.z, type: 'mine' });
  if (gameSettings.slayer && typeof scores[id] === 'number') {
    scores[id] = Math.max(1, scores[id] - DRONE_LOSS);
    io.emit('scores', scores);
  }
}

function startingScore() { return gameSettings.slayer ? SLAYER_START : 0; }

function isDead(id) { return (deadUntil[id] || 0) > Date.now(); }

function checkDeath(id) {
  if (!gameSettings.slayer || !players[id] || isDead(id)) return;
  if (scores[id] > 0) return;
  scores[id] = 0;
  deadUntil[id] = Date.now() + RESPAWN_MS;
  const pos = { x: players[id].x, y: players[id].y, z: players[id].z };
  io.emit('playerDied', { id, ...pos, respawnMs: RESPAWN_MS });
  sysMsg(`${players[id].name} exploded.`);
  // The death blast damages everyone nearby (chain deaths welcome).
  explosionDamage(pos, id);
  // A tiny generator is left at the corpse (~30 energy, varying)
  const minis = activeGenerators.filter(g => g.mini);
  if (minis.length >= MAX_MINI_GENS) {
    const oldest = minis[0];
    activeGenerators.splice(activeGenerators.indexOf(oldest), 1);
    io.emit('generatorRemoved', oldest.id);
  }
  const miniGen = {
    id: 'gen-death-' + Date.now().toString(36) + Math.random().toString(36).substr(2, 4),
    x: pos.x, y: pos.y + 0.8, z: pos.z, holder: null, owner: id,
    energy: 20 + Math.floor(Math.random() * 21), mini: true
  };
  activeGenerators.push(miniGen);
  io.emit('generatorPlaced', miniGen);
  io.emit('scores', scores);
  setTimeout(() => {
    delete deadUntil[id];
    if (players[id]) {
      scores[id] = startingScore();
      io.emit('scores', scores);
      io.emit('playerRespawned', id);
    }
  }, RESPAWN_MS);
}

// Falloff damage + coin spray around a blast. Slayer uses flat damage bands
// (percentages can never kill); the old sandbox mode keeps its pct-of-score.
function explosionDamage(pos, excludeId) {
  const droppedCoins = [];
  for (const [id, player] of Object.entries(players)) {
    if (id === excludeId || isDead(id)) continue;
    const dx = player.x - pos.x;
    const dy = player.y - pos.y;
    const dz = player.z - pos.z;
    const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);

    let pointsLost = 0;
    if (gameSettings.slayer) {
      if (dist < 1.5) pointsLost = 55;
      else if (dist < 3) pointsLost = 40;
      else if (dist < 5) pointsLost = 25;
      else if (dist < 7) pointsLost = 12;
      else if (dist < 9) pointsLost = 5;
      pointsLost = Math.min(pointsLost, scores[id] || 0);
    } else {
      let pctLost = 0;
      if (dist < 1) pctLost = 1.0;
      else if (dist < 2) pctLost = 0.5;
      else if (dist < 4) pctLost = 0.25;
      else if (dist < 6) pctLost = 0.125;
      else if (dist < 8) pctLost = 0.0625;
      if (pctLost > 0 && scores[id] > 0) pointsLost = Math.ceil(scores[id] * pctLost);
    }

    if (pointsLost > 0 && scores[id] > 0) {
      scores[id] -= pointsLost;
      const coinsToSpawn = Math.min(pointsLost, 15); // Cap visuals at 15
      for (let i = 0; i < coinsToSpawn; i++) {
        const coinId = Date.now().toString(36) + Math.random().toString(36).substr(2);
        // Spray coins in every direction with widely varying speed so they
        // scatter instead of fountaining onto one spot.
        const ang = Math.random() * Math.PI * 2;
        const horiz = 5 + Math.random() * 24;          // big horizontal speed spread
        const up = 5 + Math.random() * 22;             // big vertical speed spread
        const radial = 0.3 + Math.random() * 0.8;      // partial pull along blast dir
        const safeDist = dist > 0.001 ? dist : 1;
        const coin = {
          id: coinId,
          x: player.x + (Math.random() - 0.5) * 0.8,
          y: player.y + 1 + Math.random() * 0.6,
          z: player.z + (Math.random() - 0.5) * 0.8,
          vx: (dx / safeDist) * 5 * radial + Math.cos(ang) * horiz,
          vy: up,
          vz: (dz / safeDist) * 5 * radial + Math.sin(ang) * horiz,
          rx: (Math.random() - 0.5) * 30, ry: (Math.random() - 0.5) * 30, rz: (Math.random() - 0.5) * 30,
          // Last coin carries the remainder so total shed health is conserved
          value: i === coinsToSpawn - 1 ? pointsLost - (coinsToSpawn - 1) : 1,
          createdAt: Date.now()
        };
        activeCoins.push(coin);
        droppedCoins.push(coin);
      }
      checkDeath(id);
    }
  }
  if (droppedCoins.length > 0) io.emit('coinsDropped', droppedCoins);
  io.emit('scores', scores);
  // Drones caught in the blast pop outright
  for (const id of Object.keys(players)) {
    const d = players[id].drone;
    if (d && Math.hypot(d.x - pos.x, d.y - pos.y, d.z - pos.z) < 6) damageDrone(id, DRONE_HP);
  }
  // Turrets take heavy blast damage
  for (const t of [...activeTurrets]) {
    if (Math.hypot(t.x - pos.x, t.y - pos.y, t.z - pos.z) < 5.5) damageTurret(t.id, 30);
  }
}

// --- Generators (Slayer): humming heal stations, draggable with E ---
// energy is the finite heal pool (shown above the generator); each +1 heal
// burns 1 energy, and an empty generator disappears. mini = corpse drop.
const activeGenerators = [];  // { id, x, y, z, holder, energy, mini }
const GEN_HEAL_RANGE = 4.5;
const GEN_ENERGY = 150;
const MAX_MINI_GENS = 12;

// One heal generator, on the walkable pixel closest to the middle of the map
// that isn't inside the home deadzone (the base building owns that ground).
function autoPlaceGenerator() {
  activeGenerators.length = 0;
  if (creativeLayers) {
    let best = null;
    for (let r = 1; r < 31; r++) {
      for (let c = 1; c < 31; c++) {
        const top = pixelTop(r, c);
        if (top < 0 || inDeadzone(r, c)) continue;
        const d = Math.hypot(r - 16, c - 16);
        if (!best || d < best.d) best = { r, c, top, d };
      }
    }
    if (best) activeGenerators.push({
      id: 'gen-auto',
      x: -64 + best.c * 4 + 2, y: surfaceY(best.top) + 0.4, z: -64 + best.r * 4 + 2,
      holder: null, energy: GEN_ENERGY, mini: false
    });
  }
  io.emit('currentGenerators', activeGenerators);
}

// Heal +1 per 2 s while standing near a generator (Slayer only). Each heal
// burns 1 energy from the generator used; an empty generator disappears.
setInterval(() => {
  if (!gameSettings.slayer || activeGenerators.length === 0) return;
  let changed = false;
  const touched = new Set();
  for (const id of readyIds) {
    const p = players[id];
    if (!p || isDead(id)) continue;
    for (const g of activeGenerators) {
      if (g.energy <= 0) continue;
      const dx = p.x - g.x, dy = p.y - g.y, dz = p.z - g.z;
      if (dx * dx + dy * dy + dz * dz <= GEN_HEAL_RANGE * GEN_HEAL_RANGE) {
        scores[id] = (scores[id] || 0) + 1;
        g.energy -= 1;
        touched.add(g);
        changed = true;
        break;
      }
    }
  }
  for (const g of touched) {
    if (g.energy <= 0) {
      const idx = activeGenerators.indexOf(g);
      if (idx !== -1) activeGenerators.splice(idx, 1);
      io.emit('generatorRemoved', g.id);
    } else {
      io.emit('generatorEnergy', { id: g.id, energy: g.energy });
    }
  }
  if (changed) io.emit('scores', scores);
}, 2000);

// --- Castle walls (parametric, brick-built) ---
const activeCastles = [];  // { id, nodes, arch, kind, h, holes }

// --- NPCs ---
// Turrets belong to their spawner and shoot everyone else. The OWNER's client
// runs the aiming/firing sim (through the normal machinegun pipeline, so
// bullets damage as usual); the server owns turret health.
const activeTurrets = [];  // { id, x, y, z, ry, owner, hp }
const TURRET_HP = 60;

function damageTurret(id, dmg) {
  const t = activeTurrets.find(t => t.id === id);
  if (!t) return;
  t.hp -= Math.max(0, Math.min(30, dmg));
  if (t.hp > 0) {
    io.emit('turretHealth', { id, hp: t.hp });
    return;
  }
  activeTurrets.splice(activeTurrets.indexOf(t), 1);
  io.emit('turretDestroyed', id);
  io.emit('explosion', { x: t.x, y: t.y + 1, z: t.z, type: 'mine' });
}

// Critter flocks (crows/rats) are ambient boids simulated client-side; the
// server just remembers where each flock is anchored.
const activeFlocks = [];   // { id, kind:'crows'|'rats', x, y, z }

// --- Vehicles (Ghost-style hover + drill) ---
// driver is a socket id while mounted, null while parked. The driver's client
// is the physics authority: it relays vehicleMoved at ~20 Hz and everyone
// else interpolates.
const activeVehicles = [];  // { id, kind:'ghost'|'drill', x, y, z, ry, driver }

// --- Placeable spawn points ---
const spawnPoints = [];  // { id, x, y, z }

// --- Pedestal state ---
const pedestals = [];
const ITEMS_BY_CATEGORY = {
  green: ['grapple', 'launch_pad', 'boost_pad', 'teleporter'],
  red: ['machinegun', 'rocket', 'mines', 'crowbot'],
  yellow: ['block', 'wall', 'ramp', 'platform', 'bridge_gun']
};

setInterval(() => {
  const now = Date.now();
  let updated = false;
  for (const ped of pedestals) {
    if (!ped.currentItem && now >= (ped.spawnTime || 0)) {
      const arr = ITEMS_BY_CATEGORY[ped.type] || ITEMS_BY_CATEGORY.green;
      ped.currentItem = arr[Math.floor(Math.random() * arr.length)];
      updated = true;
    }
  }
  if (updated) {
    io.emit('pedestalsUpdated', pedestals);
  }
}, 1000);

// --- Oddball state ---
let holderID = null;
const scores = {};
let tagCooldownUntil = 0;
const TAG_COOLDOWN_MS = 4000;

// --- End-game vote state ---
// endVote = { voters:Set, yes:Set, no:Set, timer } while a vote is running.
let endVote = null;
const END_VOTE_TIMEOUT_MS = 30000;

function sysMsg(text) {
  io.emit('systemMessage', { text });
}

function votesNeeded() {
  return endVote ? Math.floor(endVote.voters.size / 2) + 1 : 0;
}

function checkEndVote() {
  if (!endVote) return;
  const needed = votesNeeded();
  if (endVote.yes.size >= needed) { finishEndVote(true); return; }
  const undecided = endVote.voters.size - endVote.yes.size - endVote.no.size;
  // Can't possibly reach the threshold anymore — fail early.
  if (endVote.yes.size + undecided < needed) finishEndVote(false);
}

function finishEndVote(passed) {
  if (!endVote) return;
  clearTimeout(endVote.timer);
  endVote = null;
  if (passed) { sysMsg('Vote passed — ending game.'); endGame(); }
  else sysMsg('Vote to end the game failed.');
}

// Auto-populate item pedestals so a fresh round has pickups without anyone
// god-placing them. Placement is RANDOM (a fixed stride read as the grid it
// was) with a minimum spacing, and each pedestal sits on top of its own
// painted column - including plateaus - rather than always on the ground
// floor, which is what had them half-buried in walls.
const PED_COUNT = 12;
const PED_SPACING = 16;   // meters between pedestals
// No yellow here: build prefabs are god-mode-only spawns, never map furniture.
const PED_TYPES = ['green', 'red'];

function autoPopulatePedestals() {
  pedestals.length = 0;
  if (!creativeLayers || !gameSettings.pedestals) { io.emit('currentPedestals', pedestals); return; }
  // Candidates: any pixel with a floor, clear of the home deadzone, whose
  // 4 neighbours are no taller than it (so nothing to clip into).
  const candidates = [];
  for (let r = 1; r < 31; r++) {
    for (let c = 1; c < 31; c++) {
      const top = pixelTop(r, c);
      if (top < 0 || inDeadzone(r, c)) continue;
      if (pixelTop(r - 1, c) > top || pixelTop(r + 1, c) > top) continue;
      if (pixelTop(r, c - 1) > top || pixelTop(r, c + 1) > top) continue;
      candidates.push({ r, c, top });
    }
  }
  for (let i = candidates.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
  }
  for (const cand of candidates) {
    if (pedestals.length >= PED_COUNT) break;
    const x = -64 + cand.c * 4 + 2;
    const z = -64 + cand.r * 4 + 2;
    if (pedestals.some(p => Math.hypot(p.x - x, p.z - z) < PED_SPACING)) continue;
    pedestals.push({
      id: 'auto-' + cand.r + '-' + cand.c,
      x, y: surfaceY(cand.top), z, ry: Math.random() * Math.PI * 2,
      type: PED_TYPES[pedestals.length % PED_TYPES.length],
      currentItem: null, spawnTime: 0
    });
  }
  io.emit('currentPedestals', pedestals);
}

// Ending the game is a FULL wipe: every placed object clears off the field
// and the painted grid resets, so the next lobby starts from scratch.
function endGame() {
  if (endVote) { clearTimeout(endVote.timer); endVote = null; }
  if (startTimer) { clearTimeout(startTimer); startTimer = null; }
  for (const id of Object.keys(scores)) scores[id] = startingScore();
  io.emit('scores', scores);
  holderID = null;
  io.emit('holderChanged', holderID);
  readyIds.clear();
  terrainEdits = [];
  creativeLayers = null;
  paintLayers = null;
  editors.clear();
  for (const id of Object.keys(spawnZones)) delete spawnZones[id];
  io.emit('spawnZones', spawnZones);
  if (editVote) { clearTimeout(editVote.timer); editVote = null; io.emit('editVote', null); }
  pedestals.length = 0;
  spawnPoints.length = 0;
  activeTeleporters.length = 0;
  activeMines.length = 0;
  activeCoins.length = 0;
  activePads.length = 0;
  activeBuilds.length = 0;
  activeModels.length = 0;
  activeChannels.length = 0;
  activeCastles.length = 0;
  activeVehicles.length = 0;
  activeGenerators.length = 0;
  activeTurrets.length = 0;
  activeFlocks.length = 0;
  io.emit('currentPedestals', []);
  io.emit('currentSpawns', []);
  io.emit('currentTeleporters', []);
  io.emit('currentMines', []);
  io.emit('currentPads', []);
  io.emit('currentBuilds', []);
  io.emit('currentModels', []);
  io.emit('currentChannels', []);
  io.emit('currentCastles', []);
  io.emit('currentVehicles', []);
  io.emit('currentGenerators', []);
  io.emit('currentTurrets', []);
  io.emit('currentFlocks', []);
  if (levelLocked) { levelLocked = false; io.emit('lobbyLocked', false); }
  io.emit('gameEnded');
}

// --- Editor votes ---
// GENERATE and CLEAR wipe or replace what everyone in the editor is working
// on, so they need unanimous agreement. Alone, they just happen.
let editVote = null;   // { kind, voters:Set, yes:Set, timer }
const EDIT_VOTE_MS = 25000;
// Sockets sitting in the map editor. They haven't 'ready'd yet, so readyIds
// doesn't see them - the editor announces itself instead.
const editors = new Set();

// Lobby start countdown: one shared timer so every menu counts in sync.
const START_COUNTDOWN_MS = 5000;
let startTimer = null;

function defaultLayers() {
  const out = [[], [], [], []];
  for (let li = 0; li < 4; li++)
    for (let r = 0; r < 32; r++) out[li].push(li === 0 ? 0xFFFFFFFF >>> 0 : 0);
  return out;
}

function broadcastEditVote() {
  if (!editVote) { io.emit('editVote', null); return; }
  io.emit('editVote', {
    kind: editVote.kind, yes: editVote.yes.size, need: editVote.voters.size
  });
}

function startEditVote(socket, kind) {
  if (editVote) return;
  // Only people actually at the canvas vote - an in-game player can't see
  // the confirmation bar, so counting them would deadlock it.
  const voters = new Set([...editors]);
  voters.add(socket.id);
  if (voters.size <= 1) { applyEditVote(kind); return; }
  editVote = { kind, voters, yes: new Set([socket.id]), timer: null };
  editVote.timer = setTimeout(() => {
    editVote = null;
    sysMsg('Vote timed out.');
    broadcastEditVote();
  }, EDIT_VOTE_MS);
  const who = players[socket.id] ? players[socket.id].name : 'Player';
  sysMsg(`${who} wants to ${kind === 'clear' ? 'clear the canvas' : 'start the game'}.`);
  broadcastEditVote();
  checkEditVote();
}

function checkEditVote() {
  if (!editVote || editVote.yes.size < editVote.voters.size) return;
  const kind = editVote.kind;
  clearTimeout(editVote.timer);
  editVote = null;
  io.emit('editVote', null);
  applyEditVote(kind);
}

function applyEditVote(kind) {
  if (kind === 'clear') {
    paintLayers = null;
    io.emit('paintCleared');
    return;
  }
  creativeLayers = paintLayers || defaultLayers();
  terrainEdits = [];
  io.emit('creativeGrid', { layers: creativeLayers });
  autoPopulatePedestals();
  autoPlaceGenerator();
}

// --- World items state ---
const activeTeleporters = [];
const activeMines = [];
const activeCoins = [];
const activePads = [];
const activeBuilds = [];
const activeModels = [];
const activeChannels = [];

function pickRandomHolder() {
  const ids = Object.keys(players);
  if (ids.length === 0) { holderID = null; return; }
  holderID = ids[Math.floor(Math.random() * ids.length)];
  tagCooldownUntil = Date.now() + TAG_COOLDOWN_MS;
  io.emit('holderChanged', holderID);
  io.emit('tagCooldown', TAG_COOLDOWN_MS);
  io.emit('scores', scores);
}

// Score tick — holder gains 1 point per second (old sandbox mode only;
// in Slayer, scores are health and only coins/generators raise them)
setInterval(() => {
  if (!gameSettings.slayer && holderID && players[holderID]) {
    scores[holderID] = (scores[holderID] || 0) + 1;
    io.emit('scores', scores);
  }
}, 1000);

// Server-side inactivity tracking
const lastActivity = {};
const INACTIVITY_LIMIT = 5 * 60 * 1000;

// Clean up uncollected coins periodically
setInterval(() => {
  const now = Date.now();
  for (let i = activeCoins.length - 1; i >= 0; i--) {
    if (now - activeCoins[i].createdAt > 15000) {
      io.emit('coinCollected', activeCoins[i].id); // fake collection to clean up visuals
      activeCoins.splice(i, 1);
    }
  }
}, 5000);

setInterval(() => {
  const now = Date.now();
  for (const id of readyIds) {
    if (lastActivity[id] && now - lastActivity[id] > INACTIVITY_LIMIT) {
      console.log(`Kicking idle player: ${id}`);
      const sock = io.sockets.sockets.get(id);
      if (sock) sock.emit('kicked', 'inactivity');
      if (sock) sock.disconnect(true);
    }
  }
}, 30000);

io.on('connection', (socket) => {
  // Send the current game state so a plain connection (the web spectator
  // dashboard — the game itself is Godot-only now) can render a live birdseye
  // view of a game in progress. Ongoing movement arrives via the existing
  // broadcast 'playerMoved'/'newPlayer'/'scores'/'holderChanged' events.
  socket.emit('spectatorPlayers', {
    activeLevel,
    players: Object.fromEntries(
      [...readyIds].filter(id => players[id]).map(id => [id, players[id]])
    ),
    scores,
    holder: holderID,
    build: SERVER_BUILD,
    uptimeMs: Date.now() - STARTED_AT
  });

  // Creative-level snapshot on plain connection (scenes load after connect,
  // so this must not wait for 'ready').
  if (creativeLayers) {
    socket.emit('creativeGrid', { layers: creativeLayers });
    socket.emit('terrainEdits', terrainEdits);
  }
  if (paintLayers) socket.emit('creativePaint', { layers: paintLayers });
  socket.emit('spawnZones', spawnZones);
  socket.emit('hello', { id: socket.id });
  socket.emit('gameSettings', gameSettings);
  socket.emit('currentSpawns', spawnPoints);

  socket.on('editing', (on) => {
    if (on) editors.add(socket.id); else editors.delete(socket.id);
  });

  // Lobby START: everyone in the lobby sees the same 5 s countdown, then all
  // of them land in the pixel editor together. If a session is already in
  // motion (painters at work or a live map), the caller just joins it.
  socket.on('requestStart', () => {
    if (creativeLayers || paintLayers || editors.size > 0 || readyIds.size > 0) {
      socket.emit('enterEditor');
      return;
    }
    if (startTimer) return;
    io.emit('startCountdown', { ms: START_COUNTDOWN_MS });
    startTimer = setTimeout(() => {
      startTimer = null;
      io.emit('enterEditor');
    }, START_COUNTDOWN_MS);
  });

  // Live painter cursors: relay-only, so co-painters see where you're hovering.
  socket.on('editCursor', (p) => {
    if (!p) return;
    socket.broadcast.emit('editCursor', {
      id: socket.id,
      r: Math.max(0, Math.min(31, Math.floor(Number(p.r) || 0))),
      c: Math.max(0, Math.min(31, Math.floor(Number(p.c) || 0)))
    });
  });

  socket.on('updateGameSetting', (u) => {
    if (!u || typeof u.key !== 'string' || !(u.key in gameSettings)) return;
    if (u.key === 'slayer') return;  // derived from mode, never set directly
    // Settings are part of the gamemode: picked in the lobby, frozen once a
    // game is live. Build mode exists precisely to change them mid-game.
    // EXCEPT the physics tuning sliders — those stay live in every mode.
    const TUNABLE = ['speedScale', 'jumpScale', 'gravityScale'];
    if (readyIds.size > 0 && gameSettings.mode !== 'build' && !TUNABLE.includes(u.key)) {
      socket.emit('systemMessage', { text: 'Settings are locked once a game starts. Build mode can change them live.' });
      return;
    }
    const who = players[socket.id] ? players[socket.id].name : 'Someone';
    if (u.key === 'mode') {
      if (!MODES.includes(u.value)) return;
      gameSettings.mode = u.value;
      gameSettings.slayer = u.value === 'slayer';
      io.emit('gameSettings', gameSettings);
      sysMsg(`${who} set the gamemode to ${u.value}`);
      return;
    }
    const numeric = typeof gameSettings[u.key] === 'number';
    gameSettings[u.key] = numeric
      ? Math.min(3, Math.max(0.05, Number(u.value) || 1))
      : !!u.value;
    io.emit('gameSettings', gameSettings);
    sysMsg(numeric
      ? `${who} set ${u.key} to ${gameSettings[u.key].toFixed(2)}`
      : `${who} turned ${u.key} ${gameSettings[u.key] ? 'ON' : 'OFF'}`);
    // Pedestals appear/vanish immediately when the toggle flips
    if (u.key === 'pedestals') autoPopulatePedestals();
  });

  socket.on('placeCastle', (c) => {
    if (!c || !Array.isArray(c.nodes) || c.nodes.length < 1) return;
    const kind = c.kind === 'tower' ? 'tower' : 'wall';
    if (kind === 'wall' && c.nodes.length < 2) return;
    const castle = {
      id: (typeof c.id === 'string' && c.id) ? c.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      nodes: c.nodes.slice(0, 16).map(n => ({ x: +n.x || 0, y: +n.y || 0, z: +n.z || 0 })),
      arch: !!c.arch,
      kind,
      h: Math.min(24, Math.max(2, Number(c.h) || 6)),
      holes: []           // Tiny-Glade-style punched openings, added live
    };
    activeCastles.push(castle);
    io.emit('castlePlaced', castle);
  });

  // Live modification of a placed wall/tower: relative height and punched
  // penetrations. Broadcasts the whole record; clients rebuild it.
  socket.on('updateCastle', (u) => {
    const castle = u && activeCastles.find(c => c.id === u.id);
    if (!castle) return;
    if (typeof u.dh === 'number') {
      castle.h = Math.min(24, Math.max(2, castle.h + Math.max(-2, Math.min(2, u.dh))));
    }
    if (u.hole && typeof u.hole.x === 'number' && castle.holes.length < 24) {
      castle.holes.push({ x: +u.hole.x, y: +u.hole.y, z: +u.hole.z });
    }
    io.emit('castleUpdated', castle);
  });

  socket.on('removeCastle', (id) => {
    const idx = activeCastles.findIndex(c => c.id === id);
    if (idx !== -1) {
      activeCastles.splice(idx, 1);
      io.emit('castleRemoved', id);
    }
  });

  // --- NPC turrets ---
  socket.on('placeTurret', (t) => {
    if (!t || typeof t.x !== 'number') return;
    const turret = {
      id: (typeof t.id === 'string' && t.id) ? t.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      x: +t.x, y: +t.y, z: +t.z, ry: 0,
      owner: socket.id, hp: TURRET_HP
    };
    activeTurrets.push(turret);
    io.emit('turretPlaced', turret);
  });

  socket.on('removeTurret', (id) => {
    const idx = activeTurrets.findIndex(t => t.id === id);
    if (idx !== -1) {
      activeTurrets.splice(idx, 1);
      io.emit('turretRemoved', id);
    }
  });

  // Owner's client relays where the head is pointing (visual only)
  socket.on('turretAim', (d) => {
    const t = d && activeTurrets.find(t => t.id === d.id);
    if (!t || t.owner !== socket.id) return;
    t.ry = +d.ry || 0;
    t.rx = +d.rx || 0;  // pitch: the gun nods up/down at its target
    socket.broadcast.emit('turretAim', { id: t.id, ry: t.ry, rx: t.rx });
  });

  socket.on('turretHit', (d) => {
    if (d && typeof d.id === 'string') damageTurret(d.id, Number(d.dmg) || 10);
  });

  // --- Critter flocks ---
  socket.on('placeFlock', (f) => {
    if (!f || typeof f.x !== 'number') return;
    const flock = {
      id: (typeof f.id === 'string' && f.id) ? f.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      kind: f.kind === 'rats' ? 'rats' : 'crows',
      x: +f.x, y: +f.y, z: +f.z
    };
    activeFlocks.push(flock);
    io.emit('flockPlaced', flock);
  });

  socket.on('removeFlock', (id) => {
    const idx = activeFlocks.findIndex(f => f.id === id);
    if (idx !== -1) {
      activeFlocks.splice(idx, 1);
      io.emit('flockRemoved', id);
    }
  });

  // Critters are shootable: boids are client-simulated but IDENTITY is by
  // index, so a kill is just "flock X, boid N is dead" + who did it (the
  // flock aggros its attacker). Shooter's client is the hit authority.
  const FLOCK_N = { crows: 11, rats: 9 };
  socket.on('critterHit', (d) => {
    if (!d || typeof d.id !== 'string') return;
    const flock = activeFlocks.find(f => f.id === d.id);
    if (!flock) return;
    const n = FLOCK_N[flock.kind] || 11;
    const idx = Math.floor(Number(d.idx));
    if (!(idx >= 0 && idx < n)) return;
    flock.dead = flock.dead || [];
    if (flock.dead.includes(idx)) return;
    flock.dead.push(idx);
    const src = (d.src && d.src.t === 'turret' && typeof d.src.id === 'string')
      ? { t: 'turret', id: d.src.id } : { t: 'player', id: socket.id };
    io.emit('critterDied', { id: flock.id, idx, src });
    if (flock.dead.length >= n) {
      activeFlocks.splice(activeFlocks.indexOf(flock), 1);
      io.emit('flockRemoved', flock.id);
    }
  });

  socket.on('placeVehicle', (v) => {
    if (!v || !['ghost', 'drill', 'crowbot', 'ratbot'].includes(v.kind)) return;
    const veh = {
      id: (typeof v.id === 'string' && v.id) ? v.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      kind: v.kind,
      x: +v.x || 0, y: +v.y || 0, z: +v.z || 0, ry: +v.ry || 0,
      driver: null
    };
    activeVehicles.push(veh);
    io.emit('vehiclePlaced', veh);
  });

  // Crow-bot pilot points at a spot: every client's guided crow flocks surge
  // there for a few seconds (boids are client-local; this only syncs intent).
  socket.on('swarmStrike', (d) => {
    if (!d || typeof d.x !== 'number') return;
    const bot = activeVehicles.find(v => v.kind === 'crowbot' && v.driver === socket.id);
    if (!bot) return;
    io.emit('swarmStrike', { id: socket.id, x: +d.x, y: +d.y, z: +d.z });
  });

  // Rat-attack pilot marked a player: guided rat packs hunt that player for a
  // while (boids are client-local; this only syncs intent).
  socket.on('swarmHunt', (d) => {
    if (!d || typeof d.t !== 'string' || !players[d.t]) return;
    const bot = activeVehicles.find(v => v.kind === 'ratbot' && v.driver === socket.id);
    if (!bot) return;
    io.emit('swarmHunt', { id: socket.id, target: d.t });
  });

  socket.on('removeVehicle', (id) => {
    const idx = activeVehicles.findIndex(v => v.id === id);
    if (idx !== -1) {
      activeVehicles.splice(idx, 1);
      io.emit('vehicleRemoved', id);
    }
  });

  socket.on('mountVehicle', (id) => {
    const veh = activeVehicles.find(v => v.id === id);
    if (!veh || veh.wrecked) return;
    // Taken by someone still connected? Re-assert the real driver so the
    // optimistic mount on the loser's client rolls back.
    if (veh.driver && veh.driver !== socket.id && io.sockets.sockets.get(veh.driver)) {
      socket.emit('vehicleDriver', { id: veh.id, driver: veh.driver });
      return;
    }
    veh.driver = socket.id;
    io.emit('vehicleDriver', { id: veh.id, driver: veh.driver });
  });

  socket.on('dismountVehicle', (id) => {
    const veh = activeVehicles.find(v => v.id === id);
    if (veh && veh.driver === socket.id) {
      veh.driver = null;
      io.emit('vehicleDriver', { id: veh.id, driver: null });
    }
  });

  socket.on('vehicleMoved', (d) => {
    const veh = d && activeVehicles.find(v => v.id === d.id);
    if (!veh || veh.driver !== socket.id) return;
    veh.x = +d.x || 0; veh.y = +d.y || 0; veh.z = +d.z || 0; veh.ry = +d.ry || 0;
    const out = { id: veh.id, x: veh.x, y: veh.y, z: veh.z, ry: veh.ry };
    // Wreck tumbles carry a full orientation, not just yaw
    if (typeof d.qx === 'number') {
      out.qx = +d.qx; out.qy = +d.qy; out.qz = +d.qz; out.qw = +d.qw;
    }
    socket.broadcast.emit('vehicleMoved', out);
  });

  // --- Crash physics ---
  // A hard stop knocks a vehicle into free rigid-body "wreck" physics on the
  // crasher's client (who keeps relay authority). It can settle upside down;
  // anyone pressing E on a wreck flips it back upright and parks it.
  socket.on('wreckVehicle', (id) => {
    const veh = activeVehicles.find(v => v.id === id);
    if (!veh || veh.driver !== socket.id) return;
    veh.wrecked = true;
    socket.broadcast.emit('vehicleWrecked', id);
  });

  // Crasher's wreck settled upright on its own: back to a parked vehicle.
  socket.on('vehicleRighted', (d) => {
    const veh = d && activeVehicles.find(v => v.id === d.id);
    if (!veh || !veh.wrecked || (veh.driver && veh.driver !== socket.id)) return;
    veh.wrecked = false;
    if (typeof d.x === 'number') { veh.x = +d.x; veh.y = +d.y; veh.z = +d.z; veh.ry = +d.ry || 0; }
    io.emit('vehicleRighted', { id: veh.id, x: veh.x, y: veh.y, z: veh.z, ry: veh.ry });
  });

  // E on an upside-down wreck: flip it upright where it lies.
  socket.on('flipVehicle', (id) => {
    const veh = activeVehicles.find(v => v.id === id);
    if (!veh || !veh.wrecked) return;
    veh.wrecked = false;
    if (veh.driver) {
      veh.driver = null;
      io.emit('vehicleDriver', { id: veh.id, driver: null });
    }
    io.emit('vehicleRighted', { id: veh.id, x: veh.x, y: veh.y, z: veh.z, ry: veh.ry });
  });

  socket.on('placeSpawn', (s) => {
    if (!s || typeof s.x !== 'number') return;
    const sp = {
      id: (typeof s.id === 'string' && s.id) ? s.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      x: +s.x, y: +s.y, z: +s.z
    };
    spawnPoints.push(sp);
    io.emit('spawnPlaced', sp);
  });

  socket.on('removeSpawn', (id) => {
    const idx = spawnPoints.findIndex(p => p.id === id);
    if (idx !== -1) {
      spawnPoints.splice(idx, 1);
      io.emit('spawnRemoved', id);
    }
  });

  // A painter claims (or drops) their spawn pixel. Zones can't overlap, so
  // nobody can plant their base inside someone else's.
  socket.on('setSpawn', (p) => {
    if (p === null || p === undefined) {
      delete spawnZones[socket.id];
      io.emit('spawnZones', spawnZones);
      return;
    }
    const r = Math.max(0, Math.min(31, Math.floor(Number(p.r) || 0)));
    const c = Math.max(0, Math.min(31, Math.floor(Number(p.c) || 0)));
    for (const [id, z] of Object.entries(spawnZones)) {
      if (id === socket.id) continue;
      if (Math.abs(r - z[0]) <= ZONE_SEPARATION && Math.abs(c - z[1]) <= ZONE_SEPARATION) {
        socket.emit('systemMessage', { text: 'That overlaps another spawn zone.' });
        return;
      }
    }
    spawnZones[socket.id] = [r, c];
    io.emit('spawnZones', spawnZones);
  });

  // GENERATE and CLEAR need everyone still in the editor to agree.
  socket.on('requestGenerate', () => startEditVote(socket, 'generate'));
  socket.on('requestClear', () => startEditVote(socket, 'clear'));
  socket.on('castEditVote', (yes) => {
    if (!editVote || !editVote.voters.has(socket.id)) return;
    const who = players[socket.id] ? players[socket.id].name : 'Player';
    if (!yes) {
      sysMsg(`${who} declined.`);
      clearTimeout(editVote.timer);
      editVote = null;
      io.emit('editVote', null);
      return;
    }
    editVote.yes.add(socket.id);
    broadcastEditVote();
    checkEditVote();
  });

  // Live co-painting of the creative editor canvas (full 32-int grid per
  // stroke burst — tiny and idempotent).
  socket.on('creativePaint', (g) => {
    const layers = normLayers(g);
    if (!layers) return;
    paintLayers = layers;
    socket.broadcast.emit('creativePaint', { layers: paintLayers });
  });

  socket.on('creativeGrid', (g) => {
    const layers = normLayers(g);
    if (!layers) return;
    creativeLayers = layers;
    terrainEdits = [];
    io.emit('creativeGrid', { layers: creativeLayers });
    autoPopulatePedestals();  // fresh map -> fresh item pedestals in open areas
    autoPlaceGenerator();     // and one heal generator near the center
  });

  socket.on('terrainEdit', (e) => {
    if (!e || typeof e.x !== 'number' || typeof e.y !== 'number' || typeof e.z !== 'number') return;
    const edit = {
      x: +e.x, y: +e.y, z: +e.z,
      r: Math.min(Math.abs(+e.r) || 3, 12),
      s: e.s >= 0 ? 1 : -1,
      st: Math.min(Math.abs(+e.st) || 1, 2),
      m: e.m === 'smooth' ? 'smooth' : 'add'   // smooth relaxes instead of adding
    };
    // Spawn deadzones are unsculptable - a brush that would reach into one is
    // dropped outright (clients block it locally too).
    for (const h of homeWorlds()) {
      if (Math.max(Math.abs(edit.x - h.x), Math.abs(edit.z - h.z)) <= DEADZONE_R + edit.r) return;
    }
    terrainEdits.push(edit);
    if (terrainEdits.length > 20000) terrainEdits.shift();
    socket.broadcast.emit('terrainEdit', edit);
  });

  // Latency probe for the spectator dashboard (socket.io ack round-trip).
  socket.on('pingCheck', (cb) => {
    if (typeof cb === 'function') cb();
  });

  socket.on('selectLevel', (level) => {
    // Once a game is in progress the level is locked and cannot change. While
    // the lobby is open, any player's selection becomes THE active level and is
    // broadcast to everyone so all lobby clients stay on the same map.
    if (levelLocked) return;
    if (typeof level === 'string' && level.endsWith('.glb') && level !== activeLevel) {
      activeLevel = level;
      io.emit('levelChanged', activeLevel);
    }
  });

  socket.on('ready', (data = {}) => {
    // Version check: Godot clients send their git build hash. Warn (don't kick)
    // on mismatch so both players know to pull. Web clients don't send one.
    const clientBuild = (typeof data.build === 'string' ? data.build : '').slice(0, 7);
    if (SERVER_BUILD && clientBuild && clientBuild !== SERVER_BUILD) {
      socket.emit('versionMismatch', { server: SERVER_BUILD, client: clientBuild });
    }
    const sp = randomSpawn();
    const color = data.skinColor || COLORS[colorIndex % COLORS.length];
    if (!data.skinColor) colorIndex++;
    
    players[socket.id] = {
      x: sp.x, y: sp.y, z: sp.z,
      color,
      type: data.type === 'ball' ? 'ball' : (data.shape || 'box'),
      name: (typeof data.name === 'string' ? data.name.slice(0, 16) : 'Player') || 'Player',
      shape: data.shape || 'box',
      skinColor: color,
      skinImage: typeof data.skinImage === 'string' ? data.skinImage.slice(0, 500) : '',
      model: typeof data.model === 'string' ? data.model : 'none'
    };
    scores[socket.id] = startingScore();
    readyIds.add(socket.id);
    lastActivity[socket.id] = Date.now();
    // First player to join locks the lobby (level + game settings) for everyone.
    if (!levelLocked) { levelLocked = true; io.emit('lobbyLocked', true); }
    console.log(`Player connected: ${socket.id} (${players[socket.id].name}, ${players[socket.id].shape})`);
    socket.emit('currentPlayers', { players, selfId: socket.id });
    socket.emit('holderChanged', holderID);
    socket.emit('scores', scores);
    socket.emit('currentPedestals', pedestals);
    socket.emit('currentTeleporters', activeTeleporters);
    socket.emit('currentMines', activeMines);
    socket.emit('currentPads', activePads);
    socket.emit('currentBuilds', activeBuilds);
    socket.emit('currentModels', activeModels);
    socket.emit('currentChannels', activeChannels);
    socket.emit('currentCastles', activeCastles);
    socket.emit('currentVehicles', activeVehicles);
    socket.emit('currentGenerators', activeGenerators);
    socket.emit('currentTurrets', activeTurrets);
    socket.emit('currentFlocks', activeFlocks);
    socket.broadcast.emit('newPlayer', { id: socket.id, ...players[socket.id] });
    socket.broadcast.emit('systemMessage', { text: `${players[socket.id].name} joined the game.` });

    // A new player joining invalidates an in-progress end-game vote tally.
    if (endVote) finishEndVote(false);

    // First player becomes holder
    if (!holderID) pickRandomHolder();
  });

  socket.on('playerMoved', (data) => {
    if (!players[socket.id]) return;
    lastActivity[socket.id] = Date.now();
    players[socket.id].x = data.x;
    players[socket.id].y = data.y;
    players[socket.id].z = data.z;
    if (data.qx !== undefined) {
      players[socket.id].qx = data.qx;
      players[socket.id].qy = data.qy;
      players[socket.id].qz = data.qz;
      players[socket.id].qw = data.qw;
    }
    if (data.smoothing !== undefined) players[socket.id].smoothing = data.smoothing;
    if (data.godmode !== undefined) players[socket.id].godmode = data.godmode;
    // Drone out? Track it as a target; fresh drones start at full health.
    if (data.drone && typeof data.drone.x === 'number') {
      if (!players[socket.id].drone) players[socket.id].droneHp = DRONE_HP;
      players[socket.id].drone = { x: +data.drone.x, y: +data.drone.y, z: +data.drone.z };
    } else if (players[socket.id].drone) {
      players[socket.id].drone = null;
      delete players[socket.id].droneHp;
    }
    socket.broadcast.emit('playerMoved', { id: socket.id, ...data });
  });

  // Shooter's client detected a bullet on someone's drone.
  socket.on('droneHit', (targetId) => {
    if (typeof targetId === 'string' && targetId !== socket.id) damageDrone(targetId, 10);
  });

  socket.on('jump', () => socket.broadcast.emit('playerJumped', socket.id));
  socket.on('sprintStart', () => socket.broadcast.emit('playerSprintStart', socket.id));

  socket.on('godmodeEnter', () => {
    if (holderID === socket.id) {
      const candidates = Object.keys(players).filter(id => id !== socket.id);
      if (candidates.length > 0) {
        holderID = candidates[Math.floor(Math.random() * candidates.length)];
        tagCooldownUntil = Date.now() + TAG_COOLDOWN_MS;
        io.emit('holderChanged', holderID);
        io.emit('tagCooldown', TAG_COOLDOWN_MS);
      }
    }
  });

  socket.on('tagPlayer', (targetId) => {
    if (holderID !== socket.id) return;
    if (Date.now() < tagCooldownUntil) return;
    if (!players[targetId]) return;
    holderID = targetId;
    tagCooldownUntil = Date.now() + TAG_COOLDOWN_MS;
    io.emit('holderChanged', holderID);
    io.emit('tagCooldown', TAG_COOLDOWN_MS);
  });

  socket.on('godmodeGive', (item) => {
    if (!gameSettings.selfAssign) {
      socket.emit('systemMessage', { text: 'Self-assigning items is disabled in game settings.' });
      return;
    }
    socket.emit('itemPickedUp', item);
  });

  socket.on('placePedestal', (pos) => {
    const id = (typeof pos.id === 'string' && pos.id) ? pos.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5));
    const ped = { ...pos, id, currentItem: null, spawnTime: 0 };
    pedestals.push(ped);
    io.emit('pedestalPlaced', ped);
  });

  socket.on('placeTeleporter', (t) => {
    activeTeleporters.push(t);
    io.emit('teleporterPlaced', t);
  });

  socket.on('placeBuild', (b) => {
    const build = { ...b, id: Date.now().toString(36) + Math.random().toString(36).substr(2) };
    activeBuilds.push(build);
    io.emit('buildPlaced', build);
  });

  socket.on('removeBuild', (id) => {
    const idx = activeBuilds.findIndex(b => b.id === id);
    if (idx !== -1) {
      activeBuilds.splice(idx, 1);
      io.emit('buildRemoved', id);
    }
  });

  socket.on('placeChannel', (c) => {
    if (!c || !Array.isArray(c.nodes) || c.nodes.length < 2) return;
    const channel = {
      id: (typeof c.id === 'string' && c.id) ? c.id : (Date.now().toString(36) + Math.random().toString(36).substr(2)),
      nodes: c.nodes.slice(0, 64).map(n => ({ x: Number(n.x) || 0, y: Number(n.y) || 0, z: Number(n.z) || 0 })),
      radius: Number(c.radius) || 2.5
    };
    activeChannels.push(channel);
    io.emit('channelPlaced', channel);
  });

  socket.on('removeChannel', (id) => {
    const idx = activeChannels.findIndex(c => c.id === id);
    if (idx !== -1) {
      activeChannels.splice(idx, 1);
      io.emit('channelRemoved', id);
    }
  });

  socket.on('placeModel', (m) => {
    if (!m || typeof m.model !== 'string' || !m.model.endsWith('.glb')) return;
    const model = {
      model: m.model,
      x: Number(m.x) || 0, y: Number(m.y) || 0, z: Number(m.z) || 0,
      ry: Number(m.ry) || 0,
      s: Math.min(6, Math.max(0.2, Number(m.s) || 1)),   // god-menu scroll scale
      id: (typeof m.id === 'string' && m.id) ? m.id : (Date.now().toString(36) + Math.random().toString(36).substr(2))
    };
    activeModels.push(model);
    io.emit('modelPlaced', model);
  });

  socket.on('removeModel', (id) => {
    const idx = activeModels.findIndex(m => m.id === id);
    if (idx !== -1) {
      activeModels.splice(idx, 1);
      io.emit('modelRemoved', id);
    }
  });

  socket.on('placePad', (pad) => {
    const p = { ...pad, id: Date.now().toString(36) + Math.random().toString(36).substr(2) };
    activePads.push(p);
    io.emit('padPlaced', p);
  });

  socket.on('fireMachinegun', (data) => {
    io.emit('machinegunFired', { ...data, owner: socket.id });
  });

  socket.on('machinegunHit', ({ targetId, dir }) => {
    if (!players[targetId] || isDead(targetId)) return;
    if (scores[targetId] > 0) {
      const pointsLost = Math.min(scores[targetId], 2);
      scores[targetId] -= pointsLost;
      const droppedCoins = [];
      for (let i = 0; i < pointsLost; i++) {
        const ang = Math.random() * Math.PI * 2;
        const horiz = 6 + Math.random() * 22;
        const coin = {
          id: Date.now().toString(36) + Math.random().toString(36).substr(2),
          x: players[targetId].x + (Math.random() - 0.5) * 0.8,
          y: players[targetId].y + 1 + Math.random() * 0.6,
          z: players[targetId].z + (Math.random() - 0.5) * 0.8,
          vx: dir.x * 14 + Math.cos(ang) * horiz,
          vy: Math.max(dir.y * 16, 8) + Math.random() * 16,
          vz: dir.z * 14 + Math.sin(ang) * horiz,
          rx: (Math.random() - 0.5) * 30, ry: (Math.random() - 0.5) * 30, rz: (Math.random() - 0.5) * 30,
          value: 1, createdAt: Date.now()
        };
        activeCoins.push(coin);
        droppedCoins.push(coin);
      }
      io.emit('coinsDropped', droppedCoins);
      io.emit('scores', scores);
      checkDeath(targetId);
    }
    io.emit('applyImpulse', { id: targetId, dir, force: 25 });
  });

  socket.on('fireRocket', (data) => {
    io.emit('rocketFired', { ...data, owner: socket.id });
  });

  socket.on('triggerExplosion', (pos) => {
    io.emit('explosion', pos);
    explosionDamage(pos);
  });

  // Slayer self-destruct (K or /kill): zero out and run the death flow.
  socket.on('suicide', () => {
    if (!gameSettings.slayer || !players[socket.id] || isDead(socket.id)) return;
    scores[socket.id] = 0;
    checkDeath(socket.id);
  });

  // Self-inflicted health cost (the drill runs on your life)
  socket.on('selfDamage', (n) => {
    if (!gameSettings.slayer || !players[socket.id] || isDead(socket.id)) return;
    const amt = Math.min(3, Math.max(0, Math.floor(Number(n) || 0)));
    if (!amt) return;
    scores[socket.id] = Math.max(0, (scores[socket.id] || 0) - amt);
    io.emit('scores', scores);
    checkDeath(socket.id);
  });

  socket.on('placeGenerator', (g) => {
    if (!g || typeof g.x !== 'number') return;
    const gen = {
      id: (typeof g.id === 'string' && g.id) ? g.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      x: +g.x, y: +g.y, z: +g.z, holder: null, owner: socket.id,
      energy: GEN_ENERGY, mini: false
    };
    activeGenerators.push(gen);
    io.emit('generatorPlaced', gen);
  });

  socket.on('removeGenerator', (id) => {
    const idx = activeGenerators.findIndex(g => g.id === id);
    if (idx !== -1) {
      activeGenerators.splice(idx, 1);
      io.emit('generatorRemoved', id);
    }
  });

  socket.on('grabGenerator', (id) => {
    const gen = activeGenerators.find(g => g.id === id);
    if (!gen) return;
    if (gen.holder && gen.holder !== socket.id && io.sockets.sockets.get(gen.holder)) {
      socket.emit('generatorHolder', { id: gen.id, holder: gen.holder });
      return;
    }
    gen.holder = socket.id;
    io.emit('generatorHolder', { id: gen.id, holder: gen.holder });
  });

  socket.on('releaseGenerator', (id) => {
    const gen = activeGenerators.find(g => g.id === id);
    if (gen && gen.holder === socket.id) {
      gen.holder = null;
      io.emit('generatorHolder', { id: gen.id, holder: null });
    }
  });

  socket.on('generatorMoved', (d) => {
    const gen = d && activeGenerators.find(g => g.id === d.id);
    // The holder relays while dragging; the OWNER may also relay while nobody
    // holds it — that's the physics drop right after placement/death.
    if (!gen || (gen.holder !== socket.id && !(gen.holder == null && gen.owner === socket.id))) return;
    gen.x = +d.x || 0; gen.y = +d.y || 0; gen.z = +d.z || 0;
    socket.broadcast.emit('generatorMoved', { id: gen.id, x: gen.x, y: gen.y, z: gen.z });
  });

  socket.on('placeMine', (pos) => {
    const mine = { ...pos, id: Date.now().toString(36) + Math.random().toString(36).substr(2) };
    activeMines.push(mine);
    io.emit('minePlaced', mine);
  });

  socket.on('triggerMine', (id) => {
    const idx = activeMines.findIndex(m => m.id === id);
    if (idx !== -1) {
      const m = activeMines.splice(idx, 1)[0];
      io.emit('mineTriggered', { id, pos: m });
      io.emit('explosion', { x: m.x, y: m.y, z: m.z, type: 'mine' });
      explosionDamage({ x: m.x, y: m.y, z: m.z });
    }
  });

  socket.on('pickupItem', (pedId) => {
    const ped = pedestals.find(p => p.id === pedId);
    if (ped && ped.currentItem) {
      const item = ped.currentItem;
      ped.currentItem = null;
      let cd = 10000; // 10s default (green)
      if (ped.type === 'red') cd = 20000; // 20s for weapons
      else if (ped.type === 'yellow') cd = 15000; // 15s for environment
      ped.spawnTime = Date.now() + cd;
      socket.emit('itemPickedUp', item);
      io.emit('pedestalsUpdated', pedestals);
    }
  });

  socket.on('collectCoin', (coinId) => {
    const idx = activeCoins.findIndex(c => c.id === coinId);
    if (idx !== -1) {
      const coin = activeCoins.splice(idx, 1)[0];
      scores[socket.id] = (scores[socket.id] || 0) + coin.value;
      io.emit('coinCollected', coinId);
      io.emit('scores', scores);
    }
  });

  socket.on('removePedestal', (id) => {
    const idx = pedestals.findIndex(p => p.id === id);
    if (idx !== -1) {
      pedestals.splice(idx, 1);
      io.emit('pedestalRemoved', id);
    }
  });

  socket.on('chat', (text) => {
    if (typeof text !== 'string') return;
    const msg = text.trim().slice(0, 200);
    if (!msg) return;
    const p = players[socket.id];
    io.emit('chatMessage', {
      id: socket.id,
      name: p ? p.name : 'Spectator',
      color: p ? p.skinColor : '#ffffff',
      text: msg
    });
  });

  socket.on('startEndVote', () => {
    if (!readyIds.has(socket.id)) return;       // only in-game players can call a vote
    if (endVote) return;                         // a vote is already running
    endVote = {
      voters: new Set([...readyIds]),
      yes: new Set([socket.id]),                 // initiator implicitly votes yes
      no: new Set(),
      timer: null
    };
    endVote.timer = setTimeout(() => finishEndVote(false), END_VOTE_TIMEOUT_MS);
    const name = players[socket.id] ? players[socket.id].name : 'Player';
    sysMsg(`${name} wants to end the game. Vote to end game? Type /vote yes or /vote no (${endVote.yes.size}/${votesNeeded()})`);
    checkEndVote();
  });

  socket.on('castVote', (val) => {
    if (!endVote || !endVote.voters.has(socket.id)) return;
    const yes = !!val;
    if (yes) { endVote.yes.add(socket.id); endVote.no.delete(socket.id); }
    else { endVote.no.add(socket.id); endVote.yes.delete(socket.id); }
    const name = players[socket.id] ? players[socket.id].name : 'Player';
    sysMsg(`${name} voted ${yes ? 'yes' : 'no'} (${endVote.yes.size}/${votesNeeded()} to end)`);
    checkEndVote();
  });

  socket.on('disconnect', () => {
    console.log(`Player disconnected: ${socket.id}`);
    const wasInGame = readyIds.has(socket.id);
    const leftName = players[socket.id] ? players[socket.id].name : null;
    delete players[socket.id];
    delete scores[socket.id];
    readyIds.delete(socket.id);
    delete lastActivity[socket.id];
    // Park any vehicle this player was driving.
    for (const veh of activeVehicles) {
      if (veh.driver === socket.id) {
        veh.driver = null;
        io.emit('vehicleDriver', { id: veh.id, driver: null });
      }
    }
    // Drop any generator this player was dragging.
    for (const gen of activeGenerators) {
      if (gen.holder === socket.id) {
        gen.holder = null;
        io.emit('generatorHolder', { id: gen.id, holder: null });
      }
    }
    delete deadUntil[socket.id];
    editors.delete(socket.id);
    if (spawnZones[socket.id]) { delete spawnZones[socket.id]; io.emit('spawnZones', spawnZones); }
    if (editVote && editVote.voters.has(socket.id)) {
      editVote.voters.delete(socket.id);
      editVote.yes.delete(socket.id);
      broadcastEditVote();
      checkEditVote();
    }
    if (wasInGame && leftName) sysMsg(`${leftName} left the game.`);
    // Drop the player from any running vote and re-evaluate the tally.
    if (endVote && endVote.voters.has(socket.id)) {
      endVote.voters.delete(socket.id);
      endVote.yes.delete(socket.id);
      endVote.no.delete(socket.id);
      if (endVote.voters.size === 0) finishEndVote(false);
      else checkEndVote();
    }
    if (holderID === socket.id) pickRandomHolder();
    // Last player leaving re-opens the lobby for level/setting changes.
    if (readyIds.size === 0 && levelLocked) { levelLocked = false; io.emit('lobbyLocked', false); }
    io.emit('playerDisconnected', socket.id);
  });
});

const PORT = process.env.PORT || 3001;
server.listen(PORT, () => console.log(`Server running at http://localhost:${PORT}`));

// Render SIGTERMs the old instance once a new deploy is healthy. Without this,
// live sessions linger on the OLD build until the process is killed — cut them
// immediately so everyone reconnects to the new version.
process.on('SIGTERM', () => {
  console.log('SIGTERM — new deploy going live, disconnecting all sessions');
  sysMsg('Server updating — you will be reconnected in a few seconds.');
  io.disconnectSockets(true);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
});

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

rl.on('line', (input) => {
  const parts = input.trim().split(' ');
  const cmd = parts[0];
  const arg = parts.slice(1).join(' ');

  if (cmd === 'kick' && arg) {
    let targetId = players[arg] ? arg : Object.keys(players).find(id => players[id].name === arg);
    if (targetId) {
      const sock = io.sockets.sockets.get(targetId);
      if (sock) {
        sock.emit('kicked');
        sock.disconnect(true);
        console.log(`Kicked player: ${arg}`);
      }
    } else {
      console.log(`Player not found: ${arg}`);
    }
  } else if (cmd === 'list') {
    console.log(Object.keys(players).map(id => `${id}: ${players[id].name}`).join('\n') || 'No players connected');
  } else if (cmd === 'spawn') {
    const allItems = Object.values(ITEMS_BY_CATEGORY).flat();
    const itemName = parts[1];
    const playerNameOrId = parts.slice(2).join(' ');

    if (!itemName) {
      console.log('Usage: spawn <item> <player_name_or_id>');
      console.log('Available items:\n  ' + allItems.join('\n  '));
      return;
    }

    if (!allItems.includes(itemName)) {
      console.log(`Invalid item: '${itemName}'. Type 'spawn' for a list.`);
      return;
    }

    if (!playerNameOrId) {
      console.log(`Please specify a player for item '${itemName}'.`);
      return;
    }

    let targetId = playerNameOrId;
    if (!players[targetId]) {
      targetId = Object.keys(players).find(id => players[id].name === playerNameOrId);
    }

    const sock = targetId ? io.sockets.sockets.get(targetId) : null;
    if (sock) {
      sock.emit('itemPickedUp', itemName);
      console.log(`Gave '${itemName}' to ${players[targetId].name}.`);
    } else {
      console.log(`Player not found: ${playerNameOrId}`);
    }
  }
});
  