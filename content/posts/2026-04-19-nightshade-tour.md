+++
title = "Nightshade is the engine that finally stuck"
tags = ["rust", "graphics", "game-engine", "wgpu", "nightshade"]
categories = ["nightshade"]
excerpt = "An overview of nightshade, the cross-platform Rust game engine I've been building, framed by the eight engines that came before it."
draft = true
+++

I've been writing game engines on and off since 2014. Iceberg2D in C++/SDL was first. Then Iceberg3D, Whyte, sepia, dragonglass (across two attempts), phantom, serenity, and a string of `nightshade-experimental*` repos. Most of those are still public. None of them survived contact with sustained use. Each one taught me something the previous draft got wrong.

[Nightshade](https://github.com/matthewjberger/nightshade) is the version that stuck. I started writing it in November 2025 and have been using it daily since. The series that follows goes deep on the individual subsystems; this is the overview.

## What it is

A data-oriented Rust game engine built on [`freecs`](https://github.com/matthewjberger/freecs) (my own archetype ECS) and [`wgpu`](https://wgpu.rs). Single crate, feature-flagged, runs on Windows, Linux, macOS, web (WebGPU), Android, and OpenXR (tested on Quest 3 with Virtual Desktop). The same `State` impl runs everywhere; what changes per platform is the entry point and a handful of `cfg`-gated modules.

Crate at [crates.io/crates/nightshade](https://crates.io/crates/nightshade). Documentation at [matthewberger.dev/nightshade-book](https://matthewberger.dev/nightshade-book).

## What's actually inside

The rendering core is a pass-based render graph: a petgraph DAG with topological scheduling, transient resource aliasing for memory savings, lifetime tracking for store-op optimization, and dead-pass culling. The graph runs WGSL shaders covering clustered lighting, HiZ depth pyramids for occlusion culling, GPU-driven mesh culling, weighted-blended OIT, environment-map filtering for image-based lighting, bloom, FXAA, depth of field, decals, water, an interior-mapping shader for distant geometry, and a five-stage grass system. There's a separate post on the frame graph and one on the shader catalog.

The ECS is freecs. Archetype storage, sparse-set tags that don't fragment archetypes, command buffers, change detection, multi-world for projects that need more than 64 component types. There's a separate post on how it's implemented entirely in declarative macros.

Beyond rendering and ECS, every other engine system is opt-in via a feature flag. Audio playback uses kira, with optional FFT analysis via rustfft. Physics is rapier3d. Gamepad input goes through gilrs. Navigation mesh generation uses rerecast. Scripting is Rhai. VR and AR use OpenXR. Steam integration goes through the Steamworks SDK. The mosaic feature is a multi-pane app framework built on egui_tiles, used by the editor; the editor itself adds gizmos, undo/redo, inspectors, and picking. Lattice deformation, SDF sculpting, and an interactive-fiction subsystem each have their own flag.

The AI integrations are two separate features. The `mcp` feature exposes around 50 tools over HTTP so AI clients (Claude Desktop, Claude Code, others) can manipulate the running scene through the Model Context Protocol. The `claude` feature is the inverse direction: a background worker that spawns Claude Code as a subprocess and surfaces its JSON output as an event channel inside the engine, so a game's UI can host an AI conversation in-process.

The `webview` feature embeds a webview with bidirectional IPC, suitable for hosting a Leptos or Yew frontend inside a nightshade window. The `plugins` and `plugin_runtime` features host sandboxed user-supplied WebAssembly modules through Wasmtime.

The feature flags layer cleanly: `core` to `runtime` to `engine` to `full`. The same crate that powers a 200-line egui app also powers a full XR scene editor with physics, navmesh, and AI scene manipulation. There's a separate post on how the cfg discipline holds together across 30+ subsystems.

## Companion projects

- [`nightshade-editor`](https://crates.io/crates/nightshade-editor): interactive scene editor
- [`nightshade-book`](https://github.com/matthewjberger/nightshade-book): mdbook covering the engine systems
- [`nightshade-examples`](https://github.com/matthewjberger/nightshade-examples): runnable showcase scenes
- [`nightshade-template`](https://github.com/matthewjberger/nightshade-template): starter for new projects
- [`nightshade-webview`](https://github.com/matthewjberger/nightshade-webview): Leptos hosted in a nightshade window

The marketing site at [matthewberger.dev/nightshade](https://matthewberger.dev/nightshade) is built with [`bamboo`](https://github.com/matthewjberger/bamboo), the static site generator I wrote for this kind of work. Engine site, blog, and personal homepage all run on the same SSG.

## The series

Deeper coverage in the rest:

1. The frame graph: petgraph DAG, resource aliasing, lifetime tracking
2. The shader catalog and why it's split across many small files
3. Cross-platform deployment across all six targets
4. Composing the engine with feature flags
5. The MCP server for AI scene manipulation
6. WASI plugins via Wasmtime
7. The supporting libraries (`freecs`, `cameras`, `frost`)
