// Campaign: co-op in a hand-built world.
//
// The world itself is the client's (Scenes/campaign.tscn loads a Blender glb
// and reads its markers). What lives here is everything friends have to AGREE
// on: who has how many coins, which quests are taken or done, which crates
// are open. Progress is keyed by player NAME and written to data/campaign.json
// so a character survives the session -- the MMO promise, at small scale.
//
// Quests are data (../Campaign/quests.json, shared with the client). Three
// kinds, all counted here from events the clients report:
//   crates   open N loot crates
//   coins    bank N coins into the wallet
//   reach    stand on a named checkpoint marker
// Nothing here trusts a client further than "you say you did it"; the stakes
// are coins in a co-op game between friends.

const fs = require('fs');
const path = require('path');

const STORE = path.join(__dirname, 'data', 'campaign.json');
const QUESTS_FILE = path.join(__dirname, '..', 'Campaign', 'quests.json');
const SHOP_FILE = path.join(__dirname, '..', 'Campaign', 'shop.json');
const CRATE_RESPAWN_MS = 120 * 1000;
const CRATE_LOOT = [
  { coins: 8 }, { coins: 12 }, { coins: 20 }, { item: 'machinegun' }, { item: 'rocket' },
  { item: 'grapple' }, { coins: 30 }, { item: 'vampire' }, { item: 'mines' }
];

let ctx = null;
let quests = [];        // from quests.json
let shop = {};          // item -> price
// name (lower) -> { coins, quests: { id: { n, done } }, kills }
const characters = {};
// crate id -> { openedAt }; a crate that isn't here is closed
const crates = {};
let saveTimer = null;

function init(c) {
  ctx = c;
  try { quests = JSON.parse(fs.readFileSync(QUESTS_FILE, 'utf8')).quests || []; }
  catch (e) { quests = []; console.log('[campaign] no quests.json:', e.message); }
  try { shop = JSON.parse(fs.readFileSync(SHOP_FILE, 'utf8')).prices || {}; }
  catch (e) { shop = {}; console.log('[campaign] no shop.json:', e.message); }
  try {
    const raw = JSON.parse(fs.readFileSync(STORE, 'utf8'));
    Object.assign(characters, raw.characters || {});
    console.log(`[campaign] restored ${Object.keys(characters).length} characters`);
  } catch (e) { /* first run */ }
}

function save() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.mkdirSync(path.dirname(STORE), { recursive: true });
      const tmp = STORE + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify({ v: 1, characters }, null, 1));
      fs.renameSync(tmp, STORE);
    } catch (e) { console.log('[campaign] save failed:', e.message); }
  }, 1200);
}

function key(id) {
  const p = ctx.players[id];
  return p ? String(p.name || '').toLowerCase() : null;
}

function character(id) {
  const k = key(id);
  if (!k) return null;
  if (!characters[k]) characters[k] = { coins: 0, quests: {}, kills: 0 };
  return characters[k];
}

// What one player needs to know about themself
function sheet(id) {
  const c = character(id);
  if (!c) return null;
  return { coins: c.coins, quests: c.quests, kills: c.kills };
}

function pushSheet(id) {
  const s = sheet(id);
  if (s) ctx.io.to(id).emit('campaignSheet', s);
}

// Shared world state: which crates are open right now
function worldState() {
  const now = Date.now();
  const open = {};
  for (const [cid, c] of Object.entries(crates)) {
    if (now - c.openedAt < CRATE_RESPAWN_MS) open[cid] = CRATE_RESPAWN_MS - (now - c.openedAt);
    else delete crates[cid];
  }
  return { crates: open, quests, shop };
}

// --- Coins -----------------------------------------------------------------

function addCoins(id, n) {
  const c = character(id);
  if (!c || !n) return;
  c.coins = Math.max(0, c.coins + n);
  progress(id, 'coins', Math.max(0, n));
  pushSheet(id);
  save();
}

// --- Quests ----------------------------------------------------------------

function questById(qid) { return quests.find(q => q.id === qid) || null; }

function accept(id, qid) {
  const c = character(id);
  const q = questById(qid);
  if (!c || !q) return false;
  if (c.quests[qid]) return false;          // taken or done already
  c.quests[qid] = { n: 0, done: false };
  pushSheet(id);
  save();
  return true;
}

// Count an event against every open quest of that kind
function progress(id, kind, n = 1, target = null) {
  const c = character(id);
  if (!c) return;
  let changed = false;
  for (const q of quests) {
    const st = c.quests[q.id];
    if (!st || st.done || q.kind !== kind) continue;
    if (kind === 'reach') {
      if (q.target !== target) continue;
      st.n = q.count || 1;
    } else {
      st.n += n;
    }
    changed = true;
    if (st.n >= (q.count || 1)) {
      st.n = q.count || 1;
      st.done = true;
      c.coins += q.reward || 0;
      ctx.sysMsg(`${ctx.players[id].name} finished "${q.title}" (+${q.reward || 0} coins)`);
    }
  }
  if (changed) { pushSheet(id); save(); }
}

// --- Crates ----------------------------------------------------------------

function openCrate(id, cid) {
  if (typeof cid !== 'string' || !cid) return null;
  const now = Date.now();
  if (crates[cid] && now - crates[cid].openedAt < CRATE_RESPAWN_MS) return null;
  crates[cid] = { openedAt: now };
  const loot = CRATE_LOOT[Math.floor(Math.random() * CRATE_LOOT.length)];
  if (loot.coins) addCoins(id, loot.coins);
  if (loot.item) ctx.io.to(id).emit('itemPickedUp', loot.item);
  progress(id, 'crates', 1);
  ctx.io.emit('crateOpened', { id: cid, by: id, loot, respawnMs: CRATE_RESPAWN_MS });
  return loot;
}

// --- Shop ------------------------------------------------------------------

function buy(id, item) {
  const c = character(id);
  const price = shop[item];
  if (!c || typeof price !== 'number') return false;
  if (c.coins < price) { ctx.io.to(id).emit('campaignDenied', { reason: 'coins', item, price }); return false; }
  c.coins -= price;
  ctx.io.to(id).emit('itemPickedUp', item);
  pushSheet(id);
  save();
  return true;
}

function onKill(id) {
  const c = character(id);
  if (!c) return;
  c.kills += 1;
  progress(id, 'kills', 1);
}

module.exports = {
  CRATE_RESPAWN_MS,
  init, character, sheet, pushSheet, worldState, addCoins, accept, progress,
  openCrate, buy, onKill, questById
};
