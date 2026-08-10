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
let creativePixels = null;
let terrainEdits = [];
let paintRows = null;  // in-progress editor canvas, live-synced between painters

// --- Global game settings (server-authoritative, alert on change) ---
const gameSettings = {
  infiniteAmmo: false,
  selfAssign: true,          // players may give themselves items via the god menu
  allowMidgameChanges: true, // when false, settings freeze while a game is running
  speedScale: 0.7,           // global movement tuning
  jumpScale: 0.58,           // ~1/3 of web jump HEIGHT (velocity scales by sqrt)
  gravityScale: 1.0
};

// --- Castle walls (parametric, brick-built) ---
const activeCastles = [];  // { id, a:{x,y,z}, b:{x,y,z}, arch }

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
  red: ['machinegun', 'rocket', 'mines'],
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
  const kind = endVote.kind || 'end';
  clearTimeout(endVote.timer);
  endVote = null;
  if (passed && kind === 'rebuild') { sysMsg('Vote passed — rebuilding the map.'); rebuildMap(); }
  else if (passed) { sysMsg('Vote passed — ending game.'); endGame(); }
  else sysMsg(kind === 'rebuild' ? 'Vote to rebuild the map failed.' : 'Vote to end the game failed.');
}

// Auto-populate item pedestals across the OPEN pixels of the creative map:
// movement (green) and weapon (red) pedestals so a fresh round has pickups
// without anyone god-placing them. Deterministic, capped at 12.
function autoPopulatePedestals() {
  if (!creativePixels) return;
  pedestals.length = 0;
  const types = ['green', 'red', 'green', 'red', 'yellow'];
  let n = 0;
  outer:
  for (let r = 2; r < 30; r += 5) {
    for (let c = 2; c < 30; c += 5) {
      if (((creativePixels[r] >>> (31 - c)) & 1) === 1) continue; // wall
      pedestals.push({
        id: 'auto-' + r + '-' + c,
        x: -64 + c * 4 + 2, y: 0, z: -64 + r * 4 + 2, ry: 0,
        type: types[n % types.length],
        currentItem: null, spawnTime: 0
      });
      if (++n >= 12) break outer;
    }
  }
  io.emit('currentPedestals', pedestals);
}

// Rebuild = round reset: world objects and terrain edits wiped, scores
// zeroed, everyone stays in-game, pedestals repopulate, and each client
// regenerates the map from the painted pixels.
function rebuildMap() {
  terrainEdits = [];
  activeTeleporters.length = 0;
  activeMines.length = 0;
  activeCoins.length = 0;
  activePads.length = 0;
  activeBuilds.length = 0;
  activeModels.length = 0;
  activeChannels.length = 0;
  activeCastles.length = 0;
  activeVehicles.length = 0;
  for (const id of Object.keys(scores)) scores[id] = 0;
  io.emit('scores', scores);
  io.emit('currentTeleporters', []);
  io.emit('currentMines', []);
  io.emit('currentPads', []);
  io.emit('currentBuilds', []);
  io.emit('currentModels', []);
  io.emit('currentChannels', []);
  io.emit('currentCastles', []);
  io.emit('currentVehicles', []);
  autoPopulatePedestals();
  pickRandomHolder();
  io.emit('mapRebuilt', { pixels: creativePixels });
}

function endGame() {
  if (endVote) { clearTimeout(endVote.timer); endVote = null; }
  for (const id of Object.keys(scores)) scores[id] = 0;
  io.emit('scores', scores);
  holderID = null;
  io.emit('holderChanged', holderID);
  readyIds.clear();
  if (levelLocked) { levelLocked = false; io.emit('lobbyLocked', false); }
  io.emit('gameEnded');
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

// Score tick — holder gains 1 point per second
setInterval(() => {
  if (holderID && players[holderID]) {
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
  if (creativePixels) {
    socket.emit('creativeGrid', creativePixels);
    socket.emit('terrainEdits', terrainEdits);
  }
  if (paintRows) socket.emit('creativePaint', paintRows);
  socket.emit('gameSettings', gameSettings);
  socket.emit('currentSpawns', spawnPoints);

  socket.on('updateGameSetting', (u) => {
    if (!u || typeof u.key !== 'string' || !(u.key in gameSettings)) return;
    if (!gameSettings.allowMidgameChanges && readyIds.size > 0 && u.key !== 'allowMidgameChanges') {
      socket.emit('systemMessage', { text: 'Game settings are locked while a game is in progress.' });
      return;
    }
    const numeric = typeof gameSettings[u.key] === 'number';
    gameSettings[u.key] = numeric
      ? Math.min(3, Math.max(0.05, Number(u.value) || 1))
      : !!u.value;
    const who = players[socket.id] ? players[socket.id].name : 'Someone';
    io.emit('gameSettings', gameSettings);
    sysMsg(numeric
      ? `${who} set ${u.key} to ${gameSettings[u.key].toFixed(2)}`
      : `${who} turned ${u.key} ${gameSettings[u.key] ? 'ON' : 'OFF'}`);
  });

  socket.on('placeCastle', (c) => {
    if (!c || !c.a || !c.b) return;
    const castle = {
      id: (typeof c.id === 'string' && c.id) ? c.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      a: { x: +c.a.x || 0, y: +c.a.y || 0, z: +c.a.z || 0 },
      b: { x: +c.b.x || 0, y: +c.b.y || 0, z: +c.b.z || 0 },
      arch: !!c.arch
    };
    activeCastles.push(castle);
    io.emit('castlePlaced', castle);
  });

  socket.on('removeCastle', (id) => {
    const idx = activeCastles.findIndex(c => c.id === id);
    if (idx !== -1) {
      activeCastles.splice(idx, 1);
      io.emit('castleRemoved', id);
    }
  });

  socket.on('placeVehicle', (v) => {
    if (!v || (v.kind !== 'ghost' && v.kind !== 'drill')) return;
    const veh = {
      id: (typeof v.id === 'string' && v.id) ? v.id : (Date.now().toString(36) + Math.random().toString(36).substr(2, 5)),
      kind: v.kind,
      x: +v.x || 0, y: +v.y || 0, z: +v.z || 0, ry: +v.ry || 0,
      driver: null
    };
    activeVehicles.push(veh);
    io.emit('vehiclePlaced', veh);
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
    if (!veh) return;
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
    socket.broadcast.emit('vehicleMoved', { id: veh.id, x: veh.x, y: veh.y, z: veh.z, ry: veh.ry });
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

  socket.on('startRebuildVote', () => {
    if (!readyIds.has(socket.id) || endVote) return;
    endVote = {
      kind: 'rebuild',
      voters: new Set([...readyIds]),
      yes: new Set([socket.id]),
      no: new Set(),
      timer: null
    };
    endVote.timer = setTimeout(() => finishEndVote(false), END_VOTE_TIMEOUT_MS);
    const name = players[socket.id] ? players[socket.id].name : 'Player';
    sysMsg(`${name} wants to rebuild the map (full reset). /vote yes or /vote no (${endVote.yes.size}/${votesNeeded()})`);
    checkEndVote();
  });

  // Live co-painting of the creative editor canvas (full 32-int grid per
  // stroke burst — tiny and idempotent).
  socket.on('creativePaint', (rows) => {
    if (!Array.isArray(rows) || rows.length === 0 || rows.length > 64) return;
    paintRows = rows.slice(0, 64).map(Number);
    socket.broadcast.emit('creativePaint', paintRows);
  });

  socket.on('creativeGrid', (rows) => {
    if (!Array.isArray(rows) || rows.length === 0 || rows.length > 64) return;
    creativePixels = rows.slice(0, 64).map(Number);
    terrainEdits = [];
    io.emit('creativeGrid', creativePixels);
    autoPopulatePedestals();  // fresh map -> fresh item pedestals in open areas
  });

  socket.on('terrainEdit', (e) => {
    if (!e || typeof e.x !== 'number' || typeof e.y !== 'number' || typeof e.z !== 'number') return;
    const edit = {
      x: +e.x, y: +e.y, z: +e.z,
      r: Math.min(Math.abs(+e.r) || 3, 12),
      s: e.s >= 0 ? 1 : -1,
      st: Math.min(Math.abs(+e.st) || 1, 2)
    };
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
    scores[socket.id] = 0;
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
    socket.broadcast.emit('playerMoved', { id: socket.id, ...data });
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
    if (!players[targetId]) return;
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
    }
    io.emit('applyImpulse', { id: targetId, dir, force: 25 });
  });

  socket.on('fireRocket', (data) => {
    io.emit('rocketFired', { ...data, owner: socket.id });
  });

  socket.on('triggerExplosion', (pos) => {
    io.emit('explosion', pos);

    const droppedCoins = [];
    for (const [id, player] of Object.entries(players)) {
      const dx = player.x - pos.x;
      const dy = player.y - pos.y;
      const dz = player.z - pos.z;
      const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);

      let pctLost = 0;
      if (dist < 1) pctLost = 1.0;
      else if (dist < 2) pctLost = 0.5;
      else if (dist < 4) pctLost = 0.25;
      else if (dist < 6) pctLost = 0.125;
      else if (dist < 8) pctLost = 0.0625;

      if (pctLost > 0 && scores[id] > 0) {
        const pointsLost = Math.ceil(scores[id] * pctLost);
        if (pointsLost > 0) {
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
              value: i === coinsToSpawn - 1 ? pointsLost - (coinsToSpawn - 1) : 1,
              createdAt: Date.now()
            };
            activeCoins.push(coin);
            droppedCoins.push(coin);
          }
        }
      }
    }
    if (droppedCoins.length > 0) {
      io.emit('coinsDropped', droppedCoins);
      io.emit('scores', scores);
    }
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
  