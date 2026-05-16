+++
title = "Build your own ECS (part 3), change detection, events, tags, and commands"
tags = ["rust", "ecs", "game-engine", "tutorial"]
categories = ["rust"]
excerpt = "The four subsystems that turn the storage layer into something a real game engine can sit on top of. A watermark-based change detector, double-buffered events, sparse-set tags, and a deferred command buffer."
+++

*This is part 3 of 3 of a series.* ← [Structural change and queries](@/posts/2026-08-02-build-your-own-ecs-structural-change.md)

[Part 2](@/posts/2026-08-02-build-your-own-ecs-structural-change.md) finished with a working archetype ECS. Spawn into an archetype, add and remove components at runtime, query and iterate by component combination, despawn safely. The storage is solid, the routing is fast, and you could build a small game on it. What you could not do was build a *frame loop* on it. The missing pieces are the things systems use to talk to each other and to the world structurally.

This post adds four pieces. Change detection records what moved so other systems can do incremental work instead of touching everything each frame. Events let one system message another across the schedule without coupling them. Sparse-set tags carry markers that flip too often to live in the archetype mask. Command buffers queue mutations during iteration so the loop does not invalidate itself. A small system schedule at the end runs the four in order.

By the end of the post you have an ECS kernel that closely mirrors what production libraries expose, in about 825 lines of Rust.

Start from the file at the end of part 2.

## Change detection by watermark

The render system wants to push transforms to the GPU only for entities that moved this frame. Recording "which slot was written" needs to cost less than the work that prompted the write, or the bookkeeping becomes more expensive than the thing it is tracking. A `HashSet<Entity>` of dirty entities would work but every mutation would touch a hashmap, which fails the cost test.

The cheaper shape is a parallel `Vec<u32>` of tick stamps next to each component vec, indexed in lockstep with `entities`. Every mutation writes the current frame's tick into the slot. To find what changed since last frame, walk the stamps and ask whose value is greater than the watermark from the end of the previous frame. No clearing pass between frames. The watermark moves and the old stamps are stale relative to it without ever being touched.

```rust
#[derive(Default)]
pub struct ComponentArrays {
    pub mask: u64,
    pub entities: Vec<Entity>,
    pub positions: Vec<Position>,
    pub positions_changed: Vec<u32>,
    pub velocities: Vec<Velocity>,
    pub velocities_changed: Vec<u32>,
}
```

For every component vec we add a parallel `Vec<u32>`. The convention is `positions[i]`, `positions_changed[i]`, and `entities[i]` always describe the same entity slot.

The `World` grows two counters.

```rust
#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
    pub current_tick: u32,
    pub last_tick: u32,
}
```

`current_tick` is the value we stamp into a slot when it is modified. `last_tick` is the watermark. Slots stamped *after* `last_tick` are considered changed. The frame-advance function moves both.

```rust
impl World {
    pub fn step(&mut self) {
        self.last_tick = self.current_tick;
        self.current_tick = self.current_tick.wrapping_add(1);
    }
}
```

After `step()`, `last_tick` is what `current_tick` was a moment ago, and `current_tick` is one higher. Slots stamped during the just-finished frame have ticks `== last_tick`, which fails the `> last_tick` check, so they no longer count as changed. Slots modified in the new frame will get the new `current_tick`, which is `> last_tick`, so they will. No clearing.

The `wrapping_add` here is a corner this design papers over. After `2^32` frames the tick rolls back to zero, and a slot stamped at the old `u32::MAX` suddenly looks ancient when `last_tick` is also `u32::MAX`. At 60 frames per second that is about 2.3 years of continuous runtime, fine for a game and not fine for a long-running server. A production engine either widens the tick to `u64` or runs a periodic rebasing pass that subtracts the watermark from every stamp.

Every place that pushes to a component vec also needs to push to its `_changed` vec, and every place that modifies an existing slot needs to stamp the current tick. Spawn first.

```rust
impl World {
    pub fn spawn(&mut self, mask: u64) -> Entity {
        let entity = self.allocator.allocate();
        let table_index = self.get_or_create_table(mask);
        let current_tick = self.current_tick;
        let table = &mut self.tables[table_index];
        let array_index = table.entities.len();

        table.entities.push(entity);
        if mask & POSITION != 0 {
            table.positions.push(Position::default());
            table.positions_changed.push(current_tick);
        }
        if mask & VELOCITY != 0 {
            table.velocities.push(Velocity::default());
            table.velocities_changed.push(current_tick);
        }

        self.entity_locations.set(entity, table_index, array_index);
        entity
    }
}
```

The mutable getters stamp the slot when handed out.

```rust
impl World {
    pub fn get_position_mut(&mut self, entity: Entity) -> Option<&mut Position> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let current_tick = self.current_tick;
        let table = &mut self.tables[table_index];
        if table.mask & POSITION == 0 {
            return None;
        }
        table.positions_changed[array_index] = current_tick;
        Some(&mut table.positions[array_index])
    }

    pub fn get_velocity_mut(&mut self, entity: Entity) -> Option<&mut Velocity> {
        let (table_index, array_index) = self.entity_locations.get(entity)?;
        let current_tick = self.current_tick;
        let table = &mut self.tables[table_index];
        if table.mask & VELOCITY == 0 {
            return None;
        }
        table.velocities_changed[array_index] = current_tick;
        Some(&mut table.velocities[array_index])
    }
}
```

This is conservative. We stamp the slot whether or not the caller actually modifies the data. The alternative (only stamp on actual write) would require wrapping the returned reference in a guard type that stamps in its `Drop`, which is more machinery than the savings justify.

Several functions need updating to keep the `_changed` vecs in lockstep with their component vec counterparts. `despawn`, `move_entity`, `set_position`, and `set_velocity` all need the right pushes, swap_removes, and tick stamps. Every `push` to `positions` gets a matching `push` to `positions_changed`. Every `swap_remove` from `positions` gets a matching `swap_remove` from `positions_changed`. Every direct write to `positions[index]` gets a `positions_changed[index] = current_tick` next to it. The full file at the end of the post shows every site updated.

One small redundancy lives in `set_position`'s migration path. It calls `add_components`, which calls `move_entity`, which already pushes `positions_changed.push(current_tick)` for the new slot. `set_position` then re-fetches the location and writes `positions_changed[array_index] = current_tick` over the just-pushed value. The store is idempotent and the redundancy keeps the post-migration write path identical to the fast no-migration path. If you want to optimize it, you can branch on whether migration happened. The save is not worth the branch.

There is a real catch the inner-loop authors need to know about. The `for_each_mut` callback from part 2 hands the caller a raw `&mut ComponentArrays`, direct access to the component vecs, no auto-stamping. A system that writes through that callback does *not* trigger change detection. The slot's tick stays at whatever value it had before. This is the speed-versus-bookkeeping trade-off. Ergonomic single-entity accessors (`set_position`, `get_position_mut`) stamp for you. Hot inner loops keep the raw access and stamp manually when they actually change something. We will see both shapes in the demo.

The new query, "iterate over entities whose components changed since last frame", is the same as `for_each_mut` but with an extra check.

```rust
impl World {
    pub fn for_each_mut_changed<F>(&mut self, include: u64, exclude: u64, mut f: F)
    where
        F: FnMut(Entity, &mut ComponentArrays, usize),
    {
        let since_tick = self.last_tick;
        let table_indices: Vec<usize> = self.cached_tables(include).to_vec();
        for table_index in table_indices {
            let table = &mut self.tables[table_index];
            if table.mask & exclude != 0 {
                continue;
            }
            for array_index in 0..table.entities.len() {
                let mut changed = false;
                if include & POSITION != 0
                    && table.mask & POSITION != 0
                    && table.positions_changed[array_index] > since_tick
                {
                    changed = true;
                }
                if include & VELOCITY != 0
                    && table.mask & VELOCITY != 0
                    && table.velocities_changed[array_index] > since_tick
                {
                    changed = true;
                }
                if changed {
                    let entity = table.entities[array_index];
                    f(entity, table, array_index);
                }
            }
        }
    }
}
```

A slot is considered changed if *any* of the queried components have a tick newer than the watermark. For a renderer that wants "every entity whose position changed", this fires only on the slots with fresh position stamps. For a system that wants "every entity whose position OR velocity changed", it fires when either is fresh. Combining changed-ness across components with OR rather than AND is the natural fit, because the typical use case is "redraw this entity if anything about its visual representation moved."

`step()` runs at the end of the frame. Until you call `step()`, every modification this frame still counts as changed. Call `step()` once per frame at the end, after every system has had a chance to read the changes from this frame.

## Events

A collision system finds two entities that overlap and the damage system needs to know. Calling damage methods from inside the collision loop couples the two together. Scribbling a pending-damage component on one of the entities works for one-off cases and turns into a mess when ten systems want to broadcast. The clean shape is a queue. The collision system writes `CollisionEvent`s without naming a receiver. The damage system reads them without naming a sender.

The tricky part is lifetime. The queue cannot empty itself the moment an event is written because a system reading later in the same frame would miss it. It cannot keep events forever because nothing would ever drain. The compromise here is a two-frame rule. An event sent on frame N is readable through the end of frame N+1 and gone by the start of frame N+2. Every system gets a full frame to react regardless of schedule order, and memory is bounded at twice the per-frame volume.

Implementation, double-buffered.

```rust
#[derive(Clone)]
pub struct EventQueue<T> {
    pub current: Vec<T>,
    pub previous: Vec<T>,
}

impl<T> Default for EventQueue<T> {
    fn default() -> Self {
        Self {
            current: Vec::new(),
            previous: Vec::new(),
        }
    }
}

impl<T> EventQueue<T> {
    pub fn send(&mut self, event: T) {
        self.current.push(event);
    }

    pub fn read(&self) -> impl Iterator<Item = &T> {
        self.previous.iter().chain(self.current.iter())
    }

    pub fn drain(&mut self) -> impl Iterator<Item = T> + '_ {
        self.previous.drain(..).chain(self.current.drain(..))
    }

    pub fn update(&mut self) {
        self.previous.clear();
        std::mem::swap(&mut self.current, &mut self.previous);
    }

    pub fn len(&self) -> usize {
        self.current.len() + self.previous.len()
    }

    pub fn is_empty(&self) -> bool {
        self.current.is_empty() && self.previous.is_empty()
    }
}
```

`send` pushes into the current buffer. `read` yields everything in both buffers (previous first, then current, the order events were sent). `update` clears the previous buffer and swaps the current into its place, so the next call starts with `previous` holding what was just sent and `current` empty. Two `update` calls between a `send` and a `read` will lose the event.

Each event type gets its own queue, stored as a field on the `World`.

```rust
#[derive(Debug, Clone)]
pub struct CollisionEvent {
    pub entity_a: Entity,
    pub entity_b: Entity,
}

#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
    pub current_tick: u32,
    pub last_tick: u32,
    pub collisions: EventQueue<CollisionEvent>,
}

impl World {
    pub fn send_collision(&mut self, event: CollisionEvent) {
        self.collisions.send(event);
    }

    pub fn read_collisions(&self) -> impl Iterator<Item = &CollisionEvent> {
        self.collisions.read()
    }

    pub fn drain_collisions(&mut self) -> impl Iterator<Item = CollisionEvent> + '_ {
        self.collisions.drain()
    }
}
```

The familiar fan-out. One set of methods per event type, hand-written here. A macro would generate them. The cost is the same as for component accessors.

`step()` advances each event queue. It is the same `step()` that advances the tick.

```rust
impl World {
    pub fn step(&mut self) {
        self.collisions.update();
        self.last_tick = self.current_tick;
        self.current_tick = self.current_tick.wrapping_add(1);
    }
}
```

The order is intentional. Update events first, then advance the tick. By the time the new frame begins, both have rolled over.

## Sparse-set tags

A tag is a `HashSet<Entity>`. Insert, remove, and membership check are all O(1). Iteration over "all entities with this tag" yields directly from the set. The reason a tag is a hash set instead of a bit in the archetype mask is the migration cost. A bit in the mask means flipping the tag triggers `move_entity`, which pulls every other component off the entity, pushes them into a new table, and compacts the old slot. For markers that flip often (the "selected" tag in an RTS, a frame-local "took damage this frame" flag, an enemy alertness state), the migration is pure waste compared to a hash insert.

The masking approach is not wrong for tags that rarely change. `Player` and `Enemy` are reasonable as archetype bits if those identities are set once at spawn and never updated. The reason this kernel puts them in a `HashSet` anyway is uniformity. Code that wants to ask "is this entity a player" should not need to know whether the answer comes from a mask check or a hash lookup.

```rust
#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
    pub current_tick: u32,
    pub last_tick: u32,
    pub collisions: EventQueue<CollisionEvent>,
    pub players: std::collections::HashSet<Entity>,
    pub enemies: std::collections::HashSet<Entity>,
}

impl World {
    pub fn add_player(&mut self, entity: Entity) {
        if self.entity_locations.get(entity).is_some() {
            self.players.insert(entity);
        }
    }

    pub fn remove_player(&mut self, entity: Entity) -> bool {
        self.players.remove(&entity)
    }

    pub fn has_player(&self, entity: Entity) -> bool {
        self.players.contains(&entity)
    }

    pub fn query_players(&self) -> impl Iterator<Item = Entity> + '_ {
        self.players.iter().copied()
    }

    pub fn add_enemy(&mut self, entity: Entity) {
        if self.entity_locations.get(entity).is_some() {
            self.enemies.insert(entity);
        }
    }

    pub fn remove_enemy(&mut self, entity: Entity) -> bool {
        self.enemies.remove(&entity)
    }

    pub fn has_enemy(&self, entity: Entity) -> bool {
        self.enemies.contains(&entity)
    }

    pub fn query_enemies(&self) -> impl Iterator<Item = Entity> + '_ {
        self.enemies.iter().copied()
    }
}
```

Insertion and removal are O(1) hash operations with no archetype touch. Querying "all players" yields directly from the set. Combined queries (a `for_each` over `POSITION | VELOCITY` plus a `has_player` filter) walk the tables and check the tag set per entity, which is a cheap hash lookup.

`despawn` needs to clear the entity out of every tag set, otherwise stale entity handles will accumulate in the sets. Add these lines to the existing `despawn`.

```rust
self.players.remove(&entity);
self.enemies.remove(&entity);
```

The name "sparse set" comes from the data structure traditionally used here. An array of slot pointers indexed by entity id (so checking membership is an array access), plus a packed list of present entities (so iteration is dense). A `HashSet` is the simplified version. For a real engine with millions of entities and many tag types, the sparse-set proper is faster, but it has the same external API.

## Command buffers

Iterating over entities while spawning, despawning, or restructuring them is impossible to do safely with direct calls. The iteration borrows the world, so any mutation requires giving up the borrow first. The standard workaround is to queue the operations and apply them later.

The queue is an enum of every operation the world supports.

```rust
pub enum Command {
    Spawn { mask: u64 },
    Despawn { entity: Entity },
    AddComponents { entity: Entity, mask: u64 },
    RemoveComponents { entity: Entity, mask: u64 },
    SetPosition { entity: Entity, value: Position },
    SetVelocity { entity: Entity, value: Velocity },
    AddPlayer { entity: Entity },
    RemovePlayer { entity: Entity },
    AddEnemy { entity: Entity },
    RemoveEnemy { entity: Entity },
}
```

Each operation that can be deferred has a variant. The component-specific `Set*` variants carry the typed payload, because that information would otherwise be erased.

The buffer is a `Vec<Command>` on the world, populated by queue methods and drained by `apply_commands`.

```rust
#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
    pub current_tick: u32,
    pub last_tick: u32,
    pub collisions: EventQueue<CollisionEvent>,
    pub players: std::collections::HashSet<Entity>,
    pub enemies: std::collections::HashSet<Entity>,
    pub command_buffer: Vec<Command>,
}

impl World {
    pub fn queue_spawn(&mut self, mask: u64) {
        self.command_buffer.push(Command::Spawn { mask });
    }

    pub fn queue_despawn(&mut self, entity: Entity) {
        self.command_buffer.push(Command::Despawn { entity });
    }

    pub fn queue_add_components(&mut self, entity: Entity, mask: u64) {
        self.command_buffer
            .push(Command::AddComponents { entity, mask });
    }

    pub fn queue_remove_components(&mut self, entity: Entity, mask: u64) {
        self.command_buffer
            .push(Command::RemoveComponents { entity, mask });
    }

    pub fn queue_set_position(&mut self, entity: Entity, value: Position) {
        self.command_buffer
            .push(Command::SetPosition { entity, value });
    }

    pub fn queue_set_velocity(&mut self, entity: Entity, value: Velocity) {
        self.command_buffer
            .push(Command::SetVelocity { entity, value });
    }

    pub fn queue_add_player(&mut self, entity: Entity) {
        self.command_buffer.push(Command::AddPlayer { entity });
    }

    pub fn queue_remove_player(&mut self, entity: Entity) {
        self.command_buffer.push(Command::RemovePlayer { entity });
    }

    pub fn queue_add_enemy(&mut self, entity: Entity) {
        self.command_buffer.push(Command::AddEnemy { entity });
    }

    pub fn queue_remove_enemy(&mut self, entity: Entity) {
        self.command_buffer.push(Command::RemoveEnemy { entity });
    }

    pub fn apply_commands(&mut self) {
        let commands = std::mem::take(&mut self.command_buffer);
        for command in commands {
            match command {
                Command::Spawn { mask } => {
                    self.spawn(mask);
                }
                Command::Despawn { entity } => {
                    self.despawn(entity);
                }
                Command::AddComponents { entity, mask } => {
                    self.add_components(entity, mask);
                }
                Command::RemoveComponents { entity, mask } => {
                    self.remove_components(entity, mask);
                }
                Command::SetPosition { entity, value } => {
                    self.set_position(entity, value);
                }
                Command::SetVelocity { entity, value } => {
                    self.set_velocity(entity, value);
                }
                Command::AddPlayer { entity } => {
                    self.add_player(entity);
                }
                Command::RemovePlayer { entity } => {
                    self.remove_player(entity);
                }
                Command::AddEnemy { entity } => {
                    self.add_enemy(entity);
                }
                Command::RemoveEnemy { entity } => {
                    self.remove_enemy(entity);
                }
            }
        }
    }
}
```

`mem::take` swaps the buffer out so the loop iterates over an owned `Vec<Command>` while leaving an empty buffer in place. This matters because some commands invoke methods that might themselves enqueue more commands. If we held a borrow into the buffer while iterating, those nested enqueues would not compile. With `mem::take`, nested commands are appended to the new buffer and will be picked up by the next `apply_commands` call.

The dispatch is a giant `match`, typed at compile time, no `dyn`, no allocation per command beyond the vec push. The enum variants are the documentation of what can be deferred.

## Resources

Some state belongs to the world, not to any specific entity. Delta time. The input snapshot for this frame. The time of day. The score. None of these have a sensible owner among the entities, but most systems in the schedule need to read or write at least one of them. The shape that holds this kind of state is a `Resources` struct attached to the world.

```rust
#[derive(Default)]
pub struct Resources {
    pub delta_time: f32,
    pub game_time: f32,
}

#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
    pub current_tick: u32,
    pub last_tick: u32,
    pub collisions: EventQueue<CollisionEvent>,
    pub players: HashSet<Entity>,
    pub enemies: HashSet<Entity>,
    pub command_buffer: Vec<Command>,
    pub resources: Resources,
}
```

A system reads from resources by accessing `world.resources.delta_time` and writes by assigning to `world.resources.game_time = ...`. No accessor functions, no per-resource fan-out. The freecs macro shown later in the post generates the same shape from a `Resources { delta_time: f32 }` block at the macro site. We are building the hand-written equivalent.

## A trivial schedule

Systems are functions that take `&mut World`. A schedule is a list of named systems run in order each frame. For an introductory build we will not need anything more complicated.

```rust
pub type SystemFn = Box<dyn FnMut(&mut World)>;

#[derive(Default)]
pub struct Schedule {
    pub systems: Vec<(&'static str, SystemFn)>,
}

impl Schedule {
    pub fn add<F>(&mut self, name: &'static str, system: F) -> &mut Self
    where
        F: FnMut(&mut World) + 'static,
    {
        self.systems.push((name, Box::new(system)));
        self
    }

    pub fn run(&mut self, world: &mut World) {
        for (_, system) in &mut self.systems {
            system(world);
        }
    }
}
```

The named entries are for introspection. You can print the system list, find a system by name, swap one out. A production schedule grows hooks for ordering constraints, parallel execution, and conditional running, but for the purpose of this series, an ordered list is enough to drive a frame loop.

## What we built

```
World  (new fields)
├── current_tick: u32                       stamped on writes
├── last_tick: u32                          watermark for changed-since checks
├── collisions: EventQueue<CollisionEvent>  double-buffered messages
├── players: HashSet<Entity>                sparse-set tag, no archetype touch
├── enemies: HashSet<Entity>                sparse-set tag
├── command_buffer: Vec<Command>            deferred structural changes
└── resources: Resources                    global state, not per-entity

ComponentArrays  (new fields)
├── positions_changed: Vec<u32>             parallel tick array
└── velocities_changed: Vec<u32>            parallel tick array
```

New operations on `World`. `step` to advance the frame, `for_each_mut_changed` to iterate only the slots touched since last step, `send_collision`/`read_collisions`/`drain_collisions` for cross-system messaging, the tag set with `add_player`/`remove_player`/`has_player`/`query_players` (and the same for enemy), the command-buffer methods `queue_spawn`/`queue_despawn`/`queue_set_position`/... and `apply_commands` to flush them, plus direct field access on `world.resources` for global state. A `Schedule` struct that runs systems in order each frame.

## Where the abstractions stop being free

We have been doing fan-out by hand for three posts now. Every component type adds a long list of edits.

- a field on `ComponentArrays`
- a parallel `_changed` field
- a mask constant
- a `match` arm in `component_index`
- a bit-position constant inside `COMPONENT_COUNT`
- a push site in `spawn`
- two push sites in `move_entity` (take from source, push to dest)
- two `swap_remove` sites (one in `despawn`, one in `move_entity`)
- two component bits in the edge-graph loop inside `get_or_create_table`
- four accessor functions (`get`, `get_mut`, `set`, `entity_has_*`)
- a branch in `for_each_mut_changed`

Adding a tenth component is editing thirty-something call sites, and any one of them being wrong is a silent correctness bug. This is the reason every production ECS in Rust ships with a macro layer.

[freecs](https://github.com/matthewjberger/freecs) is what these three posts scale to. Same data layout, same archetype graph, same query cache, same watermark change detection. The difference is a single declarative `macro_rules!` macro on top that takes one component declaration and writes the entire fan-out for you. The whole equivalent of what we built collapses to one block.

```rust
use freecs::{ecs, Entity};

#[derive(Default, Clone)] pub struct Position { pub x: f32, pub y: f32 }
#[derive(Default, Clone)] pub struct Velocity { pub x: f32, pub y: f32 }

#[derive(Debug, Clone)]
pub struct CollisionEvent {
    pub entity_a: Entity,
    pub entity_b: Entity,
}

ecs! {
    World {
        position: Position => POSITION,
        velocity: Velocity => VELOCITY,
    }
    Tags {
        player => PLAYER,
        enemy => ENEMY,
    }
    Events {
        collision: CollisionEvent,
    }
    Resources {
        delta_time: f32,
    }
}
```

That declaration generates the `World` struct, the `ComponentArrays`, every typed accessor (`get_position`, `set_position`, `get_position_mut`, `modify_position` for closure-style mutation, `add_position` for adding a defaulted component, `entity_has_position`, and others), `add_components` and `remove_components` with the typed mask helpers, the tag set with its own `add_player`/`has_player`/`query_player`, the double-buffered event queue with `send_collision`/`drain_collision`/`read_collision`, the command buffer with typed `queue_set_position` variants, the table-edge cache, the query cache, and the change-detection tick stamps. The `Schedule` type is a separate piece of the crate and works the same way as the one we built.

The scaling answer the hand-built version does not give is right here. Adding `health: Health => HEALTH,` to the declaration writes the entire per-component fan-out for `Health` automatically, every accessor, every storage site, every cache update. Adding a new event type or a new tag is one line. The eleven edits per component become zero edits, and a kernel that handles two component types and one event type handles fifty of each the same way.

Using it from a system looks like the following.

```rust
fn physics_system(world: &mut World) {
    let dt = world.resources.delta_time;
    world.query_mut()
        .with(POSITION | VELOCITY)
        .iter(|_entity, table, index| {
            table.position[index].x += table.velocity[index].x * dt;
            table.position[index].y += table.velocity[index].y * dt;
        });
}
```

The query builder, the typed table access, the change tracking, the multi-world option for more than 64 component types, the optional Rayon-based parallel iteration, the entity builder, all of it sits on top of the kernel we built. The kernel itself is unchanged.

The macro design itself is not in this series. Once the kernel underneath exists, writing a macro to stamp out the per-component fan-out is mechanical, and freecs already does it. The production version is on crates.io if you want to use it rather than rebuild it. The source is at [matthewjberger/freecs](https://github.com/matthewjberger/freecs) if you want to see how the macro arms work.

## Where the engine goes from here

The ECS is the bottom of the stack. A game engine adds rendering, asset loading, input, audio, scene serialization, scripting hooks, and so on. Each of these is most naturally expressed as components plus systems. The renderer is a system that reads `Transform + Mesh + Material` and submits draw calls. The asset loader is a system that watches a `Pending<Texture>` component and replaces it with `Loaded<Texture>` when the file is ready. Scene serialization is a function that walks `for_each(ALL, ...)` and emits the components per entity.

The ECS does not solve any of those problems. It makes each of them small and self-contained instead of tangled with everything else.

## The full file

The complete file is around 825 lines. It compiles standalone in a fresh Cargo project. The `main` function spawns a player, an enemy, and a landmark, runs a schedule of four systems for four frames, queues a despawn from inside a system at frame two, and exercises change detection, events, tags, and the command buffer in the process. Also available as a [gist](https://gist.github.com/matthewjberger/4578b6d03514523f5f345951c7395b40).

```rust
use std::collections::{HashMap, HashSet};

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
pub const COMPONENT_COUNT: usize = 2;

pub fn component_index(mask: u64) -> Option<usize> {
    match mask {
        POSITION => Some(0),
        VELOCITY => Some(1),
        _ => None,
    }
}

#[derive(Default)]
pub struct ComponentArrays {
    pub mask: u64,
    pub entities: Vec<Entity>,
    pub positions: Vec<Position>,
    pub positions_changed: Vec<u32>,
    pub velocities: Vec<Velocity>,
    pub velocities_changed: Vec<u32>,
}

#[derive(Default, Clone)]
pub struct TableEdges {
    pub add_edges: [Option<usize>; COMPONENT_COUNT],
    pub remove_edges: [Option<usize>; COMPONENT_COUNT],
}

#[derive(Clone)]
pub struct EventQueue<T> {
    pub current: Vec<T>,
    pub previous: Vec<T>,
}

impl<T> Default for EventQueue<T> {
    fn default() -> Self {
        Self {
            current: Vec::new(),
            previous: Vec::new(),
        }
    }
}

impl<T> EventQueue<T> {
    pub fn send(&mut self, event: T) {
        self.current.push(event);
    }

    pub fn read(&self) -> impl Iterator<Item = &T> {
        self.previous.iter().chain(self.current.iter())
    }

    pub fn drain(&mut self) -> impl Iterator<Item = T> + '_ {
        self.previous.drain(..).chain(self.current.drain(..))
    }

    pub fn update(&mut self) {
        self.previous.clear();
        std::mem::swap(&mut self.current, &mut self.previous);
    }

    pub fn len(&self) -> usize {
        self.current.len() + self.previous.len()
    }

    pub fn is_empty(&self) -> bool {
        self.current.is_empty() && self.previous.is_empty()
    }
}

#[derive(Debug, Clone)]
pub struct CollisionEvent {
    pub entity_a: Entity,
    pub entity_b: Entity,
}

pub enum Command {
    Spawn { mask: u64 },
    Despawn { entity: Entity },
    AddComponents { entity: Entity, mask: u64 },
    RemoveComponents { entity: Entity, mask: u64 },
    SetPosition { entity: Entity, value: Position },
    SetVelocity { entity: Entity, value: Velocity },
    AddPlayer { entity: Entity },
    RemovePlayer { entity: Entity },
    AddEnemy { entity: Entity },
    RemoveEnemy { entity: Entity },
}

#[derive(Default)]
pub struct Resources {
    pub delta_time: f32,
    pub game_time: f32,
}

#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
    pub current_tick: u32,
    pub last_tick: u32,
    pub collisions: EventQueue<CollisionEvent>,
    pub players: HashSet<Entity>,
    pub enemies: HashSet<Entity>,
    pub command_buffer: Vec<Command>,
    pub resources: Resources,
}

impl World {
    pub fn invalidate_query_cache_for_new_table(
        &mut self,
        new_mask: u64,
        new_table_index: usize,
    ) {
        for (query_mask, cached_tables) in self.query_cache.iter_mut() {
            if new_mask & query_mask == *query_mask {
                cached_tables.push(new_table_index);
            }
        }
    }

    pub fn get_or_create_table(&mut self, mask: u64) -> usize {
        if let Some(&index) = self.table_lookup.get(&mask) {
            return index;
        }
        let new_table_index = self.tables.len();
        self.tables.push(ComponentArrays {
            mask,
            ..Default::default()
        });
        self.table_edges.push(TableEdges::default());
        self.table_lookup.insert(mask, new_table_index);

        self.invalidate_query_cache_for_new_table(mask, new_table_index);

        for component_bit in [POSITION, VELOCITY] {
            let Some(component_index_value) = component_index(component_bit) else {
                continue;
            };
            for (existing_index, existing) in self.tables.iter().enumerate() {
                if existing.mask | component_bit == mask {
                    self.table_edges[existing_index].add_edges[component_index_value] =
                        Some(new_table_index);
                }
                if existing.mask & !component_bit == mask {
                    self.table_edges[existing_index].remove_edges[component_index_value] =
                        Some(new_table_index);
                }
            }
        }

        for component_bit in [POSITION, VELOCITY] {
            let Some(component_index_value) = component_index(component_bit) else {
                continue;
            };
            if let Some(&dest) = self.table_lookup.get(&(mask | component_bit)) {
                self.table_edges[new_table_index].add_edges[component_index_value] = Some(dest);
            }
            if mask & component_bit != 0
                && let Some(&dest) = self.table_lookup.get(&(mask & !component_bit))
            {
                self.table_edges[new_table_index].remove_edges[component_index_value] = Some(dest);
            }
        }

        new_table_index
    }

    pub fn cached_tables(&mut self, mask: u64) -> &[usize] {
        if !self.query_cache.contains_key(&mask) {
            let matching: Vec<usize> = self
                .tables
                .iter()
                .enumerate()
                .filter(|(_, table)| table.mask & mask == mask)
                .map(|(index, _)| index)
                .collect();
            self.query_cache.insert(mask, matching);
        }
        &self.query_cache[&mask]
    }

    pub fn current_tick(&self) -> u32 {
        self.current_tick
    }

    pub fn last_tick(&self) -> u32 {
        self.last_tick
    }

    pub fn step(&mut self) {
        self.collisions.update();
        self.last_tick = self.current_tick;
        self.current_tick = self.current_tick.wrapping_add(1);
    }

    pub fn spawn(&mut self, mask: u64) -> Entity {
        let entity = self.allocator.allocate();
        let table_index = self.get_or_create_table(mask);
        let current_tick = self.current_tick;
        let table = &mut self.tables[table_index];
        let array_index = table.entities.len();

        table.entities.push(entity);
        if mask & POSITION != 0 {
            table.positions.push(Position::default());
            table.positions_changed.push(current_tick);
        }
        if mask & VELOCITY != 0 {
            table.velocities.push(Velocity::default());
            table.velocities_changed.push(current_tick);
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
        let current_tick = self.current_tick;
        let table = &mut self.tables[table_index];
        if table.mask & POSITION == 0 {
            return None;
        }
        table.positions_changed[array_index] = current_tick;
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
        let current_tick = self.current_tick;
        let table = &mut self.tables[table_index];
        if table.mask & VELOCITY == 0 {
            return None;
        }
        table.velocities_changed[array_index] = current_tick;
        Some(&mut table.velocities[array_index])
    }

    pub fn set_position(&mut self, entity: Entity, value: Position) {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return;
        };
        let current_tick = self.current_tick;
        if self.tables[table_index].mask & POSITION != 0 {
            self.tables[table_index].positions[array_index] = value;
            self.tables[table_index].positions_changed[array_index] = current_tick;
            return;
        }
        self.add_components(entity, POSITION);
        if let Some((table_index, array_index)) = self.entity_locations.get(entity) {
            self.tables[table_index].positions[array_index] = value;
            self.tables[table_index].positions_changed[array_index] = current_tick;
        }
    }

    pub fn set_velocity(&mut self, entity: Entity, value: Velocity) {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return;
        };
        let current_tick = self.current_tick;
        if self.tables[table_index].mask & VELOCITY != 0 {
            self.tables[table_index].velocities[array_index] = value;
            self.tables[table_index].velocities_changed[array_index] = current_tick;
            return;
        }
        self.add_components(entity, VELOCITY);
        if let Some((table_index, array_index)) = self.entity_locations.get(entity) {
            self.tables[table_index].velocities[array_index] = value;
            self.tables[table_index].velocities_changed[array_index] = current_tick;
        }
    }

    pub fn move_entity(
        &mut self,
        entity: Entity,
        from_table: usize,
        from_index: usize,
        to_table: usize,
    ) {
        let from_mask = self.tables[from_table].mask;
        let current_tick = self.current_tick;

        let position = if from_mask & POSITION != 0 {
            Some(std::mem::take(
                &mut self.tables[from_table].positions[from_index],
            ))
        } else {
            None
        };
        let velocity = if from_mask & VELOCITY != 0 {
            Some(std::mem::take(
                &mut self.tables[from_table].velocities[from_index],
            ))
        } else {
            None
        };

        let to_array_index = {
            let to = &mut self.tables[to_table];
            let array_index = to.entities.len();
            to.entities.push(entity);
            if to.mask & POSITION != 0 {
                to.positions.push(position.unwrap_or_default());
                to.positions_changed.push(current_tick);
            }
            if to.mask & VELOCITY != 0 {
                to.velocities.push(velocity.unwrap_or_default());
                to.velocities_changed.push(current_tick);
            }
            array_index
        };

        self.entity_locations.set(entity, to_table, to_array_index);

        let from = &mut self.tables[from_table];
        let last_index = from.entities.len() - 1;
        let swapped = if from_index < last_index {
            Some(from.entities[last_index])
        } else {
            None
        };

        from.entities.swap_remove(from_index);
        if from.mask & POSITION != 0 {
            from.positions.swap_remove(from_index);
            from.positions_changed.swap_remove(from_index);
        }
        if from.mask & VELOCITY != 0 {
            from.velocities.swap_remove(from_index);
            from.velocities_changed.swap_remove(from_index);
        }

        if let Some(moved) = swapped {
            self.entity_locations.set(moved, from_table, from_index);
        }
    }

    pub fn add_components(&mut self, entity: Entity, mask: u64) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };
        let current_mask = self.tables[table_index].mask;
        if current_mask & mask == mask {
            return true;
        }

        let cached = if mask.count_ones() == 1 {
            component_index(mask)
                .and_then(|index| self.table_edges[table_index].add_edges[index])
        } else {
            None
        };

        let new_table_index = match cached {
            Some(index) => index,
            None => self.get_or_create_table(current_mask | mask),
        };

        self.move_entity(entity, table_index, array_index, new_table_index);
        true
    }

    pub fn remove_components(&mut self, entity: Entity, mask: u64) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };
        let current_mask = self.tables[table_index].mask;
        if current_mask & mask == 0 {
            return true;
        }

        let cached = if mask.count_ones() == 1 {
            component_index(mask)
                .and_then(|index| self.table_edges[table_index].remove_edges[index])
        } else {
            None
        };

        let new_table_index = match cached {
            Some(index) => index,
            None => self.get_or_create_table(current_mask & !mask),
        };

        self.move_entity(entity, table_index, array_index, new_table_index);
        true
    }

    pub fn despawn(&mut self, entity: Entity) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };

        self.entity_locations.mark_deallocated(entity.id);
        self.allocator.deallocate(entity);
        self.players.remove(&entity);
        self.enemies.remove(&entity);

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
            table.positions_changed.swap_remove(array_index);
        }
        if table.mask & VELOCITY != 0 {
            table.velocities.swap_remove(array_index);
            table.velocities_changed.swap_remove(array_index);
        }

        if let Some(moved) = swapped {
            self.entity_locations.set(moved, table_index, array_index);
        }

        true
    }

    pub fn query_entities(&self, mask: u64) -> impl Iterator<Item = Entity> + '_ {
        self.tables
            .iter()
            .filter(move |table| table.mask & mask == mask)
            .flat_map(|table| table.entities.iter().copied())
    }

    pub fn for_each<F>(&self, include: u64, exclude: u64, mut f: F)
    where
        F: FnMut(Entity, &ComponentArrays, usize),
    {
        for table in &self.tables {
            if table.mask & include != include || table.mask & exclude != 0 {
                continue;
            }
            for array_index in 0..table.entities.len() {
                let entity = table.entities[array_index];
                f(entity, table, array_index);
            }
        }
    }

    pub fn for_each_mut<F>(&mut self, include: u64, exclude: u64, mut f: F)
    where
        F: FnMut(Entity, &mut ComponentArrays, usize),
    {
        let table_indices: Vec<usize> = self.cached_tables(include).to_vec();
        for table_index in table_indices {
            let table = &mut self.tables[table_index];
            if table.mask & exclude != 0 {
                continue;
            }
            for array_index in 0..table.entities.len() {
                let entity = table.entities[array_index];
                f(entity, table, array_index);
            }
        }
    }

    pub fn for_each_mut_changed<F>(&mut self, include: u64, exclude: u64, mut f: F)
    where
        F: FnMut(Entity, &mut ComponentArrays, usize),
    {
        let since_tick = self.last_tick;
        let table_indices: Vec<usize> = self.cached_tables(include).to_vec();
        for table_index in table_indices {
            let table = &mut self.tables[table_index];
            if table.mask & exclude != 0 {
                continue;
            }
            for array_index in 0..table.entities.len() {
                let mut changed = false;
                if include & POSITION != 0
                    && table.mask & POSITION != 0
                    && table.positions_changed[array_index] > since_tick
                {
                    changed = true;
                }
                if include & VELOCITY != 0
                    && table.mask & VELOCITY != 0
                    && table.velocities_changed[array_index] > since_tick
                {
                    changed = true;
                }
                if changed {
                    let entity = table.entities[array_index];
                    f(entity, table, array_index);
                }
            }
        }
    }

    pub fn send_collision(&mut self, event: CollisionEvent) {
        self.collisions.send(event);
    }

    pub fn read_collisions(&self) -> impl Iterator<Item = &CollisionEvent> {
        self.collisions.read()
    }

    pub fn drain_collisions(&mut self) -> impl Iterator<Item = CollisionEvent> + '_ {
        self.collisions.drain()
    }

    pub fn add_player(&mut self, entity: Entity) {
        if self.entity_locations.get(entity).is_some() {
            self.players.insert(entity);
        }
    }

    pub fn remove_player(&mut self, entity: Entity) -> bool {
        self.players.remove(&entity)
    }

    pub fn has_player(&self, entity: Entity) -> bool {
        self.players.contains(&entity)
    }

    pub fn query_players(&self) -> impl Iterator<Item = Entity> + '_ {
        self.players.iter().copied()
    }

    pub fn add_enemy(&mut self, entity: Entity) {
        if self.entity_locations.get(entity).is_some() {
            self.enemies.insert(entity);
        }
    }

    pub fn remove_enemy(&mut self, entity: Entity) -> bool {
        self.enemies.remove(&entity)
    }

    pub fn has_enemy(&self, entity: Entity) -> bool {
        self.enemies.contains(&entity)
    }

    pub fn query_enemies(&self) -> impl Iterator<Item = Entity> + '_ {
        self.enemies.iter().copied()
    }

    pub fn queue_spawn(&mut self, mask: u64) {
        self.command_buffer.push(Command::Spawn { mask });
    }

    pub fn queue_despawn(&mut self, entity: Entity) {
        self.command_buffer.push(Command::Despawn { entity });
    }

    pub fn queue_add_components(&mut self, entity: Entity, mask: u64) {
        self.command_buffer
            .push(Command::AddComponents { entity, mask });
    }

    pub fn queue_remove_components(&mut self, entity: Entity, mask: u64) {
        self.command_buffer
            .push(Command::RemoveComponents { entity, mask });
    }

    pub fn queue_set_position(&mut self, entity: Entity, value: Position) {
        self.command_buffer
            .push(Command::SetPosition { entity, value });
    }

    pub fn queue_set_velocity(&mut self, entity: Entity, value: Velocity) {
        self.command_buffer
            .push(Command::SetVelocity { entity, value });
    }

    pub fn queue_add_player(&mut self, entity: Entity) {
        self.command_buffer.push(Command::AddPlayer { entity });
    }

    pub fn queue_remove_player(&mut self, entity: Entity) {
        self.command_buffer.push(Command::RemovePlayer { entity });
    }

    pub fn queue_add_enemy(&mut self, entity: Entity) {
        self.command_buffer.push(Command::AddEnemy { entity });
    }

    pub fn queue_remove_enemy(&mut self, entity: Entity) {
        self.command_buffer.push(Command::RemoveEnemy { entity });
    }

    pub fn apply_commands(&mut self) {
        let commands = std::mem::take(&mut self.command_buffer);
        for command in commands {
            match command {
                Command::Spawn { mask } => {
                    self.spawn(mask);
                }
                Command::Despawn { entity } => {
                    self.despawn(entity);
                }
                Command::AddComponents { entity, mask } => {
                    self.add_components(entity, mask);
                }
                Command::RemoveComponents { entity, mask } => {
                    self.remove_components(entity, mask);
                }
                Command::SetPosition { entity, value } => {
                    self.set_position(entity, value);
                }
                Command::SetVelocity { entity, value } => {
                    self.set_velocity(entity, value);
                }
                Command::AddPlayer { entity } => {
                    self.add_player(entity);
                }
                Command::RemovePlayer { entity } => {
                    self.remove_player(entity);
                }
                Command::AddEnemy { entity } => {
                    self.add_enemy(entity);
                }
                Command::RemoveEnemy { entity } => {
                    self.remove_enemy(entity);
                }
            }
        }
    }
}

pub type SystemFn = Box<dyn FnMut(&mut World)>;

#[derive(Default)]
pub struct Schedule {
    pub systems: Vec<(&'static str, SystemFn)>,
}

impl Schedule {
    pub fn add<F>(&mut self, name: &'static str, system: F) -> &mut Self
    where
        F: FnMut(&mut World) + 'static,
    {
        self.systems.push((name, Box::new(system)));
        self
    }

    pub fn run(&mut self, world: &mut World) {
        for (_, system) in &mut self.systems {
            system(world);
        }
    }
}

#[derive(Default)]
pub struct EntityBuilder {
    position: Option<Position>,
    velocity: Option<Velocity>,
}

impl EntityBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_position(mut self, value: Position) -> Self {
        self.position = Some(value);
        self
    }

    pub fn with_velocity(mut self, value: Velocity) -> Self {
        self.velocity = Some(value);
        self
    }

    pub fn spawn(self, world: &mut World) -> Entity {
        let mut mask = 0u64;
        if self.position.is_some() {
            mask |= POSITION;
        }
        if self.velocity.is_some() {
            mask |= VELOCITY;
        }
        let entity = world.spawn(mask);
        if let Some(value) = self.position {
            world.set_position(entity, value);
        }
        if let Some(value) = self.velocity {
            world.set_velocity(entity, value);
        }
        entity
    }
}

fn physics_system(world: &mut World) {
    let dt = world.resources.delta_time;
    let current_tick = world.current_tick();
    world.for_each_mut(POSITION | VELOCITY, 0, |_entity, table, index| {
        table.positions[index].x += table.velocities[index].x * dt;
        table.positions[index].y += table.velocities[index].y * dt;
        table.positions_changed[index] = current_tick;
    });
}

fn collision_system(world: &mut World) {
    let positions: Vec<(Entity, Position)> = world
        .query_entities(POSITION)
        .filter_map(|entity| world.get_position(entity).map(|position| (entity, position.clone())))
        .collect();

    for index_a in 0..positions.len() {
        for index_b in (index_a + 1)..positions.len() {
            let (entity_a, position_a) = &positions[index_a];
            let (entity_b, position_b) = &positions[index_b];
            let delta_x = position_a.x - position_b.x;
            let delta_y = position_a.y - position_b.y;
            if delta_x * delta_x + delta_y * delta_y < 1.0 {
                world.send_collision(CollisionEvent {
                    entity_a: *entity_a,
                    entity_b: *entity_b,
                });
            }
        }
    }
}

fn collision_reporter(world: &mut World) {
    for event in world.drain_collisions() {
        println!("collision: {:?} and {:?}", event.entity_a, event.entity_b);
    }
}

fn render_changed_system(world: &mut World) {
    world.for_each_mut_changed(POSITION, 0, |entity, table, index| {
        println!(
            "redraw {:?}: ({}, {})",
            entity, table.positions[index].x, table.positions[index].y
        );
    });
}

fn main() {
    let mut world = World::default();
    world.resources.delta_time = 1.0 / 60.0;

    let player = EntityBuilder::new()
        .with_position(Position { x: 0.0, y: 0.0 })
        .with_velocity(Velocity { x: 30.0, y: 0.0 })
        .spawn(&mut world);
    world.add_player(player);

    let enemy = EntityBuilder::new()
        .with_position(Position { x: 3.0, y: 0.0 })
        .with_velocity(Velocity { x: -30.0, y: 0.0 })
        .spawn(&mut world);
    world.add_enemy(enemy);

    let _landmark = EntityBuilder::new()
        .with_position(Position { x: 10.0, y: 10.0 })
        .spawn(&mut world);

    let mut schedule = Schedule::default();
    schedule
        .add("physics", physics_system)
        .add("collision", collision_system)
        .add("collision_reporter", collision_reporter)
        .add("render_changed", render_changed_system);

    world.step();

    for frame in 0..4 {
        println!("--- frame {frame} ---");
        schedule.run(&mut world);

        if frame == 2 {
            world.queue_despawn(enemy);
        }
        world.apply_commands();

        world.resources.game_time += world.resources.delta_time;
        world.step();
    }

    println!("--- final ---");
    println!("players: {}", world.query_players().count());
    println!("enemies: {}", world.query_enemies().count());
    println!("entities with position: {}", world.query_entities(POSITION).count());
    println!("game_time: {:.4}", world.resources.game_time);
}
```

`cargo run` produces four frames of output. Frames 0 and 1 print position-redraw lines for the player and enemy as they close in on each other, with no collision yet because they are still more than one unit apart. Frame 2 prints a collision line followed by both redraw lines as the two entities meet at the same x, and the main loop queues the enemy for despawn at the end of the frame. Frame 3 prints only the player's redraw, since the enemy is gone and the landmark has not moved since spawn. The render-changed system never prints the landmark because nothing has touched its position since the initial `set_position` write, which means its tick stamp stayed at zero while the watermark advanced past it.

One subtlety to call out in `collision_system`. It collects positions into a `Vec<(Entity, Position)>` before doing the O(N^2) check rather than reading them through `world.get_position` during the inner loop. The reason is the borrow checker. We cannot hold immutable borrows of `world` across the mutable call to `world.send_collision` later in the same iteration. Collecting up front releases all the read borrows before any of the writes begin. A reader copying this pattern should know that is what the up-front `collect()` is doing.

---

freecs lives at [matthewjberger/freecs](https://github.com/matthewjberger/freecs) and on crates.io as `freecs`. It is what [nightshade](https://github.com/matthewjberger/nightshade), my game engine, uses for every subsystem that touches entities. Transforms, scene graph, rendering, asset loading, input, audio, scripting, all of it goes through the same World. Once the ECS is in place, the rest of the engine is systems on top.

