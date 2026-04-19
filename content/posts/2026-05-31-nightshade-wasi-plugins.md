+++
title = "Hosting WebAssembly plugins inside a Rust game engine"
tags = ["rust", "wasm", "wasi", "plugins", "wasmtime", "nightshade"]
categories = ["nightshade"]
excerpt = "Nightshade hosts user-supplied WASM plugins through Wasmtime. The host and guest exchange messages as serialized enum values rather than going through generated bindings."
draft = true
+++

A game that wants third-party mods has a problem: arbitrary user code shouldn't be able to read your save files, open network sockets, or panic the engine into a crashed state. The conventional answers are either to severely constrain what mods can do (and accept a small modding surface) or to trust users not to be hostile (and accept the risk).

Nightshade's `plugins` and `plugin_runtime` features give a third option. User-supplied WebAssembly modules load at runtime through Wasmtime, with their own linear memory, isolated from the host. Plugins can be written in any language that targets WASM, and only see the engine surface the host explicitly exposes.

The plugin host lives at [`plugin_runtime/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/plugin_runtime). The shared types are at [`plugin.rs`](https://github.com/matthewjberger/nightshade/blob/main/crates/nightshade/src/plugin.rs).

## The boundary is two enums

Communication between host and guest goes through serialized enum messages, not generated bindings. The plugin emits `EngineCommand` values (log a message, spawn a primitive at a position, set an entity's transform, request a prefab load, ask for an entity's current rotation) by writing serialized bytes into a memory region the host can read. The host emits `EngineEvent` values (a key was pressed, the mouse moved, an async load completed) the same direction.

Both enums live in the shared `plugin.rs` so the plugin and host are guaranteed to agree on the message shape. Adding a new operation means adding a variant on one of the enums and handling it on both sides.

## What the host does

`PluginRuntime` owns a `wasmtime::Engine` and a list of loaded plugin instances. Each plugin has its own `Store<PluginState>`, its own linear memory, and an `EntityMapping` that translates between plugin-scoped entity IDs (which the plugin owns) and engine-scoped IDs (which the engine owns). The plugin can't see engine entities it didn't spawn, which keeps mods from interfering with each other or with the host's own state.

Per-frame, the runtime calls each plugin's update export, drains the command queue the plugin produced, executes the commands against the world, and pushes any pending events into the plugin's event queue for the next frame.

Async operations (file reads, prefab loads, texture loads) go through a separate channel: the plugin sends a command with a `request_id`, the host eventually completes the work, and the result is sent back as an event tagged with the matching id. The plugin doesn't block waiting for results.

## What plugins can do

The current `EngineCommand` enum covers the operations a mod typically needs:

- Log a string
- Spawn primitives (cube, sphere, cylinder, cone, plane) at a position
- Despawn an entity
- Set or query an entity's position, scale, rotation
- Set an entity's material or color
- Request a file read, texture load, or prefab load (async, returns via event)

What plugins can't do: direct GPU access, arbitrary file system or network access, calls into the engine's internals beyond what the enum exposes. A plugin that misbehaves can corrupt its own state but can't reach into the host.

## What plugins look like

A minimal plugin uses the guest-side API in `nightshade::plugin`, which exposes `log`, `spawn_cube`, `spawn_sphere`, and the rest of the operations the host knows how to dispatch:

```rust
use nightshade::plugin::{log, spawn_cube};

#[no_mangle]
pub extern "C" fn update(_delta: f32) {
    log("hello from a plugin");
    spawn_cube(0.0, 1.0, 0.0);
}
```

Compile with `--target wasm32-wasi`. Drop the resulting `.wasm` into the configured plugins directory; the host scans and loads it via `load_plugins_from_directory`, then calls each plugin's `update` export every frame.

## Performance shape

Wasmtime AOT-compiles each plugin to native code on first load. Compute-bound code inside a plugin runs close to native speed once the function-call overhead is amortized.

The boundary between host and plugin is the part to think about. Each command and each event involves serialization and a copy across the WASM/native boundary. Plugins that update every entity's transform via individual commands per frame will be slow. Plugins that batch (request a region of memory, mutate it, hand it back) won't be.

## What I'd change

The serialized-enum approach is simple and works, but it's not zero-cost. The Component Model would let me describe the host interface in WIT and let Wasmtime generate typed bindings on both sides, removing one layer of manual serialization. The trade-off is more build-time machinery for a system that's currently small enough not to need it. That's where this design might go next.
