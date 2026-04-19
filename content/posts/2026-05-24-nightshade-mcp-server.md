+++
title = "Embedding an MCP server in a Rust game engine"
tags = ["rust", "mcp", "ai", "claude", "nightshade"]
categories = ["nightshade"]
excerpt = "Nightshade exposes scene manipulation to AI clients over HTTP via the Model Context Protocol. Around 50 tools turn natural-language requests into typed engine operations."
draft = true
+++

The first time I asked Claude Desktop to "spawn a red cube at the origin and a blue sphere two meters above it" and watched it actually appear in a running nightshade scene, I sat looking at the screen for a while. Not because the spawn itself was impressive (the engine had always supported spawning cubes), but because the AI had translated a natural-language request into the right sequence of typed engine calls without a single line of glue code on my end.

That works because nightshade ships an HTTP server that speaks the Model Context Protocol. With the `mcp` feature enabled, the server runs on `http://127.0.0.1:3333/mcp` and exposes around 50 tools for inspecting and manipulating the running scene. Any MCP-aware client (Claude Desktop, Claude Code, several others) can list those tools, describe them, and invoke them.

## What MCP gives you

MCP is an open protocol for tool-calling between AI clients and arbitrary services. The server registers a set of typed tools, each with a name, description, and JSON schema for its inputs. The client (a model with appropriate harness) can enumerate them, decide which to call based on user intent, and invoke them with structured arguments. The transport in nightshade's case is plain HTTP with JSON-RPC payloads.

The integration is small. Each tool is one file under [`mcp_commands/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/run/mcp_commands) containing a descriptor and a handler that takes deserialized input plus `&mut World`. Schemas come from the input structs via `schemars`.

## What nightshade exposes

The surface area covers most of what a developer would want to do to a running scene from outside it.

For inspection: enumerate entities and their component flags, dump a full component snapshot for any entity, query subsets by component mask, read any registered resource (window state, input, graphics settings, the active camera).

For manipulation: spawn the standard primitive shapes or instantiate a prefab from the asset pipeline; set transforms, materials, and colors; despawn entities; build and edit hierarchies with parent and unparent operations.

For camera control: set the active camera, move it to a target position, point it at a target. The math is the AI's problem.

For rendering: change the atmosphere, toggle and tune bloom, enable or disable shadows. The kinds of things you'd otherwise expose through a debug UI.

For lifecycle: pause and resume the simulation, step physics once at a time, clear the scene entirely.

## The dispatch model

Every frame, in the engine's main loop, the MCP server drains a queue of pending command invocations. Each command runs against the current `World` and returns a JSON result. The HTTP request that triggered the command waits on a oneshot channel for that result.

MCP commands are sequential with respect to the simulation: they execute between frames, never during a frame's update. The AI client gets deterministic semantics with no fighting against the physics step or the render pass.

The trade-off is one frame of perceived latency. For interactive workflows that's fine; for high-frequency manipulation it's noticeable. Most use cases that benefit from MCP are conversational rather than real-time.

## What this enables

A few use cases have emerged from working with it.

Conversational scene authoring fell out immediately. "Put a red cube at the origin and a blue sphere two meters above it" decomposes into two spawn calls and two transform calls; the AI handles the decomposition without help. Editing a scene through prose turns out to be faster than clicking through an inspector for a lot of operations.

Debugging via questions works better than I expected. "Why is the player invisible?" gets answered by inspecting component state and the active camera, and the AI tends to find the issue (no transform, wrong layer, camera pointing somewhere else) before I would have thought to check. The AI is essentially using the inspector for me, faster than I could navigate it manually.

Scripted scenarios fall out naturally because the commands are deterministic. Describe what you want, let the AI build it, save the resulting JSON transcript, replay it later. A scene-authoring session becomes a reproducible artifact.

There's also AI-driven gameplay. The MCP surface includes spawning, transforms, and physics control, so an AI client can participate in the simulation as a non-player agent. More curiosity than production, but it works.

## Companion: the Claude Code subprocess worker

The `claude` feature is a separate piece. It spawns Claude Code CLI as a subprocess, streams its JSON output, and exposes the conversation as an event channel inside the engine. Combined with the `egui` feature, you can drop a chat panel into your game's UI that's backed by Claude.

This is the inverse direction: instead of an AI client driving the engine via MCP, the engine hosts the AI conversation in-process. Both can run at once.

## The trade-off worth flagging

Exposing scene mutation over HTTP from inside a game process has obvious risks. Nightshade's MCP server binds to localhost only and isn't authenticated. It's a development-time feature, not a shipping multiplayer protocol. To expose this surface to remote clients in production you'd need to add auth, transport security, and rate limiting. None of those are hard, but they're not in the box.

## Trying it

Build nightshade with `--features mcp`, run any application, point Claude Desktop at `http://127.0.0.1:3333/mcp`, and ask it to spawn a cube. The server lives in [`mcp.rs`](https://github.com/matthewjberger/nightshade/blob/main/crates/nightshade/src/mcp.rs); each tool is its own file under [`mcp_commands/`](https://github.com/matthewjberger/nightshade/tree/main/crates/nightshade/src/run/mcp_commands). Schemas come from the input structs via `schemars`.
