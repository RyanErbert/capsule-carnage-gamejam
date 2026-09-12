// Campaign end to end against a scratch server:
//   PORT=3103 node server.js
//   node test_campaign.js 3103
// START goes straight to the world; the character sheet and shared world
// arrive on ready; crates pay out and count for quests; the shop debits.
const { io } = require('socket.io-client');

const port = process.argv[2] || '3103';
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
  const b = io(URL, { transports: ['websocket'] });
  await once(b, 'connect');
  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(200);
  let gs = await new Promise(res => { a.emit('updateGameSetting', { key: 'mode', value: 'deathmatch' }); a.once('gameSettings', res); });
  a.emit('updateGameSetting', { key: 'mode', value: 'campaign' });
  gs = await until(a, 'gameSettings', g => g.mode === 'campaign');
  ok('campaign is a health mode', gs.slayer === true);

  // START: no countdown, no editor
  const enter = once(a, 'enterCampaign', 3000);
  a.emit('requestStart');
  await enter;
  ok('START goes straight into the world', true);

  // A fresh character comes with the sheet and the shared world
  const sheetP = once(a, 'campaignSheet', 4000);
  const worldP = once(a, 'campaignWorld', 4000);
  a.emit('ready', { name: 'Tester_' + Date.now().toString(36) });
  const cp = await once(a, 'currentPlayers');
  const A = cp.selfId;
  const sheet = await sheetP;
  const world = await worldP;
  ok('sheet arrives on ready', typeof sheet.coins === 'number' && typeof sheet.quests === 'object');
  ok('world carries the quest list and shop prices', Array.isArray(world.quests) && world.quests.length >= 3
    && typeof world.shop === 'object' && world.shop.machinegun > 0);
  b.emit('ready', { name: 'Friend_' + Date.now().toString(36) });
  const cpB = await once(b, 'currentPlayers');
  const B = cpB.selfId;
  await sleep(200);

  // Co-op: friends can't hurt each other regardless of pvp
  let hurt = false;
  const spy = s => { if (s[B] < 100) hurt = true; };
  a.on('scores', spy);
  a.emit('machinegunHit', { targetId: B, dir: { x: 0, y: 1, z: 0 }, src: 'machinegun' });
  a.emit('vampireTick', { t: B });
  await sleep(400);
  a.off('scores', spy);
  ok('campaign is co-op: no friendly damage', !hurt);

  // Quests: accept the crate quest, open a crate, watch it count
  a.emit('questAccept', 'scavenger');
  let sh = await until(a, 'campaignSheet', s => s.quests.scavenger, 3000);
  ok('accepting a quest puts it on the sheet', sh.quests.scavenger.n === 0 && sh.quests.scavenger.done === false);
  const opened = until(b, 'crateOpened', c => c.id === 'Crate_1', 3000);
  a.emit('openCrate', 'Crate_1');
  const cr = await opened;
  ok('a crate opening is broadcast to everyone', cr.by === A && cr.loot && cr.respawnMs > 0);
  sh = await until(a, 'campaignSheet', s => s.quests.scavenger.n === 1, 3000);
  ok('the crate counts toward the quest', sh.quests.scavenger.n === 1);
  const coinsAfterCrate = sh.coins;
  // Same crate again is empty until it respawns
  let again = false;
  const spy2 = () => { again = true; };
  b.on('crateOpened', spy2);
  a.emit('openCrate', 'Crate_1');
  await sleep(300);
  b.off('crateOpened', spy2);
  ok('an open crate stays open', !again);
  // A late joiner sees it open
  const c = io(URL, { transports: ['websocket'] });
  await once(c, 'connect');
  const worldC = once(c, 'campaignWorld', 4000);
  c.emit('ready', { name: 'Late_' + Date.now().toString(36) });
  const wc = await worldC;
  ok('a late joiner is told which crates are open', wc.crates && wc.crates.Crate_1 > 0);
  c.close();

  // Reach quest
  a.emit('questAccept', 'first_steps');
  await until(a, 'campaignSheet', s => s.quests.first_steps, 3000);
  a.emit('questReach', 'Checkpoint_Summit');
  sh = await until(a, 'campaignSheet', s => s.quests.first_steps && s.quests.first_steps.done, 3000);
  ok('standing on the checkpoint completes the reach quest', sh.quests.first_steps.done);
  ok('...and pays the reward', sh.coins >= coinsAfterCrate + 25);

  // Shop: too poor for the vampire gun, fine for mines
  let denied = false;
  a.once('campaignDenied', () => { denied = true; });
  const richEnough = sh.coins >= world.shop.vampire;
  a.emit('shopBuy', 'vampire');
  await sleep(300);
  ok('the shop refuses what you cannot afford (or sells it if you can)', richEnough ? !denied : denied);
  const item = once(a, 'itemPickedUp', 3000);
  const before = sh.coins;
  a.emit('shopBuy', 'mines');
  const got = await item;
  sh = await until(a, 'campaignSheet', s => s.coins < before, 3000);
  ok('buying hands the item over and debits the wallet', got === 'mines' && sh.coins === before - world.shop.mines);

  a.emit('leaveGame'); b.emit('leaveGame');
  await sleep(300);
  console.log(results.join('\n'));
  const fails = results.filter(r => r.startsWith('FAIL')).length;
  console.log(fails ? `${fails} FAILED` : 'all passed');
  a.close(); b.close();
  process.exit(fails ? 1 : 0);
})().catch(e => { console.log(results.join('\n')); console.error('ERROR', e.message); process.exit(2); });
