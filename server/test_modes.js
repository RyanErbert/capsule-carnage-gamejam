// End-to-end check of the gamemode rules against a real server instance:
//   PORT=3101 node server.js      (a scratch server, never Ryan's live one)
//   node test_modes.js 3101
const { io } = require('socket.io-client');

const port = process.argv[2] || '3101';
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
// Resolve with the first event whose payload passes `pred`
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
  const b = io(URL, { transports: ['websocket'] });
  await once(b, 'connect');
  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(200);

  // --- Mode names, aliases, per-mode numbers (lobby, nobody live) ---------
  a.emit('updateGameSetting', { key: 'mode', value: 'build' });
  let gs = await until(a, 'gameSettings', g => g.mode === 'creative');
  ok('legacy "build" lands as creative', gs.mode === 'creative' && gs.slayer === false);
  a.emit('updateGameSetting', { key: 'mode', value: 'reversetag' });
  gs = await until(a, 'gameSettings', g => g.mode === 'reversetag');
  ok('reversetag is not a health mode', gs.slayer === false);
  ok('tag limit is a number (600 on a fresh server)', typeof gs.tagLimit === 'number');
  a.emit('updateGameSetting', { key: 'tagLimit', value: 350 });
  gs = await until(a, 'gameSettings', g => g.tagLimit === 350);
  ok('tag limit adjustable', gs.tagLimit === 350);
  a.emit('updateGameSetting', { key: 'buildMs', value: 3 * 60000 });
  gs = await until(a, 'gameSettings', g => g.buildMs === 180000);
  ok('build phase adjustable', gs.buildMs === 180000);
  a.emit('updateGameSetting', { key: 'pvp', value: false });
  gs = await until(a, 'gameSettings', g => g.pvp === false);
  ok('pvp toggles', gs.pvp === false);

  // --- Slayer, pvp off: a hit does nothing; pvp on: it bites ---------------
  a.emit('updateGameSetting', { key: 'mode', value: 'slayer' });
  gs = await until(a, 'gameSettings', g => g.mode === 'slayer');
  ok('slayer is a health mode', gs.slayer === true);
  a.emit('ready', { name: 'ryan' });
  await once(a, 'currentPlayers');
  b.emit('ready', { name: 'tim' });
  const cp = await once(b, 'currentPlayers');
  const aId = Object.keys(cp.players).find(id => cp.players[id].name === 'ryan');
  const bId = cp.selfId;
  await sleep(200);

  // The mode is frozen once anyone is in a game, even for creative
  a.emit('updateGameSetting', { key: 'mode', value: 'creative' });
  await sleep(300);
  let swapped = false;
  a.once('gameSettings', g => { swapped = g.mode !== 'slayer'; });
  await sleep(200);
  ok('mode frozen while a round is live', !swapped);

  // pvp is OFF (set in the lobby): the hit lands nothing
  let sawScores = false;
  const spy = () => { sawScores = true; };
  a.on('scores', spy);
  a.emit('machinegunHit', { targetId: bId, dir: { x: 0, y: 1, z: 0 }, src: 'machinegun' });
  await sleep(400);
  a.off('scores', spy);
  ok('pvp off: a hit changes nothing', !sawScores);
  // Settings are frozen while live in Slayer, so back to the lobby to flip it
  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(300);
  a.emit('updateGameSetting', { key: 'pvp', value: true });
  gs = await until(a, 'gameSettings', g => g.pvp === true);
  a.emit('ready', { name: 'ryan' });
  await once(a, 'currentPlayers');
  b.emit('ready', { name: 'tim' });
  await once(b, 'currentPlayers');
  await sleep(200);
  a.emit('machinegunHit', { targetId: bId, dir: { x: 0, y: 1, z: 0 }, src: 'machinegun' });
  let scores = await until(a, 'scores', s => s[bId] === 98, 3000);
  ok('pvp on: the hit bites', scores[bId] === 98 && scores[aId] === 100);

  // --- Vampire: one point crosses per tick, rate limited ---------------------
  a.emit('vampireTick', { t: bId });
  scores = await until(a, 'scores', s => s[bId] === 97, 3000);
  ok('vampire moves a point across', scores[bId] === 97 && scores[aId] === 101);
  a.emit('vampireTick', { t: bId });
  await sleep(120);
  a.emit('vampireTick', { t: bId });
  await sleep(300);
  let latest = null;
  a.on('scores', s => { latest = s; });
  a.emit('selfDamage', { n: 0 });
  await sleep(200);
  ok('vampire ticks are rate limited (2 fast ticks -> at most 1 lands)',
    latest === null || latest[bId] >= 96);

  // --- Death leaves a BALL; rolling into it heals over time -----------------
  const placed = once(b, 'generatorPlaced', 5000);
  b.emit('playerMoved', { x: 10, y: 5, z: 10 });
  await sleep(100);
  b.emit('suicide');
  const ball = await placed;
  ok('corpse drops a ball', ball.ball === true && ball.mini === true && ball.energy >= 20);
  ok('ball lands at the corpse', Math.abs(ball.x - 10) < 0.01 && Math.abs(ball.z - 10) < 0.01);
  // a is far away: refused
  a.emit('playerMoved', { x: 60, y: 5, z: 60 });
  await sleep(100);
  a.emit('absorbBall', ball.id);
  await sleep(300);
  a.emit('playerMoved', { x: 10.5, y: 5.5, z: 10 });
  await sleep(100);
  const removed = once(a, 'generatorRemoved', 3000);
  const aura = until(a, 'aura', d => d.id === aId, 3000);
  a.emit('absorbBall', ball.id);
  const gone = await removed;
  const au = await aura;
  ok('ball swallowed from close range only', gone === ball.id);
  ok('swallowing lights the heal aura', au.kind === 'heal');
  const healed = await until(a, 'scores', s => s[aId] > 101, 3500);
  ok('pool ticks into health', healed[aId] === 102);

  // --- Reverse Tag: no cores, and the tag limit ends the round --------------
  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(300);
  console.log(results.join('\n'));
  const fails = results.filter(r => r.startsWith('FAIL')).length;
  console.log(fails ? `${fails} FAILED` : 'all passed');
  a.close(); b.close();
  process.exit(fails ? 1 : 0);
})().catch(e => { console.log(results.join('\n')); console.error('ERROR', e.message); process.exit(2); });
