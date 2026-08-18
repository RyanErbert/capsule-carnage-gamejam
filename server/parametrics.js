'use strict';

// Parametric structures: the server side of Items/parametric.
//
// A structure is never geometry over the wire. It is a record -- a type, a
// chain of nodes, and a bag of numbers -- and every client rebuilds the mesh
// from it locally. That is what makes a live handle drag cheap enough to
// broadcast at all: a wall being stretched is a couple of hundred bytes a
// frame, where the mesh it produces is megabytes.
//
// SPECS below mirrors Items/parametric/models/*.gd. It exists twice on purpose:
// the client needs it to draw the handles, and the server needs it because the
// server is authoritative and a client can send anything it likes. If you add
// a parameter, add it in both places -- specKeys() in the GDScript registry is
// checked against this table by _probe/spec_parity.

const fs = require('fs');
const path = require('path');

const MAX_NODES = 24;
const MAX_HOLES = 24;
const MAX_STRUCTURES = 400;
const MAX_SEGMENT = 64;      // metres between consecutive nodes
const WORLD_LIMIT = 4096;    // absolute coordinate clamp

// key: [min, max, default]
const SPECS = {
  wall: {
    height:    [2, 24, 6],
    thickness: [0.6, 6, 2],
    batter:    [0, 1.2, 0.22],
    coping:    [0, 2.5, 0.9],
    tooth:     [0, 3, 1.1],     // merlon height; 0 means no crenellation
    gate:      [0, 1, 0],       // bool as 0/1: arch at the middle
  },
  tower: {
    height:    [3, 40, 9],
    radius:    [1.2, 12, 3.2],
    batter:    [0, 1.5, 0.35],
    coping:    [0, 2.5, 0.9],
    tooth:     [0, 3, 1.1],
    sides:     [5, 32, 14],
  },
  bridge: {
    width:     [1.5, 12, 3],
    thick:     [0.2, 3, 0.6],
    kerb:      [0, 2, 0.45],
    pier:      [0, 1, 1],       // bool: drop piers to the ground
    span:      [4, 40, 16],     // metres between piers
  },
  path: {
    width:     [0.6, 10, 2],
    thick:     [0.1, 2, 0.35],
    crown:     [0, 0.6, 0.09],
  },
};

const TYPES = Object.keys(SPECS);

const DATA_DIR = path.join(__dirname, 'data');
const STORE = path.join(DATA_DIR, 'parametrics.json');

const active = [];
let saveTimer = null;
let nextId = 1;


function clampNum(v, lo, hi, fallback) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : fallback;
}


// Every parameter the spec names, clamped; anything else the client sent is
// dropped rather than stored, so an old or hostile client cannot smuggle keys
// into the record that later clients would try to honour.
function sanitizeParams(type, raw) {
  const spec = SPECS[type];
  const out = {};
  for (const key of Object.keys(spec)) {
    const [lo, hi, def] = spec[key];
    out[key] = clampNum(raw && raw[key], lo, hi, def);
  }
  return out;
}


// Nodes are clamped to the world and pulled in along the run when a segment is
// absurdly long, so a stray click cannot draw a wall across the whole map.
function sanitizeNodes(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const n of raw.slice(0, MAX_NODES)) {
    if (!n || typeof n !== 'object') continue;
    const p = {
      x: clampNum(n.x, -WORLD_LIMIT, WORLD_LIMIT, 0),
      y: clampNum(n.y, -WORLD_LIMIT, WORLD_LIMIT, 0),
      z: clampNum(n.z, -WORLD_LIMIT, WORLD_LIMIT, 0),
    };
    const prev = out[out.length - 1];
    if (prev) {
      const dx = p.x - prev.x, dy = p.y - prev.y, dz = p.z - prev.z;
      const d = Math.sqrt(dx * dx + dy * dy + dz * dz);
      if (d < 0.05) continue;                       // duplicate click
      if (d > MAX_SEGMENT) {
        const k = MAX_SEGMENT / d;
        p.x = prev.x + dx * k;
        p.y = prev.y + dy * k;
        p.z = prev.z + dz * k;
      }
    }
    out.push(p);
  }
  return out;
}


// A punched penetration is a POINT, not a node: it is where somebody aimed,
// and the model decides what a hole at that spot means. Holes therefore skip
// the run-length pull-in that nodes get -- there is no run to pull along.
function sanitizeHoles(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const n of raw.slice(0, MAX_HOLES)) {
    if (!n || typeof n !== 'object') continue;
    out.push({
      x: clampNum(n.x, -WORLD_LIMIT, WORLD_LIMIT, 0),
      y: clampNum(n.y, -WORLD_LIMIT, WORLD_LIMIT, 0),
      z: clampNum(n.z, -WORLD_LIMIT, WORLD_LIMIT, 0),
    });
  }
  return out;
}


function minNodes(type) {
  return type === 'tower' ? 1 : 2;
}


function makeId() {
  return `p${(nextId++).toString(36)}${Math.random().toString(36).slice(2, 7)}`;
}


// --- Store -------------------------------------------------------------------

// Written through a temp file and renamed, so a crash mid-write leaves the
// previous save intact rather than a truncated one that fails to parse.
function saveNow() {
  saveTimer = null;
  try {
    if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
    const tmp = `${STORE}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({ v: 1, structures: active }, null, 1));
    fs.renameSync(tmp, STORE);
  } catch (e) {
    console.warn('[parametrics] save failed:', e.message);
  }
}


// Handle drags fire every frame; coalesce them so a two-second stretch is one
// write instead of a hundred and twenty.
function save() {
  if (saveTimer) return;
  saveTimer = setTimeout(saveNow, 1200);
}


function load() {
  try {
    if (!fs.existsSync(STORE)) return 0;
    const raw = JSON.parse(fs.readFileSync(STORE, 'utf8'));
    const list = Array.isArray(raw && raw.structures) ? raw.structures : [];
    active.length = 0;
    for (const rec of list.slice(0, MAX_STRUCTURES)) {
      const clean = adopt(rec);
      if (clean) active.push(clean);
    }
    return active.length;
  } catch (e) {
    console.warn('[parametrics] load failed:', e.message);
    return 0;
  }
}


// A record from disk goes through exactly the same validation a record off the
// wire does: the file is editable by hand and should not be more trusted.
function adopt(rec) {
  if (!rec || !TYPES.includes(rec.type)) return null;
  const nodes = sanitizeNodes(rec.nodes);
  if (nodes.length < minNodes(rec.type)) return null;
  return {
    id: typeof rec.id === 'string' && rec.id ? rec.id : makeId(),
    type: rec.type,
    owner: typeof rec.owner === 'string' ? rec.owner.slice(0, 32) : '',
    nodes,
    holes: sanitizeHoles(rec.holes),
    params: sanitizeParams(rec.type, rec.params),
  };
}


// --- Operations --------------------------------------------------------------

function place(msg, owner) {
  if (active.length >= MAX_STRUCTURES) return null;
  const rec = adopt({ ...msg, id: null, owner });
  if (!rec) return null;
  active.push(rec);
  save();
  return rec;
}


// Partial: a handle drag sends only the parameter it moved, or only the node it
// dragged. Returns the whole record so clients rebuild from one payload.
function update(msg) {
  const rec = active.find(r => r.id === (msg && msg.id));
  if (!rec) return null;
  if (msg.params && typeof msg.params === 'object') {
    rec.params = sanitizeParams(rec.type, { ...rec.params, ...msg.params });
  }
  if (Array.isArray(msg.nodes)) {
    const nodes = sanitizeNodes(msg.nodes);
    if (nodes.length >= minNodes(rec.type)) rec.nodes = nodes;
  }
  // `hole` punches one more; `holes` replaces the set, which is how you clear
  // them. Both go through the same clamp.
  if (msg.hole && typeof msg.hole === 'object' && rec.holes.length < MAX_HOLES) {
    rec.holes.push(...sanitizeHoles([msg.hole]));
  }
  if (Array.isArray(msg.holes)) rec.holes = sanitizeHoles(msg.holes);
  save();
  return rec;
}


function remove(id) {
  const i = active.findIndex(r => r.id === id);
  if (i === -1) return false;
  active.splice(i, 1);
  save();
  return true;
}


// The round wipe archives rather than destroys. A map is regenerated from a
// fresh random seed every round, so structures genuinely cannot survive into
// the next one standing where they were -- but they were authored, and
// authored things should not evaporate. Each wipe drops a dated file next to
// the live one; loadArchive() puts any of them back.
function clear() {
  if (active.length) archive();
  active.length = 0;
  save();
}


function archive() {
  try {
    const dir = path.join(DATA_DIR, 'archive');
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    fs.writeFileSync(path.join(dir, `${stamp}.json`),
      JSON.stringify({ v: 1, structures: active }, null, 1));
    return stamp;
  } catch (e) {
    console.warn('[parametrics] archive failed:', e.message);
    return '';
  }
}


function listArchive() {
  try {
    const dir = path.join(DATA_DIR, 'archive');
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort().reverse();
  } catch (e) {
    return [];
  }
}


// Append a saved set onto whatever is standing, with fresh ids so loading the
// same archive twice gives two copies instead of a silent no-op.
function loadArchive(name) {
  try {
    const file = path.join(DATA_DIR, 'archive', path.basename(String(name)));
    if (!fs.existsSync(file)) return [];
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    const list = Array.isArray(raw && raw.structures) ? raw.structures : [];
    const added = [];
    for (const rec of list) {
      if (active.length >= MAX_STRUCTURES) break;
      const clean = adopt({ ...rec, id: null });
      if (clean) {
        active.push(clean);
        added.push(clean);
      }
    }
    if (added.length) save();
    return added;
  } catch (e) {
    console.warn('[parametrics] loadArchive failed:', e.message);
    return [];
  }
}


module.exports = {
  SPECS, TYPES, MAX_STRUCTURES, MAX_NODES, MAX_HOLES, MAX_SEGMENT,
  active, load, save, saveNow, clear,
  archive, listArchive, loadArchive,
  place, update, remove,
  sanitizeParams, sanitizeNodes, sanitizeHoles,
};
