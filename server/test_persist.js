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
    await once(s, 'parametricPlaced');
    s.emit('placeParametric', { type: 'tower',
      nodes: [{x:30,y:0,z:5}], params: { height: 18, sides: 6 } });
    await once(s, 'parametricPlaced');
    await new Promise(r => setTimeout(r, 2000));   // debounced save is 1.2s
    console.log('placed 2 and waited for the save');
  } else {
    const types = list.map(r => r.type).sort().join(',');
    const tower = list.find(r => r.type === 'tower');
    console.log(`fresh server saw ${list.length}: ${types || '(none)'}`);
    console.log((list.length === 2 && types === 'tower,wall' ? 'PASS' : 'FAIL') + '  restored across a cold boot');
    console.log((tower && tower.params.sides === 6 && tower.params.height === 18 ? 'PASS' : 'FAIL') + '  params survived the round trip');
  }
  s.close();
  process.exit(0);
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
