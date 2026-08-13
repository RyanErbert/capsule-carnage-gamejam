'use strict';

// Seeded procedural terrain for the map creator.
//
// The creator no longer opens on a blank plain: the server rolls a world first
// and the claim phase decides who gets to edit which part of it. Everything
// here is PURE — (w, h, seed) in, the same 4 packed bitmask layers the painter
// speaks out — so the client can't disagree about what the map looks like, and
// the same seed always rebuilds the same world.
//
// Layer semantics (see Terrain/voxel_terrain.gd): layer 0 is the BASEMENT, a
// slab below grade that is solid by default and carved out to make cellars and
// canyon floors; layer 1 is the ground you walk on; 2..4 stack 8 m slabs above
// it. A cell with 1 and 3 set but 2 CLEARED is a roofed corridor: that's how
// tunnels are made.

const LAYERS = 5;
const GROUND = 1;   // index of the walkable default surface

// Which passes run. Picked in the lobby; an empty pick means a bare plain.
const SCHEMES = ['plateaus', 'canyons', 'spires', 'tunnels', 'cellars', 'craters', 'causeways'];
const DEFAULT_SCHEMES = ['plateaus', 'canyons', 'spires', 'tunnels', 'cellars'];

function words(w) { return Math.ceil(w / 32); }

function emptyLayers(w, h) {
  const wc = words(w);
  const out = [];
  for (let li = 0; li < LAYERS; li++) out.push(new Array(h * wc).fill(0));
  return out;
}

function setBit(layers, li, w, r, c) {
  const i = r * words(w) + (c >> 5);
  layers[li][i] = (layers[li][i] | (1 << (31 - (c & 31)))) >>> 0;
}

function clearBit(layers, li, w, r, c) {
  const i = r * words(w) + (c >> 5);
  layers[li][i] = (layers[li][i] & ~(1 << (31 - (c & 31)))) >>> 0;
}

// Small fast PRNG — same seed, same map, on every machine.
function mulberry32(a) {
  return function () {
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const fade = t => t * t * (3 - 2 * t);

// Value noise on a lattice `cells` across, bilinear + smoothstep. Returns a
// sampler over PIXEL coordinates so callers never think in lattice space.
function valueNoise(seed, w, h, cells) {
  const gw = Math.max(2, cells + 1);
  const gh = Math.max(2, Math.round(cells * h / w) + 1);
  const rnd = mulberry32(seed);
  const g = new Float32Array(gw * gh);
  for (let i = 0; i < g.length; i++) g[i] = rnd();
  return (r, c) => {
    const fx = (c / Math.max(1, w - 1)) * (gw - 1);
    const fz = (r / Math.max(1, h - 1)) * (gh - 1);
    const x0 = Math.min(gw - 2, Math.floor(fx));
    const z0 = Math.min(gh - 2, Math.floor(fz));
    const tx = fade(fx - x0), tz = fade(fz - z0);
    const a = g[z0 * gw + x0], b = g[z0 * gw + x0 + 1];
    const cc = g[(z0 + 1) * gw + x0], d = g[(z0 + 1) * gw + x0 + 1];
    return (a + (b - a) * tx) * (1 - tz) + (cc + (d - cc) * tx) * tz;
  };
}

// Octave-summed value noise, normalized back to 0..1.
function fbm(seed, w, h, cells, octaves) {
  const bands = [];
  let amp = 1, total = 0;
  for (let o = 0; o < octaves; o++) {
    bands.push([valueNoise(seed + o * 7919, w, h, cells << o), amp]);
    total += amp;
    amp *= 0.5;
  }
  return (r, c) => {
    let v = 0;
    for (const [n, a] of bands) v += n(r, c) * a;
    return v / total;
  };
}

// Height bands. Quantizing continuous noise is what makes PLATEAUS: broad
// terraces with abrupt shoulders, instead of one smooth dune field. Returns a
// TOP LAYER INDEX, so GROUND is the floor of the range and the bands are
// weighted to spend more of the map up on the higher terraces.
const BANDS = [0.26, 0.52, 0.76];

// `base` is the floor everything is measured from: the ground layer normally,
// the basement when the arena is sunk into the world.
function heightAt(e, base) {
  for (let i = 0; i < BANDS.length; i++) if (e < BANDS[i]) return base + i;
  return Math.min(LAYERS - 1, base + 3);
}

// A wandering corridor: hold a heading and turn slowly. With no `start` it
// enters from a random edge (canyons cross the whole map); given one it
// wanders out from there (tunnels start inside the mesa they bore through).
function walk(rnd, w, h, len, start) {
  const cells = [];
  let ang = rnd() * Math.PI * 2;
  let r, c;
  if (start) {
    r = start[0];
    c = start[1];
  } else switch (Math.floor(rnd() * 4)) {
    case 0: r = 1; c = Math.floor(rnd() * w); ang = Math.PI / 2; break;
    case 1: r = h - 2; c = Math.floor(rnd() * w); ang = -Math.PI / 2; break;
    case 2: c = 1; r = Math.floor(rnd() * h); ang = 0; break;
    default: c = w - 2; r = Math.floor(rnd() * h); ang = Math.PI; break;
  }
  for (let i = 0; i < len; i++) {
    ang += (rnd() - 0.5) * 0.45;
    c += Math.cos(ang);
    r += Math.sin(ang);
    const ri = Math.round(r), ci = Math.round(c);
    if (ri < 1 || ri >= h - 1 || ci < 1 || ci >= w - 1) break;
    cells.push([ri, ci]);
  }
  return cells;
}

// Roll a world. Returns { layers, seed } — layers is exactly what the painter
// and voxel_terrain already consume.
function generate(w, h, seed, opts) {
  seed = (seed >>> 0) || 1;
  opts = opts || {};
  const picked = Array.isArray(opts.schemes) ? opts.schemes : DEFAULT_SCHEMES;
  const on = k => picked.indexOf(k) !== -1;
  // Sunk: the whole arena drops a slab, so the floor is the basement and the
  // rim stands solid to the ceiling — you play in a crater, not on a plain.
  const sub = !!opts.subterranean;
  const base = sub ? 0 : GROUND;
  const rim = sub ? LAYERS - 1 : GROUND;
  const rnd = mulberry32(seed ^ 0x5bf03635);
  const layers = emptyLayers(w, h);

  const scale = Math.max(3, Math.round(Math.min(w, h) / 10));
  const elev = fbm(seed, w, h, scale, 3);
  const canyonA = valueNoise(seed ^ 0x9e3779b9, w, h, scale + 2);
  const canyonB = valueNoise(seed ^ 0x85ebca6b, w, h, scale + 4);
  const spire = fbm(seed ^ 0xc2b2ae35, w, h, scale * 3, 2);

  // Pass 1: heights, canyons cut through them, spires punched up out of them.
  const tops = new Int8Array(w * h);
  for (let r = 0; r < h; r++) {
    for (let c = 0; c < w; c++) {
      let top = on('plateaus') ? heightAt(elev(r, c), base) : base;
      // Ridge lines: the noise field crossing its own midpoint traces long
      // winding curves. Near one, the standing ground drops away — these are
      // the valley floors the canyons will later cut down the middle of.
      const rift = Math.min(Math.abs(canyonA(r, c) - 0.5), Math.abs(canyonB(r, c) - 0.5));
      if (on('canyons') && rift < 0.06) top = base;
      // Spires: rare, small, and they only grow out of ground that's already
      // standing, so they read as pillars rather than random floating teeth.
      if (on('spires') && top > base && spire(r, c) > 0.875) top = LAYERS - 1;
      // The map boundary is the seam the bowl blends into.
      if (r === 0 || c === 0 || r === h - 1 || c === w - 1) top = rim;
      tops[r * w + c] = top;
      for (let li = 0; li <= top; li++) setBit(layers, li, w, r, c);
    }
  }

  // Pass 2: canyons. A thresholded noise contour breaks up wherever the field
  // is steep, which gives potholes instead of chasms — so the actual cut is a
  // WALK. Continuous by construction, and it drops the floor out entirely.
  // The floor of a canyon is the BASEMENT slab, so it's a ravine you can walk
  // out of rather than a hole in the world.
  const canyons = on('canyons') ? 1 + Math.floor(Math.sqrt(w * h) / 34) : 0;
  for (let t = 0; t < canyons; t++) {
    for (const [r, c] of walk(rnd, w, h, (w + h) * 2)) {
      for (let dc = 0; dc <= 1; dc++) {
        const cc = Math.min(w - 2, c + dc);
        tops[r * w + cc] = 0;
        for (let li = GROUND; li < LAYERS; li++) clearBit(layers, li, w, r, cc);
      }
    }
  }

  // Pass 3: tunnels. Bore the main slab out from under high ground and the
  // layers above it become a roof — a real corridor you can drive through.
  // A tunnel only exists where there's something left overhead, so each walk
  // starts inside a mesa and the best of several candidates is the one cut.
  const mesas = [];
  for (let r = 1; r < h - 1; r++)
    for (let c = 1; c < w - 1; c++)
      if (tops[r * w + c] >= base + 1) mesas.push([r, c]);
  const tunnels = (on('tunnels') && mesas.length) ? 2 + Math.floor(Math.sqrt(w * h) / 26) : 0;
  for (let t = 0; t < tunnels; t++) {
    let best = null, bestScore = 0;
    for (let attempt = 0; attempt < 12; attempt++) {
      const path = walk(rnd, w, h, Math.round((w + h) * 0.6),
        mesas[Math.floor(rnd() * mesas.length)]);
      const score = path.filter(([r, c]) => tops[r * w + c] >= GROUND + 1).length;
      if (score > bestScore) { bestScore = score; best = path; }
    }
    for (const [r, c] of (best || [])) {
      for (let dc = 0; dc <= 1; dc++) {
        const cc = Math.min(w - 2, c + dc);
        if (tops[r * w + cc] >= base + 1) clearBit(layers, base, w, r, cc);
      }
    }
  }

  // Pass 4: cellars. Hollow the basement out under standing ground so there's
  // something below grade worth digging down into.
  const cellars = on('cellars') && !sub ? 2 + Math.floor(Math.sqrt(w * h) / 30) : 0;
  for (let t = 0; t < cellars; t++) {
    const cr = 3 + Math.floor(rnd() * Math.max(1, h - 6));
    const cc = 3 + Math.floor(rnd() * Math.max(1, w - 6));
    const rad = 2 + Math.floor(rnd() * 3);
    for (let dr = -rad; dr <= rad; dr++)
      for (let dc = -rad; dc <= rad; dc++) {
        const r = cr + dr, c = cc + dc;
        if (r < 1 || c < 1 || r >= h - 1 || c >= w - 1) continue;
        if (dr * dr + dc * dc > rad * rad) continue;
        if (tops[r * w + c] < GROUND) continue;   // don't undercut a canyon
        clearBit(layers, 0, w, r, c);
      }
  }

  // Pass 5: craters. Round bites taken clean out of whatever is standing, with
  // a raised lip, so the map has bowls to fight in and around.
  const craters = on('craters') ? 1 + Math.floor(Math.sqrt(w * h) / 40) : 0;
  for (let t = 0; t < craters; t++) {
    const rad = 3 + Math.floor(rnd() * 4);
    const cr = rad + 2 + Math.floor(rnd() * Math.max(1, h - rad * 2 - 4));
    const cc = rad + 2 + Math.floor(rnd() * Math.max(1, w - rad * 2 - 4));
    for (let dr = -rad - 1; dr <= rad + 1; dr++)
      for (let dc = -rad - 1; dc <= rad + 1; dc++) {
        const r = cr + dr, c = cc + dc;
        if (r < 1 || c < 1 || r >= h - 1 || c >= w - 1) continue;
        const d2 = dr * dr + dc * dc;
        if (d2 <= rad * rad) {
          tops[r * w + c] = base;
          for (let li = base + 1; li < LAYERS; li++) clearBit(layers, li, w, r, c);
          for (let li = 0; li <= base; li++) setBit(layers, li, w, r, c);
        } else if (d2 <= (rad + 1) * (rad + 1) && tops[r * w + c] <= base + 1) {
          tops[r * w + c] = Math.min(LAYERS - 1, base + 1);   // the rim
          for (let li = 0; li <= tops[r * w + c]; li++) setBit(layers, li, w, r, c);
        }
      }
  }

  // Pass 6: causeways. Narrow raised walks that stitch the high ground back
  // together — the counterpart to a canyon, and the only way across one.
  const ways = on('causeways') ? 1 + Math.floor(Math.sqrt(w * h) / 38) : 0;
  for (let t = 0; t < ways; t++) {
    const lift = Math.min(LAYERS - 1, base + 1 + Math.floor(rnd() * 2));
    for (const [r, c] of walk(rnd, w, h, (w + h))) {
      if (tops[r * w + c] >= lift) continue;
      tops[r * w + c] = lift;
      for (let li = 0; li <= lift; li++) setBit(layers, li, w, r, c);
    }
  }

  // The outer ring is the seam the boundary bowl blends into: plain floor
  // normally, and solid to the ceiling when the arena is sunk, so the crater
  // has a wall instead of a horizon.
  for (let r = 0; r < h; r++) {
    for (let c = 0; c < w; c++) {
      if (r !== 0 && c !== 0 && r !== h - 1 && c !== w - 1) continue;
      for (let li = 0; li <= rim; li++) setBit(layers, li, w, r, c);
      for (let li = rim + 1; li < LAYERS; li++) clearBit(layers, li, w, r, c);
      tops[r * w + c] = rim;
    }
  }

  return { layers, seed };
}

module.exports = { generate, LAYERS, GROUND, SCHEMES, DEFAULT_SCHEMES };
