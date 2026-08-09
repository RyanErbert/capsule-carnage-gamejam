const GAME_VERSION = 'ALPHA 0.1.01';

const LEVEL_SPAWN_POINTS = {
  'level_1.glb': [
    { x: -39.64, y: 0.53, z: -31.33 },
    { x: -78.69, y: 0.53, z: -61.07 },
    { x: -57.51, y: 7.10, z: -60.48 },
    { x: -2.64, y: 0.53, z: -255.53 },
    { x: -46.90, y: 0.53, z: -309.56 },
    { x: -49.36, y: 0.46, z: -193.42 },
    { x: 46.60, y: 15.12, z: -173.82 },
    { x: 22.30, y: 0.53, z: -89.89 },
    { x: -81.11, y: 3.84, z: -464.15 },
    { x: -76.45, y: 0.53, z: -383.61 },
    { x: -60.66, y: 10.85, z: -160.14 },
    { x: -15.82, y: 35.39, z: -24.13 },
  ],
  'level_2.glb': [
    { x: -4.43, y: 161.88, z: -21.1 },
    { x: -5.72, y: 160.66, z: -3.36 },
    { x: 22.12, y: 168.59, z: 3.8 },
    { x: 24.99, y: 160.97, z: 3.07 },
    { x: -27.36, y: 161.88, z: 3.34 },
    { x: -27.66, y: 149.69, z: -28.19 },
    { x: -4.56, y: 145.73, z: -17.8 },
    { x: -4.86, y: 154.87, z: 1.14 },
    { x: 12.11, y: 160.05, z: 22.92 },
    { x: 37.7, y: 163.56, z: 20.13 },
    { x: 37.88, y: 163.56, z: -5.22 },
    { x: -34.88, y: 161.88, z: 18.03 },
    { x: 16.88, y: 151.22, z: 22.6 },
    { x: 13.89, y: 155.79, z: -3.39 },
  ],
  'level_3.glb': [
    { x: -81.52, y: -15.48, z: 22.12 },
    { x: -140.34, y: -18.29, z: 7.88 },
    { x: -145.72, y: 14.5, z: -21.92 },
    { x: -120.18, y: -23.09, z: -61.03 },
    { x: -156.08, y: -0.11, z: -116.92 },
    { x: -136.33, y: -15.51, z: -128.25 },
    { x: -91.79, y: -13.65, z: -107.49 },
    { x: -91.7, y: -17.65, z: -72.68 },
    { x: -184.28, y: -15.48, z: 52.21 },
    { x: -179.75, y: -15.48, z: 40.45 },
    { x: -174.78, y: -15.48, z: 50.9 },
    { x: -117.39, y: -15.6, z: 87.12 },
    { x: -91.7, y: -15.58, z: -26.09 },
    { x: -196.07, y: -15.48, z: -84.23 },
    { x: -169.17, y: -16.3, z: -6.25 },
  ],
};
let currentLevelName = 'level_1.glb';
let SPAWN_POINTS = LEVEL_SPAWN_POINTS['level_1.glb'];
function randomSpawn() { return SPAWN_POINTS[Math.floor(Math.random() * SPAWN_POINTS.length)]; }

const MOVE_FORCE = 60;
const SPRINT_FORCE = 120;
const MAX_SPEED = 9;
const SPRINT_SPEED = 18;
const JUMP_IMPULSE = 8;
const JOYSTICK_DEADZONE = 0.15;
const TAG_DISTANCE = 1.5;

const TAG_COOLDOWN = 4;
const SPRINT_DURATION = 4;
const SPRINT_REFILL_TIME = 6;
const JUMP_CD_AT_FULL = 5;

const isMobile = /Android|iPhone|iPad|iPod|webOS|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
  || ('ontouchstart' in window);

// --- Three.js scene ---
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x000000);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.domElement.style.cssText = 'position:fixed;top:0;left:0;z-index:1;';
document.body.appendChild(renderer.domElement);

const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.1, 1000);
camera.position.set(0, 5, 10);
scene.add(camera);

const gimbal = new THREE.AxesHelper(0.2);
gimbal.position.set(-1.2, 0.7, -2.5);
gimbal.visible = false;
camera.add(gimbal);

// Helper to create axis labels for the gimbal
function createAxisLabel(text, color, position) {
  const canvas = document.createElement('canvas');
  canvas.width = 64; canvas.height = 64;
  const ctx = canvas.getContext('2d');
  ctx.font = 'bold 48px 04b_03, Lato, sans-serif';
  ctx.fillStyle = color;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, 32, 36);
  const texture = new THREE.CanvasTexture(canvas);
  const mat = new THREE.SpriteMaterial({ map: texture, depthTest: false, depthWrite: false });
  const sprite = new THREE.Sprite(mat);
  sprite.scale.set(0.2, 0.2, 1);
  sprite.position.copy(position);
  sprite.renderOrder = 1000;
  return sprite;
}
gimbal.add(createAxisLabel('X', '#ff4444', new THREE.Vector3(0.25, 0, 0)));
gimbal.add(createAxisLabel('Y', '#44ff44', new THREE.Vector3(0, 0.25, 0)));
gimbal.add(createAxisLabel('Z', '#4444ff', new THREE.Vector3(0, 0, 0.25)));

// --- Sky gradient ---
const skyCanvas = document.createElement('canvas');
skyCanvas.width = 1; skyCanvas.height = 256;
const skyCtx = skyCanvas.getContext('2d');
const skyGrad = skyCtx.createLinearGradient(0, 0, 0, 256);
skyGrad.addColorStop(0, '#0a0a2e');
skyGrad.addColorStop(0.3, '#1a1a4e');
skyGrad.addColorStop(0.6, '#2d4a7a');
skyGrad.addColorStop(0.85, '#5a7faa');
skyGrad.addColorStop(1, '#8ab4d4');
skyCtx.fillStyle = skyGrad;
skyCtx.fillRect(0, 0, 1, 256);
const skyTex = new THREE.CanvasTexture(skyCanvas);
scene.background = skyTex;

// --- Sun light ---
const sunLight = new THREE.DirectionalLight(0xfff4e0, 1.5);
sunLight.position.set(100, 200, 80);
sunLight.castShadow = true;
sunLight.shadow.mapSize.width = 2048;
sunLight.shadow.mapSize.height = 2048;
sunLight.shadow.camera.near = 10;
sunLight.shadow.camera.far = 400;
sunLight.shadow.camera.left = -60;
sunLight.shadow.camera.right = 60;
sunLight.shadow.camera.top = 60;
sunLight.shadow.camera.bottom = -60;
// Bias to kill shadow acne on thin/curved surfaces (e.g. the channel slide) without disabling shadows.
sunLight.shadow.normalBias = 0.05;
sunLight.shadow.bias = -0.0004;
scene.add(sunLight);
scene.add(sunLight.target);

const hemiLight = new THREE.HemisphereLight(0x87ceeb, 0x553322, 0.6);
scene.add(hemiLight);
scene.add(new THREE.AmbientLight(0xffffff, 0.3));

const sunGeo = new THREE.SphereGeometry(8, 16, 16);
const sunMat = new THREE.MeshBasicMaterial({ color: 0xffffaa });
const sunMesh = new THREE.Mesh(sunGeo, sunMat);
sunMesh.position.copy(sunLight.position);
scene.add(sunMesh);

// --- Graphics settings (Escape menu) ---
// These levers trade quality vs framerate. Tone mapping + correct colour space
// are near-free visual upgrades; resolution and shadows are the real perf dials.
const graphicsSettings = {
  resolution: 'balanced', // perf (0.75x) | balanced (1.0x) | sharp (devicePixelRatio)
  shadows: 'high',        // off | medium (1024) | high (2048)
  toneMapping: true       // ACES filmic tone mapping for richer contrast
};
try {
  const saved = JSON.parse(localStorage.getItem('gfxSettings') || '{}');
  Object.assign(graphicsSettings, saved);
} catch (e) {}

if ('outputColorSpace' in renderer && THREE.SRGBColorSpace) renderer.outputColorSpace = THREE.SRGBColorSpace;
let maxAnisotropy = 1;
try { maxAnisotropy = renderer.capabilities.getMaxAnisotropy(); } catch (e) {}

function refreshSceneMaterials() {
  scene.traverse((o) => {
    if (!o.material) return;
    const mats = Array.isArray(o.material) ? o.material : [o.material];
    for (const m of mats) m.needsUpdate = true;
  });
}

function applyGraphics(recompile) {
  // Resolution scale
  let pr = 1;
  if (graphicsSettings.resolution === 'perf') pr = 0.75;
  else if (graphicsSettings.resolution === 'sharp') pr = Math.min(window.devicePixelRatio || 1, 2);
  renderer.setPixelRatio(pr);
  renderer.setSize(window.innerWidth, window.innerHeight);

  // Shadows
  if (graphicsSettings.shadows === 'off') {
    sunLight.castShadow = false;
  } else {
    sunLight.castShadow = true;
    const size = graphicsSettings.shadows === 'medium' ? 1024 : 2048;
    if (sunLight.shadow.mapSize.width !== size) {
      sunLight.shadow.mapSize.set(size, size);
      if (sunLight.shadow.map) { sunLight.shadow.map.dispose(); sunLight.shadow.map = null; }
    }
  }

  // Tone mapping (compiled into materials → only recompile when the user flips it)
  const wantTM = graphicsSettings.toneMapping ? THREE.ACESFilmicToneMapping : THREE.NoToneMapping;
  if (renderer.toneMapping !== wantTM) {
    renderer.toneMapping = wantTM;
    renderer.toneMappingExposure = 1.1;
    if (recompile) refreshSceneMaterials();
  }

  try { localStorage.setItem('gfxSettings', JSON.stringify(graphicsSettings)); } catch (e) {}
}
applyGraphics(false);

// --- Graphics settings overlay (toggled with Escape during play) ---
const gfxMenu = document.createElement('div');
gfxMenu.id = 'gfx-menu';
gfxMenu.style.cssText = 'position:fixed;inset:0;z-index:50;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,0.85);font-family:"04b_03",Lato,sans-serif;';
gfxMenu.innerHTML = `
  <div style="background:rgba(255,255,255,0.05);border:1px solid rgba(255,255,255,0.12);border-radius:10px;padding:22px 26px;min-width:340px;box-shadow:0 10px 40px rgba(0,0,0,0.6);">
    <div style="text-align:center;color:#fff;font-size:18px;letter-spacing:2px;margin-bottom:2px;">SETTINGS</div>
    <div style="text-align:center;color:#888;font-size:10px;letter-spacing:2px;margin-bottom:18px;">GRAPHICS</div>
    <div class="gfx-row" data-key="resolution" style="display:flex;align-items:center;justify-content:space-between;gap:18px;margin:12px 0;">
      <span style="color:#aaa;font-size:12px;letter-spacing:1px;">RESOLUTION</span>
      <button class="gfx-btn lobby-option"></button>
    </div>
    <div class="gfx-row" data-key="shadows" style="display:flex;align-items:center;justify-content:space-between;gap:18px;margin:12px 0;">
      <span style="color:#aaa;font-size:12px;letter-spacing:1px;">SHADOWS</span>
      <button class="gfx-btn lobby-option"></button>
    </div>
    <div class="gfx-row" data-key="toneMapping" style="display:flex;align-items:center;justify-content:space-between;gap:18px;margin:12px 0;">
      <span style="color:#aaa;font-size:12px;letter-spacing:1px;">ENHANCED COLOR</span>
      <button class="gfx-btn lobby-option"></button>
    </div>
    <button id="gfx-endvote" style="margin-top:20px;width:100%;padding:10px;background:#cc4444;color:#fff;border:none;border-radius:6px;cursor:pointer;font-family:'04b_03',Lato,sans-serif;font-size:13px;letter-spacing:1px;">VOTE END GAME</button>
    <button id="gfx-close" style="margin-top:8px;width:100%;padding:10px;background:#4488ff;color:#fff;border:none;border-radius:6px;cursor:pointer;font-family:'04b_03',Lato,sans-serif;font-size:14px;letter-spacing:1px;">RESUME (ESC)</button>
  </div>`;
document.body.appendChild(gfxMenu);
document.getElementById('gfx-close').addEventListener('mouseenter', (e) => e.target.style.background = '#3366dd');
document.getElementById('gfx-close').addEventListener('mouseleave', (e) => e.target.style.background = '#4488ff');
const gfxEndVoteBtn = document.getElementById('gfx-endvote');
gfxEndVoteBtn.addEventListener('mouseenter', (e) => e.target.style.background = '#b03333');
gfxEndVoteBtn.addEventListener('mouseleave', (e) => e.target.style.background = '#cc4444');
gfxEndVoteBtn.addEventListener('click', () => { socket.emit('startEndVote'); closeGfxMenu(); });

const GFX_CYCLES = {
  resolution: [['perf', 'Performance'], ['balanced', 'Balanced'], ['sharp', 'Sharp']],
  shadows: [['off', 'Off'], ['medium', 'Medium'], ['high', 'High']],
  toneMapping: [[true, 'On'], [false, 'Off']]
};
function gfxLabel(key) {
  const cur = graphicsSettings[key];
  const found = GFX_CYCLES[key].find(o => o[0] === cur);
  return found ? found[1] : String(cur);
}
function refreshGfxButtons() {
  gfxMenu.querySelectorAll('.gfx-row').forEach((row) => {
    const key = row.dataset.key;
    const btn = row.querySelector('.gfx-btn');
    btn.textContent = gfxLabel(key);
    // Reuse the main-menu .lobby-option look, but always rendered "selected".
    btn.classList.add('selected');
    btn.style.minWidth = '120px';
    btn.style.textAlign = 'center';
  });
}
gfxMenu.querySelectorAll('.gfx-row').forEach((row) => {
  const key = row.dataset.key;
  row.querySelector('.gfx-btn').addEventListener('click', () => {
    const opts = GFX_CYCLES[key];
    const idx = opts.findIndex(o => o[0] === graphicsSettings[key]);
    graphicsSettings[key] = opts[(idx + 1) % opts.length][0];
    applyGraphics(true);
    refreshGfxButtons();
  });
});
let gfxMenuOpen = false;
function openGfxMenu() {
  gfxMenuOpen = true;
  refreshGfxButtons();
  gfxMenu.style.display = 'flex';
  if (document.pointerLockElement) document.exitPointerLock();
}
function closeGfxMenu() {
  gfxMenuOpen = false;
  gfxMenu.style.display = 'none';
}
document.getElementById('gfx-close').addEventListener('click', closeGfxMenu);

// --- In-game chat (press T to type, messages stack bottom-right) ---
const chatLog = document.createElement('div');
chatLog.id = 'chat-log';
chatLog.style.cssText = 'position:fixed;right:12px;bottom:112px;z-index:40;display:flex;flex-direction:column;align-items:flex-end;gap:4px;max-width:340px;pointer-events:none;font-family:"04b_03",Lato,sans-serif;';
document.body.appendChild(chatLog);

const chatInputWrap = document.createElement('div');
chatInputWrap.id = 'chat-input-wrap';
chatInputWrap.style.cssText = 'position:fixed;right:12px;bottom:72px;z-index:41;display:none;';
chatInputWrap.innerHTML = '<input id="chat-input" type="text" maxlength="200" placeholder="Say something…" autocomplete="off" style="width:320px;padding:8px 12px;font-family:\'04b_03\',Lato,sans-serif;font-size:13px;color:#fff;background:rgba(0,0,0,0.8);border:1px solid #4488ff;border-radius:6px;outline:none;-webkit-user-select:text;user-select:text;">';
document.body.appendChild(chatInputWrap);
const chatInput = document.getElementById('chat-input');

let chatOpen = false;
function openChat() {
  if (!gameStarted || chatOpen) return;
  chatOpen = true;
  chatInputWrap.style.display = 'block';
  chatInput.value = '';
  refreshChatInputStyle();
  // Focus next tick so the "T" that opened chat isn't typed into the field.
  setTimeout(() => chatInput.focus(), 0);
}
function closeChat() {
  chatOpen = false;
  chatInputWrap.style.display = 'none';
  chatInput.blur();
}
function pushChatRow(row) {
  chatLog.appendChild(row);
  while (chatLog.children.length > 8) chatLog.removeChild(chatLog.firstChild);
  setTimeout(() => { row.style.opacity = '0'; setTimeout(() => row.remove(), 700); }, 9000);
}
function addChatMessage(name, color, text) {
  const row = document.createElement('div');
  row.style.cssText = 'background:rgba(0,0,0,0.7);border-radius:6px;padding:5px 9px;font-size:12px;color:#eee;text-shadow:1px 1px 2px rgba(0,0,0,0.9);word-break:break-word;transition:opacity 0.6s;opacity:1;text-align:left;';
  const safeName = document.createElement('span');
  safeName.textContent = name + ': ';
  safeName.style.cssText = 'font-weight:bold;color:' + (color || '#fff') + ';';
  const safeText = document.createElement('span');
  safeText.textContent = text;
  row.appendChild(safeName);
  row.appendChild(safeText);
  pushChatRow(row);
}
// Automated, game-generated messages (joins, votes, etc.) — italic gold, no name.
function addSystemMessage(text) {
  const row = document.createElement('div');
  row.style.cssText = 'background:rgba(20,16,0,0.7);border-left:2px solid #ffd54a;border-radius:6px;padding:5px 9px;font-size:12px;color:#ffd54a;font-style:italic;text-shadow:1px 1px 2px rgba(0,0,0,0.9);word-break:break-word;transition:opacity 0.6s;opacity:1;text-align:left;';
  row.textContent = text;
  pushChatRow(row);
}
// Parse a "/command args" line typed into chat. Returns true if it was a command.
function handleSlashCommand(raw) {
  const parts = raw.slice(1).trim().split(/\s+/);
  const cmd = (parts[0] || '').toLowerCase();
  const arg = (parts[1] || '').toLowerCase();
  if (cmd === 'vote') {
    if (arg === 'yes' || arg === 'y') socket.emit('castVote', true);
    else if (arg === 'no' || arg === 'n') socket.emit('castVote', false);
    else socket.emit('startEndVote');
  } else if (cmd === 'end' || cmd === 'endgame') {
    socket.emit('startEndVote');
  } else if (cmd === 'help') {
    addSystemMessage('Commands: /vote yes, /vote no, /end (start end-game vote)');
  } else {
    addSystemMessage(`Unknown command: /${cmd}`);
  }
}
// Highlight the input gold while it looks like a slash command.
function refreshChatInputStyle() {
  const isCmd = chatInput.value.startsWith('/');
  chatInput.style.color = isCmd ? '#ffd54a' : '#fff';
  chatInput.style.borderColor = isCmd ? '#ffd54a' : '#4488ff';
}
chatInput.addEventListener('input', refreshChatInputStyle);
chatInput.addEventListener('keydown', (e) => {
  e.stopPropagation();
  if (e.code === 'Enter') {
    const msg = chatInput.value.trim();
    if (msg) {
      if (msg.startsWith('/')) handleSlashCommand(msg);
      else socket.emit('chat', msg);
    }
    closeChat();
  } else if (e.code === 'Escape') {
    closeChat();
  }
});
chatInput.addEventListener('blur', () => { if (chatOpen) closeChat(); });

let levelLoaded = false;
let currentLevelObj = null;

const loader = new THREE.GLTFLoader();

function loadGameLevel(filename) {
  if (currentLevelObj) {
    scene.remove(currentLevelObj);
    currentLevelObj = null;
  }
  levelMeshes.length = 0;
  levelLoaded = false;
  currentLevelName = filename;
  SPAWN_POINTS = LEVEL_SPAWN_POINTS[filename] || LEVEL_SPAWN_POINTS['level_1.glb'];

  loader.load('/levels/' + filename, (gltf) => {
    const level = gltf.scene;
    level.traverse((child) => {
      if (child.isMesh) {
        child.receiveShadow = true;
        child.castShadow = true;
        if (child.material) {
          const mats = Array.isArray(child.material) ? child.material : [child.material];
          for (const m of mats) {
            for (const t of [m.map, m.normalMap, m.roughnessMap, m.metalnessMap, m.emissiveMap]) {
              if (t) { t.anisotropy = maxAnisotropy; t.needsUpdate = true; }
            }
          }
        }
        addLevelCollider(child);
      }
    });
    scene.add(level);
    currentLevelObj = level;
    levelLoaded = true;
  }, undefined, (err) => {
    console.error('Failed to load level:', err);
    const groundGeo = new THREE.PlaneGeometry(5000, 5000);
    const groundMat = new THREE.MeshStandardMaterial({ color: 0x55aa55 });
    const ground = new THREE.Mesh(groundGeo, groundMat);
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);
    currentLevelObj = ground;
    levelLoaded = true;
  });
}

// --- Cannon.js physics world ---
const world = new CANNON.World();
world.gravity.set(0, -20, 0);
world.broadphase = new CANNON.NaiveBroadphase();
world.solver.iterations = 10;

const groundMaterial = new CANNON.Material('ground');
const playerMaterial = new CANNON.Material('player');

world.addContactMaterial(new CANNON.ContactMaterial(groundMaterial, playerMaterial, {
  friction: 0.7, restitution: 0.1
}));
world.addContactMaterial(new CANNON.ContactMaterial(playerMaterial, playerMaterial, {
  friction: 0.3, restitution: 0.2
}));

// The single ground plane tracks the LOCAL player's footing via raycast. Put it
// in its own collision group so loose objects (coins) don't slam into it at the
// player's height — they get their own terrain raycast instead.
const GROUP_GROUNDPLANE = 2;
const groundBody = new CANNON.Body({ mass: 0, material: groundMaterial });
groundBody.addShape(new CANNON.Plane());
groundBody.collisionFilterGroup = GROUP_GROUNDPLANE;
groundBody.collisionFilterMask = -1; // collide with every group (players etc.)
groundBody.quaternion.setFromAxisAngle(new CANNON.Vec3(1, 0, 0), -Math.PI / 2);
groundBody.position.set(0, 0, 0);
world.addBody(groundBody);

// --- Raycast terrain detection ---
const PLAYER_RADIUS = 0.5;
const levelMeshes = [];

function addLevelCollider(mesh) {
  levelMeshes.push(mesh);
}

const raycaster = new THREE.Raycaster();
let rayGrounded = false;

function raycastLevel(origin, direction, maxDist, skipThin) {
  raycaster.set(origin, direction);
  raycaster.far = maxDist;
  const hits = raycaster.intersectObjects(levelMeshes, false);
  if (!skipThin) return hits.length > 0 ? hits[0] : null;
  // Skip thin ride-on platforms (bridges) for wall/ceiling resolution so players
  // don't catch on their edges or get bonked by their underside.
  for (const h of hits) {
    if (!(h.object.userData && h.object.userData.thinPlatform)) return h;
  }
  return null;
}

function updateGroundPlane(body) {
  const p = body.position;
  // Cast down to find the floor we're standing on. The ray starts ABOVE the
  // player's centre so we can still find a floor when slightly embedded, but
  // that means a plane the player has walked UNDER (a channel/overhang) would be
  // the first thing the ray hits going down. We must NOT treat such a surface as
  // the floor: the moving Cannon ground plane is a solid half-space, so snapping
  // it onto a surface above the player's centre ejects the player UP through it
  // (the "pushed onto the top of the plane" bug). So we skip every hit at or
  // above the centre and pick the highest surface that is genuinely below us.
  raycaster.set(new THREE.Vector3(p.x, p.y + 2, p.z), new THREE.Vector3(0, -1, 0));
  raycaster.far = 50;
  const hits = raycaster.intersectObjects(levelMeshes, false);
  let surfaceY = null;
  for (const h of hits) {
    if (h.point.y <= p.y + 0.05) { surfaceY = h.point.y; break; }
  }

  if (surfaceY !== null) {
    groundBody.position.y = surfaceY;
    // Un-embed only when GROSSLY sunk — e.g. spawned just below one of the
    // level's thin Object_3 slabs, or shoved under terrain. The Cannon ground
    // plane can't eject a body whose centre is already below it, so we lift it
    // here. A WIDE deadzone (0.35) is critical: the rolling roundcube's centre
    // naturally rests at surface+0.463 (half-extent), so correcting toward
    // surface+0.5 every frame — as the old 0.02 deadzone did — snapped it up
    // each frame and produced the wobble. Capped at 1.2 so we never yank a
    // player up through a tall overhang they are legitimately standing beneath.
    const restY = surfaceY + PLAYER_RADIUS;
    const penetration = restY - p.y;
    if (penetration > 0.35 && penetration < 1.2) {
      p.y = restY;
      if (body.velocity.y < 0) body.velocity.y = 0;
    }
    rayGrounded = (p.y - surfaceY) < 0.7;
  } else {
    groundBody.position.y = -1000;
    rayGrounded = false;
  }
}

function resolveWallCollisions(body) {
  const p = body.position;
  const wallDirs = [
    new THREE.Vector3(1, 0, 0), new THREE.Vector3(-1, 0, 0),
    new THREE.Vector3(0, 0, 1), new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(1, 0, 1).normalize(), new THREE.Vector3(-1, 0, 1).normalize(),
    new THREE.Vector3(1, 0, -1).normalize(), new THREE.Vector3(-1, 0, -1).normalize()
  ];

  const wallOrigin = new THREE.Vector3(p.x, p.y, p.z);
  for (const dir of wallDirs) {
    const hit = raycastLevel(wallOrigin, dir, PLAYER_RADIUS + 0.05, true);
    if (hit) {
      const pushDist = PLAYER_RADIUS + 0.05 - hit.distance;
      p.x -= dir.x * pushDist;
      p.z -= dir.z * pushDist;
      const velDot = body.velocity.x * dir.x + body.velocity.z * dir.z;
      if (velDot > 0) {
        body.velocity.x -= dir.x * velDot;
        body.velocity.z -= dir.z * velDot;
      }
    }
  }

  // Ceiling collision — prevent jumping through ceilings. Anchored to the
  // player's CURRENT position only (never previousPosition: a teleport/spawn can
  // leave previousPosition far below, which would turn the sweep into a huge
  // range and slam the player down onto an unrelated surface). Upward velocity is
  // killed as soon as a ceiling comes within reach (~1.3 above centre), which
  // stops a fast jump before the head ever reaches it. Several offset rays catch
  // sloped / off-centre ceilings that a single centre ray would slip past.
  const ceilBase = p.y + 0.3;
  const ceilReach = PLAYER_RADIUS + 0.5;
  const ro = PLAYER_RADIUS * 0.7;
  const ceilOffsets = [[0, 0], [ro, 0], [-ro, 0], [0, ro], [0, -ro]];
  let nearestCeil = null;
  for (const [ox, oz] of ceilOffsets) {
    const h = raycastLevel(new THREE.Vector3(p.x + ox, ceilBase, p.z + oz), new THREE.Vector3(0, 1, 0), ceilReach, true);
    // Pick the LOWEST ceiling found so we clamp under the tightest overhang.
    if (h && (!nearestCeil || h.point.y < nearestCeil.point.y)) nearestCeil = h;
  }
  if (nearestCeil) {
    if (nearestCeil.point.y - ceilBase < PLAYER_RADIUS + 0.1) {
      p.y = nearestCeil.point.y - PLAYER_RADIUS - 0.1;
    }
    if (body.velocity.y > 0) body.velocity.y = 0;
  }
}

// --- State ---
const clock = new THREE.Clock(false);
const keys = {};
let localPlayer = null;
let localMesh = null;
let localBody = null;
let selfId = null;
const remotePlayers = new Map();
const remoteMeshes = new Map();
const remoteBodies = new Map();
const outlineMeshes = new Map();
let joystickX = 0, joystickZ = 0;
let mobileSprinting = false;
let lastJoystickTap = 0;
let tiltX = 0, tiltZ = 0;
let airTime = 0;
let lastGroundedTime = 0;
const COYOTE_TIME = 0.28;
let jumpBufferTimer = 0;
const JUMP_BUFFER_TIME = 0.25;

// --- Charge jump state ---
const CHARGE_RATE = 3;
const MAX_CHARGE_MULT = 4;
let jumpCharge = 0;
let isChargingJump = false;
let jumpCooldownTimer = 0;
let jumpCooldownMax = 0;
let jumpCooldownStartPct = 0;

// --- Inventory state ---
const MAX_INVENTORY = 3;
const inventory = [];
let isGrappling = false;
let grappleTarget = null;
let grappleLine = null;
let pendingTeleporter = null;
let pendingTeleporterMesh = null;
const worldTeleporters = [];
let teleporterCooldownTimer = 0;
const activeBullets = [];
const activeRockets = [];
const worldMines = [];
const activeCoinsList = [];
const worldPads = [];
const pendingImpulses = [];
const worldBuilds = [];
const worldModels = [];

// --- GPU Particle System (Points-based) ---
const MAX_PARTICLES = 2000;
const particlePositions = new Float32Array(MAX_PARTICLES * 3);
const particleColors = new Float32Array(MAX_PARTICLES * 4);
const particleSizes = new Float32Array(MAX_PARTICLES);
const particleVelocities = new Float32Array(MAX_PARTICLES * 3);
const particleLifes = new Float32Array(MAX_PARTICLES);
const particleMaxLifes = new Float32Array(MAX_PARTICLES);
const particleGravities = new Float32Array(MAX_PARTICLES);
let particleCount = 0;

const particleGeo = new THREE.BufferGeometry();
particleGeo.setAttribute('position', new THREE.BufferAttribute(particlePositions, 3));
particleGeo.setAttribute('color', new THREE.BufferAttribute(particleColors, 4));
particleGeo.setAttribute('size', new THREE.BufferAttribute(particleSizes, 1));

const particleMat = new THREE.ShaderMaterial({
  uniforms: {},
  vertexShader: `
    attribute float size;
    attribute vec4 color;
    varying vec4 vColor;
    void main() {
      vColor = color;
      vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
      gl_PointSize = size * (200.0 / -mvPosition.z);
      gl_Position = projectionMatrix * mvPosition;
    }
  `,
  fragmentShader: `
    varying vec4 vColor;
    void main() {
      float d = length(gl_PointCoord - vec2(0.5));
      if (d > 0.5) discard;
      float alpha = vColor.a * smoothstep(0.5, 0.15, d);
      gl_FragColor = vec4(vColor.rgb, alpha);
    }
  `,
  transparent: true,
  depthWrite: false,
  blending: THREE.AdditiveBlending
});

const particleSystem = new THREE.Points(particleGeo, particleMat);
particleSystem.frustumCulled = false;
scene.add(particleSystem);

function spawnParticle(x, y, z, vx, vy, vz, r, g, b, a, size, life, gravity) {
  if (particleCount >= MAX_PARTICLES) return;
  const i = particleCount;
  particlePositions[i * 3] = x;
  particlePositions[i * 3 + 1] = y;
  particlePositions[i * 3 + 2] = z;
  particleVelocities[i * 3] = vx;
  particleVelocities[i * 3 + 1] = vy;
  particleVelocities[i * 3 + 2] = vz;
  particleColors[i * 4] = r;
  particleColors[i * 4 + 1] = g;
  particleColors[i * 4 + 2] = b;
  particleColors[i * 4 + 3] = a;
  particleSizes[i] = size;
  particleLifes[i] = life;
  particleMaxLifes[i] = life;
  particleGravities[i] = gravity;
  particleCount++;
}

function spawnExplosion(x, y, z, isMine) {
  const count = isMine ? 20 : 30;
  const speed = isMine ? 8 : 12;
  for (let i = 0; i < count; i++) {
    const dir = new THREE.Vector3(Math.random() - 0.5, Math.random() * 0.8, Math.random() - 0.5).normalize();
    const spd = speed * (0.4 + Math.random() * 0.6);
    const t = Math.random();
    const r = isMine ? 1.0 : (t < 0.3 ? 1.0 : 1.0);
    const g = isMine ? (t * 0.3) : (0.3 + t * 0.5);
    const b = isMine ? 0 : (t * 0.1);
    const size = (isMine ? 3 : 4) + Math.random() * 3;
    const life = 0.3 + Math.random() * 0.5;
    spawnParticle(x, y, z, dir.x * spd, dir.y * spd, dir.z * spd, r, g, b, 1.0, size, life, -3);
  }
  // Smoke ring
  for (let i = 0; i < 8; i++) {
    const angle = (i / 8) * Math.PI * 2;
    const spd = 3 + Math.random() * 2;
    spawnParticle(x, y, z, Math.cos(angle) * spd, 1 + Math.random() * 2, Math.sin(angle) * spd, 0.4, 0.4, 0.4, 0.6, 5 + Math.random() * 3, 0.6 + Math.random() * 0.4, -1);
  }
}

function spawnTrailParticle(x, y, z) {
  const spread = 0.15;
  spawnParticle(
    x + (Math.random() - 0.5) * spread,
    y + (Math.random() - 0.5) * spread,
    z + (Math.random() - 0.5) * spread,
    (Math.random() - 0.5) * 0.5, (Math.random() - 0.5) * 0.5, (Math.random() - 0.5) * 0.5,
    1.0, 0.65, 0.2, 0.8,
    2 + Math.random(), 0.2 + Math.random() * 0.1, 0
  );
}

function updateParticles(delta) {
  let writeIdx = 0;
  for (let i = 0; i < particleCount; i++) {
    particleLifes[i] -= delta;
    if (particleLifes[i] <= 0) continue;

    particleVelocities[i * 3 + 1] += particleGravities[i] * delta;
    particlePositions[i * 3] += particleVelocities[i * 3] * delta;
    particlePositions[i * 3 + 1] += particleVelocities[i * 3 + 1] * delta;
    particlePositions[i * 3 + 2] += particleVelocities[i * 3 + 2] * delta;

    const pct = particleLifes[i] / particleMaxLifes[i];
    particleColors[i * 4 + 3] = pct;
    particleSizes[i] *= (1 + delta * 0.5);

    if (writeIdx !== i) {
      particlePositions[writeIdx * 3] = particlePositions[i * 3];
      particlePositions[writeIdx * 3 + 1] = particlePositions[i * 3 + 1];
      particlePositions[writeIdx * 3 + 2] = particlePositions[i * 3 + 2];
      particleVelocities[writeIdx * 3] = particleVelocities[i * 3];
      particleVelocities[writeIdx * 3 + 1] = particleVelocities[i * 3 + 1];
      particleVelocities[writeIdx * 3 + 2] = particleVelocities[i * 3 + 2];
      particleColors[writeIdx * 4] = particleColors[i * 4];
      particleColors[writeIdx * 4 + 1] = particleColors[i * 4 + 1];
      particleColors[writeIdx * 4 + 2] = particleColors[i * 4 + 2];
      particleColors[writeIdx * 4 + 3] = particleColors[i * 4 + 3];
      particleSizes[writeIdx] = particleSizes[i];
      particleLifes[writeIdx] = particleLifes[i];
      particleMaxLifes[writeIdx] = particleMaxLifes[i];
      particleGravities[writeIdx] = particleGravities[i];
    }
    writeIdx++;
  }
  particleCount = writeIdx;
  particleGeo.setDrawRange(0, particleCount);
  particleGeo.attributes.position.needsUpdate = true;
  particleGeo.attributes.color.needsUpdate = true;
  particleGeo.attributes.size.needsUpdate = true;
}

// --- Inventory HUD ---
const inventoryHud = document.createElement('div');
inventoryHud.id = 'inventory-hud';
inventoryHud.style.cssText = 'position:absolute;top:10px;left:10px;display:flex;align-items:flex-start;gap:10px;z-index:20;';
document.body.appendChild(inventoryHud);

function getColorForItem(item) {
  if (['grapple', 'launch_pad', 'boost_pad', 'teleporter'].includes(item)) return '#44ff44';
  if (['machinegun', 'rocket', 'mines'].includes(item)) return '#ff4444';
  if (['block', 'wall', 'ramp', 'platform', 'bridge_gun'].includes(item)) return '#ffff44';
  return '#ffffff';
}

function swapToFirst(index) {
  if (index <= 0 || index >= inventory.length) return;
  const temp = inventory[0];
  inventory[0] = inventory[index];
  inventory[index] = temp;
  updateInventoryUI();
}

function updateInventoryUI() {
  inventoryHud.innerHTML = '';
  if (!gameStarted) return;
  inventory.forEach((invObj, index) => {
    const item = invObj.type;
    const isMain = index === 0;
    const size = isMain ? 80 : 50;
    const slot = document.createElement('div');
    slot.style.cssText = `
      width:${size}px; height:${size}px;
      background:rgba(0,0,0,0.6);
      border:2px solid ${getColorForItem(item)};
      border-radius:8px;
      display:flex; flex-direction:column; justify-content:center; align-items:center;
      color:white; font:10px "04b_03",Lato,sans-serif; text-align:center; text-transform:uppercase;
      transition: all 0.2s ease-in-out;
      transform: none; opacity: 1;
      ${isMain ? 'pointer-events:none;' : 'cursor:pointer;'}
    `;
    slot.innerHTML = `<div>${item.replace('_', ' ')}</div>${invObj.ammo > 0 && invObj.ammo !== Infinity ? `<div style="font-size:16px;margin-top:4px;color:#ff4444">${invObj.ammo}</div>` : ''}${invObj.ammo === Infinity ? `<div style="font-size:10px;margin-top:4px;color:#44aaff">∞</div>` : ''}`;
    if (!isMain) {
      slot.addEventListener('click', () => swapToFirst(index));
      slot.addEventListener('touchstart', (e) => { e.preventDefault(); swapToFirst(index); });
    }
    inventoryHud.appendChild(slot);
  });
}

function getAimPoint(ndc, isWeapon) {
  const ray = new THREE.Raycaster();
  ray.setFromCamera(ndc, camera);
  const targets = [...levelMeshes];
  if (isWeapon) {
    targets.push(...pedestalMeshes);
    for (const p of worldPads) targets.push(p.mesh);
    for (const [id, group] of remotePlayers) targets.push(group);
  }
  const hits = ray.intersectObjects(targets, true);
  return hits.length > 0 ? hits[0].point : null;
}

function shiftInventory(item, targetPt) {
  inventory.shift();
  console.log(`Consumed ${item} aimed at`, targetPt);

  const firstSlot = inventoryHud.children[0];
  if (firstSlot) {
    firstSlot.style.transform = 'scale(0.5) translateX(-50px)';
    firstSlot.style.opacity = '0';
    for (let i = 1; i < inventoryHud.children.length; i++) {
      inventoryHud.children[i].style.transform = 'translateX(-60px) scale(1.6)';
    }
    setTimeout(updateInventoryUI, 200);
  } else {
    updateInventoryUI();
  }
}

function getAimDirection() {
  const ndc = isMobile ? new THREE.Vector2(0, 0) : lastMouseNDC;
  const ray = new THREE.Raycaster();
  ray.setFromCamera(ndc, camera);
  const playerOrigin = new THREE.Vector3().copy(localBody.position).add(new THREE.Vector3(0, 0.4, 0));
  const hits = ray.intersectObjects(levelMeshes, false);
  let aimPoint;
  if (hits.length > 0 && hits[0].distance > 15) {
    aimPoint = hits[0].point;
  } else {
    aimPoint = ray.ray.origin.clone().addScaledVector(ray.ray.direction, 150);
  }
  return aimPoint.sub(playerOrigin).normalize();
}

function useAmmo() {
  if (infiniteAmmo) return;
  inventory[0].ammo--;
  updateInventoryUI();
  if (inventory[0].ammo <= 0) shiftInventory(inventory[0].type, null);
}

function consumeItem(targetPt) {
  if (inventory.length === 0) return;
  const item = inventory[0].type;

  if (item === 'grapple') {
    if (!targetPt) return;
    isGrappling = true;
    grappleTarget = new THREE.Vector3(targetPt.x, targetPt.y, targetPt.z);
    playWorldSound(boostSound, localBody ? localBody.position : null, 0.8);
    useAmmo();
    return;
  } else if (['launch_pad', 'boost_pad', 'mines'].includes(item)) {
    if (!targetPt || !localPlayer || localPlayer.position.distanceTo(targetPt) > 10) return;
    if (item === 'mines') socket.emit('placeMine', targetPt);
    else {
      const dir = new THREE.Vector3();
      camera.getWorldDirection(dir);
      dir.y = 0; dir.normalize();
      socket.emit('placePad', { x: targetPt.x, y: targetPt.y, z: targetPt.z, type: item, dx: dir.x, dz: dir.z });
    }
  } else if (item === 'teleporter') {
    if (!targetPt) return;
    if (!pendingTeleporter) {
      pendingTeleporter = targetPt;
      const geo = new THREE.CylinderGeometry(0.8, 0.8, 0.2, 16);
      const mat = new THREE.MeshStandardMaterial({ color: 0x44ff44, transparent: true, opacity: 0.5 });
      pendingTeleporterMesh = new THREE.Mesh(geo, mat);
      pendingTeleporterMesh.position.copy(targetPt);
      scene.add(pendingTeleporterMesh);
      return; // Early return to NOT consume the item on the first click
    } else {
      socket.emit('placeTeleporter', { a: pendingTeleporter, b: targetPt });
      if (pendingTeleporterMesh) { scene.remove(pendingTeleporterMesh); pendingTeleporterMesh = null; }
      pendingTeleporter = null;
    }
  } else if (['block', 'wall', 'ramp', 'platform'].includes(item)) {
    if (!buildTarget || !buildCanPlace) return;
    socket.emit('placeBuild', { type: item, ...buildTarget });
    useAmmo();
    return;
  } else if (item === 'bridge_gun') {
    if (!targetPt || !localBody) return;
    const origin = new THREE.Vector3().copy(localBody.position).add(new THREE.Vector3(0, -0.4, 0));
    const target = targetPt.clone();
    let dist = origin.distanceTo(target);
    if (dist > 100) {
      dist = 100;
      target.copy(origin).add(new THREE.Vector3().subVectors(target, origin).normalize().multiplyScalar(100));
    }
    const mid = origin.clone().lerp(target, 0.5);
    const dir = new THREE.Vector3().subVectors(target, origin).normalize();
    socket.emit('placeBuild', { type: 'bridge', x: mid.x, y: mid.y, z: mid.z, ry: Math.atan2(dir.x, dir.z), rx: -Math.asin(dir.y), length: dist });
    useAmmo();
    return;
  } else if (item === 'rocket') {
    if (!localBody || rocketCooldownTimer > 0) return;
    const fireDir = getAimDirection();

    const origin = new THREE.Vector3().copy(localBody.position).add(new THREE.Vector3(0, 0.4, 0));
    const start = origin.clone().addScaledVector(fireDir, 2.5);

    const ROCKET_SPEED = 60;
    const velocity = { x: fireDir.x * ROCKET_SPEED, y: fireDir.y * ROCKET_SPEED, z: fireDir.z * ROCKET_SPEED };
    socket.emit('fireRocket', { start, velocity });

    rocketCooldownTimer = 2.0;
    useAmmo();
    return;
  }

  shiftInventory(item, targetPt);
}

let machinegunInterval = null;
let rocketCooldownTimer = 0;

function findLockOnTarget(origin, aimDir) {
  let best = null;
  let bestDist = Infinity;
  const lockOnRadius = 3.0;
  for (const [id, group] of remotePlayers) {
    const toPlayer = new THREE.Vector3().subVectors(group.position, origin);
    const projDist = toPlayer.dot(aimDir);
    if (projDist < 2 || projDist > 80) continue;
    const closest = origin.clone().addScaledVector(aimDir, projDist);
    const perpDist = closest.distanceTo(group.position);
    if (perpDist < lockOnRadius && projDist < bestDist) {
      bestDist = projDist;
      best = group.position;
    }
  }
  return best;
}

function startMachinegun() {
  if (machinegunInterval) return;
  machinegunInterval = setInterval(() => {
    if (!localBody || inventory.length === 0 || inventory[0].type !== 'machinegun') { stopMachinegun(); return; }
    const origin = new THREE.Vector3().copy(localBody.position).add(new THREE.Vector3(0, 0.4, 0));
    let baseDir = getAimDirection();

    const lockTarget = findLockOnTarget(origin, baseDir);
    if (lockTarget) {
      baseDir = new THREE.Vector3().subVectors(lockTarget, origin).normalize();
    }

    const noisyDir = baseDir.clone();
    noisyDir.x += (Math.random() - 0.5) * 0.04;
    noisyDir.y += (Math.random() - 0.5) * 0.04;
    noisyDir.z += (Math.random() - 0.5) * 0.04;
    noisyDir.normalize();

    const start = origin.clone().addScaledVector(noisyDir, 2.0);
    socket.emit('fireMachinegun', { start, velocity: noisyDir.multiplyScalar(200) });
    if (!infiniteAmmo) {
      inventory[0].ammo--;
      updateInventoryUI();
      if (inventory[0].ammo <= 0) {
        stopMachinegun();
        shiftInventory('machinegun', null);
      }
    }
  }, 80);
}

function stopMachinegun() {
  if (machinegunInterval) {
    clearInterval(machinegunInterval);
    machinegunInterval = null;
  }
}

// --- Sprint stamina state ---
let sprintStamina = SPRINT_DURATION;
let sprintExhausted = false;
let wasSprinting = false;

// --- Tag cooldown state ---
let tagCooldownTimer = 0;

// --- Ball morph state ---
let sprintMorphT = 0;
let originalSmoothing = 0.25;
let morphedPhysicsToSphere = false;
let speedCapCurrent = MAX_SPEED;

// --- Oddball state ---
let holderID = null;
let allScores = {};
let leaderID = null;

// --- Audio state ---
const music = new Audio('/music/background.mp3');
music.loop = true;
let musicVolume = 0;
music.volume = musicVolume;
let musicPlaying = false;

const boostSound = new Audio('/sound/boost.wav');
boostSound.volume = 0.4;

const jumpSounds = [
  new Audio('/sound/jump_1.wav'),
  new Audio('/sound/jump_2.wav'),
  new Audio('/sound/jump_3.wav'),
  new Audio('/sound/jump_4.wav'),
];
const JUMP_SOUND_BASE_VOLUME = 0.5;

const bombSounds = [
  new Audio('/sound/bomb_1.wav'),
  new Audio('/sound/bomb_2.wav'),
  new Audio('/sound/bomb_3.wav'),
  new Audio('/sound/bomb_4.wav'),
  new Audio('/sound/bomb_5.wav'),
  new Audio('/sound/bomb_6.wav'),
];
const BOMB_SOUND_BASE_VOLUME = 2.0;

const MAX_SOUND_DIST = 50;

function playWorldSound(sound, position, baseVolume = 1.0) {
  if (!position) return;
  const dist = camera.position.distanceTo(position);

  if (dist > MAX_SOUND_DIST) return;

  const volume = baseVolume * Math.max(0, 1 - (dist / MAX_SOUND_DIST));
  sound.volume = Math.min(1, Math.max(0, volume));

  if (sound.volume > 0.01) {
    sound.currentTime = 0;
    sound.play().catch(e => { /* ignore play error */ });
  }
}

function playRandomJumpSound(position) {
  const sound = jumpSounds[Math.floor(Math.random() * jumpSounds.length)];
  playWorldSound(sound, position, JUMP_SOUND_BASE_VOLUME);
}

function playRandomBombSound(position) {
  const sound = bombSounds[Math.floor(Math.random() * bombSounds.length)];
  playWorldSound(sound, position, BOMB_SOUND_BASE_VOLUME);
}

// --- Inactivity timeout ---
const INACTIVITY_TIMEOUT = 5 * 60 * 1000;
const INACTIVITY_WARNING = 30 * 1000;
let lastActivityTime = Date.now();
let inactivityWarningShown = false;

const inactivityBanner = document.createElement('div');
inactivityBanner.id = 'inactivity-banner';
inactivityBanner.style.cssText = 'position:absolute;top:0;left:0;right:0;padding:12px;background:rgba(255,60,60,0.9);color:white;font:14px "04b_03",Lato,sans-serif;text-align:center;z-index:100;display:none;pointer-events:none;';
document.body.appendChild(inactivityBanner);

function resetActivity() {
  lastActivityTime = Date.now();
  if (inactivityWarningShown) {
    inactivityWarningShown = false;
    inactivityBanner.style.display = 'none';
  }
}

function returnToMenu() {
  if (godmode && localBody) {
    godmode = false;
    localBody.mass = 1;
    localBody.updateMassProperties();
    hideSpawnMarkers();
    hideGodmodeMenu();
    hideAllGhosts();
  }

  for (const ped of pedestalMeshes) scene.remove(ped);
  pedestalMeshes.length = 0;

  gameStarted = false;
  if (isMobile) {
    const jb = document.getElementById('joystick-base');
    const jmp = document.getElementById('jump-btn');
    const mhb = document.getElementById('mobile-hud-bar');
    if (jb) jb.style.display = 'none';
    if (jmp) jmp.style.display = 'none';
    if (mhb) mhb.style.display = 'none';
  }
  nameScreen.style.display = '';
  hud.style.display = 'none';
  hud.style.opacity = '1';
  hud.style.transition = '';
  leaderDisplay.style.display = 'none';
  scoreboardEl.style.display = 'none';
  debugEl.style.display = 'none';
  debugVisible = false;
  if (menuOverlay) menuOverlay.style.display = 'block';
  initLevelSelect();
  inactivityBanner.style.display = 'none';
  inactivityWarningShown = false;
  sprintMeter.wrap.style.display = 'none';
  jumpMeter.wrap.style.display = 'none';

  if (localPlayer) { scene.remove(localPlayer); localPlayer = null; }
  localMesh = null;
  localBody = null;
  selfId = null;

  for (const [id, group] of remotePlayers) scene.remove(group);
  remotePlayers.clear();
  remoteMeshes.clear();
  remoteTargets.clear();
  playerOutlines.clear();
  playerCrowns.clear();
  playerScoreSprites.clear();
  playerNames.clear();

  holderID = null;
  allScores = {};
  leaderID = null;
  inventory.length = 0;
  isGrappling = false;
  if (grappleLine) grappleLine.visible = false;
  if (pendingTeleporterMesh) { scene.remove(pendingTeleporterMesh); pendingTeleporterMesh = null; }
  pendingTeleporter = null;
  teleporterCooldownTimer = 0;

  for (const m of worldMines) scene.remove(m.mesh);
  worldMines.length = 0;

  for (const c of activeCoinsList) {
    scene.remove(c.mesh);
    world.removeBody(c.body);
  }
  activeCoinsList.length = 0;

  particleCount = 0;

  for (const b of activeBullets) scene.remove(b.mesh);
  activeBullets.length = 0;

  for (const p of worldPads) scene.remove(p.mesh);
  worldPads.length = 0;

  for (const b of worldBuilds) {
    scene.remove(b.mesh);
    if (b.body) world.removeBody(b.body);
    const lIdx = levelMeshes.indexOf(b.mesh);
    if (lIdx !== -1) levelMeshes.splice(lIdx, 1);
  }
  worldBuilds.length = 0;

  for (const wm of worldModels) {
    scene.remove(wm.group);
    wm.group.traverse((child) => {
      if (child.isMesh) {
        const li = levelMeshes.indexOf(child);
        if (li !== -1) levelMeshes.splice(li, 1);
      }
    });
  }
  worldModels.length = 0;

  if (machinegunInterval) { clearInterval(machinegunInterval); machinegunInterval = null; }

  updateInventoryUI();

  if (document.pointerLockElement) document.exitPointerLock();

  socket.disconnect();
  socket.connect();
  lastActivityTime = Date.now();
}

function checkInactivity() {
  if (!gameStarted) return;
  const elapsed = Date.now() - lastActivityTime;
  if (elapsed >= INACTIVITY_TIMEOUT) {
    returnToMenu();
    return;
  }
  if (elapsed >= INACTIVITY_TIMEOUT - INACTIVITY_WARNING && !inactivityWarningShown) {
    inactivityWarningShown = true;
    inactivityBanner.style.display = '';
  }
  if (inactivityWarningShown) {
    const remaining = Math.ceil((INACTIVITY_TIMEOUT - elapsed) / 1000);
    inactivityBanner.textContent = `AFK timeout in ${remaining}s — move to stay in game`;
  }
}

window.addEventListener('keydown', () => resetActivity(), true);
window.addEventListener('mousedown', () => resetActivity(), true);
window.addEventListener('mousemove', () => resetActivity(), true);
window.addEventListener('touchstart', () => resetActivity(), true);
window.addEventListener('touchmove', () => resetActivity(), true);
window.addEventListener('wheel', () => resetActivity(), true);

// --- Godmode item menu ---
let godmodeToolSelected = 'spawn';
const pedestalMeshes = [];
let pedestalTemplate = null;

loader.load('/prefabs/item_ped.glb', (gltf) => {
  pedestalTemplate = gltf.scene;
  pedestalTemplate.traverse((child) => {
    if (child.isMesh) {
      child.castShadow = true;
      child.receiveShadow = true;
    }
  });
}, undefined, (err) => console.warn('Failed to load pedestal model:', err));

const godmodeMenu = document.createElement('div');
godmodeMenu.id = 'godmode-menu';
godmodeMenu.style.cssText = 'position:absolute;top:50px;left:10px;background:rgba(0,0,0,0.8);border:1px solid rgba(255,255,255,0.3);border-radius:8px;padding:10px;font:12px "04b_03",Lato,sans-serif;color:white;z-index:30;display:none;user-select:none;max-height:calc(100vh - 70px);overflow-y:auto;';
godmodeMenu.innerHTML = `
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
    <span style="color:#fff;letter-spacing:1px;font-size:11px;">GODMODE</span>
    <span style="color:#888;font-size:9px;">F4 / Esc to exit</span>
  </div>
  <div style="display:flex;gap:14px;align-items:flex-start;">
   <div style="flex:1;min-width:150px;">
    <div style="margin-bottom:8px;color:#aaa;letter-spacing:1px;font-size:10px;">PREFABS</div>
    <div id="gm-tool-spawn" class="gm-tool selected" data-tool="spawn" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬦ Prefab: Player Spawn</div>
    <div id="gm-tool-ped-green" class="gm-tool" data-tool="pedestal_green" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Prefab: Movement Item</div>
    <div id="gm-tool-ped-red" class="gm-tool" data-tool="pedestal_red" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Prefab: Weapon Item</div>
    <div id="gm-tool-ped-yellow" class="gm-tool" data-tool="pedestal_yellow" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Prefab: Build Item</div>
    <div style="margin-bottom:8px;color:#aaa;letter-spacing:1px;font-size:10px;margin-top:10px;">TOOLS</div>
    <div id="gm-tool-build-block" class="gm-tool" data-tool="build_mode" data-build="block" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Block</div>
    <div id="gm-tool-build-wall" class="gm-tool" data-tool="build_mode" data-build="wall" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Wall</div>
    <div id="gm-tool-build-ramp" class="gm-tool" data-tool="build_mode" data-build="ramp" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Ramp</div>
    <div id="gm-tool-build-platform" class="gm-tool" data-tool="build_mode" data-build="platform" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Platform</div>
    <div id="gm-tool-build-bridge" class="gm-tool" data-tool="build_bridge" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Bridge</div>
    <div id="gm-tool-build-teleporter" class="gm-tool" data-tool="build_teleporter" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Teleporter</div>
    <div id="gm-tool-build-channel" class="gm-tool" data-tool="build_channel" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Build Channel</div>
    <div id="gm-tool-delete" class="gm-tool" data-tool="delete_block" style="padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;">⬡ Tool: Delete Block</div>
    <div style="margin-bottom:8px;color:#aaa;letter-spacing:1px;font-size:10px;margin-top:10px;">MODELS</div>
    <div id="gm-models-list"></div>
   </div>
   <div style="flex:1;min-width:150px;">
    <div style="border-bottom:1px solid rgba(255,255,255,0.25);padding-bottom:6px;margin-bottom:8px;">
      <div style="color:#7fd0ff;letter-spacing:1px;font-size:10px;">GIVE TO PLAYER</div>
      <div style="color:#888;font-size:9px;margin-top:2px;">Click an item to add it to your inventory</div>
    </div>
    <div style="margin-bottom:8px;color:#aaa;letter-spacing:1px;font-size:10px;">MOVEMENT ITEMS</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">
      <div class="gm-give" data-item="grapple" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Grapple</div>
      <div class="gm-give" data-item="launch_pad" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Launch Pad</div>
      <div class="gm-give" data-item="boost_pad" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Boost Pad</div>
      <div class="gm-give" data-item="teleporter" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Teleporter</div>
    </div>
    <div style="margin-bottom:8px;color:#aaa;letter-spacing:1px;font-size:10px;margin-top:10px;">WEAPON ITEMS</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">
      <div class="gm-give" data-item="machinegun" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Machinegun</div>
      <div class="gm-give" data-item="rocket" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Rocket</div>
      <div class="gm-give" data-item="mines" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Mines</div>
    </div>
    <div style="margin-bottom:8px;color:#aaa;letter-spacing:1px;font-size:10px;margin-top:10px;">BUILD ITEMS</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">
      <div class="gm-give" data-item="block" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Block</div>
      <div class="gm-give" data-item="wall" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Wall</div>
      <div class="gm-give" data-item="ramp" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Ramp</div>
      <div class="gm-give" data-item="platform" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Platform</div>
      <div class="gm-give" data-item="bridge_gun" style="padding:6px;background:rgba(255,255,255,0.1);border-radius:4px;cursor:pointer;text-align:center;">Bridge Gun</div>
    </div>
   </div>
  </div>
`;
document.body.appendChild(godmodeMenu);

// Populate placeable models from the server (middle-mouse drag to rotate the ghost before placing)
fetch('/api/models').then(r => r.json()).then((files) => {
  const list = document.getElementById('gm-models-list');
  if (!list) return;
  if (!files.length) { list.innerHTML = '<div style="color:#666;padding:4px 12px;font-size:10px;">(none)</div>'; return; }
  for (const f of files) {
    const name = f.replace(/\.glb$/i, '');
    const div = document.createElement('div');
    div.className = 'gm-tool';
    div.dataset.tool = 'model';
    div.dataset.model = f;
    div.style.cssText = 'padding:6px 12px;margin:3px 0;border-radius:4px;cursor:pointer;';
    div.textContent = '▢ Model: ' + name;
    list.appendChild(div);
  }
}).catch((err) => console.warn('Failed to load model list:', err));

const gmToolStyle = document.createElement('style');
gmToolStyle.textContent = `
  .gm-tool { transition: background 0.15s; }
  .gm-tool:hover { background: rgba(255,255,255,0.15); }
  .gm-tool.selected { background: rgba(68,136,255,0.4); border-left: 3px solid #4488ff; }
  #name-screen, #level-select, #title-canvas, #cube-preview { position:relative; z-index:10; }
  #name-screen, #name-screen *:not(input):not(button):not(.agi-box):not(.agi-dot) { background: transparent !important; background-color: transparent !important; box-shadow: none !important; border: none !important; backdrop-filter: none !important; }
  #active-game-info .agi-box { background: rgba(68,136,255,0.08) !important; border: 1px solid rgba(68,136,255,0.4) !important; }
  #active-game-info .agi-dot { border: 1px solid rgba(255,255,255,0.5) !important; }
`;
document.head.appendChild(gmToolStyle);

const menuOverlay = document.createElement('div');
menuOverlay.id = 'menu-overlay';
menuOverlay.style.cssText = 'position:absolute;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.85);pointer-events:none;z-index:5;display:none;';
document.body.appendChild(menuOverlay);

godmodeMenu.addEventListener('click', (e) => {
  e.stopPropagation();
  const give = e.target.closest('.gm-give');
  if (give) {
     socket.emit('godmodeGive', give.dataset.item);
     return;
  }
  const tool = e.target.closest('.gm-tool');
  if (!tool) return;
  godmodeToolSelected = tool.dataset.tool;
  if (tool.dataset.build) godmodeBuildType = tool.dataset.build;
  if (tool.dataset.model) selectedModel = tool.dataset.model;
  bridgeStart = null;
  hideAllGhosts();
  godmodeMenu.querySelectorAll('.gm-tool').forEach(t => t.classList.remove('selected'));
  tool.classList.add('selected');
  if (godmodeToolSelected === 'build_channel') showToast('Channel: click to add points · scroll = height · Enter = finish · Backspace = undo point · Esc = cancel');
});

function showGodmodeMenu() { godmodeMenu.style.display = ''; }
function hideGodmodeMenu() { godmodeMenu.style.display = 'none'; }

function enterGodmode() {
  if (!localBody) return;
  godmode = true;
  const dir = new THREE.Vector3();
  camera.getWorldDirection(dir);
  const yaw = Math.atan2(-dir.x, -dir.z);
  const pitch = Math.asin(Math.max(-1, Math.min(1, dir.y)));
  camera.rotation.order = 'YXZ';
  camera.rotation.set(pitch, yaw, 0);
  localBody.mass = 0;
  localBody.updateMassProperties();
  buildPlaneY = Math.round(camera.position.y / 4) * 4 - 4;
  showSpawnMarkers();
  showGodmodeMenu();
  if (document.pointerLockElement) document.exitPointerLock();
  socket.emit('godmodeEnter');
}

function exitGodmode() {
  if (!localBody) return;
  godmode = false;
  const dir = new THREE.Vector3();
  camera.getWorldDirection(dir);
  const spawnDist = 5;
  localBody.position.set(
    camera.position.x + dir.x * spawnDist,
    camera.position.y + dir.y * spawnDist,
    camera.position.z + dir.z * spawnDist
  );
  localBody.velocity.set(0, 0, 0);
  localBody.angularVelocity.set(0, 0, 0);
  localBody.mass = 1;
  localBody.updateMassProperties();
  camera.rotation.order = 'XYZ';
  camera.up.set(0, 1, 0);
  camera.quaternion.identity();
  camera.rotation.set(0, 0, 0);
  if (localPlayer) {
    const toPlayer = new THREE.Vector3().subVectors(localPlayer.position, camera.position);
    camYaw = Math.atan2(toPlayer.x, toPlayer.z);
  }
  camPitch = 0.4;
  hideSpawnMarkers();
  hideGodmodeMenu();
  hideAllGhosts();
}

function createPedestalAt(pt, pedId) {
  if (!pedestalTemplate) return null;
  const ped = pedestalTemplate.clone();
  ped.position.set(pt.x, pt.y, pt.z);
  if (pt.ry !== undefined) ped.rotation.y = pt.ry;
  ped.userData.pedestalId = pedId;
  ped.userData.type = pt.type || 'green';

  const crystalGeo = new THREE.OctahedronGeometry(0.3, 0);
  let color = 0x44ff44;
  if (ped.userData.type === 'red') color = 0xff4444;
  if (ped.userData.type === 'yellow') color = 0xffff44;
  const crystalMat = new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.4 });
  const crystal = new THREE.Mesh(crystalGeo, crystalMat);
  crystal.position.y = 1.2;
  crystal.userData.isCrystal = true;
  crystal.visible = !!pt.currentItem;
  ped.add(crystal);

  scene.add(ped);
  pedestalMeshes.push(ped);
  return ped;
}

function showPedestalMarkers() {
  for (const ped of pedestalMeshes) {
    ped.visible = true;
  }
}

// --- Placeable models (godmode) ---
let selectedModel = null;
const modelTemplates = {};   // filename -> loaded gltf.scene (template)
const modelGhosts = {};      // filename -> ghost group
let bridgeStart = null;      // first-click point for the Build Bridge tool
let teleporterStartA = null; // first-click point for the Build Teleporter tool

// --- Placement undo (godmode: spawn points, pedestals, models) ---
const MAX_UNDO = 15;
const placementUndoStack = [];
function genPlacementId() { return Date.now().toString(36) + Math.random().toString(36).substr(2); }
function pushUndo(entry) {
  placementUndoStack.push(entry);
  if (placementUndoStack.length > MAX_UNDO) placementUndoStack.shift();
}
function undoLastPlacement() {
  const entry = placementUndoStack.pop();
  if (!entry) { showToast('Cannot undo further'); return; }
  if (entry.kind === 'spawn') {
    SPAWN_POINTS = SPAWN_POINTS.filter(p => p !== entry.sp);
    if (entry.marker) {
      scene.remove(entry.marker);
      const idx = spawnMarkers.indexOf(entry.marker);
      if (idx !== -1) spawnMarkers.splice(idx, 1);
    }
    showToast('Undid spawn point');
  } else if (entry.kind === 'pedestal') {
    socket.emit('removePedestal', entry.id);
    showToast('Undid pedestal');
  } else if (entry.kind === 'model') {
    socket.emit('removeModel', entry.id);
    showToast('Undid model');
  } else if (entry.kind === 'channel') {
    socket.emit('removeChannel', entry.id);
    showToast('Undid channel');
  }
}

let toastEl = null, toastTimer = null;
function showToast(msg) {
  if (!toastEl) {
    toastEl = document.createElement('div');
    toastEl.style.cssText = 'position:absolute;bottom:90px;left:50%;transform:translateX(-50%);background:rgba(0,0,0,0.85);border:1px solid rgba(255,255,255,0.3);border-radius:6px;padding:8px 16px;font:12px "04b_03",Lato,sans-serif;color:#fff;z-index:50;pointer-events:none;opacity:0;transition:opacity 0.2s;';
    document.body.appendChild(toastEl);
  }
  toastEl.textContent = msg;
  toastEl.style.opacity = '1';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toastEl.style.opacity = '0'; }, 1500);
}

// --- Build Channel tool (multiclick half-pipe trough) ---
let channelNodes = [];        // committed THREE.Vector3 polyline points
let channelHeightOffset = 0;  // scroll-driven vertical offset for the node being placed
const CHANNEL_RADIUS = 2.5;   // inner radius — diameter 5 fits ~2 players
const CHANNEL_FACETS = 12;    // arc segments across the half-pipe
const worldChannels = [];     // { id, group, bodies, meshes }

// Mixes interpolating and approximating behavior: gentle anchors are passed
// through (interpolating); sharp corners get pulled toward the midpoint of their
// neighbors (approximating) so the curve rounds them off instead of kinking.
const CHANNEL_MAX_RELAX = 0.6;        // strongest pull at very sharp corners
function relaxChannelAnchors(points) {
  if (points.length <= 2) return points.map(p => p.clone());
  const out = [points[0].clone()];
  for (let i = 1; i < points.length - 1; i++) {
    const prev = points[i - 1], cur = points[i], next = points[i + 1];
    const v1 = new THREE.Vector3().subVectors(cur, prev);
    const v2 = new THREE.Vector3().subVectors(next, cur);
    if (v1.lengthSq() < 1e-8 || v2.lengthSq() < 1e-8) { out.push(cur.clone()); continue; }
    const angle = Math.acos(THREE.MathUtils.clamp(v1.normalize().dot(v2.normalize()), -1, 1)); // 0=straight, PI=U-turn
    // no relaxation under ~25°, ramping up to full relax past ~125°
    const t = THREE.MathUtils.clamp((angle - Math.PI / 7) / (Math.PI * 0.6), 0, 1) * CHANNEL_MAX_RELAX;
    const mid = new THREE.Vector3().addVectors(prev, next).multiplyScalar(0.5);
    out.push(cur.clone().lerp(mid, t));
  }
  out.push(points[points.length - 1].clone());
  return out;
}

// Builds the whole channel as a smooth half-pipe swept along a Catmull-Rom curve.
// Returns { geo, segmentPanels: [...], anchorPosts: [Vector3] (relaxed anchor positions, on the curve) }.
function buildChannelGeometry(points, radius) {
  if (!points || points.length < 2) return null;
  const anchors = relaxChannelAnchors(points);
  const curve = new THREE.CatmullRomCurve3(anchors.map(p => p.clone()), false, 'centripetal', 0.5);
  const L = curve.getLength();
  const N = Math.max(2, Math.min(260, Math.ceil(L / 1.5))); // ring spacing ~1.5 units
  const samples = curve.getSpacedPoints(N);                 // N+1 evenly arc-spaced points
  const M = samples.length;
  const K = CHANNEL_FACETS;

  // Per-sample tangent (finite difference) and a non-banking frame (opening faces world-up).
  const rings = [];
  const tangents = [];
  for (let i = 0; i < M; i++) {
    let T;
    if (i === 0) T = new THREE.Vector3().subVectors(samples[1], samples[0]);
    else if (i === M - 1) T = new THREE.Vector3().subVectors(samples[M - 1], samples[M - 2]);
    else T = new THREE.Vector3().subVectors(samples[i + 1], samples[i - 1]);
    if (T.lengthSq() < 1e-8) T.set(0, 0, 1);
    T.normalize();
    tangents.push(T);
    let Rt = new THREE.Vector3().crossVectors(new THREE.Vector3(0, 1, 0), T);
    if (Rt.lengthSq() < 1e-6) Rt.set(1, 0, 0); else Rt.normalize();
    const U = new THREE.Vector3().crossVectors(T, Rt).normalize();
    const ring = [];
    for (let j = 0; j <= K; j++) {
      const a = -Math.PI / 2 + (j / K) * Math.PI; // a=0 -> bottom (rides the curve), a=±90° -> top edges
      ring.push(samples[i].clone()
        .addScaledVector(Rt, radius * Math.sin(a))
        .addScaledVector(U, radius * (1 - Math.cos(a))));
    }
    rings.push(ring);
  }

  const positions = [];
  for (let i = 0; i < M; i++) for (let j = 0; j <= K; j++) { const p = rings[i][j]; positions.push(p.x, p.y, p.z); }
  const idx = (i, j) => i * (K + 1) + j;
  const indices = [];
  for (let i = 0; i < M - 1; i++) for (let j = 0; j < K; j++) {
    const a0 = idx(i, j), a1 = idx(i + 1, j), b0 = idx(i, j + 1), b1 = idx(i + 1, j + 1);
    indices.push(a0, a1, b0, a1, b1, b0);
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geo.setIndex(indices);
  geo.computeVertexNormals();

  // Physics: one body per longitudinal slice, K box panels each (broadphase culls distant slices).
  const segmentPanels = [];
  for (let i = 0; i < M - 1; i++) {
    const along = new THREE.Vector3().subVectors(samples[i + 1], samples[i]);
    const alongLen = along.length();
    const alongDir = alongLen > 1e-6 ? along.clone().normalize() : tangents[i].clone();
    const panels = [];
    for (let j = 0; j < K; j++) {
      const c0 = rings[i][j], c1 = rings[i][j + 1], c2 = rings[i + 1][j], c3 = rings[i + 1][j + 1];
      const center = c0.clone().add(c1).add(c2).add(c3).multiplyScalar(0.25);
      const crossVec = new THREE.Vector3().subVectors(c1, c0);
      const width = crossVec.length();
      const crossDir = crossVec.lengthSq() > 1e-8 ? crossVec.clone().normalize() : new THREE.Vector3(1, 0, 0);
      crossDir.addScaledVector(alongDir, -crossDir.dot(alongDir)); // orthogonalize vs length axis
      if (crossDir.lengthSq() < 1e-8) crossDir.set(1, 0, 0);
      crossDir.normalize();
      const normal = new THREE.Vector3().crossVectors(alongDir, crossDir).normalize();
      const m = new THREE.Matrix4().makeBasis(alongDir, crossDir, normal);
      const q = new THREE.Quaternion().setFromRotationMatrix(m);
      panels.push({ center, quaternion: q, hx: Math.max(alongLen / 2, 0.05), hy: Math.max(width / 2, 0.05), hz: 0.15 });
    }
    segmentPanels.push(panels);
  }
  return { geo, segmentPanels, anchorPosts: anchors };
}

const channelGhostMat = new THREE.MeshBasicMaterial({ color: 0x00ffff, transparent: true, opacity: 0.35, depthWrite: false, side: THREE.DoubleSide });
const channelGhostGroup = new THREE.Group();
scene.add(channelGhostGroup);
const channelNodeMarkerGeo = new THREE.SphereGeometry(0.35, 8, 8);
const channelNodeMarkerMat = new THREE.MeshBasicMaterial({ color: 0xffff44 });
const channelGhostRay = new THREE.Raycaster();
channelGhostRay.far = 1000;

function clearChannelGhost() {
  for (let i = channelGhostGroup.children.length - 1; i >= 0; i--) {
    const c = channelGhostGroup.children[i];
    if (c.userData.disposeGeo && c.geometry) c.geometry.dispose();
    channelGhostGroup.remove(c);
  }
}
function rebuildChannelGhost(points) {
  clearChannelGhost();
  if (points.length >= 2) {
    const data = buildChannelGeometry(points, CHANNEL_RADIUS);
    if (data) {
      const mesh = new THREE.Mesh(data.geo, channelGhostMat);
      mesh.userData.disposeGeo = true;
      channelGhostGroup.add(mesh);
    }
  }
  // markers at the actual click points
  for (const p of points) {
    const mk = new THREE.Mesh(channelNodeMarkerGeo, channelNodeMarkerMat);
    mk.position.copy(p);
    channelGhostGroup.add(mk);
  }
  // ghost support posts under the (relaxed) anchors, matching the placed result
  const down = new THREE.Vector3(0, -1, 0);
  const postAnchors = points.length >= 2 ? relaxChannelAnchors(points) : points;
  for (const a of postAnchors) {
    const topY = a.y - CHANNEL_RADIUS * 0.15;
    channelGhostRay.set(new THREE.Vector3(a.x, topY - 0.05, a.z), down);
    const hits = channelGhostRay.intersectObjects(levelMeshes, false);
    const groundY = hits.length > 0 ? hits[0].point.y : a.y - 14;
    const h = topY - groundY;
    if (h >= 0.25) {
      const post = new THREE.Mesh(new THREE.CylinderGeometry(0.35, 0.35, h, 8), channelGhostMat);
      post.position.set(a.x, groundY + h / 2, a.z);
      post.userData.disposeGeo = true;
      channelGhostGroup.add(post);
    }
  }
  channelGhostGroup.visible = points.length > 0;
}
function resetChannelDraft() {
  channelNodes = [];
  channelHeightOffset = 0;
  clearChannelGhost();
  channelGhostGroup.visible = false;
}
function finishChannel() {
  if (channelNodes.length < 2) { resetChannelDraft(); return; }
  const id = genPlacementId();
  socket.emit('placeChannel', {
    id,
    nodes: channelNodes.map(p => ({ x: +p.x.toFixed(2), y: +p.y.toFixed(2), z: +p.z.toFixed(2) })),
    radius: CHANNEL_RADIUS
  });
  pushUndo({ kind: 'channel', id });
  showToast(`Channel placed (${channelNodes.length} nodes)`);
  resetChannelDraft();
}

function loadModelTemplate(filename) {
  return new Promise((resolve) => {
    if (modelTemplates[filename]) { resolve(modelTemplates[filename]); return; }
    loader.load('/models/' + filename, (gltf) => {
      gltf.scene.traverse((child) => {
        if (child.isMesh) { child.castShadow = true; child.receiveShadow = true; }
      });
      modelTemplates[filename] = gltf.scene;
      resolve(gltf.scene);
    }, undefined, (err) => { console.warn('Failed to load model:', filename, err); resolve(null); });
  });
}

function createModelAt(m) {
  loadModelTemplate(m.model).then((template) => {
    if (!template) return;
    const group = template.clone();
    group.position.set(m.x, m.y, m.z);
    group.rotation.y = m.ry || 0;
    group.userData.modelId = m.id;
    group.traverse((child) => {
      if (child.isMesh) {
        child.castShadow = true;
        child.receiveShadow = false; // avoid self-shadow acne (scanline artifacts)
        addLevelCollider(child);
      }
    });
    scene.add(group);
    worldModels.push({ id: m.id, group });
  });
}

function removeModelById(id) {
  const idx = worldModels.findIndex(wm => wm.id === id);
  if (idx === -1) return;
  const wm = worldModels[idx];
  wm.group.traverse((child) => {
    if (child.isMesh) {
      const li = levelMeshes.indexOf(child);
      if (li !== -1) levelMeshes.splice(li, 1);
    }
  });
  scene.remove(wm.group);
  worldModels.splice(idx, 1);
}

// --- Godmode hover preview ---
const FLATNESS_THRESHOLD = 0.85;
let ghostPreview = null;
let ghostOutlineGroup = null;
let ghostCanPlace = false;
let ghostRotationY = 0;
let hoveredExisting = null;
const hoveredOriginalColors = new Map();

const ghostSpawnGeo = new THREE.OctahedronGeometry(0.4, 0);
const ghostBlueMat = new THREE.MeshStandardMaterial({ color: 0x4488ff, transparent: true, opacity: 0.45, depthWrite: false, side: THREE.DoubleSide });
const ghostRedMat = new THREE.MeshStandardMaterial({ color: 0xff3333, transparent: true, opacity: 0.45, depthWrite: false });
const outlineBlueMat = new THREE.MeshBasicMaterial({ color: 0x4488ff, side: THREE.BackSide, transparent: true, opacity: 0.6 });
const outlineRedMat = new THREE.MeshBasicMaterial({ color: 0xff3333, side: THREE.BackSide, transparent: true, opacity: 0.6 });
const deleteRedMat = new THREE.MeshStandardMaterial({ color: 0xff2222, emissive: 0xff0000, emissiveIntensity: 0.3 });
const deleteOutlineMat = new THREE.MeshBasicMaterial({ color: 0xff3333, side: THREE.BackSide });

function createGhostSpawn() {
  const group = new THREE.Group();
  const diamond = new THREE.Mesh(ghostSpawnGeo, ghostBlueMat.clone());
  diamond.scale.set(1, 1.5, 1);
  group.add(diamond);
  const outline = new THREE.Mesh(ghostSpawnGeo, outlineBlueMat.clone());
  outline.scale.set(1.2, 1.8, 1.2);
  group.add(outline);
  group.visible = false;
  scene.add(group);
  return group;
}

function createGhostPedestal() {
  if (!pedestalTemplate) return null;
  const group = new THREE.Group();
  const clone = pedestalTemplate.clone();
  const meshes = [];
  clone.traverse((child) => {
    if (child.isMesh) meshes.push(child);
  });
  for (const mesh of meshes) {
    mesh.material = ghostBlueMat.clone();
    mesh.castShadow = false;
    const olGeo = mesh.geometry.clone();
    const ol = new THREE.Mesh(olGeo, outlineBlueMat.clone());
    ol.scale.multiplyScalar(1.15);
    ol.renderOrder = -1;
    mesh.add(ol);
  }
  group.add(clone);
  group.visible = false;
  scene.add(group);
  return group;
}

let ghostSpawn = null;
let ghostPedestal = null;

function createGhostModel(filename) {
  if (modelGhosts[filename]) return modelGhosts[filename];
  const group = new THREE.Group();
  group.visible = false;
  scene.add(group);
  modelGhosts[filename] = group;
  loadModelTemplate(filename).then((template) => {
    if (!template) return;
    const clone = template.clone();
    clone.traverse((child) => {
      if (child.isMesh) { child.material = ghostBlueMat.clone(); child.castShadow = false; child.receiveShadow = false; }
    });
    group.add(clone);
  });
  return group;
}

function getGhost() {
  if (godmodeToolSelected === 'spawn') {
    if (!ghostSpawn) ghostSpawn = createGhostSpawn();
    if (ghostPedestal) ghostPedestal.visible = false;
    for (const f in modelGhosts) modelGhosts[f].visible = false;
    return ghostSpawn;
  } else if (godmodeToolSelected.startsWith('pedestal')) {
    if (!ghostPedestal) ghostPedestal = createGhostPedestal();
    if (ghostSpawn) ghostSpawn.visible = false;
    for (const f in modelGhosts) modelGhosts[f].visible = false;
    return ghostPedestal;
  } else if (godmodeToolSelected === 'model' && selectedModel) {
    if (ghostSpawn) ghostSpawn.visible = false;
    if (ghostPedestal) ghostPedestal.visible = false;
    for (const f in modelGhosts) if (f !== selectedModel) modelGhosts[f].visible = false;
    return createGhostModel(selectedModel);
  }
}

function setGhostColor(ghost, canPlace) {
  if (!ghost) return;
  let col = 0x4488ff;
  if (!canPlace) col = 0xff3333;

  ghost.traverse((child) => {
    if (child.isMesh && child.material && child.material.color) {
      if (child.material.side === THREE.BackSide) {
        child.material.color.setHex(canPlace ? 0x4488ff : 0xff3333);
      } else {
        child.material.color.setHex(col);
      }
    }
  });
}

function clearHoverHighlight() {
  if (!hoveredExisting) return;
  for (const [mesh, origColor] of hoveredOriginalColors) {
    mesh.material = mesh.userData._origMaterial || mesh.material;
    mesh.material.color.copy(origColor);
    const ol = mesh.children.find(c => c.isMesh && c.material.side === THREE.BackSide);
    if (ol && ol.userData._wasHidden !== undefined) {
      ol.visible = ol.userData._wasHidden ? false : true;
      if (ol.userData._origOlMat) ol.material = ol.userData._origOlMat;
    }
  }
  hoveredOriginalColors.clear();
  hoveredExisting = null;
}

function highlightForDelete(obj) {
  clearHoverHighlight();
  hoveredExisting = obj;
  obj.traverse((child) => {
    if (!child.isMesh || child.material.side === THREE.BackSide) return;
    hoveredOriginalColors.set(child, child.material.color.clone());
    child.userData._origMaterial = child.material;
    child.material = child.material.clone();
    child.material.color.set(0xff2222);
    child.material.emissive = new THREE.Color(0xff0000);
    child.material.emissiveIntensity = 0.3;
    const ol = child.children.find(c => c.isMesh && c.material.side === THREE.BackSide);
    if (ol) {
      ol.userData._wasHidden = !ol.visible;
      ol.userData._origOlMat = ol.material;
      ol.visible = true;
      ol.material = deleteOutlineMat.clone();
    }
  });
}

const hoverNDC = new THREE.Vector2();
const hoverRaycaster = new THREE.Raycaster();
hoverRaycaster.far = 500;

function updateGodmodeHover(mouseX, mouseY) {
  if (!godmode) return;

  hoverNDC.x = (mouseX / window.innerWidth) * 2 - 1;
  hoverNDC.y = -(mouseY / window.innerHeight) * 2 + 1;
  hoverRaycaster.setFromCamera(hoverNDC, camera);

  const ghost = getGhost();

  if (godmodeToolSelected === 'build_bridge') {
    clearHoverHighlight();
    const hits = hoverRaycaster.intersectObjects([...levelMeshes, ...worldBuilds.map(b => b.mesh)], false);
    if (hits.length === 0) { bridgeGhost.visible = false; return; }
    const hoverPt = hits[0].point.clone();
    if (!bridgeStart) { bridgeGhost.visible = false; return; }
    const target = hoverPt.clone();
    let dist = bridgeStart.distanceTo(target);
    if (dist < 0.5) { bridgeGhost.visible = false; return; }
    const mid = bridgeStart.clone().lerp(target, 0.5);
    const dir = new THREE.Vector3().subVectors(target, bridgeStart).normalize();
    bridgeGhost.scale.set(1, 1, dist);
    bridgeGhost.position.copy(mid);
    bridgeGhost.rotation.order = 'YXZ';
    bridgeGhost.rotation.set(-Math.asin(dir.y), Math.atan2(dir.x, dir.z), 0);
    bridgeGhost.visible = true;
    return;
  }

  if (godmodeToolSelected === 'build_teleporter') {
    clearHoverHighlight();
    teleporterGhostA.visible = !!teleporterStartA;
    if (teleporterStartA) teleporterGhostA.position.copy(teleporterStartA);
    const hits = hoverRaycaster.intersectObjects(levelMeshes, false);
    if (hits.length === 0) { teleporterGhostB.visible = false; return; }
    teleporterGhostB.position.copy(hits[0].point);
    teleporterGhostB.visible = true;
    return;
  }

  if (godmodeToolSelected === 'build_channel') {
    clearHoverHighlight();
    const hits = hoverRaycaster.intersectObjects([...levelMeshes, ...worldBuilds.map(b => b.mesh)], false);
    if (hits.length === 0) {
      if (channelNodes.length) rebuildChannelGhost(channelNodes);
      else channelGhostGroup.visible = false;
      return;
    }
    const candidate = hits[0].point.clone();
    candidate.y += channelHeightOffset;
    rebuildChannelGhost([...channelNodes, candidate]);
    return;
  }

  // Check for existing items to highlight for deletion
  if (godmodeToolSelected === 'spawn') {
    const markerHits = hoverRaycaster.intersectObjects(spawnMarkers, false);
    if (markerHits.length > 0) {
      const hitMarker = markerHits[0].object;
      if (hoveredExisting !== hitMarker) highlightForDelete(hitMarker);
      if (ghost) ghost.visible = false;
      return;
    }
  } else if (godmodeToolSelected.startsWith('pedestal')) {
    const pedChildren = [];
    for (const ped of pedestalMeshes) ped.traverse(c => { if (c.isMesh) pedChildren.push(c); });
    const pedHits = hoverRaycaster.intersectObjects(pedChildren, false);
    if (pedHits.length > 0) {
      let hitObj = pedHits[0].object;
      while (hitObj.parent && !hitObj.userData.pedestalId) hitObj = hitObj.parent;
      if (hitObj.userData.pedestalId && hoveredExisting !== hitObj) highlightForDelete(hitObj);
      if (ghost) ghost.visible = false;
      return;
    }
  } else if (godmodeToolSelected === 'model') {
    const modelChildren = [];
    for (const wm of worldModels) wm.group.traverse(c => { if (c.isMesh) modelChildren.push(c); });
    const modelHits = hoverRaycaster.intersectObjects(modelChildren, false);
    if (modelHits.length > 0) {
      let hitObj = modelHits[0].object;
      while (hitObj.parent && !hitObj.userData.modelId) hitObj = hitObj.parent;
      if (hitObj.userData.modelId && hoveredExisting !== hitObj) highlightForDelete(hitObj);
      if (ghost) ghost.visible = false;
      return;
    }
  } else if (godmodeToolSelected === 'delete_block') {
    const buildMeshes = worldBuilds.map(b => b.mesh);
    const buildHits = hoverRaycaster.intersectObjects(buildMeshes, false);
    if (buildHits.length > 0) {
      const hitObj = buildHits[0].object;
      if (hoveredExisting !== hitObj) highlightForDelete(hitObj);
      if (ghost) ghost.visible = false;
      return;
    }
  }

  clearHoverHighlight();

  // Raycast terrain for placement preview
  const hits = hoverRaycaster.intersectObjects(levelMeshes, false);
  if (hits.length === 0) {
    if (ghost) ghost.visible = false;
    return;
  }

  const hit = hits[0];
  const normal = hit.face ? hit.face.normal.clone() : new THREE.Vector3(0, 1, 0);
  const worldMatrix = new THREE.Matrix3().getNormalMatrix(hit.object.matrixWorld);
  normal.applyMatrix3(worldMatrix).normalize();
  const flatness = normal.dot(new THREE.Vector3(0, 1, 0));

  if (godmodeToolSelected === 'spawn') {
    ghostCanPlace = true;
    if (ghost) {
      ghost.position.set(hit.point.x, hit.point.y + 1.5, hit.point.z);
      ghost.rotation.y = ghostRotationY;
      ghost.visible = true;
      setGhostColor(ghost, true);
    }
  } else if (godmodeToolSelected.startsWith('pedestal')) {
    ghostCanPlace = flatness >= FLATNESS_THRESHOLD;
    if (ghost) {
      ghost.position.set(hit.point.x, hit.point.y, hit.point.z);
      ghost.rotation.y = ghostRotationY;
      ghost.visible = true;
      setGhostColor(ghost, ghostCanPlace);
    }
  } else if (godmodeToolSelected === 'model') {
    ghostCanPlace = flatness >= FLATNESS_THRESHOLD;
    if (ghost) {
      ghost.position.set(hit.point.x, hit.point.y, hit.point.z);
      ghost.rotation.y = ghostRotationY;
      ghost.visible = true;
      setGhostColor(ghost, ghostCanPlace);
    }
  }
}

function createRightWedgeGeometry(w, h, d) {
  const geo = new THREE.BoxGeometry(w, h, d);
  const pos = geo.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    if (pos.getY(i) > 0 && pos.getZ(i) > 0) {
      pos.setY(i, -h / 2);
    }
  }
  geo.computeVertexNormals();
  return geo;
}

// --- Block Placement Grid & Ghost ---
let buildTarget = null;
let buildCanPlace = false;
let godmodeBuildType = 'wall';
let buildRotationSteps = 0;
let buildPlacementDistance = 16;
let buildPlaneY = 0;

const buildGhostMat = new THREE.MeshStandardMaterial({ color: 0x4488ff, transparent: true, opacity: 0.45, depthWrite: false, side: THREE.DoubleSide });
const buildGhost = new THREE.Group();
const bgBlock = new THREE.Mesh(new THREE.BoxGeometry(4, 4, 4), buildGhostMat);
const bgWall = new THREE.Mesh(new THREE.BoxGeometry(4, 4, 1), buildGhostMat);
const bgRamp = new THREE.Mesh(createRightWedgeGeometry(4, 4, 4), buildGhostMat);
const bgPlatform = new THREE.Mesh(new THREE.BoxGeometry(4, 1, 4), buildGhostMat);
buildGhost.add(bgBlock, bgWall, bgRamp, bgPlatform);
buildGhost.visible = false;
scene.add(buildGhost);

const bridgeGhostMat = new THREE.MeshBasicMaterial({ color: 0x00ffff, transparent: true, opacity: 0.4, depthWrite: false });
const bridgeGhost = new THREE.Mesh(new THREE.BoxGeometry(4, 0.2, 1), bridgeGhostMat);
bridgeGhost.visible = false;
scene.add(bridgeGhost);

const teleporterGhostMat = new THREE.MeshBasicMaterial({ color: 0x44ff44, transparent: true, opacity: 0.5, depthWrite: false });
const teleporterGhostGeo = new THREE.CylinderGeometry(0.8, 0.8, 0.2, 16);
const teleporterGhostA = new THREE.Mesh(teleporterGhostGeo, teleporterGhostMat);
const teleporterGhostB = new THREE.Mesh(teleporterGhostGeo, teleporterGhostMat);
teleporterGhostA.visible = false;
teleporterGhostB.visible = false;
scene.add(teleporterGhostA);
scene.add(teleporterGhostB);

const gridPointsGeo = new THREE.BufferGeometry();
const gridPts = [];
const GRID_RAD = 4;
for (let x = -GRID_RAD; x <= GRID_RAD; x++) {
  for (let y = -GRID_RAD; y <= GRID_RAD; y++) {
    for (let z = -GRID_RAD; z <= GRID_RAD; z++) {
      gridPts.push(x * 4, y * 4, z * 4);
    }
  }
}
gridPointsGeo.setAttribute('position', new THREE.Float32BufferAttribute(gridPts, 3));
const gridPointsMat = new THREE.PointsMaterial({ color: 0x4488ff, size: 0.15, transparent: true, opacity: 0.5 });
const buildGrid = new THREE.Points(gridPointsGeo, gridPointsMat);
buildGrid.visible = false;
scene.add(buildGrid);

const groundGrid = new THREE.GridHelper(400, 100, 0x66aaff, 0x66aaff);
groundGrid.material.transparent = true;
groundGrid.material.opacity = 0;
groundGrid.material.linewidth = 2; // Supported on some non-Windows platforms
groundGrid.visible = false;
scene.add(groundGrid);

const playerGhostGeo = new THREE.CylinderGeometry(0.5, 0.5, 0.2, 16);
const playerGhostMat = new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.5 });
const playerGhost = new THREE.Mesh(playerGhostGeo, playerGhostMat);
playerGhost.visible = false;
scene.add(playerGhost);

let lastMouseNDC = new THREE.Vector2(0, 0);

let lastHoverX = 0, lastHoverY = 0;
renderer.domElement.addEventListener('mousemove', (e) => {
  lastHoverX = e.clientX;
  lastHoverY = e.clientY;
  lastMouseNDC.x = (e.clientX / window.innerWidth) * 2 - 1;
  lastMouseNDC.y = -(e.clientY / window.innerHeight) * 2 + 1;
  if (godmode) updateGodmodeHover(e.clientX, e.clientY);
});

function hideAllGhosts() {
  if (ghostSpawn) ghostSpawn.visible = false;
  if (ghostPedestal) ghostPedestal.visible = false;
  for (const f in modelGhosts) modelGhosts[f].visible = false;
  clearHoverHighlight();
  if (buildGhost) buildGhost.visible = false;
  if (buildGrid) buildGrid.visible = false;
  if (groundGrid) groundGrid.visible = false;
  if (bridgeGhost) bridgeGhost.visible = false;
  if (teleporterGhostA) teleporterGhostA.visible = false;
  if (teleporterGhostB) teleporterGhostB.visible = false;
  bridgeStart = null;
  teleporterStartA = null;
  resetChannelDraft();
}

// --- Spawn editor state ---
const spawnMarkers = [];
let spawnClickCooldown = 0;

// --- Join screen ---
const DEFAULT_NAMES = ['Blockhead', 'Squarold', 'Edgelord', 'Hexahedron', 'Rhombert', 'Squaredward'];
const randomDefault = DEFAULT_NAMES[Math.floor(Math.random() * DEFAULT_NAMES.length)];
const nameScreen = document.getElementById('name-screen');
const nameInput = document.getElementById('name-input');
nameInput.placeholder = randomDefault;
const joinBtn = document.getElementById('join-btn');
const hud = document.getElementById('hud');
const leaderDisplay = document.getElementById('leader-display');
const colorPicker = document.getElementById('color-picker');
let playerName = randomDefault;
let playerShape = 'roundcube';
let playerColor = '#4488ff';
let playerSkinImage = '';
let gameStarted = false;
let startingWeapon = 'none';
let infiniteAmmo = false;
let gameType = 'reverse-tag';
let scoreLimit = 1000;
let playerModel = 'none';

// --- Lobby settings ---
document.querySelectorAll('.weapon-opt').forEach(el => {
  el.addEventListener('click', () => {
    if (el.classList.contains('disabled')) return;
    document.querySelectorAll('.weapon-opt').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    startingWeapon = el.dataset.weapon;
  });
});
document.querySelectorAll('[data-gametype]').forEach(el => {
  el.addEventListener('click', () => {
    if (el.classList.contains('disabled')) return;
    document.querySelectorAll('[data-gametype]').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    gameType = el.dataset.gametype;
  });
});
document.querySelectorAll('[data-duration]').forEach(el => {
  el.addEventListener('click', () => {
    if (el.classList.contains('disabled')) return;
    document.querySelectorAll('[data-duration]').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    scoreLimit = parseInt(el.dataset.duration);
  });
});
document.querySelectorAll('.model-opt').forEach(el => {
  el.addEventListener('click', () => {
    if (el.classList.contains('disabled')) return;
    document.querySelectorAll('.model-opt').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    playerModel = el.dataset.model;
  });
});
const infiniteAmmoCheck = document.getElementById('infinite-ammo-check');
if (infiniteAmmoCheck) infiniteAmmoCheck.addEventListener('change', () => { infiniteAmmo = infiniteAmmoCheck.checked; });

// --- Random starting color (saturated hue) ---
(function setRandomColor() {
  const hue = Math.floor(Math.random() * 360);
  const c = document.createElement('canvas'); c.width = 1; c.height = 1;
  const cx = c.getContext('2d');
  cx.fillStyle = `hsl(${hue}, 100%, 50%)`;
  cx.fillRect(0, 0, 1, 1);
  const [r, g, b] = cx.getImageData(0, 0, 1, 1).data;
  const hex = '#' + [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('');
  colorPicker.value = hex;
  playerColor = hex;
})();

// --- Animated 3D title ---
(async function initTitle() {
  const tc = document.getElementById('title-canvas');
  if (!tc) return;

  const versionDiv = document.createElement('div');
  versionDiv.textContent = GAME_VERSION;
  versionDiv.style.cssText = 'color:#aaa; font:10px "04b_03", Lato, sans-serif; letter-spacing:1px; margin-top:2px; margin-bottom:4px; text-align:center; position:relative; z-index:10;';
  tc.parentNode.insertBefore(versionDiv, tc.nextSibling);

  try { await document.fonts.load("8px '04b_03'"); } catch(e) {}
  const ctx = tc.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  const W = tc.width, H = tc.height;
  const text = 'CUBE FIGHT!';
  const fontSize = 16;
  const t0 = performance.now();

  function drawTitle() {
    if (gameStarted) return;
    requestAnimationFrame(drawTitle);
    const t = (performance.now() - t0) / 1000;
    ctx.clearRect(0, 0, W, H);

    ctx.font = `${fontSize}px '04b_03', sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    // Flickering shadow copies behind the main text
    for (let d = 3; d >= 1; d--) {
      const flicker = Math.random();
      if (flicker < 0.3) continue;
      const brightness = Math.floor(20 + Math.random() * 30);
      ctx.globalAlpha = 0.3 + Math.random() * 0.4;
      ctx.fillStyle = `rgb(${brightness},${brightness},${brightness})`;
      ctx.fillText(text, W / 2 + d, H / 2 + d);
    }

    // Main white text
    ctx.globalAlpha = 1;
    ctx.fillStyle = '#ffffff';
    ctx.fillText(text, W / 2, H / 2);
  }
  drawTitle();
})();

// --- 3D cube preview ---
(function initCubePreview() {
  const cvs = document.getElementById('cube-preview');
  if (!cvs) return;
  const pRenderer = new THREE.WebGLRenderer({ canvas: cvs, antialias: true, alpha: true });
  pRenderer.setSize(120, 120);
  pRenderer.setClearColor(0x000000, 0);

  const pScene = new THREE.Scene();
  const pCam = new THREE.PerspectiveCamera(40, 1, 0.1, 100);
  pCam.position.set(0, 0.8, 2.8);
  pCam.lookAt(0, 0, 0);

  pScene.add(new THREE.AmbientLight(0xffffff, 1.2));
  const dl = new THREE.DirectionalLight(0xffffff, 1.5);
  dl.position.set(2, 3, 2);
  pScene.add(dl);
  const dl2 = new THREE.DirectionalLight(0xaaccff, 0.8);
  dl2.position.set(-2, 1, -1);
  pScene.add(dl2);
  pScene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 0.6));

  const cubeGeo = new THREE.BoxGeometry(1, 1, 1);
  const cubeMat = new THREE.MeshPhysicalMaterial({ color: playerColor, transparent: true, opacity: 0.7, roughness: 0.02, metalness: 0.9, clearcoat: 1.0, clearcoatRoughness: 0.02, emissive: playerColor, emissiveIntensity: 0.15 });
  const cubeMesh = new THREE.Mesh(cubeGeo, cubeMat);
  pScene.add(cubeMesh);

  // Cel-shade outline for preview cube
  const outlineGeo = cubeGeo.clone();
  const outlineMat = new THREE.MeshBasicMaterial({ color: playerColor, side: THREE.BackSide });
  const cubeOutline = new THREE.Mesh(outlineGeo, outlineMat);
  cubeOutline.scale.setScalar(1.06);
  cubeMesh.add(cubeOutline);

  let previewRat = null;
  let previewMixer = null;
  const previewRatPivot = new THREE.Group();
  pScene.add(previewRatPivot);

  function loadPreviewRat() {
    if (previewRat) return;
    const loader = new THREE.GLTFLoader();
    loader.load('/players/rat.glb', (gltf) => {
      previewRat = gltf.scene;
      const box = new THREE.Box3().setFromObject(previewRat);
      const size = box.getSize(new THREE.Vector3());
      const maxDim = Math.max(size.x, size.y, size.z);
      const scale = (0.7 / maxDim) * 1.5;
      previewRat.scale.setScalar(scale);
      const center = box.getCenter(new THREE.Vector3());
      const bottom = box.min.y;
      previewRat.position.set(-center.x * scale, -bottom * scale - 1.2, -center.z * scale);
      previewRatPivot.add(previewRat);
      if (gltf.animations && gltf.animations.length > 0) {
        previewMixer = new THREE.AnimationMixer(previewRat);
        for (const clip of gltf.animations) {
          if (clip.name.toLowerCase().includes('idle')) {
            previewMixer.clipAction(clip).play();
            break;
          }
        }
      }
    });
  }

  document.querySelectorAll('.model-opt').forEach(el => {
    el.addEventListener('click', () => {
      if (el.dataset.model === 'rat') {
        loadPreviewRat();
        previewRatPivot.visible = true;
      } else {
        previewRatPivot.visible = false;
      }
    });
  });

  colorPicker.addEventListener('input', () => {
    playerColor = colorPicker.value;
    cubeMat.color.set(playerColor);
    cubeMat.emissive.set(playerColor);
    outlineMat.color.set(playerColor);
  });

  if (isMobile) {
    const wrap = document.getElementById('cube-preview-wrap');
    wrap.style.position = 'relative';
    colorPicker.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;opacity:0;cursor:pointer;z-index:11;';
    wrap.appendChild(colorPicker);
  } else {
    colorPicker.style.display = 'none';
    cvs.style.cursor = 'pointer';
    cvs.addEventListener('click', () => colorPicker.click());

    const existingCustomizeBtn = Array.from(document.querySelectorAll('*')).find(el => el.childNodes.length === 1 && el.textContent.trim().toUpperCase() === 'CUSTOMIZE CHARACTER');
    if (existingCustomizeBtn) {
      existingCustomizeBtn.style.cursor = 'pointer';
      existingCustomizeBtn.style.position = 'relative';
      existingCustomizeBtn.style.zIndex = '10';
      existingCustomizeBtn.addEventListener('click', () => colorPicker.click());
    }
  }

  let lastPreviewTime = performance.now();
  function animCube() {
    if (gameStarted) { pRenderer.dispose(); return; }
    requestAnimationFrame(animCube);
    const now = performance.now();
    const dt = (now - lastPreviewTime) / 1000;
    lastPreviewTime = now;
    const t = now / 1000;
    cubeMesh.rotation.y = t * 0.8;
    cubeMesh.rotation.x = Math.sin(t * 0.6) * 0.3;
    previewRatPivot.rotation.y = t * 0.8;
    if (previewMixer) previewMixer.update(dt);
    pRenderer.render(pScene, pCam);
  }
  animCube();
})();

function joinGame() {
  playerName = nameInput.value.trim().slice(0, 16) || randomDefault;
  playerColor = colorPicker.value;
  playerSkinImage = '';
  nameScreen.style.display = 'none';
  if (menuOverlay) menuOverlay.style.display = 'none';
  hud.style.display = '';
  hud.style.opacity = '1';
  hud.style.transition = 'opacity 1s ease-in-out';
  leaderDisplay.style.display = '';
  updateInventoryUI();

  setTimeout(() => {
    if (gameStarted) hud.style.opacity = '0';
  }, 10000);

  // Start music on first join
  if (!musicPlaying) {
    // play() must be called in a user interaction event (like this click)
    const playPromise = music.play();
    if (playPromise) playPromise.catch(e => console.warn("Music autoplay was blocked by the browser."));
    musicPlaying = true;
  }

  // Load the level. If a game is already in progress (lobby locked) we MUST use
  // the server's active level — joining players can't bring their own map.
  const levelToLoad = lobbyLocked ? (serverActiveLevel || 'level_1.glb')
                                  : (selectedLevel || serverActiveLevel || 'level_1.glb');
  socket.emit('selectLevel', levelToLoad);
  if (currentLevelName !== levelToLoad || !levelLoaded) loadGameLevel(levelToLoad);
  // The menu birdseye blacks out the scene + hides the level; restore them for
  // gameplay (loadGameLevel may be skipped above when the level is already loaded).
  scene.background = skyTex;
  if (currentLevelObj) currentLevelObj.visible = true;
  cleanupPreviews();
  stopActiveGamePolling();
  const agiEl = document.getElementById('active-game-info');
  if (agiEl) agiEl.style.display = 'none';

  gameStarted = true;
  if (isMobile) {
    const jb = document.getElementById('joystick-base');
    const jmp = document.getElementById('jump-btn');
    const mhb = document.getElementById('mobile-hud-bar');
    if (jb) jb.style.display = '';
    if (jmp) jmp.style.display = 'flex';
    if (mhb) mhb.style.display = 'flex';
  }
  clock.start();
  startGame();
}

joinBtn.addEventListener('click', joinGame);
nameInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') joinGame(); });

// --- Scoreboard UI ---
let tabHeld = false;
document.addEventListener('keydown', (e) => {
  if (chatOpen) return;
  if (e.code === 'Tab') { e.preventDefault(); tabHeld = true; }
});
document.addEventListener('keyup', (e) => {
  if (e.code === 'Tab') { e.preventDefault(); tabHeld = false; }
});

const scoreboardEl = document.createElement('div');
scoreboardEl.id = 'scoreboard';
scoreboardEl.innerHTML = '<h3>PLAYERS</h3><div id="scoreboard-list"></div>';
document.body.appendChild(scoreboardEl);

function updateScoreboard() {
  const list = document.getElementById('scoreboard-list');
  if (!list) return;
  const entries = [];
  if (selfId) entries.push({ id: selfId, name: playerName, score: allScores[selfId] || 0 });
  for (const [id, name] of playerNames) {
    entries.push({ id, name, score: allScores[id] || 0 });
  }
  entries.sort((a, b) => b.score - a.score);
  list.innerHTML = entries.map(e => {
    const classes = [];
    if (e.id === holderID) classes.push('holder');
    if (e.id === leaderID) classes.push('leader');
    return `<div class="sb-row ${classes.join(' ')}"><span class="sb-name">${e.id === leaderID ? '\u{1F451} ' : ''}${e.id === holderID ? '[IT] ' : ''}${e.name}</span><span class="sb-score">${e.score}</span></div>`;
  }).join('');
}

// --- Meter UI ---
function createMeter(id, label) {
  const wrap = document.createElement('div');
  wrap.className = 'meter-wrap';
  wrap.id = id;
  wrap.style.display = 'none';
  const lbl = document.createElement('div');
  lbl.className = 'meter-label';
  lbl.textContent = label;
  wrap.appendChild(lbl);
  const fill = document.createElement('div');
  fill.className = 'meter-fill';
  wrap.appendChild(fill);
  document.body.appendChild(wrap);
  return { wrap, fill };
}

const sprintMeter = createMeter('sprint-meter', '⚡︎ SPRINT');
const jumpMeter = createMeter('jump-meter', '⬆︎ JUMP');

function updateMeters() {
  // Sprint meter
  sprintMeter.wrap.style.display = gameStarted ? '' : 'none';
  const sprintPct = sprintStamina / SPRINT_DURATION;
  sprintMeter.fill.style.width = (sprintPct * 100) + '%';
  sprintMeter.fill.style.backgroundColor = sprintExhausted ? '#cc2222' : '#22cc44';

  // Jump meter
  jumpMeter.wrap.style.display = gameStarted ? '' : 'none';
  if (jumpCooldownTimer > 0) {
    const cdProgress = (jumpCooldownMax > 0) ? (jumpCooldownTimer / jumpCooldownMax) : 0; // 1 -> 0
    jumpMeter.fill.style.width = (jumpCooldownStartPct * cdProgress * 100) + '%';
    jumpMeter.fill.style.backgroundColor = '#cc2222';
  } else if (isChargingJump) {
    const chargePct = (jumpCharge - 1) / (MAX_CHARGE_MULT - 1);
    jumpMeter.fill.style.width = (chargePct * 100) + '%';
    jumpMeter.fill.style.backgroundColor = '#22cc44';
  } else {
    jumpMeter.fill.style.width = '0%';
    jumpMeter.fill.style.backgroundColor = '#22cc44';
  }
}

// --- Level select system ---
let selectedLevel = null;
let serverActiveLevel = 'level_1.glb';
let lobbyLocked = false;          // true while a game is in progress (set by server)
let setVisibleMap = null;         // assigned by initLevelSelect; lets remote syncs swap the shown map
const levelPreviews = [];
let previewsActive = false;

// Gray out (without removing) the game-config controls when the lobby is locked.
// The selected option stays highlighted so everyone can see the active settings.
function setLobbyControlsLocked(locked) {
  lobbyLocked = !!locked;
  document.querySelectorAll('[data-gametype], .weapon-opt, [data-duration]').forEach(el => {
    el.style.pointerEvents = locked ? 'none' : '';
    el.style.opacity = locked ? (el.classList.contains('selected') ? '1' : '0.35') : '';
  });
  const ammo = document.getElementById('infinite-ammo-check');
  if (ammo) { ammo.disabled = locked; ammo.style.opacity = locked ? '0.5' : ''; }
  ['map-prev', 'map-next'].forEach(id => {
    const a = document.getElementById(id);
    if (a) { a.style.pointerEvents = locked ? 'none' : ''; a.style.opacity = locked ? '0.25' : ''; }
  });
}

// --- Active game panel (main menu) ---
function prettyLevelName(f) {
  return (f || '').replace(/\.glb$/, '').replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}
function renderActiveGame(state) {
  const el = document.getElementById('active-game-info');
  if (!el) return;
  const count = state ? (state.playerCount || 0) : 0;
  if (!state || count === 0) {
    el.style.display = 'block';
    el.innerHTML = '<div class="agi-box"><div class="agi-title">NO ACTIVE GAME</div><div class="agi-empty">Be the first to jump in!</div></div>';
    return;
  }
  const players = Array.isArray(state.players) ? state.players : [];
  const chips = players.map(p => {
    const dot = '<span class="agi-dot" style="background:' + (p.color || '#fff') + '"></span>';
    const span = document.createElement('span');
    span.textContent = p.name + ' (' + (p.score || 0) + ')';
    return '<span class="agi-player">' + dot + span.outerHTML + '</span>';
  }).join('');
  el.style.display = 'block';
  el.innerHTML = '<div class="agi-box">' +
    '<div class="agi-title">ACTIVE GAME · ' + prettyLevelName(state.activeLevel) + ' · ' + count + ' PLAYING</div>' +
    '<div class="agi-players">' + chips + '</div></div>';
}
let activeGamePollTimer = null;
async function pollActiveGame() {
  try {
    const state = await fetch('/api/game-state').then(r => r.json());
    if (!gameStarted) renderActiveGame(state);
  } catch (e) {}
}
function startActiveGamePolling() {
  pollActiveGame();
  if (!activeGamePollTimer) activeGamePollTimer = setInterval(pollActiveGame, 4000);
}
function stopActiveGamePolling() {
  if (activeGamePollTimer) { clearInterval(activeGamePollTimer); activeGamePollTimer = null; }
}

async function initLevelSelect() {
  try {
    const [levelsRes, stateRes] = await Promise.all([
      fetch('/api/levels').then(r => r.json()),
      fetch('/api/game-state').then(r => r.json())
    ]);

    serverActiveLevel = stateRes.activeLevel;
    selectedLevel = serverActiveLevel;

    loadGameLevel(serverActiveLevel);
    if (menuOverlay) menuOverlay.style.display = 'block';

    renderActiveGame(stateRes);
    startActiveGamePolling();

    lobbyLocked = !!stateRes.levelLocked;

    const selectDiv = document.getElementById('level-select');
    if (!selectDiv) return;

    // The map stays VISIBLE at all times. When the lobby is locked (a game is in
    // progress) the arrows are grayed out so the active map can't be changed.
    selectDiv.style.display = 'block';
    const single = (levelsRes.length <= 1) ? '' :
      '<div class="level-arrow" id="map-prev">◀</div>';
    const singleR = (levelsRes.length <= 1) ? '' :
      '<div class="level-arrow" id="map-next">▶</div>';
    selectDiv.innerHTML = '<div class="single-map"><div class="single-map-stage"></div><div class="map-nav">' +
      single + '<div class="map-name" id="map-name"></div>' + singleR + '</div></div>';
    const stage = selectDiv.querySelector('.single-map-stage');
    const nameEl = selectDiv.querySelector('#map-name');

    for (const filename of levelsRes) {
      const preview = createLevelPreview(filename, stage);
      preview.wrapper.style.display = 'none';
      levelPreviews.push(preview);
    }

    let curIndex = Math.max(0, levelsRes.indexOf(selectedLevel));

    // emit defaults true (a deliberate local pick). Remote syncs pass false so we
    // don't echo the change back to the server and start a tug-of-war.
    function showMap(i, emit) {
      curIndex = (i + levelsRes.length) % levelsRes.length;
      selectedLevel = levelsRes[curIndex];
      levelPreviews.forEach((p, idx) => {
        p.wrapper.style.display = idx === curIndex ? 'block' : 'none';
        p.wrapper.classList.toggle('selected', idx === curIndex);
      });
      if (nameEl) nameEl.textContent = prettyLevelName(selectedLevel);
      if (emit !== false) socket.emit('selectLevel', selectedLevel);
    }

    // Expose so the levelChanged socket handler can sync the shown map to match
    // whatever another player selected, without re-emitting.
    setVisibleMap = (filename) => {
      const idx = levelsRes.indexOf(filename);
      if (idx >= 0) showMap(idx, false);
    };

    const prevBtn = document.getElementById('map-prev');
    const nextBtn = document.getElementById('map-next');
    if (prevBtn) prevBtn.addEventListener('click', () => { if (!lobbyLocked) showMap(curIndex - 1, true); });
    if (nextBtn) nextBtn.addEventListener('click', () => { if (!lobbyLocked) showMap(curIndex + 1, true); });

    showMap(curIndex, false);
    setLobbyControlsLocked(lobbyLocked);

    previewsActive = true;
    animatePreviews();
  } catch (e) {
    console.error('Level select init failed:', e);
    selectedLevel = 'level_1.glb';
  }
}

function createLevelPreview(filename, container) {
  const PW = 480, PH = 300;
  const canvas = document.createElement('canvas');
  canvas.width = PW;
  canvas.height = PH;

  const pRenderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  pRenderer.setSize(PW, PH);

  const pScene = new THREE.Scene();
  pScene.background = new THREE.Color(0x1a1a2e);
  const pCamera = new THREE.PerspectiveCamera(50, PW / PH, 0.1, 10000);

  pScene.add(new THREE.AmbientLight(0xffffff, 0.5));
  const pDirLight = new THREE.DirectionalLight(0xfff4e0, 1.2);
  pDirLight.position.set(1, 2, 1);
  pScene.add(pDirLight);
  pScene.add(new THREE.HemisphereLight(0x87ceeb, 0x553322, 0.4));

  let levelGroup = null;

  const pLoader = new THREE.GLTFLoader();
  pLoader.load('/levels/' + filename, (gltf) => {
    levelGroup = gltf.scene;
    pScene.add(levelGroup);

    const box = new THREE.Box3().setFromObject(levelGroup);
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const maxDim = Math.max(size.x, size.y, size.z);

    levelGroup.position.sub(center);

    const fov = pCamera.fov * (Math.PI / 180);
    const camDist = (maxDim / (2 * Math.tan(fov / 2))) * 1.4;
    pCamera.position.set(0, maxDim * 0.3, camDist);
    pCamera.lookAt(0, 0, 0);
    pCamera.far = camDist * 4;
    pCamera.updateProjectionMatrix();
  });

  const wrapper = document.createElement('div');
  wrapper.className = 'level-card';
  wrapper.appendChild(canvas);
  container.appendChild(wrapper);

  return { renderer: pRenderer, scene: pScene, camera: pCamera, getGroup: () => levelGroup, wrapper, filename };
}

function animatePreviews() {
  if (!previewsActive) return;
  requestAnimationFrame(animatePreviews);
  for (const p of levelPreviews) {
    if (p.wrapper.style.display === 'none') continue;
    const g = p.getGroup();
    if (g) g.rotation.y += 0.003;
    p.renderer.render(p.scene, p.camera);
  }
}

function cleanupPreviews() {
  previewsActive = false;
  for (const p of levelPreviews) {
    p.renderer.dispose();
  }
  levelPreviews.length = 0;
}

initLevelSelect();

// --- Score sprite for leader ---
function createScoreSprite() {
  const canvas = document.createElement('canvas');
  canvas.width = 256; canvas.height = 80;
  const ctx = canvas.getContext('2d');
  const texture = new THREE.CanvasTexture(canvas);
  const mat = new THREE.SpriteMaterial({ map: texture, depthTest: false });
  const sprite = new THREE.Sprite(mat);
  sprite.scale.set(3, 0.9, 1);
  sprite.renderOrder = 999;
  sprite.visible = false;
  sprite.userData.canvas = canvas;
  sprite.userData.ctx = ctx;
  return sprite;
}

function updateScoreSpriteText(sprite, score) {
  const canvas = sprite.userData.canvas;
  const ctx = sprite.userData.ctx;
  ctx.clearRect(0, 0, 256, 80);
  ctx.font = 'bold 52px Lato, LatoExtended, sans-serif';
  ctx.textAlign = 'center';
  ctx.fillStyle = '#ffd700';
  ctx.strokeStyle = 'rgba(0,0,0,0.7)';
  ctx.lineWidth = 4;
  ctx.strokeText(String(score), 128, 58);
  ctx.fillText(String(score), 128, 58);
  sprite.material.map.needsUpdate = true;
}

const playerScoreSprites = new Map();
let localScoreSprite = null;

// --- Mobile controls ---
if (isMobile) {
  hud.textContent = 'Drag joystick to move · Tilt to steer · Tap JUMP';

  // Tilt (accelerometer) input blended with joystick
  const TILT_SENSITIVITY = 0.04;
  const TILT_DEADZONE = 3; // degrees
  const TILT_MAX = 25; // degrees for full deflection

  function requestTilt() {
    if (typeof DeviceOrientationEvent !== 'undefined' && DeviceOrientationEvent.requestPermission) {
      DeviceOrientationEvent.requestPermission().then(state => {
        if (state === 'granted') enableTilt();
      }).catch(() => {});
    } else {
      enableTilt();
    }
  }

  function enableTilt() {
    window.addEventListener('deviceorientation', (e) => {
      if (e.gamma === null || e.beta === null) return;
      const rawX = e.gamma; // left/right tilt (-90..90)
      const rawZ = e.beta - 30; // forward/back tilt, offset for natural hold angle
      const applyDeadzone = (v) => {
        if (Math.abs(v) < TILT_DEADZONE) return 0;
        const sign = v > 0 ? 1 : -1;
        return sign * Math.min((Math.abs(v) - TILT_DEADZONE) / (TILT_MAX - TILT_DEADZONE), 1);
      };
      tiltX = applyDeadzone(rawX);
      tiltZ = applyDeadzone(rawZ);
    });
  }

  // Request tilt on first touch interaction (needed for iOS permission)
  document.addEventListener('touchstart', function tiltInit() {
    requestTilt();
    document.removeEventListener('touchstart', tiltInit);
  }, { once: true });

  const joystickBase = document.createElement('div');
  joystickBase.id = 'joystick-base';
  joystickBase.style.display = 'none';
  const joystickKnob = document.createElement('div');
  joystickKnob.id = 'joystick-knob';
  joystickBase.appendChild(joystickKnob);
  document.body.appendChild(joystickBase);

  const jumpBtn = document.createElement('div');
  jumpBtn.id = 'jump-btn';
  jumpBtn.textContent = 'JUMP';
  jumpBtn.style.display = 'none';
  document.body.appendChild(jumpBtn);

  jumpBtn.addEventListener('touchstart', (e) => { e.preventDefault(); keys['Space'] = true; });
  jumpBtn.addEventListener('touchend', (e) => { e.preventDefault(); keys['Space'] = false; });

  // Mobile HUD buttons (Tab, Console, God)
  const mobileHudBar = document.createElement('div');
  mobileHudBar.id = 'mobile-hud-bar';
  mobileHudBar.style.cssText = 'position:absolute;bottom:8px;left:50%;transform:translateX(-50%);display:none;gap:10px;z-index:30;';
  const mobileButtons = [
    { label: 'TAB', action: 'tab' },
    { label: 'CON', action: 'console' },
    { label: 'GOD', action: 'god' }
  ];
  mobileButtons.forEach(btn => {
    const el = document.createElement('div');
    el.className = 'mobile-hud-btn';
    el.textContent = btn.label;
    el.style.cssText = 'padding:6px 14px;background:rgba(0,0,0,0.6);border:2px solid rgba(255,255,255,0.4);border-radius:6px;color:white;font:10px "04b_03",Lato,sans-serif;letter-spacing:1px;user-select:none;-webkit-user-select:none;touch-action:none;cursor:pointer;';
    if (btn.action === 'tab') {
      el.addEventListener('touchstart', (e) => { e.preventDefault(); tabHeld = true; });
      el.addEventListener('touchend', (e) => { e.preventDefault(); tabHeld = false; });
    } else if (btn.action === 'console') {
      el.addEventListener('touchstart', (e) => {
        e.preventDefault();
        debugVisible = !debugVisible;
        debugEl.style.display = debugVisible ? '' : 'none';
      });
    } else if (btn.action === 'god') {
      el.addEventListener('touchstart', (e) => {
        e.preventDefault();
        if (!gameStarted) return;
        const evt = new KeyboardEvent('keydown', { code: 'F4', bubbles: true });
        window.dispatchEvent(evt);
      });
    }
    mobileHudBar.appendChild(el);
  });
  document.body.appendChild(mobileHudBar);

  let joystickTouchId = null;
  const JOYSTICK_RADIUS = 50;

  joystickBase.addEventListener('touchstart', (e) => {
    e.preventDefault();
    joystickTouchId = e.changedTouches[0].identifier;
    updateJoystick(e.changedTouches[0]);
    const now = performance.now();
    if (now - lastJoystickTap < 300) {
      mobileSprinting = true;
    }
    lastJoystickTap = now;
  });
  window.addEventListener('touchmove', (e) => {
    if (joystickTouchId === null) return;
    const t = findTouch(e.touches, joystickTouchId);
    if (!t) return;
    e.preventDefault();
    updateJoystick(t);
  }, { passive: false });
  window.addEventListener('touchend', (e) => {
    if (!findTouch(e.changedTouches, joystickTouchId)) return;
    joystickTouchId = null;
    joystickKnob.style.transform = 'translate(-50%, -50%)';
    joystickX = 0; joystickZ = 0;
    mobileSprinting = false;
  });

  function findTouch(touches, id) {
    for (let i = 0; i < touches.length; i++) if (touches[i].identifier === id) return touches[i];
    return null;
  }

  function updateJoystick(touch) {
    const rect = joystickBase.getBoundingClientRect();
    let dx = touch.clientX - (rect.left + rect.width / 2);
    let dy = touch.clientY - (rect.top + rect.height / 2);
    const dist = Math.sqrt(dx * dx + dy * dy);
    if (dist > JOYSTICK_RADIUS) { dx = (dx / dist) * JOYSTICK_RADIUS; dy = (dy / dist) * JOYSTICK_RADIUS; }
    joystickKnob.style.transform = `translate(calc(-50% + ${dx}px), calc(-50% + ${dy}px))`;
    const rawX = dx / JOYSTICK_RADIUS, rawZ = dy / JOYSTICK_RADIUS;
    const mag = Math.sqrt(rawX * rawX + rawZ * rawZ);
    joystickX = mag < JOYSTICK_DEADZONE ? 0 : rawX;
    joystickZ = mag < JOYSTICK_DEADZONE ? 0 : rawZ;
  }

  // Touch-drag camera rotation (touches not on joystick or jump button)
  let camTouchId = null;
  let camTouchLastX = 0, camTouchLastY = 0;
  let camTouchStartX = 0, camTouchStartY = 0, camTouchStartTime = 0;
  const CAM_TOUCH_SENSITIVITY = 0.005;

  renderer.domElement.addEventListener('touchstart', (e) => {
    if (camTouchId !== null) return;
    const t = e.changedTouches[0];
    camTouchId = t.identifier;
    camTouchLastX = t.clientX;
    camTouchLastY = t.clientY;
    camTouchStartX = t.clientX;
    camTouchStartY = t.clientY;
    camTouchStartTime = performance.now();

    if (!godmode && inventory.length > 0 && inventory[0].type === 'machinegun') {
      startMachinegun();
    }
  });
  window.addEventListener('touchmove', (e) => {
    if (camTouchId === null) return;
    const t = findTouch(e.touches, camTouchId);
    if (!t) return;
    const dx = t.clientX - camTouchLastX;
    const dy = t.clientY - camTouchLastY;
    camTouchLastX = t.clientX;
    camTouchLastY = t.clientY;
    camYaw -= dx * CAM_TOUCH_SENSITIVITY;
    camPitch += dy * CAM_TOUCH_SENSITIVITY;
    camPitch = Math.max(CAM_PITCH_MIN, Math.min(CAM_PITCH_MAX, camPitch));
    lastMouseMoveTime = performance.now() / 1000;
  }, { passive: true });
  window.addEventListener('touchend', (e) => {
    stopMachinegun();
    const t = findTouch(e.changedTouches, camTouchId);
    if (t) {
      camTouchId = null;
      const dist = Math.hypot(t.clientX - camTouchStartX, t.clientY - camTouchStartY);
      if (dist < 10 && performance.now() - camTouchStartTime < 300) {
        if (!godmode && inventory.length > 0 && !['machinegun', 'block', 'wall', 'ramp', 'platform'].includes(inventory[0].type)) {
          const ndc = new THREE.Vector2((t.clientX / window.innerWidth) * 2 - 1, -(t.clientY / window.innerHeight) * 2 + 1);
          const item = inventory[0].type;
          const isWeapon = ['rocket', 'machinegun', 'grapple'].includes(item);
          consumeItem(getAimPoint(ndc, isWeapon));
        }
      }
    }
  });
} else {
  window.addEventListener('keydown', (e) => {
    if (chatOpen) return; // don't drive movement while typing in chat
    keys[e.code] = true;
    if (e.code === 'Space') e.preventDefault();
    if (e.code === 'Tab') e.preventDefault();
    if (e.code === 'Digit2') swapToFirst(1);
    if (e.code === 'Digit3') swapToFirst(2);
    if (e.altKey || e.code.startsWith('F')) {
      if (document.pointerLockElement) e.preventDefault();
    }
  });
  window.addEventListener('keyup', (e) => { keys[e.code] = false; });
}

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

// --- Name label sprite ---
function createNameSprite(name) {
  const canvas = document.createElement('canvas');
  canvas.width = 512; canvas.height = 128;
  const ctx = canvas.getContext('2d');
  ctx.font = 'bold 56px Lato, LatoExtended, sans-serif';
  ctx.textAlign = 'center';
  const textW = Math.min(ctx.measureText(name).width + 40, 500);
  const boxX = (512 - textW) / 2;
  ctx.fillStyle = 'rgba(0,0,0,0.55)';
  ctx.roundRect(boxX, 8, textW, 80, 12);
  ctx.fill();
  ctx.fillStyle = '#ffffff';
  ctx.fillText(name, 256, 68);
  const texture = new THREE.CanvasTexture(canvas);
  const mat = new THREE.SpriteMaterial({ map: texture, depthTest: false });
  const sprite = new THREE.Sprite(mat);
  sprite.scale.set(3.5, 0.9, 1);
  return sprite;
}

// --- Crown sprite for leader (big, always visible) ---
function createCrownSprite() {
  const canvas = document.createElement('canvas');
  canvas.width = 256; canvas.height = 128;
  const ctx = canvas.getContext('2d');
  ctx.font = '96px serif';
  ctx.textAlign = 'center';
  ctx.fillText('\u{1F451}', 128, 100);
  const texture = new THREE.CanvasTexture(canvas);
  const mat = new THREE.SpriteMaterial({ map: texture, depthTest: false });
  const sprite = new THREE.Sprite(mat);
  sprite.scale.set(2, 1, 1);
  sprite.renderOrder = 999;
  sprite.visible = false;
  return sprite;
}

function updateCrownScale(crown, playerPos) {
  if (!crown || !crown.visible) return;
  const dist = camera.position.distanceTo(playerPos);
  const s = Math.max(2, dist * 0.15);
  crown.scale.set(s, s * 0.5, 1);
}

// --- Outline mesh for "it" player ---
function createOutlineMesh(sourceMesh) {
  const geo = sourceMesh.geometry.clone();
  const mat = new THREE.MeshBasicMaterial({
    color: 0xffffff,
    side: THREE.BackSide
  });
  const outline = new THREE.Mesh(geo, mat);
  outline.scale.multiplyScalar(1.15);
  outline.visible = false;
  return outline;
}

// --- Player geometry by shape ---
function createShapeGeo(shape) {
  switch (shape) {
    case 'roundcube': return new THREE.BoxGeometry(1, 1, 1, 8, 8, 8);
    case 'sphere': return new THREE.SphereGeometry(0.5, 24, 24);
    case 'cylinder': return new THREE.CylinderGeometry(0.5, 0.5, 1, 16);
    default: return new THREE.BoxGeometry(1, 1, 1);
  }
}

function createRoundcubePhysicsShape(smoothing) {
  if (smoothing < 0.75) {
    const s = 0.5 * (1 - smoothing * 0.3);
    return new CANNON.Box(new CANNON.Vec3(s, s, s));
  }
  const r = 0.5 * (0.85 + smoothing * 0.15);
  return new CANNON.Sphere(r);
}

function createPhysicsShape(shape) {
  switch (shape) {
    case 'sphere': return new CANNON.Sphere(0.5);
    case 'cylinder': return new CANNON.Cylinder(0.5, 0.5, 1, 16);
    case 'roundcube': return createRoundcubePhysicsShape(roundcubeSmoothing);
    default: return new CANNON.Box(new CANNON.Vec3(0.5, 0.5, 0.5));
  }
}

let roundcubeSmoothing = 0.25;
function smoothRoundcube(geo, smoothingVal = roundcubeSmoothing) {
  const pos = geo.attributes.position;
  const box = new THREE.Vector3();
  const sphere = new THREE.Vector3();
  for (let i = 0; i < pos.count; i++) {
    box.fromBufferAttribute(pos, i);
    sphere.copy(box).normalize().multiplyScalar(0.5);
    box.lerp(sphere, smoothingVal);
    pos.setXYZ(i, box.x, box.y, box.z);
  }
  geo.computeVertexNormals();
  return geo;
}

const playerAnimMixers = new Map();

function createPlayerVisual(color, shape, name, skinImage, model) {
  const group = new THREE.Group();

  let geo = createShapeGeo(shape);
  if (shape === 'roundcube') geo = smoothRoundcube(geo);

  let mat;
  if (skinImage) {
    const tex = new THREE.TextureLoader().load(skinImage);
    mat = new THREE.MeshPhysicalMaterial({ map: tex, transparent: true, opacity: 0.3, roughness: 0.05, metalness: 0.8, clearcoat: 1.0, clearcoatRoughness: 0.05 });
  } else {
    mat = new THREE.MeshPhysicalMaterial({ color, transparent: true, opacity: 0.3, roughness: 0.05, metalness: 0.8, clearcoat: 1.0, clearcoatRoughness: 0.05 });
  }

  const mesh = new THREE.Mesh(geo, mat);
  if (shape === 'roundcube') mesh.userData.smoothing = 0.25;
  mesh.castShadow = true;
  group.add(mesh);

  const outline = createOutlineMesh(mesh);
  mesh.add(outline);

  if (model === 'rat') {
    const ratPivot = new THREE.Group();
    group.add(ratPivot);
    group.userData.ratPivot = ratPivot;
    const loader = new THREE.GLTFLoader();
    loader.load('/players/rat.glb', (gltf) => {
      const ratModel = gltf.scene;
      const box = new THREE.Box3().setFromObject(ratModel);
      const size = box.getSize(new THREE.Vector3());
      const maxDim = Math.max(size.x, size.y, size.z);
      const scale = (0.7 / maxDim) * 1.5;
      ratModel.scale.setScalar(scale);
      const center = box.getCenter(new THREE.Vector3());
      const bottom = box.min.y;
      ratModel.position.set(-center.x * scale, -bottom * scale - 1.2, -center.z * scale);
      ratPivot.add(ratModel);
      group.userData.ratModel = ratModel;

      if (gltf.animations && gltf.animations.length > 0) {
        const mixer = new THREE.AnimationMixer(ratModel);
        playerAnimMixers.set(group, mixer);
        group.userData.animations = {};
        for (const clip of gltf.animations) {
          const shortName = clip.name.replace(/^Armature\|/, '').toLowerCase();
          group.userData.animations[shortName] = clip;
        }
        const idleClip = group.userData.animations['idle'];
        if (idleClip) {
          const action = mixer.clipAction(idleClip);
          action.play();
          group.userData.currentAnim = 'idle';
        }
      }
    });
  }

  const label = createNameSprite(name);
  label.position.y = 1.2;
  group.add(label);

  const scoreSprite = createScoreSprite();
  scoreSprite.position.y = 1.55;
  group.add(scoreSprite);

  const crown = createCrownSprite();
  crown.position.y = 2.1;
  group.add(crown);

  scene.add(group);
  return { group, mesh, outline, crown, scoreSprite };
}

function createPlayerBody(shape, isLocal) {
  const angDamp = (shape === 'sphere' || shape === 'cylinder') ? 0.6 : 0.05;
  const body = new CANNON.Body({
    mass: isLocal ? 1 : 0,
    material: playerMaterial,
    shape: createPhysicsShape(shape),
    linearDamping: 0.1,
    angularDamping: angDamp
  });
  body.collisionFilterMask = -1; // must include the ground-plane group (2)
  world.addBody(body);
  return body;
}

// --- Ball morph (animated roundcube → sphere transition) ---
function updateSprintMorph() {
  if (!localMesh || playerShape !== 'roundcube') return;

  const targetSmoothing = originalSmoothing + (1 - originalSmoothing) * sprintMorphT;
  roundcubeSmoothing = targetSmoothing;

  const oldGeo = localMesh.geometry;
  let geo = new THREE.BoxGeometry(1, 1, 1, 8, 8, 8);
  geo = smoothRoundcube(geo);
  localMesh.geometry = geo;
  oldGeo.dispose();
  const outline = localMesh.children.find(c => c.isMesh);
  if (outline) {
    const oldOutGeo = outline.geometry;
    outline.geometry = geo.clone();
    oldOutGeo.dispose();
  }

  const shouldBeSphere = roundcubeSmoothing >= 0.75;
  if (shouldBeSphere && !morphedPhysicsToSphere) {
    morphedPhysicsToSphere = true;
    rebuildSprintPhysics();
  } else if (!shouldBeSphere && morphedPhysicsToSphere) {
    morphedPhysicsToSphere = false;
    rebuildSprintPhysics();
  }
}

function rebuildSprintPhysics() {
  if (!localBody) return;
  const pos = localBody.position.clone();
  const vel = localBody.velocity.clone();
  const angVel = localBody.angularVelocity.clone();
  const quat = localBody.quaternion.clone();
  world.removeBody(localBody);
  const isSpherePhysics = roundcubeSmoothing >= 0.75;
  localBody = new CANNON.Body({
    mass: godmode ? 0 : 1,
    material: playerMaterial,
    shape: createRoundcubePhysicsShape(roundcubeSmoothing),
    linearDamping: 0.1,
    angularDamping: isSpherePhysics ? 0.6 : 0.05
  });
  localBody.collisionFilterMask = -1; // must include the ground-plane group (2)
  localBody.position.copy(pos);
  localBody.velocity.copy(vel);
  localBody.angularVelocity.copy(angVel);
  localBody.quaternion.copy(quat);
  world.addBody(localBody);
}

// --- Ground check ---
function checkGrounded() {
  return rayGrounded;
}

// --- Movement ---
function handleMovement(delta) {
  if (!localBody) return;

  let inputX = 0, inputZ = 0;
  if (isMobile) {
    inputX = Math.max(-1, Math.min(1, joystickX + tiltX));
    inputZ = Math.max(-1, Math.min(1, joystickZ + tiltZ));
  }
  else {
    if (keys['KeyW']) inputZ -= 1;
    if (keys['KeyS']) inputZ += 1;
    if (keys['KeyA']) inputX -= 1;
    if (keys['KeyD']) inputX += 1;
  }

  const inputLen = Math.sqrt(inputX * inputX + inputZ * inputZ);
  const grounded = checkGrounded();

  // Sprint stamina
  const wantsSprint = keys['ShiftLeft'] || keys['ShiftRight'] || mobileSprinting;
  const sprinting = wantsSprint && !sprintExhausted && inputLen > 0;

  if (sprinting && !wasSprinting) {
    playWorldSound(boostSound, localBody.position, 0.4);
    socket.emit('sprintStart');
  }
  wasSprinting = sprinting;

  if (sprinting) {
    sprintStamina -= delta;
    if (sprintStamina <= 0) {
      sprintStamina = 0;
      sprintExhausted = true;
    }
  } else {
    const refillRate = SPRINT_DURATION / SPRINT_REFILL_TIME;
    sprintStamina = Math.min(SPRINT_DURATION, sprintStamina + refillRate * delta);
    if (sprintExhausted && sprintStamina >= SPRINT_DURATION) {
      sprintExhausted = false;
    }
  }

  // Animated ball morph while sprinting (roundcube only)
  const wantBall = sprinting && inputLen > 0;
  if (playerShape === 'roundcube') {
    const prevT = sprintMorphT;
    if (wantBall && sprintMorphT < 1) {
      sprintMorphT = Math.min(1, sprintMorphT + 3 * delta);
    } else if (!wantBall && sprintMorphT > 0) {
      sprintMorphT = Math.max(0, sprintMorphT - 3 * delta);
    }
    if (sprintMorphT !== prevT) updateSprintMorph();
  }

  // Smooth speed cap transition
  const targetCap = sprinting ? SPRINT_SPEED : MAX_SPEED;
  speedCapCurrent += (targetCap - speedCapCurrent) * Math.min(1, 2.5 * delta);

  if (inputLen > 0) {
    const inputMag = Math.min(inputLen, 1);
    const nx = inputX / inputLen;
    const nz = inputZ / inputLen;

    const forward = new THREE.Vector3();
    camera.getWorldDirection(forward);
    forward.y = 0; forward.normalize();
    const right = new THREE.Vector3().crossVectors(forward, new THREE.Vector3(0, 1, 0)).normalize();

    const worldX = right.x * nx + forward.x * (-nz);
    const worldZ = right.z * nx + forward.z * (-nz);

    const force = sprinting ? SPRINT_FORCE : MOVE_FORCE;

    localBody.applyForce(new CANNON.Vec3(worldX * force * inputMag, 0, worldZ * force * inputMag), localBody.position);
  }

  // Always apply gradual speed cap
  const vx = localBody.velocity.x, vz = localBody.velocity.z;
  const hSpeed = Math.sqrt(vx * vx + vz * vz);
  if (!isGrappling && hSpeed > speedCapCurrent) {
    localBody.velocity.x = (vx / hSpeed) * speedCapCurrent;
    localBody.velocity.z = (vz / hSpeed) * speedCapCurrent;
  }

  // Grapple logic
  if (isGrappling && localBody) {
    const currentPos = new THREE.Vector3(localBody.position.x, localBody.position.y, localBody.position.z);
    const dir = new THREE.Vector3().subVectors(grappleTarget, currentPos);
    const dist = dir.length();

    if (dist < 2 || keys['Space'] || jumpBufferTimer > 0) {
      isGrappling = false;
    } else {
      dir.normalize();
      const GRAPPLE_SPEED = 40;
      localBody.velocity.x = dir.x * GRAPPLE_SPEED;
      localBody.velocity.y = dir.y * GRAPPLE_SPEED;
      localBody.velocity.z = dir.z * GRAPPLE_SPEED;
    }
  }

  // Jump cooldown tick
  if (jumpCooldownTimer > 0) {
    jumpCooldownTimer -= delta;
    if (jumpCooldownTimer < 0) jumpCooldownTimer = 0;
  }

  // Track coyote time
  const now = performance.now() / 1000;
  if (grounded) lastGroundedTime = now;
  const timeSinceGrounded = now - lastGroundedTime;
  const canJump = timeSinceGrounded < COYOTE_TIME;

  // Charge whenever space is held and jump is not on cooldown
  if (keys['Space'] && jumpCooldownTimer <= 0) {
    if (!isChargingJump) {
      isChargingJump = true;
      jumpCharge = 1;
    }
    jumpCharge = Math.min(jumpCharge + CHARGE_RATE * delta, MAX_CHARGE_MULT);
  }

  // Jump fires on space release; buffer the attempt briefly if airborne
  if (jumpBufferTimer > 0) jumpBufferTimer -= delta;

  if (!keys['Space'] && isChargingJump) {
    if (canJump) {
      localBody.velocity.y = JUMP_IMPULSE * jumpCharge;
      jumpCooldownMax = jumpCharge;
      jumpCooldownTimer = jumpCharge;
      jumpCooldownStartPct = jumpCharge / MAX_CHARGE_MULT;
      playRandomJumpSound(localBody.position);
      socket.emit('jump');
      jumpBufferTimer = 0;
    } else {
      jumpBufferTimer = JUMP_BUFFER_TIME;
    }
    isChargingJump = false;
    jumpCharge = 0;
  }

  // Buffered jump: if we land while buffer is still active, fire the jump
  if (jumpBufferTimer > 0 && canJump && jumpCooldownTimer <= 0) {
    localBody.velocity.y = JUMP_IMPULSE;
    jumpCooldownMax = 1;
    jumpCooldownTimer = 1;
    jumpCooldownStartPct = 1 / MAX_CHARGE_MULT;
    playRandomJumpSound(localBody.position);
    socket.emit('jump');
    jumpBufferTimer = 0;
  }

  // Rocket cooldown tick
  if (rocketCooldownTimer > 0) rocketCooldownTimer -= delta;

  // Tag cooldown tick
  if (tagCooldownTimer > 0) tagCooldownTimer -= delta;

  // Auto-tag: if holder bumps into another player (respect cooldown)
  if (holderID === selfId && tagCooldownTimer <= 0) {
    for (const [id, group] of remotePlayers) {
      const dx = localBody.position.x - group.position.x;
      const dy = localBody.position.y - group.position.y;
      const dz = localBody.position.z - group.position.z;
      const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist < TAG_DISTANCE) {
        socket.emit('tagPlayer', id);
        break;
      }
    }
  }
}

const VISUAL_SMOOTH = 0.45;
const _syncPos = new THREE.Vector3();
const _syncQuat = new THREE.Quaternion();
// The visual mesh is a 1-unit shape (half-height 0.5), but the roundcube's
// PHYSICS body is shrunk (box half-extent s = 0.5*(1 - smoothing*0.3), or a
// sphere) so it rests with its centre at surface+s. Drawing the visual at the
// body centre would sink its bottom (surface + s - 0.5) below the floor.
// Lifting the visual by (0.5 - s) makes its bottom rest exactly on the surface.
function physHalfFromSmoothing(sm) {
  sm = sm || 0;
  return sm < 0.75 ? 0.5 * (1 - sm * 0.3) : 0.5 * (0.85 + sm * 0.15);
}

// When the inflated cel-shade outline (back-side hull, scaled ~1.15 about the
// centre) is showing, its bottom pokes (scale-1)*0.5 below the cube. The cube
// rolls, so we can't anchor the hull to its bottom; instead we lift the whole
// visual by that overhang so the hull rests on the floor and the small gap under
// the inner cube is hidden by the border itself. Zero when the outline is hidden
// so the cube never floats.
function outlineLift(mesh) {
  if (!mesh) return 0;
  const outline = mesh.children.find(c => c.isMesh && c.material && c.material.side === THREE.BackSide);
  if (outline && outline.visible) return (outline.scale.x - 1) * 0.5;
  return 0;
}

function syncMeshToBody(group, mesh, body) {
  const s = body.shapes && body.shapes[0];
  let half = 0.5;
  if (s) { if (s.halfExtents) half = s.halfExtents.y; else if (typeof s.radius === 'number') half = s.radius; }
  const off = (0.5 - half) + outlineLift(mesh);
  _syncPos.set(body.position.x, body.position.y + off, body.position.z);
  _syncQuat.set(body.quaternion.x, body.quaternion.y, body.quaternion.z, body.quaternion.w);
  group.position.lerp(_syncPos, VISUAL_SMOOTH);
  mesh.quaternion.slerp(_syncQuat, VISUAL_SMOOTH);
}

// --- Camera ---
let BASE_CHAIN_LENGTH = 10;
let chainLength = BASE_CHAIN_LENGTH;
let camHeight = 5.8;
let camYaw = Math.PI;
let camPitch = 0.4;
const CAM_PITCH_MIN = -1.4;
const CAM_PITCH_MAX = 1.4;
const MOUSE_SENSITIVITY = 0.003;
const CAM_DRAG_SPEED = 1.8;
// Extra catch-up multiplier applied to the auto-follow when the camera is far
// off the player's back, so sharper turns swing behind a bit faster.
const CAM_TURN_BOOST = 1.5;
let lastMouseMoveTime = 0;
const MOUSE_IDLE_DELAY = 0.6;
let cameraLookAtTarget = new THREE.Vector3();

let mouseDragging = false;
let pointerLockSupported = false;

renderer.domElement.addEventListener('contextmenu', (e) => e.preventDefault());

let isDraggingBuild = false;
let dragBuildLock = null;
let lastBuiltCell = null;

renderer.domElement.addEventListener('mousedown', (e) => {
  if (e.button === 2) mouseDragging = true;
  if (e.button === 0) {
    const item = inventory.length > 0 ? inventory[0].type : null;
    if (!godmode && item === 'machinegun') {
      startMachinegun();
    } else if ((!godmode && ['block', 'wall', 'ramp', 'platform'].includes(item)) || (godmode && godmodeToolSelected === 'build_mode')) {
      if (buildCanPlace && buildTarget) {
        isDraggingBuild = true;
        const type = godmode ? godmodeBuildType : item;
        if (type === 'wall') {
          dragBuildLock = (buildRotationSteps % 2 === 0) ? { axis: 'z', value: buildTarget.z } : { axis: 'x', value: buildTarget.x };
        } else {
          dragBuildLock = { axis: 'y', value: buildTarget.y };
        }
        lastBuiltCell = `${buildTarget.x},${buildTarget.y},${buildTarget.z}`;
        socket.emit('placeBuild', { type, ...buildTarget });
        if (!godmode) {
          useAmmo();
          if (inventory.length === 0 || inventory[0].type !== type) isDraggingBuild = false;
        }
      }
    }
  }
});
window.addEventListener('mouseup', (e) => {
  if (e.button === 2) mouseDragging = false;
  if (e.button === 0) {
    stopMachinegun();
    isDraggingBuild = false;
    dragBuildLock = null;
  }
});

document.addEventListener('mousemove', (e) => {
  if (!mouseDragging) return;
  lastMouseMoveTime = performance.now() / 1000;

  if (godmode) {
    camera.rotation.order = 'YXZ';
    camera.rotation.y -= e.movementX * MOUSE_SENSITIVITY;
    camera.rotation.x -= e.movementY * MOUSE_SENSITIVITY;
    camera.rotation.x = Math.max(-Math.PI/2, Math.min(Math.PI/2, camera.rotation.x));
    camera.rotation.z = 0;
  } else {
    camYaw -= e.movementX * MOUSE_SENSITIVITY;
    camPitch += e.movementY * MOUSE_SENSITIVITY;
    camPitch = Math.max(CAM_PITCH_MIN, Math.min(CAM_PITCH_MAX, camPitch));
  }
});

window.addEventListener('wheel', (e) => {
  if (!gameStarted) return;
  if (godmode && godmodeToolSelected === 'build_channel') {
    channelHeightOffset += (e.deltaY > 0 ? -1 : 1) * 0.5;
    showToast('Channel height: ' + channelHeightOffset.toFixed(1));
    updateGodmodeHover(lastHoverX, lastHoverY);
    return;
  }
  if (godmode && (godmodeToolSelected === 'model' || godmodeToolSelected === 'spawn' || godmodeToolSelected.startsWith('pedestal'))) {
    ghostRotationY += (e.deltaY > 0 ? 1 : -1) * (Math.PI / 8);
    const ghost = getGhost();
    if (ghost) ghost.rotation.y = ghostRotationY;
    return;
  }
  const isBuilding = (!godmode && inventory.length > 0 && ['block', 'wall', 'ramp', 'platform'].includes(inventory[0].type)) || (godmode && godmodeToolSelected === 'build_mode');
  if (isBuilding) {
    if (godmode) {
      buildPlaneY -= (e.deltaY > 0 ? 4 : -4);
    } else {
      buildPlacementDistance -= (e.deltaY > 0 ? 1 : -1) * 2;
      buildPlacementDistance = Math.max(4, Math.min(100, buildPlacementDistance));
    }
  } else {
    BASE_CHAIN_LENGTH += e.deltaY * 0.005;
    BASE_CHAIN_LENGTH = Math.max(2, Math.min(20, BASE_CHAIN_LENGTH));
  }
}, { passive: true });

// --- Spawn point editor ---
const spawnDiamondGeo = new THREE.OctahedronGeometry(0.4, 0);
const spawnDiamondMat = new THREE.MeshStandardMaterial({ color: 0x00ffcc, emissive: 0x00aa88, emissiveIntensity: 0.6 });
const spawnClickRaycaster = new THREE.Raycaster();
const spawnClickNDC = new THREE.Vector2();

function createSpawnMarker(pt) {
  const diamond = new THREE.Mesh(spawnDiamondGeo, spawnDiamondMat.clone());
  diamond.position.set(pt.x, pt.y + 1.5, pt.z);
  diamond.scale.set(1, 1.5, 1);
  diamond.userData.spawnPoint = pt;
  scene.add(diamond);
  spawnMarkers.push(diamond);
  return diamond;
}

function showSpawnMarkers() {
  for (const sp of SPAWN_POINTS) {
    createSpawnMarker(sp);
  }
}

function hideSpawnMarkers() {
  for (const m of spawnMarkers) {
    scene.remove(m);
  }
  spawnMarkers.length = 0;
}

renderer.domElement.addEventListener('click', (e) => {
  if (!godmode) {
    if (inventory.length > 0 && !['machinegun', 'block', 'wall', 'ramp', 'platform'].includes(inventory[0].type)) {
      const ndc = new THREE.Vector2((e.clientX / window.innerWidth) * 2 - 1, -(e.clientY / window.innerHeight) * 2 + 1);
      const item = inventory[0].type;
      const isWeapon = ['rocket', 'machinegun', 'grapple'].includes(item);
      consumeItem(getAimPoint(ndc, isWeapon));
    }
    return;
  }

  const now = performance.now() / 1000;

  spawnClickNDC.x = (e.clientX / window.innerWidth) * 2 - 1;
  spawnClickNDC.y = -(e.clientY / window.innerHeight) * 2 + 1;
  spawnClickRaycaster.setFromCamera(spawnClickNDC, camera);
  spawnClickRaycaster.far = 500;

  if (godmodeToolSelected === 'spawn') {
    // Check if clicking on an existing spawn marker to remove it
    const markerHits = spawnClickRaycaster.intersectObjects(spawnMarkers, false);
    if (markerHits.length > 0) {
      const hitMarker = markerHits[0].object;
      const sp = hitMarker.userData.spawnPoint;
      SPAWN_POINTS = SPAWN_POINTS.filter(p => p !== sp);
      scene.remove(hitMarker);
      const idx = spawnMarkers.indexOf(hitMarker);
      if (idx !== -1) spawnMarkers.splice(idx, 1);
      console.log(`REMOVED SPAWN POINT: { x: ${sp.x.toFixed(2)}, y: ${sp.y.toFixed(2)}, z: ${sp.z.toFixed(2)} } — ${SPAWN_POINTS.length} remaining`);
      return;
    }

    if (now - spawnClickCooldown < 0.5) return;
    spawnClickCooldown = now;

    const hits = spawnClickRaycaster.intersectObjects(levelMeshes, false);
    if (hits.length === 0) return;
    const pt = hits[0].point;
    const newSp = { x: parseFloat(pt.x.toFixed(2)), y: parseFloat(pt.y.toFixed(2)), z: parseFloat(pt.z.toFixed(2)) };
    SPAWN_POINTS.push(newSp);
    const spMarker = createSpawnMarker(newSp);
    pushUndo({ kind: 'spawn', sp: newSp, marker: spMarker });
    console.log(`SPAWN POINT ADDED: { x: ${newSp.x}, y: ${newSp.y}, z: ${newSp.z} } — ${SPAWN_POINTS.length} total`);

  } else if (godmodeToolSelected.startsWith('pedestal')) {
    // Check if clicking on an existing pedestal to remove it
    const pedChildren = [];
    for (const ped of pedestalMeshes) ped.traverse(c => { if (c.isMesh) pedChildren.push(c); });
    const pedHits = spawnClickRaycaster.intersectObjects(pedChildren, false);
    if (pedHits.length > 0) {
      let hitObj = pedHits[0].object;
      while (hitObj.parent && !hitObj.userData.pedestalId) hitObj = hitObj.parent;
      if (hitObj.userData.pedestalId) {
        socket.emit('removePedestal', hitObj.userData.pedestalId);
        return;
      }
    }

    if (!ghostCanPlace) return;

    if (now - spawnClickCooldown < 0.5) return;
    spawnClickCooldown = now;

    const hits = spawnClickRaycaster.intersectObjects(levelMeshes, false);
    if (hits.length === 0) return;
    const pt = hits[0].point;
    const type = godmodeToolSelected.replace('pedestal_', '');
    const pedId = genPlacementId();
    const pos = { id: pedId, x: parseFloat(pt.x.toFixed(2)), y: parseFloat(pt.y.toFixed(2)), z: parseFloat(pt.z.toFixed(2)), ry: parseFloat(ghostRotationY.toFixed(2)), type };
    socket.emit('placePedestal', pos);
    pushUndo({ kind: 'pedestal', id: pedId });
    console.log(`PEDESTAL PLACED: { x: ${pos.x}, y: ${pos.y}, z: ${pos.z} }`);
  } else if (godmodeToolSelected === 'model') {
    // Click an existing placed model to remove it
    const modelChildren = [];
    for (const wm of worldModels) wm.group.traverse(c => { if (c.isMesh) modelChildren.push(c); });
    const modelHits = spawnClickRaycaster.intersectObjects(modelChildren, false);
    if (modelHits.length > 0) {
      let hitObj = modelHits[0].object;
      while (hitObj.parent && !hitObj.userData.modelId) hitObj = hitObj.parent;
      if (hitObj.userData.modelId) { socket.emit('removeModel', hitObj.userData.modelId); return; }
    }

    if (!selectedModel || !ghostCanPlace) return;
    if (now - spawnClickCooldown < 0.5) return;
    spawnClickCooldown = now;

    const hits = spawnClickRaycaster.intersectObjects(levelMeshes, false);
    if (hits.length === 0) return;
    const pt = hits[0].point;
    const modelId = genPlacementId();
    const pos = { id: modelId, model: selectedModel, x: parseFloat(pt.x.toFixed(2)), y: parseFloat(pt.y.toFixed(2)), z: parseFloat(pt.z.toFixed(2)), ry: parseFloat(ghostRotationY.toFixed(3)) };
    socket.emit('placeModel', pos);
    pushUndo({ kind: 'model', id: modelId });
    console.log(`MODEL PLACED: ${selectedModel} { x: ${pos.x}, y: ${pos.y}, z: ${pos.z} }`);
  } else if (godmodeToolSelected === 'build_bridge') {
    const hits = spawnClickRaycaster.intersectObjects([...levelMeshes, ...worldBuilds.map(b => b.mesh)], false);
    if (hits.length === 0) return;
    const pt = hits[0].point.clone();
    if (!bridgeStart) {
      bridgeStart = pt;
      console.log(`BRIDGE START: { x: ${pt.x.toFixed(2)}, y: ${pt.y.toFixed(2)}, z: ${pt.z.toFixed(2)} }`);
      return;
    }
    const target = pt;
    let dist = bridgeStart.distanceTo(target);
    if (dist < 0.5) { bridgeStart = null; bridgeGhost.visible = false; return; }
    const mid = bridgeStart.clone().lerp(target, 0.5);
    const dir = new THREE.Vector3().subVectors(target, bridgeStart).normalize();
    socket.emit('placeBuild', { type: 'bridge', x: mid.x, y: mid.y, z: mid.z, ry: Math.atan2(dir.x, dir.z), rx: -Math.asin(dir.y), length: dist });
    console.log(`BRIDGE PLACED: length ${dist.toFixed(2)}`);
    bridgeStart = null;
    bridgeGhost.visible = false;
  } else if (godmodeToolSelected === 'build_teleporter') {
    const hits = spawnClickRaycaster.intersectObjects(levelMeshes, false);
    if (hits.length === 0) return;
    const pt = hits[0].point.clone();
    if (!teleporterStartA) {
      teleporterStartA = pt;
      console.log(`TELEPORTER A: { x: ${pt.x.toFixed(2)}, y: ${pt.y.toFixed(2)}, z: ${pt.z.toFixed(2)} }`);
      return;
    }
    socket.emit('placeTeleporter', { a: teleporterStartA, b: pt });
    console.log(`TELEPORTER PLACED`);
    teleporterStartA = null;
    teleporterGhostA.visible = false;
    teleporterGhostB.visible = false;
  } else if (godmodeToolSelected === 'build_channel') {
    const hits = spawnClickRaycaster.intersectObjects([...levelMeshes, ...worldBuilds.map(b => b.mesh)], false);
    if (hits.length === 0) return;
    const pt = hits[0].point.clone();
    pt.y += channelHeightOffset;
    channelNodes.push(pt);
    rebuildChannelGhost(channelNodes);
    console.log(`CHANNEL NODE ${channelNodes.length}: { x: ${pt.x.toFixed(2)}, y: ${pt.y.toFixed(2)}, z: ${pt.z.toFixed(2)} }`);
  } else if (godmodeToolSelected === 'delete_block') {
    const buildMeshes = worldBuilds.map(b => b.mesh);
    const buildHits = spawnClickRaycaster.intersectObjects(buildMeshes, false);
    if (buildHits.length > 0) {
       const id = worldBuilds.find(b => b.mesh === buildHits[0].object)?.id;
       if (id) socket.emit('removeBuild', id);
    }
  }
});

renderer.domElement.addEventListener('contextmenu', (e) => e.preventDefault());

function updateCamera(delta) {
  if (godmode || !localPlayer) return;

  let playerSpeed = 0;
  if (localBody) {
    const vx = localBody.velocity.x;
    const vz = localBody.velocity.z;
    playerSpeed = Math.sqrt(vx * vx + vz * vz);
    const now = performance.now() / 1000;
    const mouseIdle = (now - lastMouseMoveTime) > MOUSE_IDLE_DELAY;

    if (playerSpeed > 1.5 && mouseIdle) {
      const behindYaw = Math.atan2(vx, vz) + Math.PI;
      let diff = behindYaw - camYaw;
      diff = diff - Math.round(diff / (2 * Math.PI)) * 2 * Math.PI;
      // The farther the camera is from the player's back, the faster it swings
      // around — sharper turns get a higher catch-up rate.
      const turnBoost = 1 + Math.min(1, Math.abs(diff) / (Math.PI * 0.5)) * CAM_TURN_BOOST;
      const dragT = Math.min(1, CAM_DRAG_SPEED * turnBoost * delta);
      camYaw += diff * dragT;
    }
  }

  // Sprint camera pull-away: chain extends with speed, giving a "catching up" feel
  const speedExtra = Math.max(0, playerSpeed - MAX_SPEED) * 0.4;
  const targetChain = BASE_CHAIN_LENGTH + speedExtra;
  chainLength += (targetChain - chainLength) * Math.min(1, 2 * delta);
  camHeight = chainLength * 0.58;

  const offsetX = Math.sin(camYaw) * Math.cos(camPitch) * chainLength;
  const offsetZ = Math.cos(camYaw) * Math.cos(camPitch) * chainLength;
  const offsetY = Math.sin(camPitch) * chainLength;

  // Frame-rate independent exponential smoothing
  // Slower follow when sprinting = camera lags behind, feels like it's catching up
  const speedFactor = Math.min(1, playerSpeed / SPRINT_SPEED);
  const baseLerp = 1 - Math.exp(-6 * delta);
  const camLerp = baseLerp * (1 - speedFactor * 0.4);

  // Smoothly move the look-at target towards the player's head
  const lookAtTargetPos = new THREE.Vector3().copy(localPlayer.position).add(new THREE.Vector3(0, 1.0, 0));
  const lookAtLerp = 1 - Math.exp(-15 * delta); // A fairly snappy but smooth lerp
  cameraLookAtTarget.lerp(lookAtTargetPos, lookAtLerp);

  // Base the camera's target position on the smoothed look-at point, not the raw player position.
  // This prevents camera bobbing from physics ground jitter.
  const targetX = localPlayer.position.x + offsetX;
  const targetY = cameraLookAtTarget.y + 0.5 + offsetY;
  const targetZ = localPlayer.position.z + offsetZ;

  const desiredPos = new THREE.Vector3(targetX, targetY, targetZ);

  // Camera wall collision — pull camera closer if environment is between player and camera
  const camOrigin = new THREE.Vector3().copy(cameraLookAtTarget);
  const camDir = new THREE.Vector3().subVectors(desiredPos, camOrigin);
  const camDist = camDir.length();
  if (camDist > 0.1) {
    camDir.normalize();
    const camHit = raycastLevel(camOrigin, camDir, camDist);
    if (camHit) {
      const safeDist = Math.max(0.5, camHit.distance - 0.3);
      desiredPos.copy(camOrigin).addScaledVector(camDir, safeDist);
    }
  }

  camera.position.lerp(desiredPos, camLerp);
  camera.lookAt(cameraLookAtTarget);
}

// --- Oddball visuals ---
const playerCrowns = new Map();
const playerOutlines = new Map();
let localCrown = null;
let localOutline = null;

function updateOddballVisuals() {
  // Update outlines — only holder has outline
  if (localOutline) localOutline.visible = (holderID === selfId);
  for (const [id, outline] of playerOutlines) {
    outline.visible = (id === holderID);
  }

  // Update crowns — only leader has crown
  if (localCrown) localCrown.visible = (leaderID === selfId);
  for (const [id, crown] of playerCrowns) {
    crown.visible = (id === leaderID);
  }

  // Update score sprites — show for anyone with > 0 points
  if (localScoreSprite) {
    const score = allScores[selfId] || 0;
    localScoreSprite.visible = score > 0;
    if (score > 0) updateScoreSpriteText(localScoreSprite, score);
  }
  for (const [id, ss] of playerScoreSprites) {
    const score = allScores[id] || 0;
    ss.visible = score > 0;
    if (score > 0) updateScoreSpriteText(ss, score);
  }

  // Update leader display
  if (leaderID && allScores[leaderID] > 0) {
    const leaderName = getPlayerName(leaderID);
    const score = allScores[leaderID] || 0;
    leaderDisplay.innerHTML = `<span class="crown">\u{1F451}</span> ${leaderName}: ${score}`;
    leaderDisplay.style.display = '';
  }
}

function getPlayerName(id) {
  if (id === selfId) return playerName;
  return playerNames.get(id) || 'Player';
}

const playerNames = new Map();

function findLeader() {
  let maxScore = 0;
  leaderID = null;
  for (const [id, score] of Object.entries(allScores)) {
    if (score > maxScore) { maxScore = score; leaderID = id; }
  }
}

// --- Tag cooldown strobe ---
function updateTagStrobe() {
  const t = performance.now() * 0.008;
  const pulse = 0.7 + Math.sin(t) * 0.3;

  if (holderID === selfId && localOutline) {
    localOutline.visible = true;
    if (tagCooldownTimer > 0) {
      const flash = Math.sin(t * 3) * 0.5 + 0.5;
      localOutline.material.color.setRGB(1, 0.84 * flash, 0);
    } else {
      localOutline.material.color.setRGB(pulse, pulse * 0.75, 0);
    }
  }
  for (const [id, outline] of playerOutlines) {
    if (id === holderID) {
      outline.visible = true;
      if (tagCooldownTimer > 0) {
        const flash = Math.sin(t * 3) * 0.5 + 0.5;
        outline.material.color.setRGB(1, 0.84 * flash, 0);
      } else {
        outline.material.color.setRGB(pulse, pulse * 0.75, 0);
      }
    }
  }
}

function resetOutlineColors() {
  if (localOutline) localOutline.material.color.set(0xffd700);
  for (const [id, outline] of playerOutlines) {
    outline.material.color.set(0xffd700);
  }
}

// --- Crown distance scaling ---
const BASE_NAME_Y = 1.2;
const BASE_SCORE_Y = 1.55;
const BASE_CROWN_Y = 2.1;

function scaleLeaderSprites(playerPos, nameSprite, scoreSprite, crown) {
  const dist = camera.position.distanceTo(playerPos);
  const s = Math.max(2, Math.min(dist * 0.15, 6));
  const ratio = s / 2;
  if (nameSprite) {
    nameSprite.scale.set(s, s * 0.25, 1);
    nameSprite.position.y = BASE_NAME_Y;
  }
  if (scoreSprite && scoreSprite.visible) {
    scoreSprite.scale.set(s * 0.75, s * 0.2, 1);
    scoreSprite.position.y = BASE_NAME_Y + 0.45 * ratio;
  }
  if (crown && crown.visible) {
    crown.scale.set(s, s * 0.5, 1);
    crown.position.y = BASE_NAME_Y + 1.1 * ratio;
  }
}

function resetLabelScale(nameSprite, scoreSprite) {
  if (nameSprite) {
    nameSprite.scale.set(2, 0.5, 1);
    nameSprite.position.y = BASE_NAME_Y;
  }
  if (scoreSprite && scoreSprite.visible) {
    scoreSprite.scale.set(1.5, 0.4, 1);
    scoreSprite.position.y = BASE_NAME_Y + 0.45;
  }
}

function updateCrowns() {
  // Scale leader's name, score, crown with distance. Reset non-leaders to default.
  if (localPlayer) {
    const nameLabel = localPlayer.children.find(c => c.isSprite && c !== localCrown && c !== localScoreSprite);
    if (leaderID === selfId) {
      scaleLeaderSprites(localPlayer.position, nameLabel, localScoreSprite, localCrown);
    } else {
          resetLabelScale(nameLabel, localScoreSprite);
    }
  }
  for (const [id, group] of remotePlayers) {
    const crown = playerCrowns.get(id);
    const ss = playerScoreSprites.get(id);
    const nameLabel = group.children.find(c => c.isSprite && c !== crown && c !== ss);
    if (id === leaderID) {
      scaleLeaderSprites(group.position, nameLabel, ss, crown);
    } else {
          resetLabelScale(nameLabel, ss);
    }
  }
}

// --- Networking ---
const socket = io();
socket.on('chatMessage', (m) => { if (m && m.text) addChatMessage(m.name || 'Player', m.color, m.text); });
socket.on('systemMessage', (m) => { if (m && m.text) addSystemMessage(m.text); });
socket.on('gameEnded', () => {
  if (gameStarted) { addSystemMessage('Game ended — returning to menu.'); returnToMenu(); }
});

function startGame() {
  socket.emit('ready', {
    type: isMobile ? 'ball' : playerShape,
    name: playerName,
    shape: playerShape,
    skinColor: playerColor,
    skinImage: playerSkinImage,
    model: playerModel
  });
}

socket.on('currentPlayers', (data) => {
  selfId = data.selfId;
  // Clear any spectator-mode remote meshes created while we were in the menu so
  // joining doesn't leave duplicates behind.
  for (const group of remotePlayers.values()) scene.remove(group);
  remotePlayers.clear(); remoteMeshes.clear(); remoteTargets.clear();
  playerOutlines.clear(); playerCrowns.clear(); playerScoreSprites.clear();
  for (const [id, info] of Object.entries(data.players)) {
    const shape = info.shape || info.type || 'box';
    const color = info.skinColor || info.color;
    const { group, mesh, outline, crown, scoreSprite } = createPlayerVisual(color, shape, info.name, info.skinImage, info.model);
    group.position.set(info.x, info.y, info.z);
    if (id === selfId) {
      localPlayer = group;
      localMesh = mesh;
      localOutline = outline;
      localCrown = crown;
      localScoreSprite = scoreSprite;
      localBody = createPlayerBody(shape, true);
      // Spawn-point Y values are surface heights (captured via downward raycast),
      // so lift the body centre by the player radius to rest ON the floor rather
      // than embedded in it. (Previously the per-frame anti-sink did this, but it
      // fought the rolling cube, so we lift once at spawn instead.)
      localBody.position.set(info.x, info.y + PLAYER_RADIUS, info.z);
      camera.position.set(group.position.x, group.position.y + camHeight, group.position.z + chainLength);
      cameraLookAtTarget.copy(localBody.position);
    } else {
      remotePlayers.set(id, group);
      remoteMeshes.set(id, mesh);
      playerOutlines.set(id, outline);
      playerCrowns.set(id, crown);
      playerScoreSprites.set(id, scoreSprite);
      playerNames.set(id, info.name);
    }
  }
  if (startingWeapon !== 'none') {
    const ammoMap = { machinegun: 100, rocket: 3, mines: 3, grapple: 5 };
    inventory.push({ type: startingWeapon, ammo: infiniteAmmo ? Infinity : (ammoMap[startingWeapon] || 0) });
    updateInventoryUI();
  }
});

socket.on('newPlayer', (data) => {
  const shape = data.shape || data.type || 'box';
  const color = data.skinColor || data.color;
  const { group, mesh, outline, crown, scoreSprite } = createPlayerVisual(color, shape, data.name, data.skinImage, data.model);
  group.position.set(data.x, data.y, data.z);
  remotePlayers.set(data.id, group);
  remoteMeshes.set(data.id, mesh);
  playerOutlines.set(data.id, outline);
  playerCrowns.set(data.id, crown);
  playerScoreSprites.set(data.id, scoreSprite);
  playerNames.set(data.id, data.name);
});

const remoteTargets = new Map();

socket.on('playerJumped', (id) => {
  const playerGroup = remotePlayers.get(id);
  if (playerGroup) {
    playRandomJumpSound(playerGroup.position);
  }
});

socket.on('playerSprintStart', (id) => {
  const playerGroup = remotePlayers.get(id);
  if (playerGroup) {
    playWorldSound(boostSound, playerGroup.position, 0.4);
  }
});

socket.on('playerMoved', (data) => {
  if (remotePlayers.has(data.id)) remoteTargets.set(data.id, data);
});

// Roster snapshot for the menu birdseye spectator. Build meshes for any players
// already in a game when we connected; ongoing updates come via 'playerMoved'.
socket.on('spectatorPlayers', (data) => {
  if (gameStarted) return;
  if (data && data.activeLevel) serverActiveLevel = data.activeLevel;
  for (const [id, info] of Object.entries((data && data.players) || {})) {
    if (id === selfId || remotePlayers.has(id)) continue;
    const shape = info.shape || info.type || 'box';
    const color = info.skinColor || info.color;
    const { group, mesh, outline, crown, scoreSprite } = createPlayerVisual(color, shape, info.name, info.skinImage, info.model);
    group.position.set(info.x, info.y, info.z);
    remotePlayers.set(id, group);
    remoteMeshes.set(id, mesh);
    playerOutlines.set(id, outline);
    playerCrowns.set(id, crown);
    playerScoreSprites.set(id, scoreSprite);
    playerNames.set(id, info.name);
    remoteTargets.set(id, info);
  }
});

socket.on('playerDisconnected', (id) => {
  const group = remotePlayers.get(id);
  if (group) {
    scene.remove(group);
    remotePlayers.delete(id);
    remoteMeshes.delete(id);
    remoteTargets.delete(id);
    playerOutlines.delete(id);
    playerCrowns.delete(id);
    playerScoreSprites.delete(id);
    playerNames.delete(id);
  }
});

socket.on('holderChanged', (id) => {
  holderID = id;
  updateOddballVisuals();
});

socket.on('tagCooldown', (ms) => {
  tagCooldownTimer = ms / 1000;
  resetOutlineColors();
});

socket.on('scores', (s) => {
  allScores = s;
  findLeader();
  updateOddballVisuals();
});

socket.on('levelChanged', (level) => {
  serverActiveLevel = level;
  selectedLevel = level;
  if (!gameStarted) {
    // Sync the visible map (and selection) to what the server says is active so
    // every lobby client shows and will load the same level.
    if (setVisibleMap) setVisibleMap(level);
    else for (const p of levelPreviews) p.wrapper.classList.toggle('selected', p.filename === level);
    if (menuOverlay) menuOverlay.style.display = 'block';
  }
  if (currentLevelName !== level || !levelLoaded) loadGameLevel(level);
});

socket.on('lobbyLocked', (locked) => {
  if (!gameStarted) setLobbyControlsLocked(locked);
  else lobbyLocked = !!locked;
});

socket.on('kicked', () => {
  if (gameStarted) returnToMenu();
});

socket.on('currentPedestals', (peds) => {
  for (const ped of pedestalMeshes) scene.remove(ped);
  pedestalMeshes.length = 0;
  for (const ped of peds) createPedestalAt(ped, ped.id);
});

socket.on('pedestalPlaced', (ped) => {
  createPedestalAt(ped, ped.id);
});

socket.on('pedestalRemoved', (pedId) => {
  const idx = pedestalMeshes.findIndex(p => p.userData.pedestalId === pedId);
  if (idx !== -1) {
    scene.remove(pedestalMeshes[idx]);
    pedestalMeshes.splice(idx, 1);
  }
});

socket.on('pedestalsUpdated', (peds) => {
  for (const p of peds) {
    const mesh = pedestalMeshes.find(m => m.userData.pedestalId === p.id);
    if (mesh) {
      const crystal = mesh.children.find(c => c.userData.isCrystal);
      if (crystal) crystal.visible = !!p.currentItem;
    }
  }
});

socket.on('itemPickedUp', (item) => {
  if (inventory.length < MAX_INVENTORY) {
    const ammoMap = { machinegun: 100, rocket: 3, bridge_gun: 3, wall: 3, ramp: 3, platform: 3 };
    inventory.push({ type: item, ammo: ammoMap[item] || 0 });
    console.log(`Picked up ${item}! Inventory:`, inventory);
    updateInventoryUI();
  }
});

function addTeleporterToWorld(t) {
  const geo = new THREE.CylinderGeometry(0.8, 0.8, 0.2, 16);
  const mat = new THREE.MeshStandardMaterial({ color: 0x33ccff, emissive: 0x0a6699, emissiveIntensity: 0.8 });
  const meshA = new THREE.Mesh(geo, mat.clone());
  const meshB = new THREE.Mesh(geo, mat.clone());
  const posA = new THREE.Vector3(t.a.x, t.a.y, t.a.z);
  const posB = new THREE.Vector3(t.b.x, t.b.y, t.b.z);
  meshA.position.copy(posA);
  meshB.position.copy(posB);
  scene.add(meshA);
  scene.add(meshB);
  worldTeleporters.push({ a: posA, b: posB, meshA, meshB });
}

socket.on('currentTeleporters', (ts) => {
  for (const wt of worldTeleporters) { scene.remove(wt.meshA); scene.remove(wt.meshB); }
  worldTeleporters.length = 0;
  for (const t of ts) addTeleporterToWorld(t);
});

socket.on('teleporterPlaced', (t) => addTeleporterToWorld(t));

function addPadToWorld(p) {
  const geo = new THREE.BoxGeometry(1.2, 0.1, 1.2);
  const mat = new THREE.MeshStandardMaterial({ color: 0x44ff44, emissive: 0x114411 });
  const mesh = new THREE.Mesh(geo, mat);
  mesh.position.set(p.x, p.y + 0.05, p.z);
  if (p.type === 'boost_pad') {
    const dirBox = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.15, 0.8), new THREE.MeshBasicMaterial({color: 0xffffff}));
    dirBox.position.set(0, 0, 0);
    mesh.rotation.y = Math.atan2(p.dx, p.dz);
    mesh.add(dirBox);
  } else {
    const upBox = new THREE.Mesh(new THREE.BoxGeometry(0.6, 0.15, 0.6), new THREE.MeshBasicMaterial({color: 0xffffff}));
    mesh.add(upBox);
  }
  scene.add(mesh);
  worldPads.push({ ...p, mesh, pos: new THREE.Vector3(p.x, p.y, p.z) });
}
socket.on('currentPads', (ps) => { for (const p of worldPads) scene.remove(p.mesh); worldPads.length = 0; for (const p of ps) addPadToWorld(p); });
socket.on('padPlaced', (p) => addPadToWorld(p));

function addBuildToWorld(b) {
  const isHolo = b.type === 'bridge';
  const mat = new THREE.MeshStandardMaterial({ color: isHolo ? 0x00ffff : 0xaaaaaa, transparent: isHolo, opacity: isHolo ? 0.6 : 1.0, roughness: 0.8, side: THREE.DoubleSide });
  let w = 4, h = 4, d = 4;
  let geo, shape;
  if (b.type === 'block') { w = 4; h = 4; d = 4; geo = new THREE.BoxGeometry(w, h, d); shape = new CANNON.Box(new CANNON.Vec3(w/2, h/2, d/2)); }
  else if (b.type === 'wall') { w = 4; h = 4; d = 1; geo = new THREE.BoxGeometry(w, h, d); shape = new CANNON.Box(new CANNON.Vec3(w/2, h/2, d/2)); }
  else if (b.type === 'platform') { w = 4; h = 1; d = 4; geo = new THREE.BoxGeometry(w, h, d); shape = new CANNON.Box(new CANNON.Vec3(w/2, h/2, d/2)); }
  else if (b.type === 'bridge') { w = 4; h = 0.2; d = b.length; geo = new THREE.BoxGeometry(w, h, d); shape = new CANNON.Box(new CANNON.Vec3(w/2, h/2, d/2)); }
  else if (b.type === 'ramp') {
    geo = createRightWedgeGeometry(w, h, d);
    const vertices = [
      new CANNON.Vec3(-w/2, -h/2,  d/2), new CANNON.Vec3( w/2, -h/2,  d/2),
      new CANNON.Vec3( w/2, -h/2, -d/2), new CANNON.Vec3(-w/2, -h/2, -d/2),
      new CANNON.Vec3(-w/2,  h/2, -d/2), new CANNON.Vec3( w/2,  h/2, -d/2)
    ];
    const faces = [
      [0, 3, 2, 1], // Bottom
      [3, 4, 5, 2], // Back
      [0, 4, 3],    // Left
      [1, 2, 5],    // Right
      [0, 1, 5, 4]  // Slope
    ];
    shape = new CANNON.ConvexPolyhedron(vertices, faces);
  } else {
    geo = new THREE.BoxGeometry(w, h, d); shape = new CANNON.Box(new CANNON.Vec3(w/2, h/2, d/2));
  }
  const mesh = new THREE.Mesh(geo, mat);
  mesh.userData.type = b.type;
  mesh.position.set(b.x, b.y, b.z);
  mesh.rotation.order = 'YXZ';
  if (b.ry) mesh.rotation.y = b.ry;
  if (b.rx) mesh.rotation.x = b.rx;
  mesh.castShadow = !isHolo; mesh.receiveShadow = !isHolo;
  scene.add(mesh);
  addLevelCollider(mesh);

  // Bridges are thin ride-on walkways: collide via the downward ground ray only
  // (no Cannon body, skipped by wall/ceiling rays) so players don't snag on them.
  let body = null;
  if (b.type === 'bridge') {
    mesh.userData.thinPlatform = true;
  } else {
    body = new CANNON.Body({ mass: 0, shape, material: groundMaterial });
    body.position.set(b.x, b.y, b.z);
    if (b.ry || b.rx) {
       const qx = new CANNON.Quaternion(); if (b.rx) qx.setFromAxisAngle(new CANNON.Vec3(1,0,0), b.rx);
       const qy = new CANNON.Quaternion(); if (b.ry) qy.setFromAxisAngle(new CANNON.Vec3(0,1,0), b.ry);
       body.quaternion = qy.mult(qx);
    }
    world.addBody(body);
  }
  worldBuilds.push({ id: b.id, mesh, body });
}
socket.on('currentModels', (ms) => {
  for (const wm of worldModels) scene.remove(wm.group);
  worldModels.length = 0;
  for (const m of ms) createModelAt(m);
});
socket.on('modelPlaced', (m) => createModelAt(m));
socket.on('modelRemoved', (id) => removeModelById(id));

const channelMat = new THREE.MeshStandardMaterial({ color: 0x6f8aa6, roughness: 0.55, metalness: 0.15, side: THREE.DoubleSide });
const channelPostMat = new THREE.MeshStandardMaterial({ color: 0x556070, roughness: 0.7, metalness: 0.2 });
const CHANNEL_POST_RADIUS = 0.35;
const channelPostRaycaster = new THREE.Raycaster();
channelPostRaycaster.far = 1000;
function addChannelToWorld(c) {
  const group = new THREE.Group();
  const bodies = [];
  const meshes = [];
  const pts = c.nodes.map(n => new THREE.Vector3(n.x, n.y, n.z));
  const radius = c.radius || CHANNEL_RADIUS;
  const data = buildChannelGeometry(pts, radius);

  // Support posts: drop a pillar from each (relaxed) anchor down to whatever is below.
  // Use the curve's anchor positions so posts sit under the actual tube; tuck their
  // tops just under the floor so they don't poke up into the slide. Done BEFORE the
  // tube joins levelMeshes so the down-ray can't self-hit.
  const postAnchors = (data && data.anchorPosts) ? data.anchorPosts : pts;
  const down = new THREE.Vector3(0, -1, 0);
  for (const a of postAnchors) {
    const topY = a.y - radius * 0.15; // tuck under the trough floor
    channelPostRaycaster.set(new THREE.Vector3(a.x, topY - 0.05, a.z), down);
    const hits = channelPostRaycaster.intersectObjects(levelMeshes, false);
    const groundY = hits.length > 0 ? hits[0].point.y : a.y - 14; // fallback length if nothing below
    const height = topY - groundY;
    if (height < 0.25) continue;
    const postMesh = new THREE.Mesh(new THREE.CylinderGeometry(CHANNEL_POST_RADIUS, CHANNEL_POST_RADIUS, height, 10), channelPostMat);
    postMesh.position.set(a.x, groundY + height / 2, a.z);
    postMesh.castShadow = true; postMesh.receiveShadow = true;
    postMesh.userData.channelId = c.id;
    group.add(postMesh);
    meshes.push(postMesh);
    const pbody = new CANNON.Body({ mass: 0, material: groundMaterial });
    pbody.addShape(new CANNON.Box(new CANNON.Vec3(CHANNEL_POST_RADIUS, height / 2, CHANNEL_POST_RADIUS)));
    pbody.position.set(a.x, groundY + height / 2, a.z);
    world.addBody(pbody);
    bodies.push(pbody);
  }

  if (data) {
    const mesh = new THREE.Mesh(data.geo, channelMat);
    mesh.castShadow = true; mesh.receiveShadow = true;
    mesh.userData.channelId = c.id;
    group.add(mesh);
    addLevelCollider(mesh);
    meshes.push(mesh);
    for (const panels of data.segmentPanels) {
      const body = new CANNON.Body({ mass: 0, material: groundMaterial });
      for (const p of panels) {
        body.addShape(
          new CANNON.Box(new CANNON.Vec3(p.hx, p.hy, p.hz)),
          new CANNON.Vec3(p.center.x, p.center.y, p.center.z),
          new CANNON.Quaternion(p.quaternion.x, p.quaternion.y, p.quaternion.z, p.quaternion.w)
        );
      }
      world.addBody(body);
      bodies.push(body);
    }
  }
  scene.add(group);
  worldChannels.push({ id: c.id, group, bodies, meshes });
}
socket.on('currentChannels', (cs) => { for (const c of cs) addChannelToWorld(c); });
socket.on('channelPlaced', (c) => addChannelToWorld(c));
socket.on('channelRemoved', (id) => {
  const idx = worldChannels.findIndex(c => c.id === id);
  if (idx === -1) return;
  const c = worldChannels[idx];
  scene.remove(c.group);
  for (const b of c.bodies) world.removeBody(b);
  for (const m of c.meshes) {
    const li = levelMeshes.indexOf(m); if (li !== -1) levelMeshes.splice(li, 1);
    if (m.geometry) m.geometry.dispose();
  }
  worldChannels.splice(idx, 1);
});

socket.on('currentBuilds', (bs) => { for (const b of bs) addBuildToWorld(b); });
socket.on('buildPlaced', (b) => addBuildToWorld(b));
socket.on('buildRemoved', (id) => {
  const idx = worldBuilds.findIndex(b => b.id === id);
  if (idx !== -1) {
    const b = worldBuilds[idx];
    scene.remove(b.mesh); if (b.body) world.removeBody(b.body);
    const lIdx = levelMeshes.indexOf(b.mesh); if (lIdx !== -1) levelMeshes.splice(lIdx, 1);
    worldBuilds.splice(idx, 1);
  }
});

socket.on('machinegunFired', (data) => {
  const geo = new THREE.CylinderGeometry(0.05, 0.05, 2.0, 4);
  geo.rotateX(Math.PI / 2);
  const mat = new THREE.MeshBasicMaterial({ color: 0xffff00 });
  const mesh = new THREE.Mesh(geo, mat);
  const start = new THREE.Vector3(data.start.x, data.start.y, data.start.z);
  const velocity = new THREE.Vector3(data.velocity.x, data.velocity.y, data.velocity.z);
  mesh.position.copy(start);
  mesh.lookAt(new THREE.Vector3().copy(start).add(velocity));
  scene.add(mesh);
  activeBullets.push({ mesh, pos: start, velocity, life: 2, owner: data.owner });
  playWorldSound(boostSound, start, 0.2);
});

socket.on('applyImpulse', (data) => {
  if (data.id === selfId && localBody) {
    localBody.wakeUp();
    localBody.position.y += 0.1; // Pop off ground to break friction
    localBody.velocity.x += data.dir.x * data.force;
    localBody.velocity.y += data.dir.y * data.force;
    localBody.velocity.z += data.dir.z * data.force;
    speedCapCurrent = Math.max(speedCapCurrent, Math.sqrt(localBody.velocity.x**2 + localBody.velocity.z**2));
  }
});

socket.on('rocketFired', (data) => {
  const geo = new THREE.CylinderGeometry(0.05, 0.15, 0.8, 8);
  geo.rotateX(Math.PI / 2);
  const mat = new THREE.MeshStandardMaterial({ color: 0xff2222, emissive: 0xff4400, emissiveIntensity: 0.6 });
  const mesh = new THREE.Mesh(geo, mat);
  const start = new THREE.Vector3(data.start.x, data.start.y, data.start.z);
  const velocity = new THREE.Vector3(data.velocity.x, data.velocity.y, data.velocity.z);
  mesh.position.copy(start);
  mesh.lookAt(new THREE.Vector3().copy(start).add(velocity));
  scene.add(mesh);
  activeRockets.push({ mesh, pos: start, velocity, life: 5, owner: data.owner });
  playWorldSound(boostSound, start, 1.0);
});

socket.on('explosion', (pos) => {
  const p = new THREE.Vector3(pos.x, pos.y, pos.z);
  const isMine = pos.type === 'mine';
  spawnExplosion(p.x, p.y, p.z, isMine);
  playRandomBombSound(p);

  if (localPlayer && localBody) {
    const dist = localPlayer.position.distanceTo(p);
    const blastRadius = isMine ? 6 : 8;
    if (dist < blastRadius) {
      const dir = new THREE.Vector3().subVectors(localPlayer.position, p).normalize();
      if (isMine) {
        dir.y = Math.max(0.3, dir.y + 0.4);
        dir.normalize();
        const force = (blastRadius - dist) * 9;
        pendingImpulses.push({ dir, force, popY: 1.0 });
      } else {
        dir.y = Math.max(0.5, dir.y + 1.0);
        dir.normalize();
        const force = (blastRadius - dist) * 7;
        pendingImpulses.push({ dir, force, popY: 1.5 });
      }
    }
  }
});

function addMineToWorld(m) {
  const geo = new THREE.CylinderGeometry(0.4, 0.4, 0.1, 12);
  const mat = new THREE.MeshStandardMaterial({ color: 0xff2222, emissive: 0x440000 });
  const mesh = new THREE.Mesh(geo, mat);
  const pos = new THREE.Vector3(m.x, m.y, m.z);
  mesh.position.copy(pos);
  scene.add(mesh);
  worldMines.push({ id: m.id, mesh, pos });
}
socket.on('currentMines', (ms) => { for (const m of worldMines) scene.remove(m.mesh); worldMines.length = 0; for (const m of ms) addMineToWorld(m); });
socket.on('minePlaced', (m) => addMineToWorld(m));
socket.on('mineTriggered', (data) => { const idx = worldMines.findIndex(m => m.id === data.id); if (idx !== -1) { scene.remove(worldMines[idx].mesh); worldMines.splice(idx, 1); } });

socket.on('coinsDropped', (coins) => {
  for (const c of coins) {
    const body = new CANNON.Body({
      mass: 1,
      shape: new CANNON.Cylinder(0.3, 0.3, 0.1, 8),
      material: playerMaterial,
      linearDamping: 0.1, angularDamping: 0.1
    });
    body.collisionFilterMask = ~GROUP_GROUNDPLANE; // ignore the player-tracking plane
    body.position.set(c.x, c.y, c.z);
    body.velocity.set(c.vx, c.vy, c.vz);
    body.angularVelocity.set(c.rx || 0, c.ry || 0, c.rz || 0);
    world.addBody(body);
    const geo = new THREE.CylinderGeometry(0.3, 0.3, 0.1, 16);
    geo.rotateX(Math.PI / 2);
    const mat = new THREE.MeshStandardMaterial({ color: 0xffd700, emissive: 0xaa8800 });
    const mesh = new THREE.Mesh(geo, mat);
    scene.add(mesh);
    activeCoinsList.push({ id: c.id, body, mesh, collectTimer: 1.0 }); // Can't be collected for 1 second
  }
});

socket.on('coinCollected', (id) => {
  const idx = activeCoinsList.findIndex(c => c.id === id);
  if (idx !== -1) { const c = activeCoinsList.splice(idx, 1)[0]; scene.remove(c.mesh); world.removeBody(c.body); playWorldSound(boostSound, c.mesh.position, 0.6); }
});

function sendPosition() {
  if (!localBody) return;
  if (godmode) {
    const c = camera.position;
    socket.emit('playerMoved', { x: c.x, y: c.y, z: c.z, qx: 0, qy: 0, qz: 0, qw: 1, smoothing: roundcubeSmoothing, godmode: true });
  } else {
    const p = localBody.position;
    const q = localBody.quaternion;
    socket.emit('playerMoved', { x: p.x, y: p.y, z: p.z, qx: q.x, qy: q.y, qz: q.z, qw: q.w, smoothing: roundcubeSmoothing, godmode: false });
  }
}

// --- Godmode / Noclip ---
let godmode = false;
const godCamSpeed = 40;

function handleGodmode(delta) {
  let mx = 0, my = 0, mz = 0;
  if (keys['KeyW']) mz -= 1;
  if (keys['KeyS']) mz += 1;
  if (keys['KeyA']) mx -= 1;
  if (keys['KeyD']) mx += 1;
  if (keys['Space'] || keys['KeyE']) my += 1;
  if (keys['KeyQ'] || keys['ShiftLeft'] || keys['ShiftRight']) my -= 1;

  const forward = new THREE.Vector3();
  camera.getWorldDirection(forward);
  const right = new THREE.Vector3().crossVectors(forward, new THREE.Vector3(0, 1, 0)).normalize();

  camera.position.x += (right.x * mx + forward.x * (-mz)) * godCamSpeed * delta;
  camera.position.y += my * godCamSpeed * delta;
  camera.position.z += (right.z * mx + forward.z * (-mz)) * godCamSpeed * delta;

  if (keys['ArrowLeft']) camera.rotation.y += 2 * delta;
  if (keys['ArrowRight']) camera.rotation.y -= 2 * delta;
  if (keys['ArrowUp']) camera.rotation.x += 1.5 * delta;
  if (keys['ArrowDown']) camera.rotation.x -= 1.5 * delta;

  camera.rotation.z = 0;
}

// --- Debug HUD ---
let debugVisible = false;
const debugEl = document.createElement('div');
debugEl.id = 'debug-hud';
debugEl.style.cssText = 'position:absolute;top:10px;right:10px;width:300px;color:#0f0;font:12px "04b_03",Lato,sans-serif;background:rgba(0,0,0,0.8);border:2px solid #0f0;padding:10px;border-radius:8px;white-space:pre;display:none;pointer-events:none;z-index:30;';
document.body.appendChild(debugEl);

// --- Debug Projectile Visuals ---
const DEBUG_RENDER_ORDER = 999;

const debugLineGeo = new THREE.BufferGeometry();
const debugLineMat = new THREE.LineBasicMaterial({ color: 0x00ff00, depthTest: false, transparent: true, opacity: 0.8 });
const debugAimLine = new THREE.Line(debugLineGeo, debugLineMat);
debugAimLine.visible = false;
debugAimLine.renderOrder = DEBUG_RENDER_ORDER;
debugAimLine.frustumCulled = false;
scene.add(debugAimLine);

const debugArcGeo = new THREE.BufferGeometry();
const debugArcMat = new THREE.LineBasicMaterial({ color: 0xffa500, depthTest: false, transparent: true, opacity: 0.8 });
const debugArcLine = new THREE.Line(debugArcGeo, debugArcMat);
debugArcLine.visible = false;
debugArcLine.renderOrder = DEBUG_RENDER_ORDER;
debugArcLine.frustumCulled = false;
scene.add(debugArcLine);

const debugDistCanvas = document.createElement('canvas');
debugDistCanvas.width = 256; debugDistCanvas.height = 64;
const debugDistCtx = debugDistCanvas.getContext('2d');
const debugDistTex = new THREE.CanvasTexture(debugDistCanvas);
const debugDistMat = new THREE.SpriteMaterial({ map: debugDistTex, depthTest: false });
const debugDistSprite = new THREE.Sprite(debugDistMat);
debugDistSprite.scale.set(4, 1, 1);
debugDistSprite.renderOrder = DEBUG_RENDER_ORDER;
debugDistSprite.visible = false;
scene.add(debugDistSprite);

const debugCrosshair = document.createElement('div');
debugCrosshair.style.cssText = 'position:absolute;width:16px;height:16px;border:2px solid #0f0;border-radius:50%;transform:translate(-50%,-50%);pointer-events:none;z-index:9999;display:none;';
document.body.appendChild(debugCrosshair);

// --- Debug hit marker ---
const debugHitMarkerGeo = new THREE.RingGeometry(0.6, 0.9, 16);
const debugHitMarkerMat = new THREE.MeshBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.6, depthTest: false, side: THREE.DoubleSide });
const debugHitMarker = new THREE.Mesh(debugHitMarkerGeo, debugHitMarkerMat);
debugHitMarker.visible = false;
debugHitMarker.renderOrder = DEBUG_RENDER_ORDER;
debugHitMarker.frustumCulled = false;
scene.add(debugHitMarker);

// --- Debug spread cone ---
const SPREAD_HALF_ANGLE = Math.atan(0.06);
const CONE_LENGTH = 30;
const CONE_SEGMENTS = 12;
const debugConeGroup = new THREE.Group();
debugConeGroup.visible = false;
scene.add(debugConeGroup);

const coneCenterMat = new THREE.LineBasicMaterial({ color: 0x00ff00, depthTest: false });
const coneEdgeMat = new THREE.LineBasicMaterial({ color: 0x00ff00, depthTest: false, transparent: true, opacity: 0.4 });
const coneRingMat = new THREE.LineBasicMaterial({ color: 0x00ff00, depthTest: false, transparent: true, opacity: 0.3 });

const coneCenterGeo = new THREE.BufferGeometry();
const coneCenterLine = new THREE.Line(coneCenterGeo, coneCenterMat);
coneCenterLine.renderOrder = DEBUG_RENDER_ORDER;
coneCenterLine.frustumCulled = false;
debugConeGroup.add(coneCenterLine);

const coneEdgeLines = [];
for (let i = 0; i < CONE_SEGMENTS; i++) {
  const geo = new THREE.BufferGeometry();
  const line = new THREE.Line(geo, coneEdgeMat);
  line.renderOrder = DEBUG_RENDER_ORDER;
  line.frustumCulled = false;
  debugConeGroup.add(line);
  coneEdgeLines.push(line);
}

const coneRingLines = [];
for (const ringDist of [0.33, 0.66, 1.0]) {
  const geo = new THREE.BufferGeometry();
  const line = new THREE.LineLoop(geo, coneRingMat);
  line.renderOrder = DEBUG_RENDER_ORDER;
  line.frustumCulled = false;
  debugConeGroup.add(line);
  coneRingLines.push({ line, pct: ringDist });
}

function debugCheckHit(origin, aimDir) {
  let hitTarget = null;
  let hitDist = Infinity;

  for (const [id, group] of remotePlayers) {
    const toPlayer = new THREE.Vector3().subVectors(group.position, origin);
    const projDist = toPlayer.dot(aimDir);
    if (projDist < 0 || projDist > CONE_LENGTH) continue;

    const closest = origin.clone().addScaledVector(aimDir, projDist);
    const perpDist = closest.distanceTo(group.position);
    const coneRadiusAtDist = Math.tan(SPREAD_HALF_ANGLE) * projDist;
    const hitRadius = 1.5;

    if (perpDist < coneRadiusAtDist + hitRadius && projDist < hitDist) {
      hitDist = projDist;
      hitTarget = { id, group, dist: projDist, perpDist, inCenter: perpDist < hitRadius };
    }
  }
  return hitTarget;
}

function updateDebugCone(origin, aimDir, hitInfo) {
  const up = new THREE.Vector3(0, 1, 0);
  if (Math.abs(aimDir.dot(up)) > 0.99) up.set(1, 0, 0);
  const right = new THREE.Vector3().crossVectors(aimDir, up).normalize();
  const camUp = new THREE.Vector3().crossVectors(right, aimDir).normalize();

  const coneEnd = origin.clone().addScaledVector(aimDir, CONE_LENGTH);
  coneCenterLine.geometry.setFromPoints([origin, coneEnd]);

  coneCenterMat.color.setHex(hitInfo ? 0xff4444 : 0x00ff00);
  coneEdgeMat.color.setHex(hitInfo ? 0xff4444 : 0x00ff00);
  coneRingMat.color.setHex(hitInfo ? 0xff4444 : 0x00ff00);

  const coneRadius = Math.tan(SPREAD_HALF_ANGLE) * CONE_LENGTH;

  for (let i = 0; i < CONE_SEGMENTS; i++) {
    const angle = (i / CONE_SEGMENTS) * Math.PI * 2;
    const edgeEnd = coneEnd.clone()
      .addScaledVector(right, Math.cos(angle) * coneRadius)
      .addScaledVector(camUp, Math.sin(angle) * coneRadius);
    coneEdgeLines[i].geometry.setFromPoints([origin, edgeEnd]);
  }

  for (const ring of coneRingLines) {
    const ringCenter = origin.clone().addScaledVector(aimDir, CONE_LENGTH * ring.pct);
    const ringR = Math.tan(SPREAD_HALF_ANGLE) * CONE_LENGTH * ring.pct;
    const ringPts = [];
    for (let i = 0; i <= CONE_SEGMENTS; i++) {
      const angle = (i / CONE_SEGMENTS) * Math.PI * 2;
      ringPts.push(ringCenter.clone()
        .addScaledVector(right, Math.cos(angle) * ringR)
        .addScaledVector(camUp, Math.sin(angle) * ringR));
    }
    ring.line.geometry.setFromPoints(ringPts);
  }

  if (hitInfo) {
    debugHitMarker.visible = true;
    debugHitMarker.position.copy(hitInfo.group.position);
    debugHitMarker.position.y += 0.5;
    debugHitMarker.lookAt(camera.position);
    const pulse = 1.0 + Math.sin(performance.now() * 0.01) * 0.3;
    debugHitMarker.scale.setScalar(pulse);
    debugHitMarkerMat.color.setHex(hitInfo.inCenter ? 0xff0000 : 0xffaa00);
    debugHitMarkerMat.opacity = hitInfo.inCenter ? 0.7 : 0.4;
  } else {
    debugHitMarker.visible = false;
  }
}

// --- Debug front-face marker ---
const debugFrontGroup = new THREE.Group();
debugFrontGroup.visible = false;
scene.add(debugFrontGroup);

const frontArrowPts = [
  new THREE.Vector3(0, 0, -0.6),
  new THREE.Vector3(0.25, 0, -0.9),
  new THREE.Vector3(0, 0, -1.2),
  new THREE.Vector3(-0.25, 0, -0.9),
  new THREE.Vector3(0, 0, -0.6),
];
const frontArrowGeo = new THREE.BufferGeometry().setFromPoints(frontArrowPts);
const frontArrowMat = new THREE.LineBasicMaterial({ color: 0x00ffff, depthTest: false });
const frontArrow = new THREE.Line(frontArrowGeo, frontArrowMat);
frontArrow.renderOrder = DEBUG_RENDER_ORDER;
frontArrow.frustumCulled = false;
debugFrontGroup.add(frontArrow);

const frontDotGeo = new THREE.SphereGeometry(0.06, 6, 6);
const frontDotMat = new THREE.MeshBasicMaterial({ color: 0x00ffff, depthTest: false });
const frontDot = new THREE.Mesh(frontDotGeo, frontDotMat);
frontDot.position.set(0, 0, -0.55);
frontDot.renderOrder = DEBUG_RENDER_ORDER;
frontDot.frustumCulled = false;
debugFrontGroup.add(frontDot);

window.addEventListener('keydown', (e) => {
  if (chatOpen) return; // chat input handles its own keys (Enter/Esc)
  if (e.code === 'KeyT' && gameStarted && !gfxMenuOpen) {
    e.preventDefault();
    openChat();
    return;
  }
  if (e.code === 'Backquote') {
    e.preventDefault();
    debugVisible = !debugVisible;
    debugEl.style.display = debugVisible ? '' : 'none';
    gimbal.visible = debugVisible;
    debugFrontGroup.visible = debugVisible;
    if (!debugVisible) clearHoverHighlight();
  }
  if (e.code === 'F4' && gameStarted) {
    e.preventDefault();
    if (!godmode) enterGodmode(); else exitGodmode();
  }
  if (e.code === 'Escape' && gameStarted && godmode) {
    e.preventDefault();
    if (godmodeToolSelected === 'build_channel' && channelNodes.length > 0) {
      resetChannelDraft(); showToast('Channel cancelled'); // cancel in-progress channel draft, stay in godmode
    } else {
      exitGodmode(); // single press: back to normal
    }
  } else if (e.code === 'Escape' && gameStarted && !godmode) {
    e.preventDefault();
    if (gfxMenuOpen) closeGfxMenu(); else openGfxMenu();
  }
  if (e.code === 'Enter' && gameStarted && godmode && godmodeToolSelected === 'build_channel') {
    e.preventDefault();
    finishChannel();
  }
  if (e.code === 'Backspace' && gameStarted && godmode && godmodeToolSelected === 'build_channel' && channelNodes.length > 0) {
    e.preventDefault();
    channelNodes.pop();
    rebuildChannelGhost(channelNodes);
  }
  if ((e.ctrlKey || e.metaKey) && e.code === 'KeyZ' && gameStarted && godmode) {
    e.preventDefault();
    undoLastPlacement();
  }
  if (e.code === 'BracketRight') { BASE_CHAIN_LENGTH = Math.min(20, BASE_CHAIN_LENGTH + 0.5); }
  if (e.code === 'BracketLeft') { BASE_CHAIN_LENGTH = Math.max(2, BASE_CHAIN_LENGTH - 0.5); }
  if (e.code === 'KeyR' && gameStarted) {
    const isBuilding = (!godmode && inventory.length > 0 && ['block', 'wall', 'ramp', 'platform'].includes(inventory[0].type)) || (godmode && godmodeToolSelected === 'build_mode');
    if (isBuilding) {
      buildRotationSteps = (buildRotationSteps + 1) % 4;
    } else if (godmode && (godmodeToolSelected === 'spawn' || godmodeToolSelected.startsWith('pedestal') || godmodeToolSelected === 'model')) {
      ghostRotationY += Math.PI / 8;
      const ghost = getGhost();
      if (ghost) ghost.rotation.y = ghostRotationY;
    }
  }
  if (e.code === 'Comma' && playerShape === 'roundcube' && localMesh) {
    roundcubeSmoothing = Math.max(0, roundcubeSmoothing - 0.05);
    originalSmoothing = roundcubeSmoothing;
    rebuildLocalRoundcube();
  }
  if (e.code === 'Period' && playerShape === 'roundcube' && localMesh) {
    roundcubeSmoothing = Math.min(1, roundcubeSmoothing + 0.05);
    originalSmoothing = roundcubeSmoothing;
    rebuildLocalRoundcube();
  }
  if (debugVisible) {
    if (e.code === 'PageUp') {
      musicVolume = Math.min(1, musicVolume + 0.1);
      music.volume = musicVolume;
    } else if (e.code === 'PageDown') {
      musicVolume = Math.max(0, musicVolume - 0.1);
      music.volume = musicVolume;
    }
  }
});

function rebuildLocalRoundcube() {
  if (!localMesh) return;
  const oldGeo = localMesh.geometry;
  let geo = new THREE.BoxGeometry(1, 1, 1, 8, 8, 8);
  geo = smoothRoundcube(geo);
  localMesh.geometry = geo;
  oldGeo.dispose();
  const outline = localMesh.children.find(c => c.isMesh);
  if (outline) {
    const oldOutGeo = outline.geometry;
    outline.geometry = geo.clone();
    oldOutGeo.dispose();
  }
  if (localBody) {
    const pos = localBody.position.clone();
    const vel = localBody.velocity.clone();
    const angVel = localBody.angularVelocity.clone();
    const quat = localBody.quaternion.clone();
    world.removeBody(localBody);
    const isSpherePhysics = roundcubeSmoothing >= 0.75;
    localBody = new CANNON.Body({
      mass: 1,
      material: playerMaterial,
      shape: createRoundcubePhysicsShape(roundcubeSmoothing),
      linearDamping: 0.1,
      angularDamping: isSpherePhysics ? 0.6 : 0.05
    });
    localBody.collisionFilterMask = -1; // must include the ground-plane group (2)
    localBody.position.copy(pos);
    localBody.velocity.copy(vel);
    localBody.angularVelocity.copy(angVel);
    localBody.quaternion.copy(quat);
    world.addBody(localBody);
  }
}

let fpsFrames = 0, fpsTime = 0, fpsDisplay = 0;
let lastDebugHit = null;

function updateDebug(delta) {
  if (!debugVisible) {
    debugAimLine.visible = false;
    debugArcLine.visible = false;
    debugDistSprite.visible = false;
    debugCrosshair.style.display = 'none';
    debugConeGroup.visible = false;
    debugHitMarker.visible = false;
    debugFrontGroup.visible = false;
    return;
  }

  gimbal.quaternion.copy(camera.quaternion).invert();

  fpsFrames++; fpsTime += delta;
  if (fpsTime >= 0.5) { fpsDisplay = Math.round(fpsFrames / fpsTime); fpsFrames = 0; fpsTime = 0; }

  if (localBody) {
    const origin = new THREE.Vector3().copy(localBody.position).add(new THREE.Vector3(0, 0.4, 0));
    const aimDir = getAimDirection();
    const aimEnd = origin.clone().addScaledVector(aimDir, CONE_LENGTH);
    const dist = CONE_LENGTH;

    debugAimLine.geometry.setFromPoints([origin, aimEnd]);
    debugAimLine.visible = true;

    const hitInfo = debugCheckHit(origin, aimDir);
    lastDebugHit = hitInfo;

    const levelHit = raycastLevel(origin, aimDir, CONE_LENGTH);
    const hitsGround = levelHit && levelHit.distance < 5;
    const aimColor = hitInfo ? 0xff4444 : (hitsGround ? 0xff8800 : 0x00ff00);
    debugLineMat.color.setHex(aimColor);

    const mid = origin.clone().lerp(aimEnd, 0.5);
    debugDistSprite.position.copy(mid);
    debugDistSprite.visible = true;
    debugDistCtx.clearRect(0, 0, 256, 64);
    debugDistCtx.font = '22px "04b_03", Lato, sans-serif';
    debugDistCtx.textAlign = 'center';
    if (hitInfo) {
      debugDistCtx.fillStyle = '#ff4444';
      const name = playerNames.get(hitInfo.id) || 'Player';
      debugDistCtx.fillText(dist.toFixed(1) + 'm  HIT: ' + name, 128, 28);
      debugDistCtx.font = '16px "04b_03", Lato, sans-serif';
      debugDistCtx.fillStyle = hitInfo.inCenter ? '#ff0000' : '#ffaa00';
      debugDistCtx.fillText(hitInfo.inCenter ? 'CENTER' : 'SPREAD', 128, 52);
    } else if (hitsGround) {
      debugDistCtx.fillStyle = '#ff8800';
      debugDistCtx.fillText(dist.toFixed(1) + 'm  GROUND', 128, 40);
    } else {
      debugDistCtx.fillStyle = '#0f0';
      debugDistCtx.fillText(dist.toFixed(1) + 'm', 128, 40);
    }
    debugDistTex.needsUpdate = true;

    debugCrosshair.style.display = '';
    debugCrosshair.style.borderColor = hitInfo ? '#f44' : '#0f0';
    const crossNdc = isMobile ? new THREE.Vector2(0, 0) : lastMouseNDC;
    debugCrosshair.style.left = ((crossNdc.x + 1) / 2 * window.innerWidth) + 'px';
    debugCrosshair.style.top = (-(crossNdc.y - 1) / 2 * window.innerHeight) + 'px';

    const start = origin.clone().addScaledVector(aimDir, 2.5);
    const ROCKET_SPEED = 60;
    const rocketVel = new THREE.Vector3(aimDir.x * ROCKET_SPEED, aimDir.y * ROCKET_SPEED, aimDir.z * ROCKET_SPEED);

    const arcPoints = [];
    const simDuration = 3;
    for (let i = 0; i <= 30; i++) {
      const simT = (i / 30) * simDuration;
      arcPoints.push(new THREE.Vector3(
        start.x + rocketVel.x * simT,
        start.y + rocketVel.y * simT + 0.5 * -20 * simT * simT,
        start.z + rocketVel.z * simT
      ));
    }
    debugArcLine.geometry.setFromPoints(arcPoints);
    debugArcLine.visible = true;

    debugConeGroup.visible = true;
    updateDebugCone(origin, aimDir, hitInfo);

    if (localPlayer && localMesh) {
      debugFrontGroup.visible = debugVisible;
      debugFrontGroup.position.copy(localPlayer.position);
      debugFrontGroup.quaternion.copy(localMesh.quaternion);
    }
  }

  if (godmode) {
    const c = camera.position;
    const r = camera.rotation;
    debugEl.textContent =
      `=== GODMODE (F4 to exit) ===\n` +
      `FPS:    ${fpsDisplay}\n` +
      `CamPos: (${c.x.toFixed(2)}, ${c.y.toFixed(2)}, ${c.z.toFixed(2)})\n` +
      `CamRot: (${r.x.toFixed(2)}, ${r.y.toFixed(2)}, ${r.z.toFixed(2)})\n` +
      `WASD: fly  E/Q/Shift: up/down\n` +
      `Tool:  ${godmodeToolSelected}\n` +
      `Click: place/remove ${godmodeToolSelected}\n` +
      `Spawns: ${SPAWN_POINTS.length}  Pedestals: ${pedestalMeshes.length}\n` +
      `Chain:  ${chainLength.toFixed(1)} [ / ] to adjust`;
    return;
  }

  if (!localBody) return;
  const v = localBody.velocity;
  const hSpeed = Math.sqrt(v.x * v.x + v.z * v.z);
  const totalSpeed = Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  const sprinting = (keys['ShiftLeft'] || keys['ShiftRight']) && !sprintExhausted;
  const p = localBody.position;
  const myScore = allScores[selfId] || 0;

  const dbgNdc = isMobile ? new THREE.Vector2(0,0) : lastMouseNDC;
  const dbgRay = new THREE.Raycaster();
  dbgRay.setFromCamera(dbgNdc, camera);
  const dbgDir = dbgRay.ray.direction;
  const dbgItem = inventory.length > 0 ? inventory[0].type : 'none';
  const dbgAmmo = inventory.length > 0 && inventory[0].ammo > 0 ? inventory[0].ammo : '';

  debugEl.textContent =
    `FPS:   ${fpsDisplay}\n` +
    `Speed: ${hSpeed.toFixed(2)} / ${sprinting ? SPRINT_SPEED : MAX_SPEED}\n` +
    `Vel:   (${v.x.toFixed(2)}, ${v.y.toFixed(2)}, ${v.z.toFixed(2)}) |${totalSpeed.toFixed(2)}|\n` +
    `Pos:   (${p.x.toFixed(1)}, ${p.y.toFixed(1)}, ${p.z.toFixed(1)})\n` +
    `State: ${sprinting ? 'SPRINT' : 'walk'}${sprintExhausted ? ' (exhausted)' : ''}${checkGrounded() ? '' : ' (air)'}\n` +
    `Sprint:${sprintStamina.toFixed(1)}/${SPRINT_DURATION}s\n` +
    `Jump:  ${isChargingJump ? '>' + '='.repeat(Math.round(jumpCharge * 5)) + ' ' + jumpCharge.toFixed(1) + 'x' : (jumpCooldownTimer > 0 ? 'CD ' + jumpCooldownTimer.toFixed(1) + 's' : 'ready')}\n` +
    `--- AIM ---\n` +
    `Dir:   (${dbgDir.x.toFixed(2)}, ${dbgDir.y.toFixed(2)}, ${dbgDir.z.toFixed(2)})\n` +
    `Item:  ${dbgItem}${dbgAmmo ? ' [' + dbgAmmo + ']' : ''}\n` +
    `Target:${debugHitMarker.visible ? ' ' + (playerNames.get(lastDebugHit?.id) || 'Player') + ' (' + (lastDebugHit?.inCenter ? 'CENTER' : 'SPREAD') + ' ' + lastDebugHit?.dist.toFixed(1) + 'm)' : ' none'}\n` +
    `Bullets: ${activeBullets.length}  Rockets: ${activeRockets.length}${rocketCooldownTimer > 0 ? '  CD:' + rocketCooldownTimer.toFixed(1) + 's' : ''}\n` +
    `Tag CD:${tagCooldownTimer > 0 ? tagCooldownTimer.toFixed(1) + 's' : 'none'}\n` +
    `Score: ${myScore}  ${holderID === selfId ? '[IT]' : ''}\n` +
    `Chain: ${chainLength.toFixed(1)} [ / ] to adjust\n` +
    (playerShape === 'roundcube' ? `Round: ${roundcubeSmoothing.toFixed(2)} (<, >)\n` : '') +
    `Music: ${Math.round(musicVolume * 100)}% (PgUp/PgDn)\n` +
    `F4: godmode`;
}

// --- Menu background / live birdseye spectator ---
// In the menu the full-screen scene stays BLACK. The selected map is previewed
// in the selector panel instead. When a game is actually in progress we render a
// dimmed birdseye that smoothly glides between the live players.
const _blackBg = new THREE.Color(0x000000);
let spectateTargetId = null;
let spectateHold = 0;
const SPECTATE_HOLD_TIME = 6;
const _specDesired = new THREE.Vector3();
const _specLook = new THREE.Vector3();
const _specLookCurrent = new THREE.Vector3();
let _specLookInit = false;

function updateMenuBackground(delta) {
  const ids = [...remotePlayers.keys()];
  const active = ids.length > 0;

  // Black unless a game is on; only show the level + players during spectating.
  if (scene.background !== (active ? skyTex : _blackBg)) scene.background = active ? skyTex : _blackBg;
  if (currentLevelObj) currentLevelObj.visible = active;
  for (const g of remotePlayers.values()) g.visible = active;
  // Lighter overlay while spectating so the action shows through the dim.
  if (menuOverlay) menuOverlay.style.background = active ? 'rgba(0,0,0,0.5)' : 'rgba(0,0,0,0.85)';

  if (!active) { spectateTargetId = null; _specLookInit = false; return; }

  // Cycle the focused player every few seconds.
  spectateHold -= delta;
  if (!spectateTargetId || !remotePlayers.has(spectateTargetId) || spectateHold <= 0) {
    const idx = ids.indexOf(spectateTargetId);
    spectateTargetId = ids[(idx + 1) % ids.length];
    spectateHold = SPECTATE_HOLD_TIME;
  }
  const target = remotePlayers.get(spectateTargetId);
  if (!target) return;

  // Moderate-distance birdseye that slowly arcs around the focused player; the
  // camera lerps toward the target each frame so switching players glides over.
  const t = performance.now() / 1000;
  const angle = t * 0.2;
  const dist = 16, height = 10;
  _specDesired.set(
    target.position.x + Math.cos(angle) * dist,
    target.position.y + height,
    target.position.z + Math.sin(angle) * dist
  );
  const a = 1 - Math.exp(-1.5 * delta); // frame-rate independent smoothing
  camera.position.lerp(_specDesired, a);
  _specLook.copy(target.position);
  if (!_specLookInit) { _specLookCurrent.copy(_specLook); _specLookInit = true; }
  _specLookCurrent.lerp(_specLook, a);
  camera.lookAt(_specLookCurrent);
}

// --- Main loop ---
const PHYSICS_STEP = 1 / 60;

function animate() {
  requestAnimationFrame(animate);
  const rawDelta = clock.getDelta();
  const delta = Math.min(rawDelta, 0.05);

  const isBuilding = (!godmode && inventory.length > 0 && ['block', 'wall', 'ramp', 'platform'].includes(inventory[0].type)) || (godmode && godmodeToolSelected === 'build_mode');

  if (!gameStarted) {
    updateMenuBackground(delta);
  }

  if (gameStarted && localBody) {
    if (godmode) {
      handleGodmode(delta);
      // Spin spawn markers
      for (const m of spawnMarkers) {
        m.rotation.y += delta * 1.5;
      }
    } else {
      handleMovement(delta);
      while (pendingImpulses.length > 0) {
        const imp = pendingImpulses.shift();
        localBody.wakeUp();
        localBody.position.y += imp.popY;
        localBody.velocity.x += imp.dir.x * imp.force;
        localBody.velocity.y = Math.max(localBody.velocity.y, 0) + imp.dir.y * imp.force;
        localBody.velocity.z += imp.dir.z * imp.force;
        const hSpd = Math.sqrt(localBody.velocity.x ** 2 + localBody.velocity.z ** 2);
        speedCapCurrent = Math.max(speedCapCurrent, hSpd);
      }
      updateGroundPlane(localBody);
      if (levelLoaded) world.step(PHYSICS_STEP, delta, 3);
      resolveWallCollisions(localBody);
      syncMeshToBody(localPlayer, localMesh, localBody);
    }

    if (isGrappling && localPlayer) {
      if (!grappleLine) {
        const mat = new THREE.LineBasicMaterial({ color: 0x44ff44, linewidth: 2 });
        const geo = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3()]);
        grappleLine = new THREE.Line(geo, mat);
        scene.add(grappleLine);
      }
      grappleLine.visible = true;
      grappleLine.geometry.setFromPoints([localPlayer.position, grappleTarget]);
    } else if (grappleLine) {
      grappleLine.visible = false;
    }

    // Player item ghosting
    if (localPlayer) {
      const item = isBuilding ? (godmode ? godmodeBuildType : inventory[0].type) : (inventory.length > 0 ? inventory[0].type : null);
      if (godmode && (godmodeToolSelected === 'build_bridge' || godmodeToolSelected === 'build_teleporter' || godmodeToolSelected === 'build_channel')) {
        playerGhost.visible = false;
        buildGrid.visible = false;
        groundGrid.visible = false;
        buildGhost.visible = false;
        // bridge/teleporter/channel ghosts are driven by updateGodmodeHover
      } else if (['mines', 'launch_pad', 'boost_pad'].includes(item)) {
        buildGrid.visible = false;
        groundGrid.visible = false;
        buildGhost.visible = false;
        if (bridgeGhost) bridgeGhost.visible = false;
        hoverRaycaster.setFromCamera(lastMouseNDC, camera);
        const hits = hoverRaycaster.intersectObjects(levelMeshes, false);
        if (hits.length > 0) {
          const pt = hits[0].point;
          const dist = localPlayer.position.distanceTo(pt);
          playerGhost.position.set(pt.x, pt.y + 0.1, pt.z);
          playerGhost.visible = true;
          playerGhost.material.color.setHex(dist <= 10 ? 0x4488ff : 0xff3333);
        } else playerGhost.visible = false;
      } else if (['block', 'wall', 'ramp', 'platform'].includes(item)) {
        playerGhost.visible = false;
        buildGrid.visible = true;
        groundGrid.visible = true;
        if (bridgeGhost) bridgeGhost.visible = false;

        const px = Math.round((godmode ? camera.position.x : localPlayer.position.x) / 4) * 4;
        const py = godmode ? buildPlaneY : Math.round(localPlayer.position.y / 4) * 4;
        const pz = Math.round((godmode ? camera.position.z : localPlayer.position.z) / 4) * 4;
        buildGrid.position.set(px, py, pz);
        groundGrid.position.set(px, py, pz);

        const distToGrid = camera.position.distanceTo(groundGrid.position);
        const opacity = 1.0 - THREE.MathUtils.smoothstep(50, 150, distToGrid);
        groundGrid.material.opacity = opacity * 0.6;
        buildGrid.material.opacity = opacity * 0.8;

        hoverRaycaster.setFromCamera(lastMouseNDC, camera);
        const hits = hoverRaycaster.intersectObjects([...levelMeshes, ...worldBuilds.map(b => b.mesh)], false);

        let targetPt;
        if (godmode) {
          const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), -py);
          targetPt = new THREE.Vector3();
          if (!hoverRaycaster.ray.intersectPlane(plane, targetPt)) {
            targetPt = hoverRaycaster.ray.origin.clone().add(hoverRaycaster.ray.direction.multiplyScalar(buildPlacementDistance));
          }
        } else {
          if (hits.length > 0 && hits[0].distance <= buildPlacementDistance) {
            const pt = hits[0].point;
            const norm = hits[0].face ? hits[0].face.normal.clone() : new THREE.Vector3(0,1,0);
            const worldMatrix = new THREE.Matrix3().getNormalMatrix(hits[0].object.matrixWorld);
            norm.applyMatrix3(worldMatrix).normalize();
            targetPt = new THREE.Vector3(pt.x + norm.x * 0.1, pt.y + norm.y * 0.1, pt.z + norm.z * 0.1);
          } else {
            targetPt = hoverRaycaster.ray.origin.clone().add(hoverRaycaster.ray.direction.multiplyScalar(buildPlacementDistance));
          }
        }

        buildGhost.visible = true;
        bgBlock.visible = item === 'block';
        bgWall.visible = item === 'wall';
        bgRamp.visible = item === 'ramp';
        bgPlatform.visible = item === 'platform';

        const cx = Math.floor(targetPt.x / 4) * 4 + 2;
        const cy = Math.floor(targetPt.y / 4) * 4 + 2;
        const cz = Math.floor(targetPt.z / 4) * 4 + 2;

          let finalX = cx, finalY = cy, finalZ = cz;
          let rotY = buildRotationSteps * (Math.PI / 2);
          let rotX = 0;

          if (item === 'wall') {
            if (buildRotationSteps === 0) finalZ -= 2; else if (buildRotationSteps === 1) finalX -= 2; else if (buildRotationSteps === 2) finalZ += 2; else if (buildRotationSteps === 3) finalX += 2;
          } else if (item === 'platform') {
            finalY -= 1.5;
          }

          if (dragBuildLock) {
            if (dragBuildLock.axis === 'x') finalX = dragBuildLock.value;
            if (dragBuildLock.axis === 'y') finalY = dragBuildLock.value;
            if (dragBuildLock.axis === 'z') finalZ = dragBuildLock.value;
          }

          buildGhost.position.set(finalX, finalY, finalZ);
          buildGhost.rotation.set(rotX, rotY, 0);
          buildTarget = { x: finalX, y: finalY, z: finalZ, ry: rotY, rx: rotX };

          let overlap = false;
          for (const b of worldBuilds) {
            const isSamePos = b.mesh.position.distanceTo(buildGhost.position) < 0.1;
            const isSameType = b.mesh.userData.type === item;
            const isSameRot = Math.abs(b.mesh.rotation.y - buildGhost.rotation.y) < 0.1 && Math.abs(b.mesh.rotation.x - buildGhost.rotation.x) < 0.1;
            if (isSamePos && isSameType && isSameRot) { overlap = true; break; }
          }
          
          buildCanPlace = !overlap;
          setGhostColor(buildGhost, buildCanPlace);

          if (isDraggingBuild && buildCanPlace) {
            const cellKey = `${finalX},${finalY},${finalZ}`;
            if (cellKey !== lastBuiltCell) {
              lastBuiltCell = cellKey;
              const bType = godmode ? godmodeBuildType : item;
              socket.emit('placeBuild', { type: bType, ...buildTarget });
              if (!godmode) {
                useAmmo();
                if (inventory.length === 0 || inventory[0].type !== bType) isDraggingBuild = false;
              }
            }
          }
      } else if (item === 'bridge_gun' && !godmode) {
        playerGhost.visible = false;
        buildGrid.visible = false;
        groundGrid.visible = false;
        buildGhost.visible = false;

        hoverRaycaster.setFromCamera(lastMouseNDC, camera);
        const hits = hoverRaycaster.intersectObjects([...levelMeshes, ...worldBuilds.map(b => b.mesh)], false);
        if (hits.length > 0) {
          const targetPt = hits[0].point;
          const origin = new THREE.Vector3().copy(localPlayer.position).add(new THREE.Vector3(0, -0.4, 0));
          const target = targetPt.clone();
          let dist = origin.distanceTo(target);
          if (dist > 100) {
            dist = 100;
            target.copy(origin).add(new THREE.Vector3().subVectors(target, origin).normalize().multiplyScalar(100));
          }
          const mid = origin.clone().lerp(target, 0.5);
          const dir = new THREE.Vector3().subVectors(target, origin).normalize();

          bridgeGhost.scale.set(1, 1, dist);
          bridgeGhost.position.copy(mid);
          bridgeGhost.rotation.order = 'YXZ';
          bridgeGhost.rotation.set(-Math.asin(dir.y), Math.atan2(dir.x, dir.z), 0);
          bridgeGhost.visible = true;
        } else {
          if (bridgeGhost) bridgeGhost.visible = false;
        }
      } else {
        playerGhost.visible = false;
        buildGrid.visible = false;
        groundGrid.visible = false;
        buildGhost.visible = false;
        if (bridgeGhost) bridgeGhost.visible = false;
      }
    } else {
      if (playerGhost && playerGhost.visible) playerGhost.visible = false;
      if (buildGrid && buildGrid.visible) buildGrid.visible = false;
      if (groundGrid && groundGrid.visible) groundGrid.visible = false;
      if (buildGhost && buildGhost.visible) buildGhost.visible = false;
      if (bridgeGhost && bridgeGhost.visible) bridgeGhost.visible = false;
    }

    // Teleport logic
    if (teleporterCooldownTimer > 0) teleporterCooldownTimer -= delta;
    if (localPlayer && localBody) {
      for (const wt of worldTeleporters) {
        const distA = localPlayer.position.distanceTo(wt.a);
        const distB = localPlayer.position.distanceTo(wt.b);
        if ((distA < 1.5 || distB < 1.5) && teleporterCooldownTimer <= 0) {
          if (distA < 1.5) {
            localBody.position.set(wt.b.x, wt.b.y + 1.5, wt.b.z);
            playWorldSound(boostSound, wt.b, 1.0);
          } else {
            localBody.position.set(wt.a.x, wt.a.y + 1.5, wt.a.z);
            playWorldSound(boostSound, wt.a, 1.0);
          }
          teleporterCooldownTimer = 1.5;
        }
      }
    }
  } // End of local physics block

  // --- WORLD ENTITY UPDATES (Always run, even in main menu) ---

    for (const wt of worldTeleporters) {
      for (const pad of [wt.a, wt.b]) {
        for (let i = 0; i < 3; i++) {
          const ang = Math.random() * Math.PI * 2;
          const rad = 0.45 + Math.random() * 0.35;
          const ox = Math.cos(ang) * rad, oz = Math.sin(ang) * rad;
          // bright cyan-white core spark, thin and fast-rising
          const cool = Math.random() < 0.5;
          const r = cool ? 0.45 : 0.8, g = cool ? 0.85 : 0.95, b = 1.0;
          spawnParticle(pad.x + ox, pad.y + Math.random() * 0.15, pad.z + oz, ox * 0.6, 2.8 + Math.random() * 2.8, oz * 0.6, r, g, b, 0.95, 0.4 + Math.random() * 0.3, 0.3 + Math.random() * 0.2, 0);
        }
      }
    }

    // Machine gun bullets
    for (let i = activeBullets.length - 1; i >= 0; i--) {
      const b = activeBullets[i];
      b.life -= delta;
      b.pos.addScaledVector(b.velocity, delta);
      b.mesh.position.copy(b.pos);

      let hit = false;
      const moveDist = b.velocity.length() * delta;
      if (b.pos.y < 0 || raycastLevel(b.pos, b.velocity.clone().normalize(), moveDist + 0.1)) hit = true;

      if (!hit && b.owner === selfId) {
        for (const [id, group] of remotePlayers) {
          if (group.position.distanceTo(b.pos) < 1.5) { hit = true; socket.emit('machinegunHit', { targetId: id, dir: b.velocity.clone().normalize() }); break; }
        }
      }
      if (!hit && b.owner !== selfId && localPlayer && localPlayer.position.distanceTo(b.pos) < 1.5) hit = true;

      if (hit || b.life <= 0) { scene.remove(b.mesh); activeBullets.splice(i, 1); }
    }

    // Rockets
    for (let i = activeRockets.length - 1; i >= 0; i--) {
      const r = activeRockets[i];
      r.life -= delta;
      r.velocity.y += -8 * delta; // Gravity
      r.pos.addScaledVector(r.velocity, delta);
      r.mesh.position.copy(r.pos);
      r.mesh.lookAt(new THREE.Vector3().copy(r.pos).add(r.velocity));

      if (Math.random() < 0.8) {
        spawnTrailParticle(r.pos.x, r.pos.y, r.pos.z);
      }

      const moveDist = r.velocity.length() * delta;
      let hit = false;
      if (r.pos.y < 0 || raycastLevel(r.pos, r.velocity.clone().normalize(), moveDist + 0.5)) hit = true;
      if (!hit) {
        const groundHit = raycastLevel(r.pos, new THREE.Vector3(0, -1, 0), 0.5);
        if (groundHit) hit = true;
      }
      for (const [id, group] of remotePlayers) if (id !== r.owner && group.position.distanceTo(r.pos) < 1.2) hit = true;
      if (selfId !== r.owner && localPlayer && localPlayer.position.distanceTo(r.pos) < 1.2) hit = true;

      if (hit || r.life <= 0) {
        if (hit && r.owner === selfId) socket.emit('triggerExplosion', { x: r.pos.x, y: r.pos.y, z: r.pos.z });
        scene.remove(r.mesh);
        activeRockets.splice(i, 1);
      }
    }

    // Update GPU particles (explosions + trails)
    updateParticles(delta);

    // Mines
    if (localPlayer) {
      for (const m of worldMines) if (localPlayer.position.distanceTo(m.pos) < 1.2) socket.emit('triggerMine', m.id);
    }

    // Update coins
    for (const c of activeCoinsList) {
      // Rest on the actual terrain beneath each coin (the shared ground plane
      // only follows the local player, so without this coins all settle on one
      // height). Cheap: ≤15 coins, gone after 15s.
      const cp = c.body.position;
      const groundHit = raycastLevel(new THREE.Vector3(cp.x, cp.y + 0.6, cp.z), new THREE.Vector3(0, -1, 0), 80, false);
      if (groundHit) {
        const restY = groundHit.point.y + 0.06;
        if (cp.y < restY) {
          cp.y = restY;
          if (c.body.velocity.y < 0) c.body.velocity.y *= -0.3; // gentle bounce
          c.body.velocity.x *= 0.6; c.body.velocity.z *= 0.6;   // ground friction
        }
      }
      c.mesh.position.copy(c.body.position);
      c.mesh.quaternion.copy(c.body.quaternion);
      if (c.collectTimer > 0) c.collectTimer -= delta;
      if (c.collectTimer <= 0 && localPlayer) {
        if (localPlayer.position.distanceTo(c.mesh.position) < 1.5) {
          c.collectTimer = 999;
          socket.emit('collectCoin', c.id);
        }
      }
    }

    for (const ped of pedestalMeshes) {
      const crystal = ped.children.find(c => c.userData.isCrystal);
      if (crystal && crystal.visible) {
        crystal.rotation.y += delta * 2;
        crystal.position.y = 1.2 + Math.sin(Date.now() * 0.003 + ped.position.x) * 0.1;

        if (!godmode && localBody && inventory.length < MAX_INVENTORY) {
          const dx = localBody.position.x - ped.position.x;
          const dy = localBody.position.y - ped.position.y;
          const dz = localBody.position.z - ped.position.z;
          if (Math.sqrt(dx * dx + dy * dy + dz * dz) < 1.8) {
            crystal.visible = false; // Optimistically hide it
            socket.emit('pickupItem', ped.userData.pedestalId);
          }
        }
      }
    }

  if (gameStarted && localBody) {

    if (checkGrounded() || localBody.velocity.y >= 0) {
      airTime = 0;
    } else {
      airTime += delta;
    }
    if (airTime > 10) {
      const rsp = randomSpawn();
      localBody.position.set(rsp.x, rsp.y + PLAYER_RADIUS, rsp.z);
      localBody.velocity.set(0, 0, 0);
      localBody.angularVelocity.set(0, 0, 0);
      airTime = 0;
    }
  }

  // --- Remote player interpolation (Always run, even in main menu) ---

    for (const [id, target] of remoteTargets) {
      const group = remotePlayers.get(id);
      const mesh = remoteMeshes.get(id);
      if (group && mesh) {
        // Lift the visual so the cube (and its cel-shade hull, when shown) rests
        // on top of the floor instead of clipping in — same offset as the local
        // player, derived from the networked smoothing and outline visibility.
        const rOff = (0.5 - physHalfFromSmoothing(mesh.userData.smoothing)) + outlineLift(mesh);
        group.position.x += (target.x - group.position.x) * 0.3;
        group.position.y += (target.y + rOff - group.position.y) * 0.3;
        group.position.z += (target.z - group.position.z) * 0.3;
        if (target.qx !== undefined) {
          mesh.quaternion.slerp(new THREE.Quaternion(target.qx, target.qy, target.qz, target.qw), 0.3);
        }
        if (target.smoothing !== undefined && mesh.userData.smoothing !== undefined && mesh.userData.smoothing !== target.smoothing) {
          mesh.userData.smoothing = target.smoothing;
          const oldGeo = mesh.geometry;
          let geo = new THREE.BoxGeometry(1, 1, 1, 8, 8, 8);
          geo = smoothRoundcube(geo, target.smoothing);
          mesh.geometry = geo;
          oldGeo.dispose();
          const outline = mesh.children.find(c => c.isMesh);
          if (outline) {
            const oldOutGeo = outline.geometry;
            outline.geometry = geo.clone();
            oldOutGeo.dispose();
          }
        }

        const isGhost = !!target.godmode;
        const currentlyGhost = !!mesh.userData.isGhost;
        if (isGhost !== currentlyGhost) {
          mesh.userData.isGhost = isGhost;
          mesh.material.transparent = true;
          mesh.material.opacity = isGhost ? 0.3 : 1.0;
          mesh.castShadow = !isGhost;
          const outline = mesh.children.find(c => c.isMesh);
          if (outline) {
            outline.material.transparent = true;
            outline.material.opacity = isGhost ? 0.15 : 1.0;
          }
          for (const child of group.children) {
            if (child.isSprite) {
              child.material.opacity = isGhost ? 0.3 : 1.0;
              child.material.transparent = true;
            }
          }
        }
      }
    }

  if (gameStarted && localBody) {

    // Pads
    if (localPlayer && localBody) {
      for (const p of worldPads) {
        if (localPlayer.position.distanceTo(p.pos) < 1.5) {
          if (p.type === 'launch_pad' && localBody.velocity.y < JUMP_IMPULSE * 2) {
             localBody.velocity.y = JUMP_IMPULSE * 4;
             playRandomJumpSound(localBody.position);
          } else if (p.type === 'boost_pad') {
             const hSpeed = Math.sqrt(localBody.velocity.x**2 + localBody.velocity.z**2);
             if (hSpeed < SPRINT_SPEED * 1.5) {
                 const boostForce = SPRINT_SPEED * 2.5;
                 localBody.velocity.set(p.dx * boostForce, 5, p.dz * boostForce);
                 speedCapCurrent = Math.max(speedCapCurrent, boostForce);
                 playWorldSound(boostSound, localBody.position, 1.0);
             }
          }
        }
      }
    }

    updateCamera(delta);
    sendPosition();
    updateDebug(delta);

    // Tag strobe effect
    updateTagStrobe();

    // Crown scaling
    updateCrowns();

    // Meters
    updateMeters();

    // Tab scoreboard
    if (tabHeld) {
      scoreboardEl.style.display = 'block';
      updateScoreboard();
    } else {
      scoreboardEl.style.display = 'none';
    }

    sunLight.position.set(camera.position.x + 80, camera.position.y + 150, camera.position.z + 60);
    sunLight.target.position.copy(camera.position);

    checkInactivity();
  }

  // Update player animation mixers
  for (const [group, mixer] of playerAnimMixers) {
    mixer.update(delta);
  }

  // Switch local player between walk/idle, face movement, scale anim speed
  if (localPlayer && localPlayer.userData.animations && localBody) {
    const vx = localBody.velocity.x, vz = localBody.velocity.z;
    const speed = Math.sqrt(vx * vx + vz * vz);
    const wantAnim = speed > 1.5 ? 'walk' : 'idle';
    const mixer = playerAnimMixers.get(localPlayer);
    if (mixer) {
      if (localPlayer.userData.currentAnim !== wantAnim) {
        const oldClip = localPlayer.userData.animations[localPlayer.userData.currentAnim];
        const newClip = localPlayer.userData.animations[wantAnim];
        if (newClip) {
          if (oldClip) mixer.clipAction(oldClip).fadeOut(0.2);
          const action = mixer.clipAction(newClip).reset().fadeIn(0.2);
          action.play();
          localPlayer.userData.currentAnim = wantAnim;
        }
      }
      // Scale walk animation speed with movement speed
      if (wantAnim === 'walk') {
        const walkClip = localPlayer.userData.animations['walk'];
        if (walkClip) {
          mixer.clipAction(walkClip).timeScale = Math.max(0.5, speed / 9);
        }
      }
    }
    // Rotate rat pivot to face movement direction
    if (speed > 1.5 && localPlayer.userData.ratPivot) {
      const targetAngle = Math.atan2(vx, vz);
      const pivot = localPlayer.userData.ratPivot;
      let diff = targetAngle - pivot.rotation.y;
      while (diff > Math.PI) diff -= Math.PI * 2;
      while (diff < -Math.PI) diff += Math.PI * 2;
      pivot.rotation.y += diff * Math.min(1, delta * 10);
    }
  }

  renderer.render(scene, camera);
}
animate();
