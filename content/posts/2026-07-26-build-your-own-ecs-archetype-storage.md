+++
title = "Build your own ECS (part 1), archetype storage"
tags = ["rust", "ecs", "game-engine", "tutorial"]
categories = ["rust"]
excerpt = "An ECS, built from nothing, in three posts. Part 1 lays down the storage. Generational entity handles and archetype tables in struct-of-arrays layout."
+++

*This is part 1 of 3 of a series.* Next → [Structural change and queries](@/posts/2026-08-02-build-your-own-ecs-structural-change.md)

ECS stands for Entity Component System. An entity is a handle, a small id with no data and no methods. A component is a struct of data attached to an entity, like `Position` or `Velocity`. A system is a function that reads or writes components on the entities that match a query, like "every entity with both Position and Velocity." The data lives in components, the work happens in systems, and entities are the keys that line them up.

The fast layout for an ECS groups entities by which components they have and lays out each component type as its own contiguous `Vec`. A query for "every entity with position and velocity" turns into a tight loop over packed memory rather than a HashMap walk. Mutating a component is a write into a known slot, not a heap indirection. Adding a component is a one-time migration to a different bucket. This is the shape almost every fast Rust ECS uses under the hood, and the next three posts build it from scratch.

End state at part 3 is around 800 lines of straightforward Rust with structural change at runtime, queries, change detection, events, sparse-set tags, deferred command buffers, and a small system schedule. No proc-macros, no `unsafe`, only the standard library.

Aimed at Rust developers who want to understand how an archetype ECS is shaped, well enough to write one or to read a production crate without guessing. If you want a finished version to drop in rather than build, [freecs](https://github.com/matthewjberger/freecs) is on crates.io and saves you the work.

Part one covers spawn, despawn, and reading and writing components inside a fixed archetype. Runtime structural change is part two. Events, change detection, tags, and command buffers are part three. The complete file (just under 250 lines) sits at the end of this post.

What gets built over the series is the kernel of [freecs](https://github.com/matthewjberger/freecs), my Rust ECS crate. freecs wraps the same data layout in a declarative macro that writes the typed component accessors for you, and it is the foundation of [nightshade](https://github.com/matthewjberger/nightshade), my game engine.

## Why this layout

The choice that makes the design fast is data-oriented. Object-oriented programming groups data by what kind of thing is being modeled, with the fields of a game object packed inside an instance of its class. Data-oriented design groups data by how the data gets accessed, with all the positions stored together because the physics loop iterates over positions, all the velocities stored together because it iterates them alongside. Systems become functions over arrays of data instead of methods on objects. The storage is laid out for the access pattern, not for the conceptual identity of a thing.

For ten thousand entities and a physics step that reads position and velocity from each, the difference is concrete. An OOP layout pays a cache miss per access, because each object's fields live wherever the allocator put them. The DOD layout pays one cache miss per cache line of contiguous data, which holds several positions at a time. The savings compound across every iteration of every system that runs each frame.

Inheritance also fails the modeling side. Real game objects are combinations of orthogonal capabilities. A destructible barrel, a chest that holds items and can be locked, a vendor that takes damage and runs an AI routine. Forcing a tree shape on that means committing to one combination and breaking the next. Composition over `Vec<Box<dyn Component>>` per entity expresses the combinations correctly but routes every access through a v-table dispatch and a heap indirection, so it solves the modeling problem by reintroducing the cache problem.

What works is to flip the storage. Group entities by which components they have, lay out each component type as its own dense `Vec`, and the question becomes "which buckets satisfy this query" plus "walk those buckets." Iteration is sequential reads through packed memory, which matches what the hardware prefetcher is optimized for. Adding a component triggers a one-time migration to a different bucket rather than paying a per-access cost forever.

The rest of part one is how to build that shape in Rust.

## A note on style before the code starts

Everything in this series uses plain structs with public fields. The `World` type has methods, but the fields underneath are `pub`, and the methods are not protecting any invariants. They are there because writing `world.spawn(mask)` is nicer than writing `spawn(&mut world, mask)`. If the methods were not there, free functions would do the same job. Nothing is encapsulated for OOP reasons.

`&mut self` shows up because Rust needs it for any function that mutates the world, not because the data is private. Where direct field access is more convenient than a method, just reach in.

## Entity handles

An `Entity` is not an object. It owns nothing. It is a small handle the storage uses to find the components.

A bare `u32` would work, but it has a hazard. If you despawn entity `42` and then spawn a new one, the allocator will reuse id `42` (otherwise ids grow without bound). Now any code holding the old handle to `42` will silently access the new entity's data. This is the ABA problem, and in a game it produces bugs that are extremely hard to diagnose because nothing crashes. Your AI just suddenly starts targeting a wall.

The fix is a generation counter. Every time an id is recycled, its generation is bumped. The handle stores both the id and the generation it was minted at. The storage refuses to honor a handle whose generation does not match the current generation for that slot. Stale handles fail loudly with `None` instead of returning the wrong data.

```rust
#[derive(Default, Copy, Clone, Debug, Eq, PartialEq, Hash)]
pub struct Entity {
    pub id: u32,
    pub generation: u32,
}
```

`Copy` because handles are cheap to pass around. `Eq` and `Hash` because we will want to put them in sets later.

## Allocating entities

The allocator hands out `Entity` handles. It needs two things. A counter for the next never-before-used id, and a freelist of recently-freed `(id, next_generation)` pairs to reuse.

```rust
#[derive(Default)]
pub struct EntityAllocator {
    pub next_id: u32,
    pub free: Vec<(u32, u32)>,
}

impl EntityAllocator {
    pub fn allocate(&mut self) -> Entity {
        if let Some((id, generation)) = self.free.pop() {
            Entity { id, generation }
        } else {
            let id = self.next_id;
            self.next_id += 1;
            Entity { id, generation: 0 }
        }
    }

    pub fn deallocate(&mut self, entity: Entity) {
        self.free.push((entity.id, entity.generation.wrapping_add(1)));
    }
}
```

On deallocate, we precompute the *next* generation to be handed out for that id and stash it in the freelist. `wrapping_add(1)` so that an id used billions of times still works (in practice this never happens, but it costs nothing). The next allocation pulls that pair off the freelist and produces a handle with the bumped generation. Old handles with the old generation will not match.

`next_id` itself uses regular `+= 1`. At `u32::MAX` ever-spawned ids it will overflow, panicking in debug and wrapping in release. That is four billion unique entity ids across the lifetime of the program, only a real concern for long-running services that churn entities aggressively. A production allocator would either widen `next_id` to `u64` or recycle ids more aggressively. We leave it as is.

A quick sanity check at this point.

```rust
let mut allocator = EntityAllocator::default();
let first = allocator.allocate();
assert_eq!(first.generation, 0);
allocator.deallocate(first);
let recycled = allocator.allocate();
assert_eq!(recycled.id, first.id);
assert_eq!(recycled.generation, 1);
```

The allocator does not know whether a handle is currently valid. That bookkeeping lives elsewhere. Its job is to mint id-and-generation pairs that are unique over the lifetime of the program.

## Components are just structs

Components are plain data. No traits, no inheritance, no marker interfaces. We will start with two.

```rust
#[derive(Default, Clone, Debug)]
pub struct Position {
    pub x: f32,
    pub y: f32,
}

#[derive(Default, Clone, Debug)]
pub struct Velocity {
    pub x: f32,
    pub y: f32,
}
```

`Default` is required because of how component migration works in part 2. We will rely on `mem::take` to move components between archetypes without allocation, and `mem::take` requires `Default`. `Clone` is convenient for tests. We are not adding any other constraint.

The "components are just structs" rule is more important than it looks. Component types are decoupled from the storage. Any struct can become a component just by declaring its existence to the world. There is no `impl Component for Foo` ceremony.

## Why HashMap is the wrong storage

Before we build the archetype storage, it is worth understanding why the obvious approach fails.

```rust
struct NaiveWorld {
    positions: HashMap<Entity, Position>,
    velocities: HashMap<Entity, Velocity>,
}
```

This is correct. It is also slow. To advance physics you iterate over every entity that has both a position and a velocity.

```rust
for (entity, position) in &mut world.positions {
    if let Some(velocity) = world.velocities.get(entity) {
        position.x += velocity.x;
        position.y += velocity.y;
    }
}
```

For each entity, one hash lookup. The position and velocity for the same entity live at unrelated heap addresses, so each access is a cache miss. With ten thousand entities that is ten thousand hash lookups and twenty thousand probable cache misses every frame.

The data we want to access together is not stored together. Fixing that is the whole point of archetypes.

## Grouping by component set

Group entities by *which set of components they have*. Every entity that has exactly `Position + Velocity` lives in one bucket. Every entity that has only `Position` lives in another. Inside each bucket, store each component type as its own `Vec` in slot-aligned order. The position at index `7` and the velocity at index `7` belong to the same entity.

This is "structure of arrays" instead of "array of structures." The physics loop becomes the following.

```rust
for table in tables_with(POSITION | VELOCITY) {
    for index in 0..table.entities.len() {
        table.positions[index].x += table.velocities[index].x;
        table.positions[index].y += table.velocities[index].y;
    }
}
```

Inside the inner loop, `positions[index]` and `velocities[index]` are stride-1 accesses on dense arrays the CPU prefetcher can predict. No hash lookups. No indirection. The component combination is identified by a bitmask, where each component type is assigned a bit.

```rust
pub const POSITION: u64 = 1 << 0;
pub const VELOCITY: u64 = 1 << 1;
```

A `u64` mask gives us 64 component types per world. That is the practical ceiling of this design. 64 is enough for most games. If you need more, freecs has a multi-world macro form that splits components across logical worlds with a shared entity allocator, mentioned at the end of part 3.

## The archetype table

```rust
#[derive(Default)]
pub struct ComponentArrays {
    pub mask: u64,
    pub entities: Vec<Entity>,
    pub positions: Vec<Position>,
    pub velocities: Vec<Velocity>,
}
```

`mask` records which components this table holds. `entities` records which entity owns each slot, indexed in lockstep with the component arrays. `positions` and `velocities` get pushed to only when the corresponding bit is set in `mask`, otherwise they stay empty. A table with mask `POSITION` (bit 0 set, bit 1 clear) has entries in `positions` and an empty `velocities`.

This struct is awkward. We are hard-coding two component fields and two corresponding masks, and adding a new component means editing this struct, the spawn code, the despawn code, the read code, the write code. A real ECS solves this with code generation. A macro stamps out the per-component fields and accessors from a single declaration. We will not do that here. The whole point of the series is to see the machine working, and a macro would hide the moving parts. The macro layer that scales this kernel cleanly to arbitrary component sets is exactly what [freecs](https://github.com/matthewjberger/freecs) is, and part 3 shows what its `ecs!` declaration looks like next to the hand-rolled equivalent.

## Routing entities to their slots

We have entities (handles) and we have tables (storage). We need a way to look up "given this entity, where do its components live." A `HashMap<Entity, (table_index, array_index)>` would work, but entity ids come out of a small counter and most of them will be densely packed. A `Vec` indexed by id is faster and just as compact.

```rust
#[derive(Default, Copy, Clone)]
pub struct EntityLocation {
    pub generation: u32,
    pub table_index: u32,
    pub array_index: u32,
    pub allocated: bool,
}

#[derive(Default)]
pub struct EntityLocations {
    pub locations: Vec<EntityLocation>,
}
```

Each slot stores the generation of the entity currently at this id, the `(table, index)` of its components, and an `allocated` flag. The flag flips between two states. `true` while an entity is live at this id, `false` once that entity has been despawned. The generation lets a recycled handle be distinguished from the entity that previously held its id. The `allocated` flag lets a fully-deallocated id be distinguished from anything live. Together they reject every stale handle.

`EntityLocation::default()` setting `allocated: false` is load-bearing. When `ensure_slot` grows the backing vec, it fills the new entries with `EntityLocation::default()`. A slot that has been grown into but never written looks identical to a despawned slot, and `get` rejects both. We get safe defaults for free from the derive.

```rust
impl EntityLocations {
    pub fn ensure_slot(&mut self, id: u32) {
        let needed = id as usize + 1;
        if needed > self.locations.len() {
            self.locations.resize(needed, EntityLocation::default());
        }
    }

    pub fn get(&self, entity: Entity) -> Option<(usize, usize)> {
        let location = self.locations.get(entity.id as usize)?;
        if !location.allocated || location.generation != entity.generation {
            return None;
        }
        Some((location.table_index as usize, location.array_index as usize))
    }

    pub fn set(&mut self, entity: Entity, table_index: usize, array_index: usize) {
        self.ensure_slot(entity.id);
        self.locations[entity.id as usize] = EntityLocation {
            generation: entity.generation,
            table_index: table_index as u32,
            array_index: array_index as u32,
            allocated: true,
        };
    }

    pub fn mark_deallocated(&mut self, id: u32) {
        if let Some(location) = self.locations.get_mut(id as usize) {
            location.allocated = false;
        }
    }
}
```

`get` is the gatekeeper. It refuses to return a location if the slot is unallocated or if the requested entity's generation does not match. Stale handles die here. The function returns `Option<(usize, usize)>` rather than `Option<&EntityLocation>` because the caller only ever needs the table index and the array index inside it.

`ensure_slot` resizes the backing vec to fit the requested id. We use `resize`, not doubling, because the allocator hands out ids monotonically when the freelist is empty, so growing on demand by exact size is fine.

## The World

```rust
use std::collections::HashMap;

#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
}
```

Four fields. The allocator (so it can mint entities), the location map (so it can route), the tables (so it can store components), and a `mask` to `table_index` lookup so we can find the right table for a given component combination without scanning.

Finding or creating a table.

```rust
impl World {
    pub fn get_or_create_table(&mut self, mask: u64) -> usize {
        if let Some(&index) = self.table_lookup.get(&mask) {
            return index;
        }
        let index = self.tables.len();
        self.tables.push(ComponentArrays { mask, ..Default::default() });
        self.table_lookup.insert(mask, index);
        index
    }
}
```

The first time someone spawns an entity with `POSITION | VELOCITY`, this creates a fresh table for that mask. Every subsequent spawn with the same mask reuses it.

## Spawning

```rust
impl World {
    pub fn spawn(&mut self, mask: u64) -> Entity {
        let entity = self.allocator.allocate();
        let table_index = self.get_or_create_table(mask);
        let table = &mut self.tables[table_index];
        let array_index = table.entities.len();

        table.entities.push(entity);
        if mask & POSITION != 0 {
            table.positions.push(Position::default());
        }
        if mask & VELOCITY != 0 {
            table.velocities.push(Velocity::default());
        }

        self.entity_locations.set(entity, table_index, array_index);
        entity
    }
}
```

Allocate the handle, find the table, append a slot to every component vec the mask says is present, record the entity's location. The mask-checked pushes are the manual fan-out the macro would generate. In a hand-written ECS, this block grows linearly with the number of component types, which is the main reason ECS libraries use macros.

The components are initialized to `Default`. In part 2 we will add a way to spawn with custom values. For now, the caller writes the components after spawn.

## Reading and writing components

```rust
impl World {
    pub fn get_position(&self, entity: Entity) -> Option<&Position> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &self.tables[table_index];
        if table.mask & POSITION == 0 {
            return None;
        }
        Some(&table.positions[array_index])
    }

    pub fn get_position_mut(&mut self, entity: Entity) -> Option<&mut Position> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &mut self.tables[table_index];
        if table.mask & POSITION == 0 {
            return None;
        }
        Some(&mut table.positions[array_index])
    }

    pub fn get_velocity(&self, entity: Entity) -> Option<&Velocity> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &self.tables[table_index];
        if table.mask & VELOCITY == 0 {
            return None;
        }
        Some(&table.velocities[array_index])
    }

    pub fn get_velocity_mut(&mut self, entity: Entity) -> Option<&mut Velocity> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &mut self.tables[table_index];
        if table.mask & VELOCITY == 0 {
            return None;
        }
        Some(&mut table.velocities[array_index])
    }
}
```

Two reasons a get can fail. The entity is invalid (stale handle, despawned, never existed), or the entity is valid but its archetype does not contain this component. The first case bails out at `entity_locations.get`. The second is the `mask & POSITION == 0` check.

This is fan-out again. Four near-identical functions per component type. A macro would write them. We are not.

## Despawning

Despawn has to do three things. Invalidate the entity so future lookups fail, remove its components from the table so they do not leak, and keep the table compact so iteration stays fast.

The compactness requirement is the source of all the complexity. We could mark the slot as a tombstone and skip it during iteration, but that wastes memory and slows iteration with branching. The standard answer is `swap_remove`. Take the last entry in the vec and move it into the deleted slot. That keeps the vec contiguous. The cost is that the entity formerly at the last slot now lives at a different array index, so its `EntityLocation` needs updating.

```rust
impl World {
    pub fn despawn(&mut self, entity: Entity) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };

        self.entity_locations.mark_deallocated(entity.id);
        self.allocator.deallocate(entity);

        let table = &mut self.tables[table_index];
        let last_index = table.entities.len() - 1;
        let swapped = if array_index < last_index {
            Some(table.entities[last_index])
        } else {
            None
        };

        table.entities.swap_remove(array_index);
        if table.mask & POSITION != 0 {
            table.positions.swap_remove(array_index);
        }
        if table.mask & VELOCITY != 0 {
            table.velocities.swap_remove(array_index);
        }

        if let Some(moved) = swapped {
            self.entity_locations.set(moved, table_index, array_index);
        }

        true
    }
}
```

Order matters here. We capture which entity is about to be moved *before* we do the `swap_remove`, because afterwards the last index is gone and we cannot recover it. We do all the `swap_remove`s on the component vecs in lockstep, since `entities[i]`, `positions[i]`, and `velocities[i]` must always describe the same entity. Then we update the moved entity's location.

If the despawned entity was the last one in its table, there is no swap to track.

## What we built

```
World
├── allocator: EntityAllocator          mints generational handles
├── entity_locations: EntityLocations   maps entity id to (table, slot)
├── tables: Vec<ComponentArrays>        one per archetype
└── table_lookup: HashMap<u64, usize>   mask to table index

ComponentArrays  (one per unique component combination)
├── mask: u64                           which components this table holds
├── entities: Vec<Entity>               which entity owns each slot
├── positions: Vec<Position>            populated iff mask & POSITION
└── velocities: Vec<Velocity>           populated iff mask & VELOCITY

EntityLocation  (one per entity id)
├── generation: u32                     ABA guard
├── table_index: u32
├── array_index: u32
└── allocated: bool                     stale-handle guard
```

Operations on `World`. `spawn(mask)`, `get_position`/`get_position_mut`, `get_velocity`/`get_velocity_mut`, `despawn`. Despawned ids get recycled with a bumped generation, and stale handles fail closed with `None`.

## What is missing

There are several gaps in what we built. None of them are accidents.

You cannot add a component to an entity that did not have it at spawn time. There is no `add_velocity(entity)`. The entity is locked into the archetype it was spawned into. Real games need to add and remove components at runtime (a "stunned" effect, equipment, AI states), and the way archetypes handle this is the central trick of part 2. The entity has to be physically moved to a different table.

There is no way to query. You can ask "what is this entity's position?" but you cannot ask "give me every entity that has both a position and a velocity." That is also part 2.

There is no `set_position` that adds the component if it is missing. There is no batch spawn. There is no parallelism. There is no change tracking, no events, no tags, no commands. Those are part 3.

Part 2 picks up structural change and queries. Making components addable and removable at runtime, walking the tables to find entities that match a component combination, and the two caches (archetype graph for migration, query cache for iteration) that turn the naive O(N) scans into near-constant time without changing the surface API.

## The full file

Here is everything together as a single file you can drop into a fresh Cargo project. Run `cargo new ecs && cd ecs`, replace `src/main.rs`, then `cargo run`. Also available as a [gist](https://gist.github.com/matthewjberger/bbf7e0dc3fd5be28fe01f5c72cdaedb7) if you want to copy from there.

```rust
use std::collections::HashMap;

#[derive(Default, Copy, Clone, Debug, Eq, PartialEq, Hash)]
pub struct Entity {
    pub id: u32,
    pub generation: u32,
}

#[derive(Default)]
pub struct EntityAllocator {
    pub next_id: u32,
    pub free: Vec<(u32, u32)>,
}

impl EntityAllocator {
    pub fn allocate(&mut self) -> Entity {
        if let Some((id, generation)) = self.free.pop() {
            Entity { id, generation }
        } else {
            let id = self.next_id;
            self.next_id += 1;
            Entity { id, generation: 0 }
        }
    }

    pub fn deallocate(&mut self, entity: Entity) {
        self.free.push((entity.id, entity.generation.wrapping_add(1)));
    }
}

#[derive(Default, Copy, Clone)]
pub struct EntityLocation {
    pub generation: u32,
    pub table_index: u32,
    pub array_index: u32,
    pub allocated: bool,
}

#[derive(Default)]
pub struct EntityLocations {
    pub locations: Vec<EntityLocation>,
}

impl EntityLocations {
    pub fn ensure_slot(&mut self, id: u32) {
        let needed = id as usize + 1;
        if needed > self.locations.len() {
            self.locations.resize(needed, EntityLocation::default());
        }
    }

    pub fn get(&self, entity: Entity) -> Option<(usize, usize)> {
        let location = self.locations.get(entity.id as usize)?;
        if !location.allocated || location.generation != entity.generation {
            return None;
        }
        Some((location.table_index as usize, location.array_index as usize))
    }

    pub fn set(&mut self, entity: Entity, table_index: usize, array_index: usize) {
        self.ensure_slot(entity.id);
        self.locations[entity.id as usize] = EntityLocation {
            generation: entity.generation,
            table_index: table_index as u32,
            array_index: array_index as u32,
            allocated: true,
        };
    }

    pub fn mark_deallocated(&mut self, id: u32) {
        if let Some(location) = self.locations.get_mut(id as usize) {
            location.allocated = false;
        }
    }
}

#[derive(Default, Clone, Debug)]
pub struct Position {
    pub x: f32,
    pub y: f32,
}

#[derive(Default, Clone, Debug)]
pub struct Velocity {
    pub x: f32,
    pub y: f32,
}

pub const POSITION: u64 = 1 << 0;
pub const VELOCITY: u64 = 1 << 1;

#[derive(Default)]
pub struct ComponentArrays {
    pub mask: u64,
    pub entities: Vec<Entity>,
    pub positions: Vec<Position>,
    pub velocities: Vec<Velocity>,
}

#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
}

impl World {
    pub fn get_or_create_table(&mut self, mask: u64) -> usize {
        if let Some(&index) = self.table_lookup.get(&mask) {
            return index;
        }
        let index = self.tables.len();
        self.tables.push(ComponentArrays {
            mask,
            ..Default::default()
        });
        self.table_lookup.insert(mask, index);
        index
    }

    pub fn spawn(&mut self, mask: u64) -> Entity {
        let entity = self.allocator.allocate();
        let table_index = self.get_or_create_table(mask);
        let table = &mut self.tables[table_index];
        let array_index = table.entities.len();

        table.entities.push(entity);
        if mask & POSITION != 0 {
            table.positions.push(Position::default());
        }
        if mask & VELOCITY != 0 {
            table.velocities.push(Velocity::default());
        }

        self.entity_locations.set(entity, table_index, array_index);
        entity
    }

    pub fn get_position(&self, entity: Entity) -> Option<&Position> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &self.tables[table_index];
        if table.mask & POSITION == 0 {
            return None;
        }
        Some(&table.positions[array_index])
    }

    pub fn get_position_mut(&mut self, entity: Entity) -> Option<&mut Position> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &mut self.tables[table_index];
        if table.mask & POSITION == 0 {
            return None;
        }
        Some(&mut table.positions[array_index])
    }

    pub fn get_velocity(&self, entity: Entity) -> Option<&Velocity> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &self.tables[table_index];
        if table.mask & VELOCITY == 0 {
            return None;
        }
        Some(&table.velocities[array_index])
    }

    pub fn get_velocity_mut(&mut self, entity: Entity) -> Option<&mut Velocity> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let table = &mut self.tables[table_index];
        if table.mask & VELOCITY == 0 {
            return None;
        }
        Some(&mut table.velocities[array_index])
    }

    pub fn despawn(&mut self, entity: Entity) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };

        self.entity_locations.mark_deallocated(entity.id);
        self.allocator.deallocate(entity);

        let table = &mut self.tables[table_index];
        let last_index = table.entities.len() - 1;
        let swapped = if array_index < last_index {
            Some(table.entities[last_index])
        } else {
            None
        };

        table.entities.swap_remove(array_index);
        if table.mask & POSITION != 0 {
            table.positions.swap_remove(array_index);
        }
        if table.mask & VELOCITY != 0 {
            table.velocities.swap_remove(array_index);
        }

        if let Some(moved) = swapped {
            self.entity_locations.set(moved, table_index, array_index);
        }

        true
    }
}

fn main() {
    let mut world = World::default();

    let mover = world.spawn(POSITION | VELOCITY);
    *world.get_position_mut(mover).unwrap() = Position { x: 1.0, y: 2.0 };
    *world.get_velocity_mut(mover).unwrap() = Velocity { x: 0.5, y: 0.0 };

    let landmark = world.spawn(POSITION);
    *world.get_position_mut(landmark).unwrap() = Position { x: 10.0, y: 10.0 };

    let position = world.get_position(mover).unwrap();
    let velocity = world.get_velocity(mover).unwrap();
    println!(
        "mover: pos=({}, {}) vel=({}, {})",
        position.x, position.y, velocity.x, velocity.y
    );

    assert!(world.get_velocity(landmark).is_none());

    world.despawn(mover);
    assert!(world.get_position(mover).is_none());

    let recycled = world.spawn(POSITION);
    assert_eq!(recycled.id, mover.id);
    assert_eq!(recycled.generation, mover.generation + 1);
    assert!(world.get_position(mover).is_none());
    assert!(world.get_position(recycled).is_some());

    println!("ok");
}
```

`cargo run` should print the mover's state and then `ok`. The final block exercises the generational guard. After we despawn `mover`, the next spawn reuses its id but bumps the generation, and the original handle no longer resolves.

