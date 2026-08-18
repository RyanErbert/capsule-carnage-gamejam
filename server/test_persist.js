// Two steps, run as separate processes so the boot ordering is real:
//   node test_persist.js place <port>    -- place structures, wait for the save
//   node test_persist.js check <port>    -- connect to a freshly booted server
const { io } = require('socket.io-client');
const once = (s, ev, ms = 5000) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error('timeout ' + ev)), ms);
  s.once(ev, d => { clearTimeout(t); res(d); });
});
const [mode, port] = process.argv.slice(2);

(async () => {
  const s = io(`http://localhost:${port}`, { transports: ['websocket'] });
  await once(s, 'connect');
  s.emit('ready', { name: mode === 'place' ? 'ryan' : 'tim' });
  const list = await once(s, 'currentParametrics');

  if (mode === 'place') {
    s.emit('placeParametric', { type: 'wall',
      nodes: [{x:-10,y:0,z:0},{x:10,y:0,z:0}], params: { height: 11 } });
    const wall = await once(s, 'parametricPlaced');
    s.emit('placeParametric', { type: 'tower',
      nodes: [{x:30,y:0,z:5}], params: { height: 18, sides: 6 } });
    const tower = await once(s, 'parametricPlaced');
    // A punched penetration is part of the record too, and has to come back
    // with it -- a wall that forgets its windows is a different wall.
    s.emit('updateParametric', { id: wall.id, hole: { x: 0, y: 4, z: 0 } });
    await once(s, 'parametricUpdated');
    await new Promise(r => setTimeout(r, 2000));   // debounced save is 1.2s
    console.log(`placed 2 (${wall.id}, ${tower.id}) + 1 hole, waited for the save`);
  } else {
    const types = list.map(r => r.type).sort().join(',');
    const tower = list.find(r => r.type === 'tower');
    const wall = list.find(r => r.type === 'wall');
    console.log(`fresh server saw ${list.length}: ${types || '(none)'}`);
    console.log((list.length === 2 && types === 'tower,wall' ? 'PASS' : 'FAIL') + '  restored across a cold boot');
    console.log((tower && tower.params.sides === 6 && tower.params.height === 18 ? 'PASS' : 'FAIL') + '  params survived the round trip');
    console.log((wall && wall.holes && wall.holes.length === 1 && wall.holes[0].y === 4 ? 'PASS' : 'FAIL') + '  punched holes survived too');
  }
  s.close();
  process.exit(0);
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
