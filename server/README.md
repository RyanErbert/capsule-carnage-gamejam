# friendslop-gamejam

A simple 3D multiplayer web game where players move around, jump, and interact on a shared ground plane. Desktop players appear as boxes, mobile players appear as balls.

## Features

- **Multiplayer** — connect from multiple browsers via WebSockets
- **Movement** — WASD with acceleration and friction, Shift to sprint
- **Jumping** — Space to jump, land on other players' heads
- **Camera** — ball-on-a-chain style, trails behind your movement
- **Mobile support** — virtual joystick and jump button, tilt-friendly sphere player
- **Name entry** — choose a name on join, displayed above your head
- **Collisions** — AABB collision with platforming (jump on each other)
- **Debug HUD** — press ` for speed/position/FPS metrics, `[`/`]` to adjust camera distance

## Tech Stack

- **Three.js** (r128) — 3D rendering via CDN
- **Node.js + Express** — static file server
- **Socket.io** — real-time multiplayer communication
- No build tools — plain HTML/JS

## Run locally

```bash
npm install
npm start
```

Open `http://localhost:3001` in two browser tabs. Other devices on your network can connect via your local IP.

## Deploy

Ready for Render, Railway, or any Node.js host. The server reads `process.env.PORT` automatically.


Play it here!

https://friendslop-gamejam.onrender.com/
