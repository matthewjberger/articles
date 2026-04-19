+++
title = "Composing a game engine with feature flags"
tags = ["rust", "cargo", "feature-flags", "game-engine", "nightshade"]
categories = ["nightshade"]
excerpt = "Nightshade lets users pay only for what they turn on. The discipline of cfg-gating across 30+ subsystems."
draft = true
+++

Nightshade ships as a single crate, but every subsystem is opt-in. A user who wants a 200-line egui app shouldn't compile a physics engine. A user who wants a full XR scene editor shouldn't wire it up by hand. The mechanism is Cargo feature flags. The discipline is making them compose cleanly.

## The hierarchy

The flags layer like an onion:

```
core ─────────────── windowing, math, ECS, time
text ─────────────── 3D text rendering (fontdue)
behaviors ────────── built-in entity behaviors
assets ───────────── asset loading (gltf, image, bincode)
runtime ──────────── core + text + behaviors
engine (default) ─── runtime + assets + scene_graph + terrain + picking + ...
full ─────────────── engine + egui + audio + physics + scripting + fbx + editor + ...

Add-on features:
wgpu ─────────────── GPU rendering (DX12, Metal, Vulkan, WebGPU)
egui ─────────────── immediate-mode UI
audio ────────────── kira playback
physics ──────────── 3D physics (rapier3d)
gamepad ──────────── controller input
navmesh ──────────── pathfinding
scripting ────────── Rhai
fbx ──────────────── FBX asset loading
lattice ──────────── lattice deformation
sdf_sculpt ───────── SDF sculpting
mosaic ───────────── multi-pane app framework
editor ───────────── scene editor infrastructure
openxr ───────────── VR/AR
steam ────────────── Steamworks integration
mcp ──────────────── AI scene manipulation server
claude ───────────── Claude Code subprocess worker
webview ──────────── embedded webview with IPC
plugins ──────────── WASI plugin guest API
plugin_runtime ───── WASI plugin host (Wasmtime)
```

The aggregate features (`core`, `runtime`, `engine`, `full`) just enable the right combinations of granular flags. The granular flags do the actual cfg-gating in source.

## What this looks like in code

A typical module is one `#[cfg(feature = "...")]` away from existing or not:

```rust
// crates/nightshade/src/lib.rs

#[cfg(feature = "runtime")]
pub mod ecs;
#[cfg(feature = "runtime")]
pub mod render;
#[cfg(feature = "runtime")]
pub mod run;

#[cfg(feature = "openxr")]
pub mod xr;

#[cfg(all(feature = "mcp", not(target_arch = "wasm32")))]
pub mod mcp;

#[cfg(all(feature = "claude", not(target_arch = "wasm32")))]
pub mod claude;

#[cfg(all(feature = "plugin_runtime", not(target_arch = "wasm32")))]
pub mod plugin_runtime;
```

Notice the platform overlays. Some features (`mcp`, `claude`, `plugin_runtime`) only make sense on native targets and are gated against `target_arch = "wasm32"`.

Inside modules, the same discipline:

```rust
// crates/nightshade/src/ecs/world/resources.rs

#[cfg(feature = "physics")]
pub physics: PhysicsWorld,

#[cfg(feature = "audio")]
pub audio: AudioState,

#[cfg(feature = "scripting")]
pub scripts: ScriptEngine,
```

The `World` struct itself shrinks or grows depending on what's enabled. A minimal build has no physics field; a full build has all of them.

## The prelude

The user imports one thing:

```rust
use nightshade::prelude::*;
```

The prelude in `lib.rs` is a long sequence of `pub use` statements, each gated by the relevant feature. If `physics` isn't enabled, the prelude doesn't export `RigidBodyComponent` or `ColliderShape`. The user who didn't ask for physics doesn't see them in their namespace.

This matters more than it looks. Without disciplined prelude gating, every `Cargo.toml` configuration ends up with subtly different IDE autocomplete, and "missing feature flag" errors get cryptic. With it, the surface area always matches what the user opted into.

## The gotchas

Default features are sticky. Anyone who depends on nightshade with `default-features = true` (which most users do) gets the `engine` feature set, which pulls in a lot. Users who want minimal builds have to write `default-features = false` and explicitly list what they want. The default is opinionated toward "I want to make a game" rather than "I want minimal."

Feature flags are additive but module structure isn't. If three different feature flags want to add fields to the same struct, you need three `#[cfg]` blocks in the struct definition. Refactoring across many feature combinations gets tedious; I've reached for `Option<T>` in a few places where the alternative was an explosion of cfg blocks.

The compile-time test matrix is impossible to exhaust. With over 2^20 feature combinations, CI runs four canonical ones (`core`, `runtime + wgpu + egui`, `engine`, `full`) plus the WASM and OpenXR builds. That catches almost everything but doesn't catch oddball user combinations.

Doc tests need feature awareness too. A doc test that uses `RigidBodyComponent` has to be gated with `#[cfg_attr(not(feature = "physics"), ignore)]` or it fails when the docs are built without that feature. Found this one the hard way.

## Why this is worth the discipline

A minimal build (`runtime + wgpu + egui`) compiles in roughly a quarter of the time of a `full` build. For users who only need the small surface, that's the difference between iterating every 4 seconds and iterating every 16 seconds. WASM bundle size scales the same way, which is what makes the web demos at [matthewberger.dev/nightshade](https://matthewberger.dev/nightshade) feasible at all. And users who only opted into rendering don't have to read API docs for physics, scripting, or navmesh; the apparent surface area shrinks to match what they're doing.

The thing I'd change if I started over is keeping `core` even smaller. Right now `core` includes ECS, math, windowing, and time. ECS in particular could plausibly be a separate feature for the case where someone wants just `petgraph` and `winit` without dragging freecs along. The trade-off is more flags to think about. Worth doing eventually.

The feature flag definitions are in the workspace root [`Cargo.toml`](https://github.com/matthewjberger/nightshade/blob/main/Cargo.toml) and in [`crates/nightshade/Cargo.toml`](https://github.com/matthewjberger/nightshade/blob/main/crates/nightshade/Cargo.toml). The cfg gates are everywhere; grep for `cfg(feature` to see the patterns.
