+++
title = "Build your own ECS (part 3), change detection, events, tags, and commands"
tags = ["rust", "ecs", "game-engine", "tutorial"]
categories = ["rust"]
excerpt = "The four subsystems that turn the storage layer into something a real game engine can sit on top of. A watermark-based change detector, sequence-numbered event channels, sparse-set tags, and a deferred command buffer."
series = "ecs"
series_part = 3
+++

*This is part 3 of 3 of a series.* ← [Structural change and queries](@/posts/2026-04-12-build-your-own-ecs-structural-change.md)

[Part 2](@/posts/2026-04-12-build-your-own-ecs-structural-change.md) finished with a working archetype ECS. Spawn into an archetype, add and remove components at runtime, query and iterate by component combination, despawn safely. The storage is solid, the routing is fast, and you could build a small game on it. What you could not do was build a *frame loop* on it. The missing pieces are the things systems use to talk to each other and to the world structurally.

This post adds four pieces. Change detection records what moved so other systems can do incremental work instead of touching everything each frame. Events let one system message another across the schedule without coupling them. Sparse-set tags carry markers that flip too often to live in the archetype mask. Command buffers queue mutations during iteration so the loop does not invalidate itself. A small system schedule at the end runs the four in order.

By the end of the post you have an ECS kernel that closely mirrors what production libraries expose.

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

The `wrapping_add` here is a corner this design papers over. After `2^32` frames the tick rolls back to zero, and a slot stamped at the old `u32::MAX` suddenly looks ancient when `last_tick` is also `u32::MAX`. At 60 frames per second that is about 2.3 years of continuous runtime, fine for a game and not fine for a long-running server. A production engine widens the tick to `u64`, rebases the stamps periodically, or compares ticks with wrapping subtraction and a sign check so the ordering survives the rollover. freecs does the last of these.

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

The tricky part is lifetime. The queue cannot empty itself the moment an event is written because a system reading later in the same frame would miss it. It cannot keep events forever because nothing would ever drain. The classic answer is double buffering, two vecs swapped once per frame, so an event survives into the next frame and disappears after. It works, and an earlier version of this kernel shipped exactly that, but it gives every reader the same view. Two systems that both want to consume the queue cannot each see every event exactly once. One drains and the other starves, or both read and both see duplicates across the frame boundary.

Sequence numbers fix that and need less machinery. Events live in one flat vec. Every event has a monotonically increasing sequence number, implicitly, by position. The channel remembers `base_sequence`, the count of events already dropped off the front, so the event at index `i` has sequence `base_sequence + i + 1`. A reader owns a cursor, the sequence it has consumed through. Reading is slicing from the cursor forward. After reading, the reader records the current head as its new cursor.

```rust
#[derive(Clone)]
pub struct EventChannel<T> {
    pub events: Vec<T>,
    pub base_sequence: u64,
    pub previous_update_sequence: u64,
}

impl<T> Default for EventChannel<T> {
    fn default() -> Self {
        Self {
            events: Vec::new(),
            base_sequence: 0,
            previous_update_sequence: 0,
        }
    }
}

impl<T> EventChannel<T> {
    pub fn send(&mut self, event: T) {
        self.events.push(event);
    }

    pub fn sequence(&self) -> u64 {
        self.base_sequence + self.events.len() as u64
    }

    pub fn events_since(&self, cursor: u64) -> &[T] {
        let start = cursor
            .saturating_sub(self.base_sequence)
            .min(self.events.len() as u64) as usize;
        &self.events[start..]
    }

    pub fn read(&self) -> impl Iterator<Item = &T> {
        self.events.iter()
    }

    pub fn trim(&mut self, up_to_sequence: u64) {
        let drop_count = up_to_sequence
            .saturating_sub(self.base_sequence)
            .min(self.events.len() as u64) as usize;
        self.events.drain(..drop_count);
        self.base_sequence += drop_count as u64;
    }

    pub fn update(&mut self) {
        let expire = self.previous_update_sequence;
        self.trim(expire);
        self.previous_update_sequence = self.sequence();
    }

    pub fn len(&self) -> usize {
        self.events.len()
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}
```

The manual `Default` impl exists because deriving it would demand `T: Default`, and event types have no reason to carry that bound.

`send` pushes. `sequence` reports the head. `events_since(cursor)` returns the slice of everything newer than the cursor, clamped at both ends, so a reader that has fallen behind the buffer gets whatever is still there instead of a panic. `trim` drops consumed events off the front and advances `base_sequence`, which is what keeps sequence numbers stable under a reader while memory gets reclaimed.

`update` is the frame hook, and it is where the two-frame rule survives. The channel remembers where the head was at the previous `update` and trims to that point. An event sent during frame N is untouched by the update that ends frame N, because the remembered head predates it, and is dropped by the update that ends frame N+1. Readers that do not track cursors just call `read` or `len` and see everything still buffered, exactly the view the old double buffer gave them.

Each event type gets its own channel, stored as a field on the `World`.

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
    pub collisions: EventChannel<CollisionEvent>,
}

impl World {
    pub fn send_collision(&mut self, event: CollisionEvent) {
        self.collisions.send(event);
    }

    pub fn read_collisions(&self) -> impl Iterator<Item = &CollisionEvent> {
        self.collisions.read()
    }

    pub fn read_collisions_since(&self, cursor: u64) -> &[CollisionEvent] {
        self.collisions.events_since(cursor)
    }

    pub fn collision_sequence(&self) -> u64 {
        self.collisions.sequence()
    }
}
```

The familiar fan-out. One set of methods per event type, hand-written here. A macro would generate them. The cost is the same as for component accessors.

A consumer's cursor has to live somewhere across frames, and a system is a plain function with no state of its own. The natural home in this design is the `Resources` struct introduced later in this post. The demo keeps `world.resources.collision_cursor` and its reporter system reads everything since the cursor, prints it, then records the new head. Two consumers keep two cursors and each sees each event exactly once. A consumer that skips a frame catches up from wherever its cursor points, provided it reads before the two-frame expiry claims the events.

`step()` advances each channel. It is the same `step()` that advances the tick.

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

One production note. A channel that nobody reads or trims grows without bound. freecs caps the buffer and drops the oldest half when a send finds it full, a backstop the kernel here leaves out to keep the shape visible.

## Sparse-set tags

A tag is a membership set with three operations that all need to be O(1), insert, remove, and "does this entity carry it". The reason a tag lives outside the archetype mask is the migration cost. A bit in the mask means flipping the tag triggers `move_entity`, which pulls every other component off the entity, pushes them into a new table, and compacts the old slot. For markers that flip often (the "selected" tag in an RTS, a frame-local "took damage this frame" flag, an enemy alertness state), the migration is pure waste next to a set insert.

The masking approach is not wrong for tags that rarely change. `Player` and `Enemy` are reasonable as archetype bits if those identities are set once at spawn and never updated. The reason this kernel puts them in a side structure anyway is uniformity. Code that wants to ask "is this entity a player" should not need to know whether the answer comes from a mask check or a set lookup.

The structure that earns the section its name is a sparse set, two arrays that point into each other. `dense` is the packed list of entities carrying the tag, in insertion order, so iterating members walks contiguous memory. `sparse` is indexed by entity id and holds that id's position in `dense`, or a sentinel meaning absent. Membership is two array reads. Insert appends to `dense` and records the position. Remove swap-removes from `dense` and patches the `sparse` entry of whichever entity got moved into the hole, the same trick `despawn` plays on the component vecs.

```rust
const TAG_ABSENT: u32 = u32::MAX;

#[derive(Default, Clone)]
pub struct SparseTagSet {
    pub dense: Vec<Entity>,
    pub sparse: Vec<u32>,
}

impl SparseTagSet {
    pub fn insert(&mut self, entity: Entity) -> bool {
        let index = entity.id as usize;
        if index >= self.sparse.len() {
            self.sparse.resize(index + 1, TAG_ABSENT);
        }
        let slot = self.sparse[index];
        if slot != TAG_ABSENT {
            let existing = &mut self.dense[slot as usize];
            if *existing == entity {
                return false;
            }
            *existing = entity;
            return true;
        }
        self.sparse[index] = self.dense.len() as u32;
        self.dense.push(entity);
        true
    }

    pub fn remove(&mut self, entity: Entity) -> bool {
        let index = entity.id as usize;
        let Some(&slot) = self.sparse.get(index) else {
            return false;
        };
        if slot == TAG_ABSENT || self.dense[slot as usize] != entity {
            return false;
        }
        self.dense.swap_remove(slot as usize);
        self.sparse[index] = TAG_ABSENT;
        if (slot as usize) < self.dense.len() {
            let moved = self.dense[slot as usize];
            self.sparse[moved.id as usize] = slot;
        }
        true
    }

    pub fn contains(&self, entity: Entity) -> bool {
        self.sparse
            .get(entity.id as usize)
            .is_some_and(|&slot| slot != TAG_ABSENT && self.dense[slot as usize] == entity)
    }

    pub fn iter(&self) -> impl Iterator<Item = Entity> + '_ {
        self.dense.iter().copied()
    }

    pub fn len(&self) -> usize {
        self.dense.len()
    }

    pub fn is_empty(&self) -> bool {
        self.dense.is_empty()
    }
}
```

Storing the whole `Entity` in `dense` rather than the bare id makes membership generation-checked for free. A stale handle whose id was recycled compares unequal against the stored entity, so `contains` answers false, the same fail-closed behavior the location map gives component access. `insert` overwrites a stale entry for the same id instead of growing, which lets a recycled entity take over its predecessor's slot cleanly.

A `HashSet<Entity>` would give the same external API in three lines and is a fine stand-in while prototyping. The sparse set buys membership checks that are array probes with no hashing, iteration over members that is a dense contiguous walk, and a deterministic iteration order. Determinism starts to matter the moment replays or lockstep networking show up, because a hash set yields its members in whatever order the hasher seeded that particular run.

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
    pub collisions: EventChannel<CollisionEvent>,
    pub players: SparseTagSet,
    pub enemies: SparseTagSet,
}

impl World {
    pub fn add_player(&mut self, entity: Entity) {
        if self.entity_locations.get(entity).is_some() {
            self.players.insert(entity);
        }
    }

    pub fn remove_player(&mut self, entity: Entity) -> bool {
        self.players.remove(entity)
    }

    pub fn has_player(&self, entity: Entity) -> bool {
        self.players.contains(entity)
    }

    pub fn query_players(&self) -> impl Iterator<Item = Entity> + '_ {
        self.players.iter()
    }

    pub fn add_enemy(&mut self, entity: Entity) {
        if self.entity_locations.get(entity).is_some() {
            self.enemies.insert(entity);
        }
    }

    pub fn remove_enemy(&mut self, entity: Entity) -> bool {
        self.enemies.remove(entity)
    }

    pub fn has_enemy(&self, entity: Entity) -> bool {
        self.enemies.contains(entity)
    }

    pub fn query_enemies(&self) -> impl Iterator<Item = Entity> + '_ {
        self.enemies.iter()
    }
}
```

Insertion and removal never touch the archetype storage. Querying "all players" yields straight out of `dense`. Combined queries (a `for_each` over `POSITION | VELOCITY` plus a `has_player` filter) walk the tables and check the tag set per entity, two array reads each.

`despawn` needs to clear the entity out of every tag set, otherwise stale entries pile up in `dense`. Add these lines to the existing `despawn`.

```rust
self.players.remove(entity);
self.enemies.remove(entity);
```

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
    pub collisions: EventChannel<CollisionEvent>,
    pub players: SparseTagSet,
    pub enemies: SparseTagSet,
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
    pub collision_cursor: u64,
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
    pub collisions: EventChannel<CollisionEvent>,
    pub players: SparseTagSet,
    pub enemies: SparseTagSet,
    pub command_buffer: Vec<Command>,
    pub resources: Resources,
}
```

A system reads from resources by accessing `world.resources.delta_time` and writes by assigning to `world.resources.game_time = ...`. No accessor functions, no per-resource fan-out. This is also where the event cursor from the events section lives, `collision_cursor`, cross-frame reader state with no better owner. The freecs macro shown later in the post generates the same shape from a `Resources { delta_time: f32 }` block at the macro site. We are building the hand-written equivalent.

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

The `World` grew seven fields: `current_tick` and `last_tick` for change detection, `collisions` as a sequence-numbered event channel, `players` and `enemies` as sparse-set tags, `command_buffer` for deferred structural changes, and `resources` for global state. Each `ComponentArrays` grew a parallel `_changed: Vec<u32>` tick array per component.

New operations on `World`. `step` to advance the frame, `for_each_mut_changed` to iterate only the slots touched since last step, `send_collision`, `read_collisions`, and the cursor pair `read_collisions_since` and `collision_sequence` for cross-system messaging, the tag set with `add_player`/`remove_player`/`has_player`/`query_players` (and the same for enemy), the command-buffer methods `queue_spawn`/`queue_despawn`/`queue_set_position`/... and `apply_commands` to flush them, plus direct field access on `world.resources` for global state. A `Schedule` struct that runs systems in order each frame.

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

[freecs](https://github.com/matthewjberger/freecs) is what these three posts scale to. Same data layout, same archetype graph, same query cache, same watermark change detection, same sparse-set tags and event channels. The difference is a single declarative `macro_rules!` macro on top that takes one component declaration and writes the entire fan-out for you.

This is also where the design parts ways with bevy and hecs. Those crates solve the fan-out problem at runtime: a component is registered when first used, stored in a type-erased column, and reached through a `TypeId` lookup and a downcast. That is what lets them accept any user type without code generation, and it costs a layer of dynamic indirection on every access. freecs moves the same work to compile time. Because the macro is handed the complete component set, it can emit a concrete field and a concrete typed accessor per component, so `get_position` is a direct field access with no erasure and no dispatch. The trade is that the component set is fixed when the macro expands rather than open-ended at runtime, which for a single game is the set you already know. The whole equivalent of what we built collapses to one block.

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

That declaration generates the `World` struct, the `ComponentArrays`, every typed accessor (`get_position`, `set_position`, `get_position_mut`, `modify_position` for closure-style mutation, `add_position` for adding a defaulted component, `entity_has_position`, and others), `add_components` and `remove_components` with the typed mask helpers, the tag set with its own `add_player`/`has_player`/`query_player`, the event channel with `send_collision`, `read_collision`, and the cursor pair `read_collision_since` and `sequence_collision`, the command buffer with typed `queue_set_position` variants, the table-edge cache, the query cache, and the change-detection tick stamps. The `Schedule` type is a separate piece of the crate and works the same way as the one we built.

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

freecs also generates a few things this series does not build directly. `modify_position(entity, f)` mutates a component through a closure that releases the borrow at the end of the call, so you can write `world.modify_position(entity, |p| p.x += 1.0)` and access the world again on the next line without an explicit drop. `spawn_batch(mask, count, init)` reserves capacity for N entities and runs an init closure on each freshly-pushed slot in one call, which is the primitive a real game uses for bullet spawning, particle systems, and level loading. `par_for_each_mut` parallelizes iteration via Rayon when the entity count and per-entity work both justify the overhead. Slice iteration (`iter_position_slices_mut`) hands out `&mut [Position]` for SIMD-friendly inner loops. The multi-world form `ecs! { Game { CoreWorld { ... } RenderWorld { ... } } }` splits components across logical worlds with a shared entity allocator when the 64-component-per-world ceiling is not enough. Each of these is a mechanical extension of the kernel from this series, layered on without changing how the data is stored.

The macro design itself is not in this series. Once the kernel underneath exists, writing a macro to stamp out the per-component fan-out is mechanical, and freecs already does it. The production version is on crates.io if you want to use it rather than rebuild it. The source is at [matthewjberger/freecs](https://github.com/matthewjberger/freecs) if you want to see how the macro arms work.

## Where the engine goes from here

The ECS is the bottom of the stack. A game engine adds rendering, asset loading, input, audio, scene serialization, scripting hooks, and so on. Each of these is most naturally expressed as components plus systems. The renderer is a system that reads `Transform + Mesh + Material` and submits draw calls. The asset loader is a system that watches a `Pending<Texture>` component and replaces it with `Loaded<Texture>` when the file is ready. Scene serialization is a function that walks `for_each(ALL, ...)` and emits the components per entity.

The ECS does not solve any of those problems. It makes each of them small and self-contained instead of tangled with everything else.

## The full file

The complete file is around 980 lines and lives as a [gist](https://gist.github.com/matthewjberger/4578b6d03514523f5f345951c7395b40). It compiles standalone in a fresh Cargo project. The `main` function spawns a player, an enemy, and a landmark, runs a schedule of four systems for four frames, queues a despawn from inside a system at frame two, and exercises change detection, events, tags, and the command buffer in the process.

`cargo run` produces four frames of output. Frames 0 and 1 print position-redraw lines for the player and enemy as they close in on each other, with no collision yet because they are still more than one unit apart. Frame 2 prints a collision line followed by both redraw lines as the two entities meet at the same x, and the main loop queues the enemy for despawn at the end of the frame. Frame 3 prints only the player's redraw, since the enemy is gone and the landmark has not moved since spawn. The render-changed system never prints the landmark because nothing has touched its position since the initial `set_position` write, which means its tick stamp stayed at zero while the watermark advanced past it.

One subtlety to call out in `collision_system`. It collects positions into a `Vec<(Entity, Position)>` before doing the O(N^2) check rather than reading them through `world.get_position` during the inner loop. The reason is the borrow checker. We cannot hold immutable borrows of `world` across the mutable call to `world.send_collision` later in the same iteration. Collecting up front releases all the read borrows before any of the writes begin. A reader copying this pattern should know that is what the up-front `collect()` is doing.

---

freecs lives at [matthewjberger/freecs](https://github.com/matthewjberger/freecs) and on crates.io as `freecs`. It is what [nightshade](https://github.com/matthewjberger/nightshade), my game engine, uses for every subsystem that touches entities. Transforms, scene graph, rendering, asset loading, input, audio, scripting, all of it goes through the same World. Once the ECS is in place, the rest of the engine is systems on top.

