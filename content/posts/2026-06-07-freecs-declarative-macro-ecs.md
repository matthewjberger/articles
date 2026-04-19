+++
title = "An archetype ECS as a single declarative macro"
tags = ["rust", "ecs", "macro_rules", "freecs", "game-engine"]
categories = ["rust"]
excerpt = "freecs is an archetype-based ECS implemented entirely in macro_rules!. The design choices and what they cost."
draft = true
+++

Most Rust ECS libraries that aim for compile-time codegen use proc-macros. [`freecs`](https://github.com/matthewjberger/freecs), my archetype-based ECS, doesn't. The whole thing is a single declarative macro called `ecs!`, and it's the substrate that [`nightshade`](https://github.com/matthewjberger/nightshade) is built on. Going declarative for something this size is unusual enough to be worth explaining.

## What it does

```rust
use freecs::{ecs, Entity};

#[derive(Default, Clone)] struct Position { x: f32, y: f32 }
#[derive(Default, Clone)] struct Velocity { x: f32, y: f32 }
#[derive(Default, Clone)] struct Health { value: f32 }

ecs! {
  World {
    position: Position => POSITION,
    velocity: Velocity => VELOCITY,
    health: Health => HEALTH,
  }
  Tags {
    player => PLAYER,
    enemy => ENEMY,
  }
  Resources {
    delta_time: f32
  }
}

let mut world = World::default();
let entity = world.spawn_entities(POSITION | VELOCITY, 1)[0];
world.set_position(entity, Position { x: 1.0, y: 2.0 });
```

The macro generates the `World` struct, archetype storage, component getters and setters, query methods, command buffers, event types, and resource access, all from that declaration.

## Why declarative

The build-time math was the first reason. `macro_rules!` expands in the same compiler pass that handles the rest of the source: no extra crate, no extra link step. Proc-macros do the same job at the cost of a separate compilation step, which adds up when the library is central to a project that's already heavy on macros elsewhere.

Error message quality was the second. When a `macro_rules!` macro misfires, the error tends to point at the user's invocation rather than at proc-macro internals. For a library where the macro is the entire API surface, having the user see a comprehensible error mattered more than usual.

The third was about transitive dependencies. A proc-macro library pulls in `syn` and `quote` at build time, which propagates to anyone using freecs. Going declarative kept the dependency graph small. Personal preference, not a universal rule.

The fourth came out of writing the thing. A large declarative macro is uncomfortable to maintain, and the discomfort forces a small, regular interface. You can't easily generate code that depends on Turing-complete logic at expansion time, so the design has to be expressible as substitutions over a fixed grammar. That constraint kept the API from growing clever-but-fragile features that I would have added if the language let me.

The trade-offs are real. When the macro itself misbehaves, debugging is unpleasant; `cargo expand` is the only tool that helps, and reading expanded output is slow. A misplaced comma anywhere in the macro body produces a mountain of derivative errors, which makes bisecting where the break happened tedious. And some things proc-macros do trivially (looking up arbitrary type information, traversing AST shapes) aren't possible declaratively at all, so freecs works around those gaps with conventions instead.

## What it does well

Storage is archetype-based. Entities with the same component set live in contiguous Structure-of-Arrays layouts, which keeps iteration cache-coherent and lets the compiler generate SIMD where component types are POD. Tags use a sparse set instead of contributing to the archetype mask, so toggling a tag is O(1) and doesn't trigger an entity migration. Iteration can run in parallel via Rayon without any extra ceremony.

Mutations during iteration go through command buffers: spawn and despawn while iterating, the changes apply at the end, no aliasing-mutability problems. Change detection tracks which components were modified, for systems that only want to see the delta. Events are type-safe and double-buffered (`world.publish_collision(event)` and `world.drain_collisions()`).

Multi-world is the pressure-relief valve for projects that exhaust the 64-component-type bitmask cap on a single world. You declare two `ecs!` invocations, link entities between them with a small bridging type, and treat the pair as one logical state. nightshade does this: rendering and physics live in the engine's World, game-specific state lives in a `GameWorld`, and an `EngineEntity(Entity)` component bridges the two.

The whole library is zero `unsafe`. Archetype storage is `Vec<T>` and indices, not raw pointers.

The benchmark suite at [`benches/ecs_benchmarks.rs`](https://github.com/matthewjberger/freecs/blob/main/benches/ecs_benchmarks.rs) covers spawn, query, mutation, and parallel iteration. Numbers vary by hardware; freecs is competitive with the standard archetype implementations on the synthetic benchmarks and holds up on the workloads that matter for the games I've used it on.

## Where it doesn't fit

If you need components defined at runtime rather than at compile time, freecs is the wrong choice. The archetype machinery is generated when the macro expands, so every component type has to be known then. Engines that want to load components from data files, or expose component definitions through a scripting layer, want a different ECS.

The macro itself is at [`src/lib.rs`](https://github.com/matthewjberger/freecs/blob/main/src/lib.rs); each arm has a comment describing what it expands to. The examples directory has full programs (asteroids clone, boids, pong, tower defense) that exercise different parts of the API.
