extends RefCounted

## What a parametric model exposes, and how you grab it.
##
## A model declares a flat list of parameters. That one table drives the network
## payload, the god-menu readout, the save file and the handles, so adding a
## parameter is one line rather than four edits that can disagree.
##
## Entries are {key, label, min, max, step, default, unit}. The ranges MUST
## match server/parametrics.js SPECS, which is checked by _probe/spec_parity.gd
## rather than trusted -- the server clamps everything it is sent, so a client
## whose ranges drifted would draw handles that quietly refuse to move.
##
## A HANDLE is the spatial half. Most parameters are a distance from somewhere
## in some direction, which is exactly what you want to grab:
##
##   origin + axis * value * scale
##
## is where the grab sphere sits, and dragging it inverts that expression to get
## the value back. Nodes are the exception: they are positions, not distances,
## so they drag on a plane instead of along a line.

const NODE_HANDLE := -2   ## `node` on a param handle, meaning "not a node"


## One parameter's entry, or {} if the model has no such key.
static func entry(spec: Array, key: String) -> Dictionary:
	for e in spec:
		if str((e as Dictionary).get("key", "")) == key:
			return e
	return {}


static func defaults(spec: Array) -> Dictionary:
	var out := {}
	for e in spec:
		out[str((e as Dictionary)["key"])] = float((e as Dictionary)["default"])
	return out


## Every key the spec names, clamped; anything else dropped. Same contract as
## the server's sanitizeParams, so a record survives a round trip unchanged.
static func sanitize(spec: Array, params: Dictionary) -> Dictionary:
	var out := {}
	for e in spec:
		var d: Dictionary = e
		var key := str(d["key"])
		var v := float(params.get(key, d["default"]))
		out[key] = clampf(v, float(d["min"]), float(d["max"]))
	return out


static func value(spec: Array, params: Dictionary, key: String, fallback := 0.0) -> float:
	var e := entry(spec, key)
	if e.is_empty():
		return fallback
	return clampf(float(params.get(key, e["default"])), float(e["min"]), float(e["max"]))


static func flag(spec: Array, params: Dictionary, key: String) -> bool:
	return value(spec, params, key) >= 0.5


static func param(key: String, label: String, lo: float, hi: float, def: float,
		step := 0.1, unit := "m") -> Dictionary:
	return {
		"key": key, "label": label, "min": lo, "max": hi,
		"default": def, "step": step, "unit": unit,
	}


# --- Handles -----------------------------------------------------------------

## A parameter grabbed along a fixed direction. `scale` is how far the grab sits
## per unit of value: a thickness handle rides the outer face, so it moves half
## a metre per metre of thickness.
static func axis_handle(spec: Array, params: Dictionary, key: String,
		origin: Vector3, axis: Vector3, scale := 1.0) -> Dictionary:
	var e := entry(spec, key)
	if e.is_empty():
		return {}
	var v := value(spec, params, key)
	var dir := axis.normalized()
	return {
		"key": key, "label": str(e["label"]), "node": NODE_HANDLE,
		"origin": origin, "axis": dir, "scale": scale,
		"value": v, "min": float(e["min"]), "max": float(e["max"]),
		"step": float(e["step"]), "unit": str(e["unit"]),
		"pos": origin + dir * v * scale,
	}


## A node grabbed on the ground plane. No axis: it follows the cursor.
static func node_handle(index: int, at: Vector3) -> Dictionary:
	return {
		"key": "", "label": "NODE", "node": index,
		"origin": at, "axis": Vector3.ZERO, "scale": 1.0,
		"value": 0.0, "min": 0.0, "max": 0.0, "step": 0.0, "unit": "",
		"pos": at,
	}


## Invert the placement expression: where along the axis did the drag land.
static func value_at(handle: Dictionary, point: Vector3) -> float:
	var scale := float(handle.get("scale", 1.0))
	if absf(scale) < 1e-6:
		return float(handle.get("value", 0.0))
	var along := (point - (handle["origin"] as Vector3)).dot(handle["axis"])
	var v := along / scale
	var step := float(handle.get("step", 0.0))
	if step > 0.0:
		v = roundf(v / step) * step
	return clampf(v, float(handle["min"]), float(handle["max"]))
