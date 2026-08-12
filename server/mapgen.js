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

function heightAt(e) {
  for (let i = 0; i < BANDS.length; i++) if (e < BANDS[i]) return GROUND + i;
  return GROUND + 3;
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
function generate(w, h, seed) {
  seed = (seed >>> 0) || 1;
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
      let top = heightAt(elev(r, c));
      // Ridge lines: the noise field crossing its own midpoint traces long
      // winding curves. Near one, the standing ground drops away — these are
      // the valley floors the canyons will later cut down the middle of.
      const rift = Math.min(Math.abs(canyonA(r, c) - 0.5), Math.abs(canyonB(r, c) - 0.5));
      if (rift < 0.06) top = GROUND;
      // Spires: rare, small, and they only grow out of ground that's already
      // standing, so they read as pillars rather than random floating teeth.
      if (top > GROUND && spire(r, c) > 0.875) top = LAYERS - 1;
      // The map boundary is the seam the bowl blends into: always plain floor.
      if (r === 0 || c === 0 || r === h - 1 || c === w - 1) top = GROUND;
      tops[r * w + c] = top;
      for (let li = 0; li <= top; li++) setBit(layers, li, w, r, c);
    }
  }

  // Pass 2: canyons. A thresholded noise contour breaks up wherever the field
  // is steep, which gives potholes instead of chasms — so the actual cut is a
  // WALK. Continuous by construction, and it drops the floor out entirely.
  // The floor of a canyon is the BASEMENT slab, so it's a ravine you can walk
  // out of rather than a hole in the world.
  const canyons = 1 + Math.floor(Math.sqrt(w * h) / 34);
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
      if (tops[r * w + c] >= GROUND + 1) mesas.push([r, c]);
  const tunnels = mesas.length ? 2 + Math.floor(Math.sqrt(w * h) / 26) : 0;
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
        if (tops[r * w + cc] >= GROUND + 1) clearBit(layers, GROUND, w, r, cc);
      }
    }
  }

  // Pass 4: cellars. Hollow the basement out under standing ground so there's
  // something below grade worth digging down into.
  const cellars = 2 + Math.floor(Math.sqrt(w * h) / 30);
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

  // The outer ring stays plain walkable floor whatever the passes above did to
  // it: it's the seam the boundary bowl blends into.
  for (let r = 0; r < h; r++) {
    for (let c = 0; c < w; c++) {
      if (r !== 0 && c !== 0 && r !== h - 1 && c !== w - 1) continue;
      setBit(layers, 0, w, r, c);
      setBit(layers, GROUND, w, r, c);
      for (let li = GROUND + 1; li < LAYERS; li++) clearBit(layers, li, w, r, c);
      tops[r * w + c] = GROUND;
    }
  }

  return { layers, seed };
}

module.exports = { generate, LAYERS, GROUND };
