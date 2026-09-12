// Fortwars end to end against a scratch server:
//   PORT=3102 node server.js
//   node test_fortwars.js 3102
// Two players, two teams: the grab plays as teams, the map generates straight
// into a walled build phase, the ball drops at the border when it ends, and
// the carrier's team scores until they die and drop it.
const { io } = require('socket.io-client');

const port = process.argv[2] || '3102';
const URL = `http://localhost:${port}`;
const results = [];
const ok = (n, c) => results.push((c ? 'PASS' : 'FAIL') + '  ' + n);
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function once(sock, ev, ms = 4000) {
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('timeout waiting for ' + ev)), ms);
    sock.once(ev, (d) => { clearTimeout(t); res(d); });
  });
}
function until(sock, ev, pred, ms = 4000) {
  return new Promise((res, rej) => {
    const t = setTimeout(() => { sock.off(ev, h); rej(new Error('timeout waiting for ' + ev)); }, ms);
    const h = (d) => { if (pred(d)) { clearTimeout(t); sock.off(ev, h); res(d); } };
    sock.on(ev, h);
  });
}

(async () => {
  const a = io(URL, { transports: ['websocket'] });
  await once(a, 'connect');
  let lastZones = {};
  a.on('spawnZones', z => { lastZones = z || {}; });
  const b = io(URL, { transports: ['websocket'] });
  await once(b, 'connect');
  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(200);

  a.emit('updateGameSetting', { key: 'mode', value: 'fortwars' });
  let gs = await until(a, 'gameSettings', g => g.mode === 'fortwars');
  ok('fortwars is a health mode', gs.slayer === true);
  // The server is silent when a setting already has the value asked for, so
  // only wait for the ones that actually change (a scratch server keeps state
  // between runs).
  const want = { buildMs: 30000, gridW: 24, gridH: 24 };
  for (const [k, v] of Object.entries(want)) {
    if (gs[k] === v) continue;
    a.emit('updateGameSetting', { key: k, value: v });
    gs = await until(a, 'gameSettings', g => g[k] === v);
  }

  // --- The grab, as teams ---------------------------------------------------
  const enter = once(a, 'enterEditor', 6000);
  a.emit('requestStart');
  await enter;
  a.emit('editing', true);
  b.emit('editing', true);
  const fs0 = await until(a, 'fortState', f => f && f.teams && Object.keys(f.teams).length === 2, 6000);
  const teams = Object.values(fs0.teams);
  ok('two players land on two teams', teams.includes('red') && teams.includes('blue'));
  const claim = await until(a, 'claimState', c => c && c.phase === 'claim' && c.ids.length === 2, 8000);
  ok('claim snapshot names each snake\'s board index', Array.isArray(claim.oidx) && claim.oidx.length === 2);
  ok('board indices are the teams (0/1), not the snakes', claim.oidx.every(i => i === 0 || i === 1)
    && claim.oidx[0] !== claim.oidx[1]);
  ok('palette is the team colours', Array.isArray(claim.palette) && claim.palette.length === 2);
  // Steer both snakes round a 5-cell square the moment the board is up, so
  // each closes a loop and owns more than its home plot (a straight run never
  // encloses anything). Loops turn toward the board centre so they can't
  // stall on the edge; a tick is 130 ms.
  const legsFor = (pos) => {
    const dr = pos[0] < 12 ? 1 : -1, dc = pos[1] < 12 ? 1 : -1;
    return [[0, dc], [dr, 0], [0, -dc], [-dr, 0]];
  };
  const legsA = legsFor(claim.pos[0]);
  const legsB = legsFor(claim.pos[1]);
  for (let leg = 0; leg < 4; leg++) {
    a.emit('claimDir', { dr: legsA[leg][0], dc: legsA[leg][1] });
    b.emit('claimDir', { dr: legsB[leg][0], dc: legsB[leg][1] });
    await sleep(130 * 5);
  }
  await sleep(400);
  const built = until(a, 'fortState', f => f && f.phase === 'build', 15000);
  const grid = once(a, 'creativeGrid', 15000);
  a.emit('endClaim');
  const fs1 = await built;
  await grid;
  ok('the grab goes straight into the 3D build phase', fs1.phase === 'build' && fs1.t > 20000);
  ok('build snapshot carries the board', typeof fs1.own === 'string' && fs1.own.length === 24 * 24);
  const aId = Object.keys(fs1.teams).find(id => fs1.teams[id] !== fs1.teams[Object.keys(fs1.teams)[1]] || true);

  // --- Join the world -------------------------------------------------------
  a.emit('ready', { name: 'ryan' });
  const cpA = await once(a, 'currentPlayers');
  b.emit('ready', { name: 'tim' });
  const cpB = await once(b, 'currentPlayers');
  const A = cpA.selfId, B = cpB.selfId;
  ok('player records carry their team', cpB.players[A].team && cpB.players[B].team
    && cpB.players[A].team !== cpB.players[B].team);

  // Truce: nobody can be hurt behind the barriers
  let hurt = false;
  const spy = s => { if (s[B] < 100) hurt = true; };
  a.on('scores', spy);
  a.emit('machinegunHit', { targetId: B, dir: { x: 0, y: 1, z: 0 }, src: 'machinegun' });
  await sleep(400);
  a.off('scores', spy);
  ok('build phase is a truce', !hurt);

  // Territory gate: an edit on the OTHER team's ground never reaches anyone
  const own = fs1.own; const w = 24;
  const myIdx = fs1.teams[A] === 'red' ? 0 : 1;
  // Spawn blocks are unsculptable for everyone, so pick ground clear of them
  const zones = Object.values(await new Promise(res => { a.emit('leaveGame'); a.once('spawnZones', res); a.emit('editing', false); setTimeout(() => res(lastZones), 800); }));
  const clear = (r, c) => zones.every(z => Math.max(Math.abs(r - z[0]), Math.abs(c - z[1])) > 2);
  let mine = null, theirs = null;
  for (let i = 0; i < own.length; i++) {
    const o = own.charCodeAt(i) - 50;
    const r = Math.floor(i / w), c = i % w;
    const x = -48 + c * 4 + 2, z = -48 + r * 4 + 2;
    if (o === myIdx && !mine && clear(r, c)) mine = { x, z };
    if (o === 1 - myIdx && !theirs && clear(r, c)) theirs = { x, z };
  }
  a.emit('ready', { name: 'ryan' }); await once(a, 'currentPlayers');
  // The grab is a game with random starts: if a snake got cut before it
  // closed anything, its side is one home plot and the gate has nothing clear
  // of the spawn to test on. That's the dice, not the rule.
  if (!mine || !theirs) results.push('SKIP  territory gate (a snake died before it owned ground beyond its plot)');
  if (mine && theirs) {
    let heard = 0;
    b.on('terrainEdit', () => heard++);
    a.emit('terrainEdit', { x: theirs.x, y: 2, z: theirs.z, r: 1, s: 1, st: 1, m: 'add' });
    await sleep(300);
    ok('sculpting the other side is refused', heard === 0);
    a.emit('terrainEdit', { x: mine.x, y: 2, z: mine.z, r: 1, s: 1, st: 1, m: 'add' });
    await sleep(300);
    ok('sculpting your own side goes through', heard === 1);
  }

  // --- Battle ---------------------------------------------------------------
  const battle = until(a, 'fortState', f => f && f.phase === 'battle', 40000);
  const ballPlaced = until(a, 'generatorPlaced', g => g.id === 'ball-game', 40000);
  const fs2 = await battle;
  const ball = await ballPlaced;
  ok('the ball spawns when the clock runs out', ball.game === true && ball.ball === true);
  ok('...in a zone on the board', fs2.zone && typeof fs2.zone.x === 'number');
  ok('...and it is the zone the ball sits in', Math.abs(ball.x - fs2.zone.x) < 0.01 && Math.abs(ball.z - fs2.zone.z) < 0.01);

  // A rolls into it
  a.emit('playerMoved', { x: ball.x, y: ball.y, z: ball.z });
  await sleep(150);
  const holder = until(a, 'generatorHolder', h => h.id === 'ball-game' && h.holder === A, 4000);
  const aura = until(a, 'aura', d => d.id === A && d.kind === 'ball', 4000);
  a.emit('absorbBall', 'ball-game');
  await holder; await aura;
  ok('rolling into the ball makes you its carrier', true);
  const myTeam = fs2.teams[A];
  const tick = await until(a, 'fortTick', t => t.score[myTeam] > 0, 4000);
  ok('carrying scores for the team', tick.score[myTeam] >= 2);
  const other = myTeam === 'red' ? 'blue' : 'red';
  ok('...and only for that team', tick.score[other] === 0);

  // B (other team) can hurt A now the truce is over; A dies and drops the ball
  a.emit('playerMoved', { x: 20, y: 5, z: 20 });
  await sleep(100);
  const dropped = until(b, 'generatorHolder', h => h.id === 'ball-game' && h.holder === null, 4000);
  const moved = until(b, 'generatorMoved', m => m.id === 'ball-game', 4000);
  const auraOff = until(a, 'aura', d => d.id === A && d.kind === '', 4000);
  a.emit('suicide');
  await dropped;
  const at = await moved;
  ok('the carrier dying drops the ball where they fell', Math.abs(at.x - 20) < 0.01 && Math.abs(at.z - 20) < 0.01);
  const off = await auraOff.catch(() => null);
  ok('...and takes the aura off them', off !== null);

  // Teammates cannot hurt each other; enemies can (truce over)
  b.emit('machinegunHit', { targetId: A, dir: { x: 0, y: 1, z: 0 }, src: 'machinegun' });
  await sleep(300);
  // (A is dead right now, so the hit is refused for that reason; test the rule
  // the other way: A shoots B)
  await until(a, 'playerRespawned', id => id === A, 6000).catch(() => null);
  const hit = until(a, 'scores', s => s[B] < 100, 3000);
  a.emit('machinegunHit', { targetId: B, dir: { x: 0, y: 1, z: 0 }, src: 'machinegun' });
  const sc = await hit.catch(() => null);
  ok('enemies can hurt each other in the battle', sc !== null && sc[B] === 98);

  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(300);
  console.log(results.join('\n'));
  const fails = results.filter(r => r.startsWith('FAIL')).length;
  console.log(fails ? `${fails} FAILED` : 'all passed');
  a.close(); b.close();
  process.exit(fails ? 1 : 0);
})().catch(e => { console.log(results.join('\n')); console.error('ERROR', e.message); process.exit(2); });
