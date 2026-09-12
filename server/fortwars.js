// Fortwars: two teams, one ball.
//
// The round runs in three phases on top of the shared land grab:
//   grab    the Xonix claim, played as TEAMS: the board's owner index is the
//           team, so a teammate's trail is not a wall and ground either of you
//           closes belongs to you both
//   build   the map is live but split: translucent barriers stand along every
//           border between the territories, nobody can hurt anybody, and you
//           sculpt and build behind your own wall for gameSettings.buildMs
//   battle  the barriers drop and the game ball spawns in a marked zone on the
//           border. Carry it and your team banks points; kill and your team
//           banks more; first to gameSettings.teamLimit wins.
//
// This module owns the roster, the board it inherits from the claim, and the
// rules. server.js owns the sockets and calls in through init(); what the
// clients need comes back out of snapshot() / tickPayload().

const TEAMS = ['red', 'blue'];
const COLORS = { red: '#ff6b5e', blue: '#5ea8ff' };

// Team score per second while someone on the team is carrying the ball
const CARRY_POINTS_PER_S = 2;
// ...and what a kill is worth to the killer's side
const KILL_POINTS = 25;
// Holding the ball is slow healing: +1 health a minute
const CARRY_HEAL_MS = 60 * 1000;
// Somebody has to pick it up eventually: a ball that sits untouched this long
// returns to its zone so nobody has to fish it out of a chasm.
const BALL_IDLE_RESET_MS = 90 * 1000;
const BALL_ID = 'ball-game';
const ZONE_R = 6;

const state = {
  phase: '',                 // '' | 'build' | 'battle'
  team: {},                  // socket id -> 'red' | 'blue'
  score: { red: 0, blue: 0 },
  phaseEndsAt: 0,
  zone: null,                // { x, y, z, r } where the ball spawns
  ball: null,                // { x, y, z, holder, idleSince }
  lastHeal: 0,
  // The territory board, copied out of the claim when the map generates
  own: null, w: 0, h: 0
};

let ctx = null;   // what server.js lends us: io, players, scores, helpers

function init(c) { ctx = c; }

function reset() {
  state.phase = '';
  state.team = {};
  state.score = { red: 0, blue: 0 };
  state.phaseEndsAt = 0;
  state.zone = null;
  state.ball = null;
  state.lastHeal = 0;
  state.own = null; state.w = 0; state.h = 0;
}

function teamOf(id) { return state.team[id] || null; }
function teamIdx(id) { return TEAMS.indexOf(teamOf(id)); }

// Smallest team gets the newcomer; ties go to red so the first pair splits.
function assign(id) {
  if (state.team[id]) return state.team[id];
  const count = { red: 0, blue: 0 };
  for (const t of Object.values(state.team)) count[t]++;
  state.team[id] = count.blue < count.red ? 'blue' : 'red';
  if (ctx && ctx.players[id]) ctx.players[id].team = state.team[id];
  return state.team[id];
}

function forget(id, pos) {
  if (state.ball && state.ball.holder === id) dropBall(id, pos);
  delete state.team[id];
}

// Whether `byId` may hurt `targetId` under Fortwars rules: never during the
// build truce, never a teammate. Unknown attackers (an unowned mine) count as
// the other side.
function canHurt(byId, targetId) {
  if (state.phase === 'build') return false;
  const a = teamOf(byId), b = teamOf(targetId);
  if (a && b && a === b) return false;
  return true;
}

// --- The board -----------------------------------------------------------

function adoptBoard(owner, w, h) {
  state.own = Int8Array.from(owner);
  state.w = w;
  state.h = h;
}

function boardString() {
  if (!state.own) return '';
  let s = '';
  for (let i = 0; i < state.own.length; i++) s += String.fromCharCode(50 + state.own[i]);
  return s;
}

function cellOwner(x, z) {
  if (!state.own) return -1;
  const c = Math.floor((x + state.w * 2) / 4);
  const r = Math.floor((z + state.h * 2) / 4);
  if (r < 0 || c < 0 || r >= state.h || c >= state.w) return -1;
  return state.own[r * state.w + c];
}

// During the build phase you may only touch ground your team won.
function mayBuild(id, x, z) {
  if (state.phase !== 'build') return true;
  return cellOwner(x, z) === teamIdx(id);
}

// --- Phases --------------------------------------------------------------

function startBuild(ms) {
  state.phase = 'build';
  state.phaseEndsAt = Date.now() + ms;
  state.score = { red: 0, blue: 0 };
  state.ball = null;
  state.zone = null;
}

// The ball zone: a border cell between the two territories, as central as the
// border allows. Falls back to the middle of the map if the grab never put the
// teams side by side (one team gifted a plot, say).
function pickZone() {
  const { own, w, h } = state;
  let best = null, bestD = Infinity;
  if (own) {
    for (let r = 1; r < h - 1; r++) {
      for (let c = 1; c < w - 1; c++) {
        const o = own[r * w + c];
        if (o < 0) continue;
        const other = 1 - o;
        const touching = own[(r - 1) * w + c] === other || own[(r + 1) * w + c] === other
          || own[r * w + c - 1] === other || own[r * w + c + 1] === other;
        if (!touching) continue;
        if (ctx.pixelTop(r, c) < 0 || ctx.inDeadzone(r, c)) continue;
        const d = Math.hypot(r - h / 2, c - w / 2) + Math.random() * 0.5;
        if (d < bestD) { bestD = d; best = [r, c]; }
      }
    }
  }
  if (!best) best = [h >> 1, w >> 1];
  const [r, c] = best;
  return {
    x: -w * 2 + c * 4 + 2,
    y: ctx.surfaceY(ctx.pixelTop(r, c)),
    z: -h * 2 + r * 4 + 2,
    r: ZONE_R
  };
}

function startBattle() {
  state.phase = 'battle';
  state.phaseEndsAt = 0;
  state.zone = pickZone();
  const ball = {
    id: BALL_ID, x: state.zone.x, y: state.zone.y + 1.5, z: state.zone.z,
    holder: null, owner: null, energy: 0, mini: false, ball: true, game: true
  };
  const old = ctx.activeGenerators.findIndex(g => g.id === BALL_ID);
  if (old !== -1) { ctx.activeGenerators.splice(old, 1); ctx.io.emit('generatorRemoved', BALL_ID); }
  ctx.activeGenerators.push(ball);
  ctx.io.emit('generatorPlaced', ball);
  state.ball = { x: ball.x, y: ball.y, z: ball.z, holder: null, idleSince: Date.now() };
  ctx.sysMsg('The ball is out. Barriers down.');
}

function gameBall() { return ctx.activeGenerators.find(g => g.id === BALL_ID) || null; }

// Somebody rolled into the game ball
function pickUp(id, gen) {
  if (state.phase !== 'battle' || !gen || gen.id !== BALL_ID) return;
  if (state.ball && state.ball.holder && state.ball.holder !== id) {
    ctx.setAura(state.ball.holder, '');
  }
  gen.holder = id;
  gen.carry = true;
  state.ball = { x: gen.x, y: gen.y, z: gen.z, holder: id, idleSince: 0 };
  state.lastHeal = Date.now();
  ctx.setAura(id, 'ball');
  ctx.io.emit('generatorHolder', { id: gen.id, holder: id, carry: true });
  const p = ctx.players[id];
  ctx.sysMsg(`${p ? p.name : 'someone'} has the ball`);
}

// The carrier died (or left): the ball lands where they were. The dead
// player's client still runs, so it owns the physics drop like any corpse ball.
function dropBall(id, pos) {
  const gen = gameBall();
  if (!gen || !state.ball || state.ball.holder !== id) return false;
  const at = pos || { x: gen.x, y: gen.y, z: gen.z };
  gen.holder = null;
  gen.carry = false;
  gen.owner = id;
  gen.x = at.x; gen.y = at.y + 0.8; gen.z = at.z;
  state.ball = { x: gen.x, y: gen.y, z: gen.z, holder: null, idleSince: Date.now() };
  ctx.setAura(id, '');
  ctx.io.emit('generatorHolder', { id: gen.id, holder: null, carry: false });
  ctx.io.emit('generatorMoved', { id: gen.id, x: gen.x, y: gen.y, z: gen.z });
  return true;
}

// Somebody moved the loose ball (physics drop relayed by its owner)
function ballMoved(x, y, z) {
  if (state.ball && !state.ball.holder) { state.ball.x = x; state.ball.y = y; state.ball.z = z; }
}

// --- Scoring -------------------------------------------------------------

function onDeath(id, pos, byId) {
  if (state.phase !== 'battle') return;
  dropBall(id, pos);
  const t = teamOf(byId);
  if (t && byId !== id) state.score[t] += KILL_POINTS;
}

function onCoin(id, value) {
  if (state.phase !== 'battle') return;
  const t = teamOf(id);
  if (t) state.score[t] += value;
}

// Once a second from server.js. Returns the winning team's name when the round
// is decided, otherwise null.
function tick(teamLimit) {
  const now = Date.now();
  if (state.phase === 'build') {
    if (now >= state.phaseEndsAt) {
      startBattle();
      ctx.io.emit('fortState', snapshot());
    }
    return null;
  }
  if (state.phase !== 'battle') return null;
  const gen = gameBall();
  if (state.ball && state.ball.holder) {
    const hid = state.ball.holder;
    const p = ctx.players[hid];
    if (!p || ctx.isDead(hid)) {
      dropBall(hid, p ? { x: p.x, y: p.y, z: p.z } : null);
    } else {
      const t = teamOf(hid);
      if (t) state.score[t] += CARRY_POINTS_PER_S;
      state.ball.x = p.x; state.ball.y = p.y; state.ball.z = p.z;
      if (gen) { gen.x = p.x; gen.y = p.y; gen.z = p.z; }
      if (now - state.lastHeal >= CARRY_HEAL_MS) {
        state.lastHeal = now;
        ctx.scores[hid] = (ctx.scores[hid] || 0) + 1;
        ctx.io.emit('scores', ctx.scores);
      }
    }
  } else if (state.ball && gen && now - state.ball.idleSince > BALL_IDLE_RESET_MS) {
    gen.x = state.zone.x; gen.y = state.zone.y + 1.5; gen.z = state.zone.z;
    gen.owner = null;
    state.ball = { x: gen.x, y: gen.y, z: gen.z, holder: null, idleSince: now };
    ctx.io.emit('generatorMoved', { id: gen.id, x: gen.x, y: gen.y, z: gen.z });
    ctx.sysMsg('The ball went home.');
  }
  for (const t of TEAMS) {
    if (state.score[t] >= teamLimit) return t;
  }
  return null;
}

// --- For the clients -----------------------------------------------------

// Everything, on a phase change or a join
function snapshot() {
  return {
    phase: state.phase,
    teams: state.team,
    colors: COLORS,
    score: state.score,
    t: Math.max(0, state.phaseEndsAt - Date.now()),
    zone: state.zone,
    ball: state.ball,
    own: boardString(),
    gs: [state.w, state.h]
  };
}

// The second-by-second part only
function tickPayload() {
  return {
    phase: state.phase,
    score: state.score,
    t: Math.max(0, state.phaseEndsAt - Date.now()),
    ball: state.ball
  };
}

module.exports = {
  TEAMS, COLORS, CARRY_POINTS_PER_S, KILL_POINTS, CARRY_HEAL_MS, BALL_IDLE_RESET_MS, BALL_ID,
  state, init, reset, teamOf, teamIdx, assign, forget, canHurt,
  adoptBoard, cellOwner, mayBuild, startBuild, startBattle, pickUp, dropBall, ballMoved,
  onDeath, onCoin, tick, snapshot, tickPayload
};
