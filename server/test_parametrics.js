// End-to-end check of the parametric protocol against a real server instance.
const { io } = require('socket.io-client');

const URL = 'http://localhost:3101';
const results = [];
const ok = (n, c) => results.push((c ? 'PASS' : 'FAIL') + '  ' + n);

function once(sock, ev, ms = 4000) {
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('timeout waiting for ' + ev)), ms);
    sock.once(ev, (d) => { clearTimeout(t); res(d); });
  });
}

(async () => {
  const a = io(URL, { transports: ['websocket'] });
  await once(a, 'connect');
  const b = io(URL, { transports: ['websocket'] });
  await once(b, 'connect');

  a.emit('ready', { name: 'ryan' });
  const initial = await once(a, 'currentParametrics');
  ok('join receives currentParametrics', Array.isArray(initial));

  // A places a wall; B must hear about it without asking.
  const heard = once(b, 'parametricPlaced');
  a.emit('placeParametric', {
    type: 'wall',
    nodes: [{ x: 0, y: 0, z: 0 }, { x: 14, y: 0, z: 0 }, { x: 14, y: 0, z: 9 }],
    params: { height: 7, thickness: 2.4, opening: 4 },
  });
  const rec = await heard;
  ok('peer sees the placement', rec && rec.type === 'wall');
  ok('owner stamped by server', rec.owner === 'ryan');
  ok('params kept', rec.params.height === 7 && rec.params.thickness === 2.4);
  ok('three nodes kept', rec.nodes.length === 3);

  // Handle drag: send one parameter, get the whole record back.
  const upd = once(b, 'parametricUpdated');
  a.emit('updateParametric', { id: rec.id, params: { height: 13.5 } });
  const after = await upd;
  ok('drag updates the one param', after.params.height === 13.5);
  ok('other params untouched', after.params.thickness === 2.4);
  ok('nodes untouched by a param drag', after.nodes.length === 3);

  // Node drag.
  const moved = once(b, 'parametricUpdated');
  a.emit('updateParametric', {
    id: rec.id,
    nodes: [{ x: 0, y: 0, z: 0 }, { x: 20, y: 3, z: 0 }, { x: 20, y: 3, z: 9 }],
  });
  const m = await moved;
  ok('node drag moves the node', Math.abs(m.nodes[1].x - 20) < 1e-6);
  ok('params survive a node drag', m.params.height === 13.5);

  // Hostile input is clamped, not trusted.
  const bad = once(b, 'parametricUpdated');
  a.emit('updateParametric', { id: rec.id, params: { height: 99999, evil: 1 } });
  const c = await bad;
  ok('out of range clamped', c.params.height === 24);
  ok('unknown key not stored', !('evil' in c.params));

  const gone = once(b, 'parametricRemoved');
  a.emit('removeParametric', rec.id);
  ok('removal broadcast', (await gone) === rec.id);

  a.close(); b.close();
  console.log(results.join('\n'));
  console.log(results.some(r => r.startsWith('FAIL')) ? '\nSOME FAILED' : '\nALL PASS');
  process.exit(0);
})().catch((e) => { console.log(results.join('\n')); console.error('ERROR:', e.message); process.exit(1); });
