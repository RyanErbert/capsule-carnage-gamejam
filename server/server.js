const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');
const readline = require('readline');
const mapgen = require('./mapgen');
const parametrics = require('./parametrics');
const { LAYERS, GROUND } = mapgen;

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
// ...and WHEN that commit was made, so a client can tell which of the two is
// behind. Without it "the builds differ" is all anyone knows, and a client on an
// older commit would ask the server to rebuild to the very commit it is already
// running, forever.
function readGitCommitTime() {
  try {
    const logPath = path.join(__dirname, '..', '.git', 'logs', 'HEAD');
    const lines = fs.readFileSync(logPath, 'utf8').trim().split(/\r?\n/);
    const head = lines[lines.length - 1].split(/\t/)[0].split(' ');
    for (let i = head.length - 1; i >= 0; i--) {
      if (/^\d{9,}$/.test(head[i])) return parseInt(head[i], 10);
    }
  } catch (e) { /* not running from a clone */ }
  return 0;
}
const SERVER_BUILD_TIME = readGitCommitTime();

// version.json is the answer to "which build is newer" -- a hash cannot be
// ordered, a number can. Client and server read the same file.
function readVersion() {
  try {
    const v = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'version.json'), 'utf8'));
    return [v.major | 0, v.minor | 0, v.build | 0];
  } catch (e) { return [0, 0, 0]; }
}
const SERVER_VERSION = readVersion();
console.log(`Server version: v${SERVER_VERSION.join('.')}`);
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

// Who a socket IS, from the moment it opens the lobby. `players` only exists
// once someone has 'ready'd into an actual match, which is why the lobby roster
// used to be blind to anyone sitting in the menu and chat called them all
// Spectator. Profiles fill that gap; a live player entry always wins.
const profiles = {};

function profileOf(id) {
  return players[id] || profiles[id] || null;
}

// Only somebody who never introduced themselves — a browser on the spectator
// dashboard — has no name of their own.
function nameOf(id) {
  const p = profileOf(id);
  return p && p.name ? p.name : 'Spectator';
}

// Lobby, map editor, or out on the field.
function whereIs(id) {
  if (readyIds.has(id)) return 'game';
  if (editors.has(id)) return 'editor';
  return 'lobby';
}

function presenceList() {
  const out = [];
  for (const id of io.sockets.sockets.keys()) {
    const p = profileOf(id);
    if (!p) continue;
    out.push({ id, name: p.name, color: p.skinColor || '#ffffff', where: whereIs(id) });
  }
  return out;
}

function pushPresence() {
  io.emit('presence', presenceList());
}

// Everything said this session, replayed to anyone who connects. Scene changes
// build a whole new chat box, so without this the conversation restarted every
// time you moved between the lobby, the editor and the game.
const CHAT_LOG_MAX = 80;
const chatLog = [];

function logChat(entry) {
  chatLog.push(entry);
  while (chatLog.length > CHAT_LOG_MAX) chatLog.shift();
}

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
  return zoneList().map(h => ({ x: -halfX() + h[1] * 4 + 2, z: -halfZ() + h[0] * 4 + 2 }));
}
function inDeadzone(r, c) {
  return zoneList().some(h => Math.abs(r - h[0]) <= 2 && Math.abs(c - h[1]) <= 2);
}

function zoneFree(r, c, exceptId) {
  return Object.entries(spawnZones).every(([id, z]) => id === exceptId
    || Math.abs(r - z[0]) > ZONE_SEPARATION || Math.abs(c - z[1]) > ZONE_SEPARATION);
}

// A claimed spawn CARVES its block open: ground restored underfoot, every
// layer above it cleared. Terrain painted before or after can't bury a spawn.
function clearZoneColumn(r, c) {
  if (!paintLayers) paintLayers = defaultLayers();
  const words = gridWords();
  for (let rr = Math.max(0, r - 2); rr <= Math.min(gridH() - 1, r + 2); rr++) {
    for (let cc = Math.max(0, c - 2); cc <= Math.min(gridW() - 1, c + 2); cc++) {
      const i = rr * words + (cc >> 5);
      const bit = 1 << (31 - (cc & 31));
      paintLayers[0][i] = (paintLayers[0][i] | bit) >>> 0;
      paintLayers[GROUND][i] = (paintLayers[GROUND][i] | bit) >>> 0;
      for (let li = GROUND + 1; li < LAYERS; li++)
        paintLayers[li][i] = (paintLayers[li][i] & ~bit) >>> 0;
    }
  }
  io.emit('creativePaint', { layers: paintLayers, gs: gridShape() });
}

// Everyone who walks into the map creator gets a spawn without hunting for a
// free pixel. Only while a map is still being painted — mid-game joiners take
// the map as it stands.
function autoClaimZone(id) {
  if (spawnZones[id] || creativeLayers) return;
  for (let tries = 0; tries < 240; tries++) {
    const m = 3;   // keep clear of the map edge
    const r = m + Math.floor(Math.random() * Math.max(1, gridH() - m * 2));
    const c = m + Math.floor(Math.random() * Math.max(1, gridW() - m * 2));
    if (!zoneFree(r, c, id)) continue;
    spawnZones[id] = [r, c];
    clearZoneColumn(r, c);
    io.emit('spawnZones', spawnZones);
    return;
  }
}

// The painted grid is gridW x gridH pixels; each ROW is gridWords() uint32
// bitmasks laid out flat (row * words + (col >> 5)), bit (31 - col&31) =
// filled. At 32x32 this is byte-identical to the original one-word rows.
function gridW() { return gameSettings.gridW || 32; }
function gridH() { return gameSettings.gridH || 32; }
function halfX() { return gridW() * 2; }   // pixels are 4 m
function halfZ() { return gridH() * 2; }
function gridWords(w) { return Math.ceil((w || gridW()) / 32); }
function gridBit(rows, r, c) {
  return (rows[r * gridWords() + (c >> 5)] >>> (31 - (c & 31))) & 1;
}

// Highest painted layer at a pixel (-1 = pit), and the world Y its surface
// meshes out at: 8 m slabs stacked over bedrock, surface ~1 m into the slab.
function pixelTop(r, c) {
  if (!creativeLayers) return 0;
  let top = -1;
  for (let li = 0; li < LAYERS; li++) if (gridBit(creativeLayers[li], r, c)) top = li;
  return top;
}
// `top` is a layer index: GROUND meshes out at y ~= 1, each slab above adds
// 8 m, and below GROUND you're in the basement or straight through to bedrock.
function surfaceY(top) {
  if (top < 0) return -15;
  if (top < GROUND) return -7;
  return (top - GROUND) * 8 + 1;
}

function normLayers(g) {
  if (!g || !Array.isArray(g.layers) || g.layers.length !== LAYERS) return null;
  // A canvas painted at a stale size is dropped; clients resize on the
  // gameSettings broadcast and repaint fresh.
  const gs = Array.isArray(g.gs) ? g.gs : [32, 32];
  if (Number(gs[0]) !== gridW() || Number(gs[1]) !== gridH()) return null;
  const expect = gridH() * gridWords();
  const out = [];
  for (const rows of g.layers) {
    if (!Array.isArray(rows) || rows.length !== expect) return null;
    out.push(rows.map(n => Number(n) >>> 0));
  }
  return out;
}

// Every layers payload carries its shape so clients can resize with it.
function gridShape() { return [gridW(), gridH()]; }

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
  speedScale: 1.3,           // movement tuning: top speed        -> 11.7 m/s
  accelScale: 1.5,           // ...how hard you push toward it     -> 90 m/s2
  turnScale: 1.0,            // ...how fast momentum swings        -> 4.0 /s
  boostScale: 1.93,          // ...and what holding shift is worth -> 3.9x
  jumpScale: 0.58,           // ~1/3 of web jump HEIGHT (velocity scales by sqrt)
  gravityScale: 1.0,
  gridW: 32,                 // painted map size in pixels, per axis
  gridH: 32,
  gen: mapgen.DEFAULT_SCHEMES.slice(),   // which generator passes run
  subterranean: false,       // sink the arena into the ground
  monkey: true               // Super Monkey Ball physics: tilt the world, not the ball
};
// Each axis picks its own size, so any oblong is buildable. Pixels are 4 m, so
// 96x48 is a 384x192 m arena. Multiples of 4 only: the voxel lattice is
// PX * 2 + 16 cells and has to stay divisible by the 8-cell chunk.
const GRID_SIZES = [24, 32, 40, 48, 56, 64, 80, 96];

// --- Slayer: coins ARE health. Players spawn with 100, damage sheds coins,
// zero triggers a death explosion (clients carve + scorch) and a respawn
// countdown, after which the server restores 100.
const SLAYER_START = 100;
const RESPAWN_MS = 4000;
const deadUntil = {};   // socket.id -> timestamp while dead

// --- Kill credit ---
// Every damage event stamps its victim with WHO did it and WHAT with, so the
// death line can name the weapon and the killer banks the point. A stamp
// older than HIT_CREDIT_MS has gone cold: the death reads as a plain blast.
const kills = {};        // socket.id -> confirmed kills
const lastHit = {};      // victim id -> { by, cause, at }
const HIT_CREDIT_MS = 8000;

const DEATH_LINES = {
  rats: '%s was devoured by rats',
  crows: '%s was murdered by crows',
  rocket: '%s was exploded by rockets',
  mine: '%s tripped on a landmine',
  machinegun: '%s was turned into swiss cheese',
  turret: '%s was turned by a sentry',
  drill: '%s got screwed',
  terra: '%s dug their own grave',
  ghost: '%s headbutted a ghost',
  blast: '%s exploded'
};
const CAUSES = Object.keys(DEATH_LINES);

function creditHit(victimId, byId, cause) {
  if (!players[victimId]) return;
  lastHit[victimId] = {
    by: (byId && byId !== victimId && players[byId]) ? byId : null,
    cause: CAUSES.includes(cause) ? cause : 'blast',
    at: Date.now()
  };
}

function freshHit(victimId) {
  const hit = lastHit[victimId];
  return (hit && Date.now() - hit.at < HIT_CREDIT_MS) ? hit : null;
}

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
  // What killed them names the line, and whoever landed it banks the kill.
  const hit = freshHit(id);
  // Where the killer was standing rides along, so the dead player's camera can
  // hold on them instead of cutting straight to the respawn.
  const by = hit && hit.by && players[hit.by] ? hit.by : null;
  const byPos = by
    ? { byX: players[by].x, byY: players[by].y, byZ: players[by].z }
    : {};
  io.emit('playerDied', { id, ...pos, respawnMs: RESPAWN_MS, by, ...byPos });
  sysMsg(DEATH_LINES[hit ? hit.cause : 'blast'].replace('%s', players[id].name));
  if (hit && hit.by) {
    kills[hit.by] = (kills[hit.by] || 0) + 1;
    io.emit('kills', kills);
  }
  delete lastHit[id];
  // The death blast damages everyone nearby (chain deaths welcome).
  explosionDamage(pos, id, 'blast', id);
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
function explosionDamage(pos, excludeId, cause, byId) {
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
      creditHit(id, byId, cause);
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

// Three big cores per map, BURIED: they sit well under the painted surface,
// scattered away from the spawn zones and from each other, so healing is
// something you dig for and then haul back rather than something you stand on.
const BIG_CORES = 3;
const CORE_DEPTH = 7;      // meters below the painted surface

function autoPlaceGenerator() {
  activeGenerators.length = 0;
  if (creativeLayers) {
    const picks = [];
    for (let tries = 0; tries < 800 && picks.length < BIG_CORES; tries++) {
      // Constraints relax if the map is too cramped to satisfy them
      const away = tries < 400 ? 34 : 12;
      const spread = tries < 400 ? 26 : 8;
      const r = 2 + Math.floor(Math.random() * Math.max(1, gridH() - 4));
      const c = 2 + Math.floor(Math.random() * Math.max(1, gridW() - 4));
      const top = pixelTop(r, c);
      if (top < 0 || inDeadzone(r, c)) continue;
      const x = -halfX() + c * 4 + 2, z = -halfZ() + r * 4 + 2;
      if (homeWorlds().some(h => Math.hypot(h.x - x, h.z - z) < away)) continue;
      if (picks.some(p => Math.hypot(p.x - x, p.z - z) < spread)) continue;
      picks.push({ x, y: surfaceY(top) - CORE_DEPTH, z });
    }
    picks.forEach((p, i) => activeGenerators.push({
      id: 'gen-core-' + i, x: p.x, y: p.y, z: p.z,
      holder: null, energy: GEN_ENERGY, mini: false, buried: true
    }));
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
    // Overlapping rings STACK: park two cores together and heal twice as fast.
    let gained = 0;
    for (const g of activeGenerators) {
      if (g.energy <= 0) continue;
      const dx = p.x - g.x, dy = p.y - g.y, dz = p.z - g.z;
      if (dx * dx + dy * dy + dz * dz <= GEN_HEAL_RANGE * GEN_HEAL_RANGE) {
        gained += 1;
        g.energy -= 1;
        touched.add(g);
      }
    }
    if (gained > 0) {
      scores[id] = (scores[id] || 0) + gained;
      changed = true;
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

// Everyone's round trip, broadcast on its own slow tick rather than bolted to
// the score events: a ping that updates twice a second is a ping, and scores
// fire in nine different places for reasons that have nothing to do with this.
function pingMap() {
  const out = {};
  for (const id of readyIds) {
    if (players[id] && typeof players[id].ping === 'number') out[id] = players[id].ping;
  }
  return out;
}
setInterval(() => {
  if (readyIds.size) io.emit('pings', pingMap());
}, 2000);


// --- Castle walls (parametric, brick-built) ---
const activeCastles = [];  // { id, nodes, arch, kind, h, holes }

// --- Parametric structures (server/parametrics.js) ---
// Records, never geometry: { id, type, owner, nodes, params }. Saved to disk on
// every change and reloaded on boot, so a redeploy does not take the world with
// it. See parametrics.js for why the wipe archives instead of deleting.
{
  const restored = parametrics.load();
  if (restored) console.log(`[parametrics] restored ${restored} structures`);
}

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
  yellow: ['block', 'wall', 'ramp', 'platform', 'bridge_gun', 'terragun']
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
// (The button that starts it is just labelled END GAME — it still polls.)
let endVote = null;
const END_VOTE_TIMEOUT_MS = 30000;

function sysMsg(text) {
  logChat({ sys: true, text });
  io.emit('systemMessage', { text });
}

function votesNeeded() {
  return endVote ? Math.floor(endVote.voters.size / 2) + 1 : 0;
}

// The tally, so the HUD can put YES/NO under your thumb instead of making you
// type /vote in the middle of a firefight.
function endVoteState() {
  if (!endVote) return null;
  return { yes: endVote.yes.size, no: endVote.no.size, needed: votesNeeded() };
}

function pushEndVote() {
  io.emit('endVote', endVoteState());
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
  pushEndVote();
  if (passed) endGame();
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
  // Pickups belong to the structures: they arrive with the first 'wfcSpots'
  // report. Loose ground scatter is only the fallback for a map with nothing
  // standing on it.
  if (wfcExpected > 0) { io.emit('currentPedestals', pedestals); return; }
  scatterPedestals();
}

function scatterPedestals() {
  pedestals.length = 0;
  if (!creativeLayers || !gameSettings.pedestals) { io.emit('currentPedestals', pedestals); return; }
  // Candidates: any pixel with a floor, clear of the home deadzone, whose
  // 4 neighbours are no taller than it (so nothing to clip into).
  const candidates = [];
  for (let r = 1; r < gridH() - 1; r++) {
    for (let c = 1; c < gridW() - 1; c++) {
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
    const x = -halfX() + cand.c * 4 + 2;
    const z = -halfZ() + cand.r * 4 + 2;
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
  clearStartVote();
  for (const id of Object.keys(scores)) scores[id] = startingScore();
  io.emit('scores', scores);
  for (const id of Object.keys(kills)) delete kills[id];
  io.emit('kills', kills);
  holderID = null;
  io.emit('holderChanged', holderID);
  readyIds.clear();
  terrainEdits = [];
  creativeLayers = null;
  paintLayers = null;
  editors.clear();
  stopClaim();
  io.emit('claimState', null);
  for (const id of Object.keys(spawnZones)) delete spawnZones[id];
  io.emit('spawnZones', spawnZones);
  io.emit('editVote', null);   // legacy clients still hide their vote bar on this
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
  parametrics.clear();   // archives first
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
  io.emit('currentParametrics', []);
  io.emit('currentVehicles', []);
  io.emit('currentGenerators', []);
  io.emit('currentTurrets', []);
  io.emit('currentFlocks', []);
  if (levelLocked) { levelLocked = false; io.emit('lobbyLocked', false); }
  io.emit('gameEnded');
}

// Sockets sitting in the map editor. They haven't 'ready'd yet, so readyIds
// doesn't see them - the editor announces itself instead.
const editors = new Set();

// --- Start vote --------------------------------------------------------------
// Cutting the sculpting phase short takes EVERYONE in the editor: one person
// pressing START GAME opens a poll, and the map only generates early if every
// last painter says yes. Nobody answering isn't a yes — the edit timer runs out
// on its own and starts the match anyway, so a vote never blocks the round.
let startVote = null;            // { yes:Set, no:Set, timer }
const START_VOTE_MS = 30000;

function startVoteState() {
  if (!startVote) return null;
  return {
    voters: [...editors],
    yes: [...startVote.yes].filter(id => editors.has(id)),
    no: [...startVote.no].filter(id => editors.has(id))
  };
}

function pushStartVote() {
  io.emit('startVote', startVoteState());
}

function clearStartVote() {
  if (!startVote) return;
  clearTimeout(startVote.timer);
  startVote = null;
  pushStartVote();
}

function openStartVote(id) {
  if (startVote) { castStartVote(id, true); return; }
  // Sculpting alone: there's nobody to poll, so the button is just a button.
  if (editors.size <= 1) { applyEditVote('generate'); return; }
  startVote = { yes: new Set([id]), no: new Set(), timer: null };
  startVote.timer = setTimeout(() => {
    clearStartVote();
  }, START_VOTE_MS);
  pushStartVote();   // the bar says START? 1/2 on its own
  checkStartVote();
}

function castStartVote(id, yes) {
  if (!startVote || !editors.has(id)) return;
  if (yes) { startVote.yes.add(id); startVote.no.delete(id); }
  else { startVote.no.add(id); startVote.yes.delete(id); }
  pushStartVote();
  checkStartVote();
}

function checkStartVote() {
  if (!startVote) return;
  const voters = [...editors];
  if (voters.some(id => startVote.no.has(id))) {
    clearStartVote();
    return;
  }
  if (voters.length && voters.every(id => startVote.yes.has(id))) {
    clearStartVote();
    applyEditVote('generate');
  }
}

// Lobby start countdown: one shared timer so every menu counts in sync.
const START_COUNTDOWN_MS = 3000;
let startTimer = null;

function defaultLayers() {
  const w = gridW(), words = gridWords(w);
  const out = [];
  for (let li = 0; li < LAYERS; li++) {
    out.push([]);
    for (let r = 0; r < gridH(); r++)
      for (let wi = 0; wi < words; wi++) {
        const bits = Math.min(32, w - wi * 32);
        // Basement AND ground start solid; everything above them starts empty.
        out[li].push(li <= GROUND ? ((0xFFFFFFFF << (32 - bits)) >>> 0) : 0);
      }
  }
  return out;
}

// The map goes live: either the editor voted it in or the clock ran out.
function applyEditVote(kind) {
  if (kind === 'clear') {
    paintLayers = null;
    io.emit('paintCleared');
    return;
  }
  clearStartVote();
  creativeLayers = paintLayers || defaultLayers();
  terrainEdits = [];
  stopClaim();
  io.emit('creativeGrid', { layers: creativeLayers, gs: gridShape() });
  autoPlaceStructures();    // structures first: they carry the item pedestals
  autoPopulatePedestals();
  autoPlaceGenerator();
}

// Scatter a few wave-function-collapsed compounds (Items/wfc.gd) across the
// finished map, so the structures are part of the world instead of something
// you have to fly the drone out and place by hand. The payload is one seed —
// every client collapses the identical building from it.
const WFC_FOOTPRINT = 48;   // metres per side, mirrors builds.gd WFC_SIZE * CELL

// Which compounds carry which item pedestals. The client that first collapses
// a seed reports where its balconies are (see 'wfcSpots'): the grid only exists
// in Items/wfc.gd, so the server places items where it is told, not by guess.
const wfcSpotsSeen = new Set();
let wfcExpected = 0;

function autoPlaceStructures() {
  for (let i = activeBuilds.length - 1; i >= 0; i--)
    if (activeBuilds[i].type === 'wfc') activeBuilds.splice(i, 1);
  wfcSpotsSeen.clear();
  wfcExpected = 0;
  if (!creativeLayers) return;
  const want = Math.max(2, Math.min(6, Math.round(Math.sqrt(gridW() * gridH()) / 20)));
  const picks = [];
  const half = WFC_FOOTPRINT / 2;
  const pxRadius = Math.ceil(half / 4);
  for (let tries = 0; tries < 900 && picks.length < want; tries++) {
    const pad = pxRadius + 1;               // keep the footprint on the map
    const r = pad + Math.floor(Math.random() * Math.max(1, gridH() - pad * 2));
    const c = pad + Math.floor(Math.random() * Math.max(1, gridW() - pad * 2));
    if (inDeadzone(r, c)) continue;
    // Seat it on the LOWEST ground under its whole footprint: picking the
    // height of the centre pixel alone left half of a compound hanging over a
    // slope with daylight under it. The foundations do the rest — they are
    // pillars now, so uneven ground under a structure is the intended look.
    let low = 99, holes = 0;
    for (let rr = r - pxRadius; rr <= r + pxRadius; rr++)
      for (let cc = c - pxRadius; cc <= c + pxRadius; cc++) {
        const t = pixelTop(rr, cc);
        if (t < 0) holes++;
        else if (t < low) low = t;
      }
    if (low === 99 || holes > 10) continue;  // too much void to stand on
    const x = -halfX() + c * 4 + 2, z = -halfZ() + r * 4 + 2;
    if (homeWorlds().some(hm => Math.hypot(hm.x - x, hm.z - z) < 30)) continue;
    // Close enough to be linked by a walkway, far enough to be its own node
    if (picks.some(p => Math.hypot(p.x - x, p.z - z) < WFC_FOOTPRINT * 1.05)) continue;
    picks.push({ x, y: surfaceY(low) - 0.4, z });
  }
  wfcExpected = picks.length;
  picks.forEach((p, i) => {
    const build = {
      id: 'wfc-' + Date.now().toString(36) + Math.random().toString(36).substr(2, 4),
      type: 'wfc', seed: (Math.random() * 0xffffffff) >>> 0,
      // Every third one is a silo: roofed corridors and tunnels instead of
      // open terraces, and it goes in the ground rather than on it.
      style: i % 3 === 2 ? 'silo' : 'surface',
      x: p.x, y: i % 3 === 2 ? p.y - 6 : p.y, z: p.z,
      ry: (Math.floor(Math.random() * 4) * Math.PI) / 2
    };
    activeBuilds.push(build);
    io.emit('buildPlaced', build);
  });
  // If nobody is connected to collapse them, the map still needs pickups.
  setTimeout(() => {
    if (wfcExpected && pedestals.length === 0) scatterPedestals();
  }, 8000);
}

// =========================================================================
// CLAIM PHASE (Xonix)
// =========================================================================
// The map creator opens on a seeded world (mapgen.js), not a blank plain, and
// who gets to EDIT which part of it is decided by a game of SNAKE.
//
// You are always moving. You cannot stop, only turn. Everyone starts on a small
// home plot, and behind you runs a trail of placed blocks. Ground is taken by
// leaving your own territory and coming back to it: the loop that draws closes
// against LAND YOU ALREADY OWN, never against the live trail itself, and
// everything sealed inside falls in with it. The map boundary is a wall you
// stall against. Drive into ANOTHER player's trail and they are out of the
// round, and you get fifteen more seconds to spend on the board.
//
// When the clock runs out (or someone ends it early) the unclaimed ground fogs
// over: from then on you only see and sculpt your own territory, until the
// edit timer expires or someone starts the game.
//
// Server-authoritative down to the cell: cursors move on the server's tick and
// clients only send a direction, so nobody's map can drift from anyone else's.

const FREE = -1;                // nobody's yet
const CLAIM_TICK_MS = 130;      // one pixel of travel per tick
const EDIT_MS = 5 * 60 * 1000;  // sculpting time once the land is divided
const GIFT_R = 3;               // radius of the consolation region, in pixels
const HOME_R = 2;               // the plot you start the grab standing on
const CUT_BONUS_MS = 15000;     // taking someone out buys you more runtime

let claim = null;
let claimTimer = null;
let claimPending = false;       // enterEditor sent, waiting for a client

// Big maps take longer to cross, so they get longer — but sub-linearly, or a
// 96x96 claim would outlast everyone's patience.
function claimMs(w, h) {
  return Math.round((20 + Math.sqrt(w * h) * 1.2) * 1000);
}

function claimIdx(r, c) { return r * claim.w + c; }

// One char per cell, '0' = edge, '1' = unclaimed, '2'+ = player index. A 96x96
// board is 9 KB of plain text instead of a 25 KB array of numbers.
function claimBoard() {
  let s = '';
  for (let i = 0; i < claim.owner.length; i++) s += String.fromCharCode(50 + claim.owner[i]);
  return s;
}

function claimSnapshot() {
  if (!claim) return null;
  return {
    phase: claim.phase,
    gs: [claim.w, claim.h],
    ids: claim.ids,
    own: claimBoard(),
    pos: claim.ids.map(id => claim.pos[id] || [-1, -1]),
    dead: claim.ids.map(id => !id || !!claim.dead[id]),
    trail: claimTrail(),
    // Milliseconds remaining, not a wall-clock deadline: client clocks drift.
    t: Math.max(0, claim.endsAt - Date.now())
  };
}

// Every live trail cell as flat [idx, playerIndex, ...] pairs.
function claimTrail() {
  const out = [];
  for (let i = 0; i < claim.trail.length; i++)
    if (claim.trail[i] >= 0) out.push(i, claim.trail[i]);
  return out;
}

function startClaim() {
  stopClaim();
  claimPending = false;
  const w = gridW(), h = gridH();
  const seed = (Math.random() * 0xffffffff) >>> 0;
  const world = mapgen.generate(w, h, seed, {
    schemes: gameSettings.gen, subterranean: gameSettings.subterranean
  });
  paintLayers = world.layers;
  // A grab means a NEW map: nothing from the last round survives it.
  creativeLayers = null;
  terrainEdits = [];
  claim = {
    phase: 'claim', w, h, seed,
    owner: new Int8Array(w * h).fill(FREE),
    trail: new Int8Array(w * h).fill(-1),
    ids: [], pos: {}, dir: {}, dead: {},
    endsAt: Date.now() + claimMs(w, h)
  };
  for (const id of editors) joinClaim(id);
  // Any zone claimed before the grab started belongs to the old map. Spawns
  // are placed by endClaim, inside the ground people actually won.
  for (const id of Object.keys(spawnZones)) delete spawnZones[id];
  io.emit('spawnZones', spawnZones);
  io.emit('creativePaint', { layers: paintLayers, gs: gridShape() });
  io.emit('claimState', claimSnapshot());
  claimTimer = setInterval(claimTick, CLAIM_TICK_MS);
}

function stopClaim() {
  if (claimTimer) { clearInterval(claimTimer); claimTimer = null; }
  if (claim) io.emit('claimState', null);   // clients drop the board and the fog
  claim = null;
  claimPending = false;
}

// Everyone starts ALREADY MOVING, spread across the board and aimed inward so
// nobody's first tick is into a wall, standing on a small plot of their own.
// The plot is the whole game's foundation: a loop only closes against ground
// you already own, so without one there'd be nothing to run back to.
function joinClaim(id) {
  if (!claim || claim.ids.includes(id)) return;
  claim.ids.push(id);
  let best = [claim.h >> 1, claim.w >> 1], bestD = -1;
  for (let tries = 0; tries < 200; tries++) {
    const m = 5;
    const cell = [
      m + Math.floor(Math.random() * Math.max(1, claim.h - m * 2)),
      m + Math.floor(Math.random() * Math.max(1, claim.w - m * 2))
    ];
    let d = 1e9;
    for (const other of claim.ids) {
      const p = claim.pos[other];
      if (p) d = Math.min(d, Math.abs(p[0] - cell[0]) + Math.abs(p[1] - cell[1]));
    }
    if (d > bestD) { bestD = d; best = cell; }
  }
  claim.pos[id] = best;
  const dr = (claim.h >> 1) - best[0], dc = (claim.w >> 1) - best[1];
  claim.dir[id] = Math.abs(dr) > Math.abs(dc)
    ? [Math.sign(dr) || 1, 0] : [0, Math.sign(dc) || 1];
  claim.dead[id] = false;
  const pi = claim.ids.indexOf(id);
  for (let r = best[0] - HOME_R; r <= best[0] + HOME_R; r++)
    for (let c = best[1] - HOME_R; c <= best[1] + HOME_R; c++) {
      if (r < 0 || c < 0 || r >= claim.h || c >= claim.w) continue;
      if (claim.owner[r * claim.w + c] === FREE) claim.owner[r * claim.w + c] = pi;
    }
}

function leaveClaim(id) {
  if (!claim) return;
  const pi = claim.ids.indexOf(id);
  if (pi === -1) return;
  wipeTrail(pi);
  delete claim.pos[id];
  delete claim.dir[id];
  delete claim.dead[id];
  // Their index has to stay put — the owner grid stores it in every cell they
  // took — so the slot is blanked rather than spliced out.
  claim.ids[pi] = '';
}

function wipeTrail(pi) {
  for (let i = 0; i < claim.trail.length; i++) if (claim.trail[i] === pi) claim.trail[i] = -1;
}

// Out of the round. Whatever they already fenced off stays theirs; the trail
// they were mid-way through drawing does not.
function killSnake(pi, reason) {
  const id = claim.ids[pi];
  if (!id || claim.dead[id]) return;
  claim.dead[id] = true;
  wipeTrail(pi);
  delete claim.pos[id];
  if (players[id]) sysMsg(`${players[id].name} ${reason}`);
}


function livingSnakes() {
  return claim.ids.filter(id => id && !claim.dead[id]).length;
}


// A loop closed: the trail becomes land, and then every pocket of unclaimed
// ground SEALED INSIDE it falls in with it. Sealed means it can't reach the
// map boundary through unclaimed ground — anybody's territory is a wall as far
// as the flood is concerned, which is exactly what makes a run out of your own
// plot and back into it enclose the ground it went around.
function closeLoop(pi) {
  const { w, h, owner, trail } = claim;
  let took = 0;
  for (let i = 0; i < trail.length; i++) {
    if (trail[i] !== pi) continue;
    trail[i] = -1;
    owner[i] = pi;
    took++;
  }
  if (!took) return 0;

  // Flood in from the border across everything still unclaimed: whatever the
  // flood never reaches is enclosed.
  const outside = new Uint8Array(w * h);
  const queue = [];
  for (let c = 0; c < w; c++) {
    pushOutside(queue, outside, c);
    pushOutside(queue, outside, (h - 1) * w + c);
  }
  for (let r = 0; r < h; r++) {
    pushOutside(queue, outside, r * w);
    pushOutside(queue, outside, r * w + w - 1);
  }
  for (let qi = 0; qi < queue.length; qi++) {
    const i = queue[qi];
    const r = (i / w) | 0, c = i % w;
    if (r > 0) pushOutside(queue, outside, i - w);
    if (r < h - 1) pushOutside(queue, outside, i + w);
    if (c > 0) pushOutside(queue, outside, i - 1);
    if (c < w - 1) pushOutside(queue, outside, i + 1);
  }
  for (let i = 0; i < owner.length; i++) {
    if (owner[i] !== FREE || outside[i]) continue;
    owner[i] = pi;
    took++;
  }
  return took;
}

function pushOutside(queue, outside, i) {
  if (outside[i] || claim.owner[i] !== FREE) return;
  outside[i] = 1;
  queue.push(i);
}


function claimTick() {
  if (!claim || claim.phase !== 'claim') return;
  if (Date.now() >= claim.endsAt) { endClaim(); return; }
  const adds = [];
  let board = false;   // something big enough to need a full snapshot
  for (let pi = 0; pi < claim.ids.length; pi++) {
    const id = claim.ids[pi];
    if (!id || claim.dead[id]) continue;
    const [dr, dc] = claim.dir[id];
    const [r, c] = claim.pos[id];
    const nr = r + dr, nc = c + dc;
    // The boundary is a wall you lean on, not a cliff: you stall against it
    // until you steer away.
    if (nr < 0 || nc < 0 || nr >= claim.h || nc >= claim.w) continue;
    const ni = nr * claim.w + nc;
    const hit = claim.trail[ni];
    if (hit >= 0 && hit !== pi) {
      // Cut someone off mid-loop: they're out of the round, and the clock
      // gives you fifteen more seconds to spend on the board. Alone out there,
      // fifteen seconds is ALL that's left — a solo victory lap, not a stroll.
      killSnake(hit, 'was cut off.');
      claim.endsAt = livingSnakes() <= 1
        ? Date.now() + CUT_BONUS_MS : claim.endsAt + CUT_BONUS_MS;
      board = true;
    }
    claim.pos[id] = [nr, nc];
    const o = claim.owner[ni];
    // Only LAND YOU ALREADY OWN closes the loop. A live trail is not ground
    // yet — running back over your own is inert, and anyone else's territory
    // is a neutral crossing that leaves no trail behind.
    if (o === pi) {
      if (closeLoop(pi) > 0) board = true;
    } else if (o === FREE && claim.trail[ni] < 0) {
      claim.trail[ni] = pi;
      adds.push(ni, pi);
    }
  }
  if (board) {
    io.emit('claimState', claimSnapshot());
    return;
  }
  io.emit('claimTick', {
    t: Math.max(0, claim.endsAt - Date.now()),
    pos: claim.ids.map(id => (id && claim.pos[id]) || [-1, -1]),
    add: adds
  });
}

// Clock's up. Anyone shut out gets a plot anyway, spawns drop inside the
// territory people actually won, and the sculpting timer starts.
function endClaim() {
  if (!claim) return;
  claim.phase = 'edit';
  for (let i = 0; i < claim.trail.length; i++) claim.trail[i] = -1;
  for (let pi = 0; pi < claim.ids.length; pi++) if (claim.ids[pi]) giftIfLandless(pi);
  claim.endsAt = Date.now() + EDIT_MS;
  for (const id of claim.ids) if (id) claimSpawnFor(id);
  io.emit('spawnZones', spawnZones);
  io.emit('claimState', claimSnapshot());
  clearInterval(claimTimer);
  claimTimer = setInterval(() => {
    if (!claim || claim.phase !== 'edit') return;
    if (Date.now() >= claim.endsAt) applyEditVote('generate');
  }, 1000);
}

// "If a player has no tiles, a small circular region is gifted to them."
function giftIfLandless(pi) {
  const { w, h, owner } = claim;
  if (owner.includes(pi)) return;
  let best = null, bestScore = -1;
  for (let tries = 0; tries < 400; tries++) {
    const r = GIFT_R + 1 + Math.floor(Math.random() * Math.max(1, h - GIFT_R * 2 - 2));
    const c = GIFT_R + 1 + Math.floor(Math.random() * Math.max(1, w - GIFT_R * 2 - 2));
    let free = 0;
    for (let dr = -GIFT_R; dr <= GIFT_R; dr++)
      for (let dc = -GIFT_R; dc <= GIFT_R; dc++)
        if (dr * dr + dc * dc <= GIFT_R * GIFT_R && owner[(r + dr) * w + (c + dc)] === FREE) free++;
    if (free > bestScore) { bestScore = free; best = [r, c]; }
    if (bestScore >= (GIFT_R * 2 + 1) ** 2 * 0.7) break;
  }
  if (!best) return;
  for (let dr = -GIFT_R; dr <= GIFT_R; dr++)
    for (let dc = -GIFT_R; dc <= GIFT_R; dc++)
      if (dr * dr + dc * dc <= GIFT_R * GIFT_R) owner[(best[0] + dr) * w + (best[1] + dc)] = pi;
}

// A spawn inside your own land, as deep into it as the shape allows. Every
// owned pixel is scored rather than sampled: a gifted plot is only ~37 cells,
// and random probing missed it often enough to leave people spawn-less.
function claimSpawnFor(id) {
  const pi = claim.ids.indexOf(id);
  if (pi < 0 || spawnZones[id]) return;
  let best = null, bestScore = -1;
  for (let r = 3; r < claim.h - 3; r++) {
    for (let c = 3; c < claim.w - 3; c++) {
      if (claim.owner[r * claim.w + c] !== pi || !zoneFree(r, c, id)) continue;
      // Prefer a pixel whose whole 5x5 deadzone block is on home ground
      let own = 0;
      for (let dr = -2; dr <= 2; dr++)
        for (let dc = -2; dc <= 2; dc++)
          if (claim.owner[(r + dr) * claim.w + (c + dc)] === pi) own++;
      if (own > bestScore) { bestScore = own; best = [r, c]; }
    }
  }
  if (!best) return;
  spawnZones[id] = best;
  clearZoneColumn(best[0], best[1]);
}

// Who owns the pixel a given socket wants to sculpt. Before the clock runs out
// everything is still communal; after it, you're confined to your own ground.
function mayEdit(id, r, c) {
  if (!claim || claim.phase !== 'edit') return true;
  const pi = claim.ids.indexOf(id);
  return pi >= 0 && claim.owner[r * claim.w + c] === pi;
}

// Clients send the whole canvas per stroke burst, so the guard is a diff:
// changes on your own ground go through, changes anywhere else are reverted to
// what the server already had. No kick, no error - the brush just does nothing.
// Returns null while the land grab itself is running: nobody sculpts then.
function mergePaint(id, incoming) {
  if (claim && claim.phase === 'claim') return null;
  if (!claim || !paintLayers) return incoming;
  const w = gridW(), words = gridWords();
  const out = incoming.map(rows => rows.slice());
  let reverted = false;
  for (let r = 0; r < gridH(); r++) {
    for (let c = 0; c < w; c++) {
      if (mayEdit(id, r, c)) continue;
      const i = r * words + (c >> 5);
      const bit = 1 << (31 - (c & 31));
      for (let li = 0; li < LAYERS; li++) {
        const keep = ((out[li][i] & ~bit) | (paintLayers[li][i] & bit)) >>> 0;
        if (keep !== out[li][i]) { out[li][i] = keep; reverted = true; }
      }
    }
  }
  // Identity when the stroke was legal: the caller uses that to skip echoing
  // the canvas back at the painter mid-stroke, which would eat their input.
  return reverted ? out : incoming;
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
    buildTime: SERVER_BUILD_TIME,
    version: SERVER_VERSION,
    uptimeMs: Date.now() - STARTED_AT
  });

  // Creative-level snapshot on plain connection (scenes load after connect,
  // so this must not wait for 'ready').
  if (creativeLayers) {
    socket.emit('creativeGrid', { layers: creativeLayers, gs: gridShape() });
    socket.emit('terrainEdits', terrainEdits);
  }
  if (paintLayers) socket.emit('creativePaint', { layers: paintLayers, gs: gridShape() });
  if (claim) socket.emit('claimState', claimSnapshot());
  socket.emit('spawnZones', spawnZones);
  socket.emit('hello', { id: socket.id });
  socket.emit('gameSettings', gameSettings);
  socket.emit('currentSpawns', spawnPoints);
  // Pick the conversation up where the room left it, whichever menu you're in
  socket.emit('chatHistory', chatLog);
  socket.emit('presence', presenceList());
  if (startVote) socket.emit('startVote', startVoteState());

  socket.on('editing', (on) => {
    if (!on) {
      editors.delete(socket.id);
      pushPresence();
      checkStartVote();     // the last holdout walking out settles the poll
      pushStartVote();
      return;
    }
    editors.add(socket.id);
    pushPresence();
    if (startVote) pushStartVote();   // a latecomer is a vote still outstanding
    // First client to reach the creator opens the land grab, so the board is
    // on someone's screen before any cursor moves.
    if (claimPending) { claimPending = false; startClaim(); return; }
    if (!claim) { autoClaimZone(socket.id); return; }
    // A claim is running: a latecomer gets a cursor if the land grab is still
    // on, or a gifted plot and a spawn in it if the map is already divided.
    joinClaim(socket.id);
    if (claim.phase === 'edit') {
      giftIfLandless(claim.ids.indexOf(socket.id));
      claimSpawnFor(socket.id);
      io.emit('spawnZones', spawnZones);
    }
    io.emit('claimState', claimSnapshot());
  });

  // Lobby START: everyone in the lobby sees the same 5 s countdown, then all
  // of them land in the pixel editor together. If a session is already in
  // motion (painters at work or a live map), the caller just joins it.
  // Back in the lobby: stop counting this socket as a player in a live game.
  socket.on('leaveGame', () => {
    if (!readyIds.has(socket.id)) { pushPresence(); return; }
    readyIds.delete(socket.id);
    editors.delete(socket.id);
    socket.broadcast.emit('playerLeft', socket.id);
    pushPresence();
  });

  socket.on('requestStart', () => {
    // Something LIVE to join: a land grab, people sculpting, or a running game.
    // A finished round's leftover map is none of those — it's debris, and
    // treating it as a session to join is what used to drop the second player
    // straight into a generated map with no editor at all.
    if (claim || editors.size > 0 || readyIds.size > 0) {
      socket.emit('enterEditor');
      return;
    }
    if (startTimer) return;
    creativeLayers = null;
    paintLayers = null;
    terrainEdits = [];
    for (const id of Object.keys(spawnZones)) delete spawnZones[id];
    io.emit('paintCleared');
    io.emit('spawnZones', spawnZones);
    io.emit('startCountdown', { ms: START_COUNTDOWN_MS });
    startTimer = setTimeout(() => {
      startTimer = null;
      claimPending = true;
      io.emit('enterEditor');
      // The claim opens as soon as the first client reports for duty (below),
      // so cursors never start moving before anyone can see the board. This
      // is the backstop for the case where nobody ever announces.
      setTimeout(() => { if (claimPending) startClaim(); }, 2500);
    }, START_COUNTDOWN_MS);
  });

  // Xonix cursor steering: the client only ever says which way it's holding.
  socket.on('claimDir', (d) => {
    if (!claim || claim.phase !== 'claim' || claim.dead[socket.id]) return;
    const cur = claim.dir[socket.id];
    if (!cur) return;
    const dr = Math.sign(Number(d && d.dr) || 0);
    const dc = Math.sign(Number(d && d.dc) || 0);
    if (!dr && !dc) return;                       // you never stop, only turn
    // One axis at a time — diagonal trails can't enclose anything — and no
    // instant reversal onto the block you just laid.
    const next = (dr !== 0 && dc !== 0) ? [0, dc] : [dr, dc];
    if (next[0] === -cur[0] && next[1] === -cur[1]) return;
    claim.dir[socket.id] = next;
  });

  // Whoever's had enough ends the land grab; the fog and the edit timer start
  // immediately. (START GAME then ends the edit phase, same as before.)
  socket.on('endClaim', () => {
    if (!claim || claim.phase !== 'claim') return;
    const who = nameOf(socket.id);
    sysMsg(`${who} ended the grab.`);
    endClaim();
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
    const TUNABLE = ['speedScale', 'accelScale', 'turnScale', 'boostScale',
      'jumpScale', 'gravityScale'];
    if (readyIds.size > 0 && gameSettings.mode !== 'build' && !TUNABLE.includes(u.key)) {
      return;
    }
    const who = nameOf(socket.id);
    if (u.key === 'mode') {
      if (!MODES.includes(u.value)) return;
      gameSettings.mode = u.value;
      gameSettings.slayer = u.value === 'slayer';
      io.emit('gameSettings', gameSettings);
      sysMsg(`${who} set the gamemode to ${u.value}`);
      return;
    }
    if (u.key === 'gridW' || u.key === 'gridH') {
      const v = Number(Array.isArray(u.value) ? u.value[0] : u.value);
      if (!GRID_SIZES.includes(v)) return;
      if (gameSettings[u.key] === v) return;
      if (claim) return;                 // the size is set for this round
      gameSettings[u.key] = v;
      // The canvas is meaningless at a different size: start fresh
      paintLayers = null;
      io.emit('paintCleared');
      io.emit('gameSettings', gameSettings);
      sysMsg(`${who} set the map to ${gridW()}x${gridH()}`);
      return;
    }
    if (u.key === 'gen') {
      if (claim) return;
      const want = Array.isArray(u.value)
        ? u.value.filter(k => mapgen.SCHEMES.includes(k)) : [];
      gameSettings.gen = want;
      io.emit('gameSettings', gameSettings);
      sysMsg(`${who} set generation: ${want.join(' ') || 'flat'}`);
      return;
    }
    if (u.key === 'subterranean') {
      if (claim) return;
      gameSettings.subterranean = !!u.value;
      io.emit('gameSettings', gameSettings);
      sysMsg(`${who} turned subterranean ${gameSettings.subterranean ? 'ON' : 'OFF'}`);
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

  // --- Parametric structures -------------------------------------------------
  // Place once, then edit forever. A handle drag sends only the parameter it
  // moved and gets the whole record back, so every client rebuilds from one
  // payload and none of them can disagree about what is standing there.

  socket.on('placeParametric', (msg) => {
    const rec = parametrics.place(msg, nameOf(socket.id));
    if (rec) io.emit('parametricPlaced', rec);
  });

  socket.on('updateParametric', (msg) => {
    const rec = parametrics.update(msg);
    if (rec) io.emit('parametricUpdated', rec);
  });

  // Round-trip clock. Named netPing/netPong because socket.io has its own
  // ping/pong at the transport layer and reusing those names invites confusion
  // at best. The client times the round trip itself and sends its reading back
  // on the NEXT tick, which is how everyone else's ping reaches the scoreboard
  // without the server timing every client separately.
  socket.on('netPing', (m) => {
    const p = players[socket.id];
    if (p) {
      const rtt = Number(m && m.rtt);
      p.ping = Number.isFinite(rtt) && rtt >= 0 ? Math.min(9999, Math.round(rtt)) : -1;
    }
    socket.emit('netPong', { t: (m && m.t) || 0 });
  });

  socket.on('removeParametric', (id) => {
    if (parametrics.remove(id)) io.emit('parametricRemoved', id);
  });

  // Saved sets: every round wipe leaves one behind, and any of them can be
  // stood back up on the current map.
  socket.on('listParametricSaves', () => {
    socket.emit('parametricSaves', parametrics.listArchive());
  });

  socket.on('loadParametricSave', (name) => {
    const added = parametrics.loadArchive(name);
    for (const rec of added) io.emit('parametricPlaced', rec);
    if (added.length) sysMsg(`${nameOf(socket.id)} loaded ${added.length} structures`);
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
    t.f = !!(d && d.f);  // firing: drives the mouth and the barrel spin
    socket.broadcast.emit('turretAim', { id: t.id, ry: t.ry, rx: t.rx, f: t.f });
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
      // Spawns are removable, but a map with none has nowhere to put anyone.
      if (Object.keys(spawnZones).length <= 1) {
        return;
      }
      delete spawnZones[socket.id];
      io.emit('spawnZones', spawnZones);
      return;
    }
    const r = Math.max(0, Math.min(gridH() - 1, Math.floor(Number(p.r) || 0)));
    const c = Math.max(0, Math.min(gridW() - 1, Math.floor(Number(p.c) || 0)));
    if (!zoneFree(r, c, socket.id)) {
      return;
    }
    if (!mayEdit(socket.id, r, c)) {
      return;
    }
    spawnZones[socket.id] = [r, c];
    clearZoneColumn(r, c);
    io.emit('spawnZones', spawnZones);
  });

  // START GAME polls the editor: everyone sculpting has to agree to cut the
  // phase short. The edit timer is the backstop, so a stalled vote costs
  // nothing but the rest of the clock.
  socket.on('requestGenerate', () => {
    // Mid-grab there's nothing to generate yet — END GRAB is the button for
    // that. This also stops a client that missed the claim snapshot (and so
    // still shows a plain painter) from skipping everyone past the editor.
    if (claim && claim.phase === 'claim') {
      return;
    }
    openStartVote(socket.id);
  });
  socket.on('startVoteCast', (v) => castStartVote(socket.id, !!v));
  socket.on('requestClear', () => applyEditVote('clear'));

  // Live co-painting of the creative editor canvas (full 32-int grid per
  // stroke burst — tiny and idempotent).
  socket.on('creativePaint', (g) => {
    const layers = normLayers(g);
    if (!layers) return;
    const merged = mergePaint(socket.id, layers);
    if (!merged) return;
    paintLayers = merged;
    // Off-territory strokes were reverted, so the sender needs the corrected
    // canvas back too — otherwise their screen keeps a stroke nobody else has.
    if (merged === layers) socket.broadcast.emit('creativePaint', { layers: paintLayers, gs: gridShape() });
    else io.emit('creativePaint', { layers: paintLayers, gs: gridShape() });
  });

  socket.on('creativeGrid', (g) => {
    const layers = normLayers(g);
    if (!layers) return;
    creativeLayers = layers;
    terrainEdits = [];
    io.emit('creativeGrid', { layers: creativeLayers, gs: gridShape() });
    autoPlaceStructures();    // collapsed compounds to fight over...
    autoPopulatePedestals();  // ...which is where the item pedestals live
    autoPlaceGenerator();     // buried heal cores
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
    profiles[socket.id] = { name: players[socket.id].name, skinColor: color };
    lastActivity[socket.id] = Date.now();
    pushPresence();
    // First player to join locks the lobby (level + game settings) for everyone.
    if (!levelLocked) { levelLocked = true; io.emit('lobbyLocked', true); }
    console.log(`Player connected: ${socket.id} (${players[socket.id].name}, ${players[socket.id].shape})`);
    socket.emit('currentPlayers', { players, selfId: socket.id });
    socket.emit('holderChanged', holderID);
    socket.emit('scores', scores);
    socket.emit('kills', kills);
    socket.emit('pings', pingMap());
    socket.emit('currentPedestals', pedestals);
    socket.emit('currentTeleporters', activeTeleporters);
    socket.emit('currentMines', activeMines);
    socket.emit('currentPads', activePads);
    socket.emit('currentBuilds', activeBuilds);
    socket.emit('currentModels', activeModels);
    socket.emit('currentChannels', activeChannels);
    socket.emit('currentCastles', activeCastles);
    socket.emit('currentParametrics', parametrics.active);
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

  // Where a compound's balconies are. Only the client runs the collapse, so
  // the first report per structure is what the server places items on; every
  // later client sends the identical list and is ignored.
  socket.on('wfcSpots', (data) => {
    if (!data || typeof data.id !== 'string' || !Array.isArray(data.spots)) return;
    if (!gameSettings.pedestals || wfcSpotsSeen.has(data.id)) return;
    if (!activeBuilds.some(b => b.id === data.id && b.type === 'wfc')) return;
    wfcSpotsSeen.add(data.id);
    const added = [];
    data.spots.slice(0, 6).forEach((s, i) => {
      if (typeof s.x !== 'number' || typeof s.y !== 'number' || typeof s.z !== 'number') return;
      const ped = {
        id: data.id + '-p' + i, x: s.x, y: s.y, z: s.z,
        ry: Math.random() * Math.PI * 2,
        type: PED_TYPES[(pedestals.length + i) % PED_TYPES.length],
        currentItem: null, spawnTime: 0
      };
      pedestals.push(ped);
      added.push(ped);
    });
    for (const ped of added) io.emit('pedestalPlaced', ped);
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

  socket.on('machinegunHit', ({ targetId, dir, src }) => {
    if (!players[targetId] || isDead(targetId)) return;
    if (scores[targetId] > 0) {
      const pointsLost = Math.min(scores[targetId], 2);
      scores[targetId] -= pointsLost;
      creditHit(targetId, socket.id, src === 'turret' ? 'turret' : 'machinegun');
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
    explosionDamage(pos, null, (pos && pos.cause) || 'rocket', socket.id);
  });

  // A vehicle ran someone down. The driver's client owns the collision test;
  // the server does the damage so the flavour and the kill credit line up.
  socket.on('ramPlayer', (d) => {
    if (!d || !players[d.t] || isDead(d.t) || d.t === socket.id) return;
    if (!gameSettings.slayer || !(scores[d.t] > 0)) return;
    const dmg = Math.min(scores[d.t], Math.max(4, Math.min(35, Math.floor(Number(d.dmg) || 0))));
    scores[d.t] -= dmg;
    creditHit(d.t, socket.id, d.kind === 'drill' ? 'drill' : 'ghost');
    const dir = d.dir || { x: 0, y: 1, z: 0 };
    io.emit('applyImpulse', { id: d.t, dir, force: 60 });
    io.emit('scores', scores);
    checkDeath(d.t);
  });

  // Slayer self-destruct (K or /kill): zero out and run the death flow.
  socket.on('suicide', () => {
    if (!gameSettings.slayer || !players[socket.id] || isDead(socket.id)) return;
    scores[socket.id] = 0;
    checkDeath(socket.id);
  });

  // Self-inflicted health cost: gnawing critters, and the drill running on
  // your life. `n` is either a bare number (legacy) or { n, cause }.
  socket.on('selfDamage', (n) => {
    if (!gameSettings.slayer || !players[socket.id] || isDead(socket.id)) return;
    const raw = (n && typeof n === 'object') ? n.n : n;
    const amt = Math.min(3, Math.max(0, Math.floor(Number(raw) || 0)));
    if (!amt) return;
    scores[socket.id] = Math.max(0, (scores[socket.id] || 0) - amt);
    creditHit(socket.id, null, (n && typeof n === 'object') ? n.cause : 'blast');
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

  // `carry` distinguishes a core racked on a vehicle from one roped to a
  // player on foot: only the roped kind draws a tether on other clients. The
  // holder re-sends this when they mount or bail out mid-haul. Older clients
  // send a bare id string, which reads as the roped case.
  socket.on('grabGenerator', (d) => {
    const id = (d && typeof d === 'object') ? d.id : d;
    const carry = !!(d && typeof d === 'object' && d.carry);
    const gen = activeGenerators.find(g => g.id === id);
    if (!gen) return;
    if (gen.holder && gen.holder !== socket.id && io.sockets.sockets.get(gen.holder)) {
      socket.emit('generatorHolder', { id: gen.id, holder: gen.holder, carry: !!gen.carry });
      return;
    }
    gen.holder = socket.id;
    gen.carry = carry;
    io.emit('generatorHolder', { id: gen.id, holder: gen.holder, carry });
  });

  socket.on('releaseGenerator', (id) => {
    const gen = activeGenerators.find(g => g.id === id);
    if (gen && gen.holder === socket.id) {
      gen.holder = null;
      gen.carry = false;
      io.emit('generatorHolder', { id: gen.id, holder: null, carry: false });
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
      explosionDamage({ x: m.x, y: m.y, z: m.z }, null, 'mine', null);
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
    const p = profileOf(socket.id);
    const line = {
      id: socket.id,
      name: nameOf(socket.id),
      color: (p && p.skinColor) || '#ffffff',
      text: msg
    };
    logChat(line);
    io.emit('chatMessage', line);
  });

  // Who you are before you're a player: the lobby sends this the moment it
  // opens, and again whenever you change your name or colour.
  socket.on('profile', (d) => {
    if (!d || typeof d !== 'object') return;
    const name = (typeof d.name === 'string' ? d.name.slice(0, 16) : '') || 'Player';
    const color = typeof d.skinColor === 'string' ? d.skinColor.slice(0, 9) : '#ffffff';
    profiles[socket.id] = { name, skinColor: color };
    if (players[socket.id]) {
      players[socket.id].name = name;
      players[socket.id].skinColor = color;
      players[socket.id].color = color;
    }
    pushPresence();
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
    sysMsg(`${nameOf(socket.id)} voted end`);
    pushEndVote();
    checkEndVote();
  });

  socket.on('castVote', (val) => {
    if (!endVote || !endVote.voters.has(socket.id)) return;
    const yes = !!val;
    if (yes) { endVote.yes.add(socket.id); endVote.no.delete(socket.id); }
    else { endVote.no.add(socket.id); endVote.yes.delete(socket.id); }
    sysMsg(`${nameOf(socket.id)} voted ${yes ? 'yes' : 'no'}`);
    pushEndVote();
    checkEndVote();
  });

  socket.on('disconnect', () => {
    console.log(`Player disconnected: ${socket.id}`);
    const wasInGame = readyIds.has(socket.id);
    const leftName = players[socket.id] ? players[socket.id].name : null;
    delete players[socket.id];
    delete scores[socket.id];
    delete kills[socket.id];
    delete lastHit[socket.id];
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
        gen.carry = false;
        io.emit('generatorHolder', { id: gen.id, holder: null, carry: false });
      }
    }
    delete deadUntil[socket.id];
    delete profiles[socket.id];
    editors.delete(socket.id);
    pushPresence();
    checkStartVote();       // one fewer holdout can settle a running poll
    if (startVote) pushStartVote();
    if (claim) { leaveClaim(socket.id); io.emit('claimState', claimSnapshot()); }
    if (spawnZones[socket.id]) { delete spawnZones[socket.id]; io.emit('spawnZones', spawnZones); }
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
    checkIdleReset();
  });

  clearIdleReset();   // someone is here again
});

// An empty server drops its world after a grace period: the next person to
// connect gets a clean lobby instead of somebody's abandoned map.
const IDLE_RESET_MS = 30000;
let idleTimer = null;

function clearIdleReset() {
  if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
}

function checkIdleReset() {
  clearIdleReset();
  if (io.sockets.sockets.size > 0) return;
  if (!creativeLayers && !paintLayers && readyIds.size === 0) return;  // nothing to wipe
  idleTimer = setTimeout(() => {
    idleTimer = null;
    if (io.sockets.sockets.size > 0) return;
    console.log('Server empty for 30s — resetting the map');
    endGame();
  }, IDLE_RESET_MS);
}

const PORT = process.env.PORT || 3001;
server.listen(PORT, () => console.log(`Server running at http://localhost:${PORT}`));

// Render SIGTERMs the old instance once a new deploy is healthy. Without this,
// live sessions linger on the OLD build until the process is killed — cut them
// immediately so everyone reconnects to the new version.
process.on('SIGTERM', () => {
  console.log('SIGTERM — new deploy going live, disconnecting all sessions');
  sysMsg('Server updating.');
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
  