// Fortwars: two teams, one ball.
//
// The round runs in three phases on top of the shared land grab:
//   grab    the Xonix claim, played as TEAMS (a teammate's trail is not a wall
//           and ground either of you closes belongs to you both)
//   build   the map is live but split: translucent barriers stand along every
//           border between the two territories, nobody can hurt anybody, and
//           you sculpt and build behind your own wall for gameSettings.buildMs
//   battle  the barriers drop and the game ball spawns in a marked zone on the
//           border. Carry it and your team banks points; kill and your team
//           banks more; first to gameSettings.teamLimit wins.
//
// This module owns the roster and the rules. server.js owns the sockets and
// calls in; the state it needs to broadcast comes back out of snapshot().

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

const state = {
  phase: '',                 // '' | 'build' | 'battle'
  team: {},                  // socket id -> 'red' | 'blue'
  score: { red: 0, blue: 0 },
  phaseEndsAt: 0,
  zone: null,                // { x, y, z, r } where the ball spawns
  ball: null,                // { x, y, z, holder, idleSince }
  lastHeal: 0
};

function reset() {
  state.phase = '';
  state.team = {};
  state.score = { red: 0, blue: 0 };
  state.phaseEndsAt = 0;
  state.zone = null;
  state.ball = null;
}

function teamOf(id) { return state.team[id] || null; }

// Smallest team gets the newcomer; ties go to red so the first pair splits.
function assign(id) {
  if (state.team[id]) return state.team[id];
  const count = { red: 0, blue: 0 };
  for (const t of Object.values(state.team)) count[t]++;
  state.team[id] = count.blue < count.red ? 'blue' : 'red';
  return state.team[id];
}

function forget(id) {
  delete state.team[id];
  if (state.ball && state.ball.holder === id) {
    state.ball.holder = null;
    state.ball.idleSince = Date.now();
  }
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

// Hand out for the clients: who is on which side and how the round stands.
function snapshot() {
  return {
    phase: state.phase,
    teams: state.team,
    colors: COLORS,
    score: state.score,
    t: Math.max(0, state.phaseEndsAt - Date.now()),
    zone: state.zone,
    ball: state.ball
  };
}

module.exports = {
  TEAMS, COLORS, CARRY_POINTS_PER_S, KILL_POINTS, CARRY_HEAL_MS, BALL_IDLE_RESET_MS,
  state, reset, teamOf, assign, forget, canHurt, snapshot
};
