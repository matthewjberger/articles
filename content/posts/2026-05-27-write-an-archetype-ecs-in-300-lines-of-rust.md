+++
title = "Write an archetype ECS in 300 lines of Rust"
tags = ["rust", "ecs", "game-engine", "data-oriented", "tutorial"]
categories = ["rust"]
excerpt = "An archetype ECS built from nothing in a single file. Generational handles, struct-of-arrays tables, runtime component migration, and the two caches that keep it fast. Then the engine layer on top: change detection, events, tags, command buffers, resources, and a schedule."
+++

ECS stands for Entity Component System. An entity is a handle, a small id with no data and no methods. A component is a struct of data attached to an entity, like `Position` or `Velocity`. A system is a function that reads or writes the components of every entity matching a query, like "everything with a position and a velocity." The data lives in components, the work happens in systems, and entities are the keys that line them up.

This post builds one from nothing, in one file, with no proc-macros, no `unsafe`, and nothing outside the standard library. It is written so you can type it out as you read. Every section adds one idea, the code compiles after each one, and the running program does something you can check. By the end you have an archetype ECS kernel of about 300 lines, and then the engine layer that turns the kernel into something a frame loop can sit on.

The finished kernel is a [gist](https://gist.github.com/matthewjberger/ff6fc2aba33d94330fdadbbb99d45563) if you want the destination in front of you. The kernel plus the full engine layer is a [second gist](https://gist.github.com/matthewjberger/d4c11ec250cfd1a8d761f54cb0ae51f4). Neither is required reading. The point of the post is to build them.

## Why archetypes

The slow way to store components is one map per type:

```rust
struct World {
    positions: HashMap<Entity, Position>,
    velocities: HashMap<Entity, Velocity>,
}
```

This is correct and it is what most people reach for first. It is also slow in the exact place that matters. To advance physics you walk every entity that has both a position and a velocity, and for each one you do a hash lookup into two maps whose entries live at unrelated heap addresses. Ten thousand entities is twenty thousand cache misses per frame, every frame.

The data you read together is not stored together. The archetype layout fixes that. Group entities by which set of components they have, and inside each group store every component type as its own contiguous `Vec`. Everything with exactly `Position + Velocity` lives in one table; everything with `Position + Velocity + Vitality` lives in another. The position at row 7 and the velocity at row 7 in a given table belong to the same entity. A system becomes a walk over packed arrays, one cache line at a time, with no hashing and no pointer chasing. Adding or removing a component becomes a one-time move between tables instead of a per-access cost paid forever.

That is the whole idea. Five pieces make it work, and we build them in this order:

1. Generational handles, so a stale entity reference is detectable instead of silently wrong.
2. A dense location array, so finding an entity's data is an indexed load, not a hash.
3. Archetype tables in struct-of-arrays layout, the storage itself.
4. Runtime structural change, moving a row from one table to another when components are added or removed.
5. Two caches, one for migration and one for queries, so the common operations stay fast.

One note on style before the code. Everything here is plain data and free functions. `World` is a struct of `Vec`s and `HashMap`s with no methods and no hidden invariants, and every operation is a function that takes the world or the relevant fields as arguments. There is no encapsulation to protect because there is nothing to protect: the data is the interface. This is the data-oriented way to write it, and it happens to make the borrow checker easier to satisfy, because a function can borrow two fields of the world separately where a method would borrow the whole thing.

## Components and masks

Start with the components. They are plain structs. `Default` is required because a new row is zero-initialised when an entity gains a component it did not have before. `Clone` is convenient and costs nothing here.

```rust
#[derive(Default, Clone, Debug)]
struct Position { x: f32, y: f32 }

#[derive(Default, Clone, Debug)]
struct Velocity { dx: f32, dy: f32 }

#[derive(Default, Clone, Debug)]
struct Vitality { hp: f32 }
```

Every component type gets one bit. A set of components is then a single `u64` with those bits set, and we call it a mask. The mask is the identity of an archetype: two entities are stored together exactly when their masks are equal.

```rust
const POSITION: u64 = 1 << 0;
const VELOCITY: u64 = 1 << 1;
const VITALITY: u64 = 1 << 2;
const COMPONENT_COUNT: usize = 3;
```

`COMPONENT_COUNT` is the number of component bits. We use it later to size a fixed array. A `u64` mask gives 64 component types, which is the ceiling of this design and plenty for one game.

## Generational handles

An entity is not an object. It owns nothing. It is a handle the storage uses to find data. A bare `u32` index would work until you despawn an entity and spawn another, at which point the index gets reused and any old handle now points at a different entity. Nothing crashes. Your code just reads the wrong thing, which in a game means an enemy that suddenly tracks a wall.

The fix is a generation counter. The handle carries both an index and the generation it was minted at. Each index has a current generation stored in the world. When an entity is despawned, its index's generation is bumped, so any handle still holding the old generation no longer matches and is detectably stale.

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct Entity { index: u32, generation: u32 }
```

The allocator is two `Vec`s. `generations` maps an index to its current generation. `free_ids` holds indices that have been freed and are waiting to be handed out again.

```rust
fn alloc_entity(generations: &mut Vec<u32>, free_ids: &mut Vec<u32>) -> Entity {
    if let Some(index) = free_ids.pop() {
        Entity { index, generation: generations[index as usize] }
    } else {
        let index = generations.len() as u32;
        generations.push(0);
        Entity { index, generation: 0 }
    }
}

fn free_entity(generations: &mut Vec<u32>, free_ids: &mut Vec<u32>, e: Entity) {
    generations[e.index as usize] = generations[e.index as usize].wrapping_add(1);
    free_ids.push(e.index);
}

fn is_live(generations: &[u32], e: Entity) -> bool {
    generations.get(e.index as usize).copied() == Some(e.generation)
}
```

Allocation reuses a freed index if one exists, handing it out with the generation that was written when it was freed. Otherwise it grows `generations` by one fresh slot at generation 0. Freeing bumps the generation first, then parks the index for reuse. `is_live` is a single indexed read and an equality check: no hashing, no allocation. It runs on every accessor and every structural change, so it has to be that cheap.

You can run this much already:

```rust
fn main() {
    let mut generations = Vec::new();
    let mut free_ids = Vec::new();

    let first = alloc_entity(&mut generations, &mut free_ids);
    free_entity(&mut generations, &mut free_ids, first);
    let second = alloc_entity(&mut generations, &mut free_ids);

    println!("same index: {}", first.index == second.index);  // true
    println!("first live: {}", is_live(&generations, first));  // false
    println!("second live: {}", is_live(&generations, second)); // true
}
```

The second entity reuses the first one's index, but the first handle is now stale and `is_live` says so. That is the entire point of the generation field.

## Where an entity lives

For each live entity we record where its data sits: which table, and which row inside that table. Because every column in a table shares a row index, that pair locates all of the entity's components at once.

```rust
#[derive(Clone, Copy, Debug)]
struct Location { table: usize, row: usize }
```

Locations are stored in a `Vec<Option<Location>>` indexed by entity index, not a `HashMap`. Indices come from a dense counter, so a `Vec` stays compact and every lookup is one indexed load.

```rust
fn get_location(locations: &[Option<Location>], e: Entity) -> Option<Location> {
    locations.get(e.index as usize).and_then(|l| *l)
}

fn set_location(locations: &mut Vec<Option<Location>>, e: Entity, loc: Location) {
    let i = e.index as usize;
    if i >= locations.len() { locations.resize(i + 1, None); }
    locations[i] = Some(loc);
}

fn clear_location(locations: &mut Vec<Option<Location>>, e: Entity) {
    if let Some(slot) = locations.get_mut(e.index as usize) { *slot = None; }
}
```

## Archetype tables

A table holds every entity that shares one mask. The component `Vec`s are the storage. They are always the same length as `entities` and share a row index. For now a table is just its mask, its entities, and one `Vec` per component. We add more fields to it later, when we make migration fast.

```rust
struct Table {
    mask:       u64,
    entities:   Vec<Entity>,
    positions:  Vec<Position>,
    velocities: Vec<Velocity>,
    vitalities: Vec<Vitality>,
}
```

Two operations on a table. Pushing a row appends a default value to every column the mask says is present, and only those columns. Removing a row is the interesting one. We want the columns to stay packed so iteration stays fast, so instead of leaving a hole we take the last row and swap it into the vacated slot. That keeps every `Vec` contiguous. The cost is that the entity formerly at the last row now lives at a different index, so `swap_remove` returns it and the caller fixes its location.

```rust
fn table_push(table: &mut Table, e: Entity) -> usize {
    let row = table.entities.len();
    table.entities.push(e);
    if table.mask & POSITION != 0 { table.positions.push(Position::default()); }
    if table.mask & VELOCITY != 0 { table.velocities.push(Velocity::default()); }
    if table.mask & VITALITY != 0 { table.vitalities.push(Vitality::default()); }
    row
}

fn table_swap_remove(table: &mut Table, idx: usize) -> Option<Entity> {
    let last = table.entities.len().saturating_sub(1);
    let moved = if idx < last { Some(table.entities[last]) } else { None };
    table.entities.swap_remove(idx);
    if table.mask & POSITION != 0 { table.positions.swap_remove(idx); }
    if table.mask & VELOCITY != 0 { table.velocities.swap_remove(idx); }
    if table.mask & VITALITY != 0 { table.vitalities.swap_remove(idx); }
    moved
}
```

If `idx` was already the last row there is nothing to back-fill, so `moved` is `None`.

## The world, spawning, and reading data

Now the world ties it together. For the kernel it needs the tables, a mask to table-index map so we can find a table without scanning, and the location and allocator fields from before.

```rust
use std::collections::HashMap;

#[derive(Default)]
struct World {
    tables:      Vec<Table>,
    table_map:   HashMap<u64, usize>,
    locations:   Vec<Option<Location>>,
    generations: Vec<u32>,
    free_ids:    Vec<u32>,
}
```

For that to derive `Default`, `Table` needs a `Default` too. It is mechanical, so write it out:

```rust
impl Default for Table {
    fn default() -> Self {
        Self {
            mask:       0,
            entities:   Vec::new(),
            positions:  Vec::new(),
            velocities: Vec::new(),
            vitalities: Vec::new(),
        }
    }
}
```

Finding or creating a table for a mask is a map lookup with a fallback that appends a new table:

```rust
fn get_or_create_table(
    tables:    &mut Vec<Table>,
    table_map: &mut HashMap<u64, usize>,
    mask:      u64,
) -> usize {
    if let Some(&i) = table_map.get(&mask) { return i; }
    let i = tables.len();
    tables.push(Table { mask, ..Default::default() });
    table_map.insert(mask, i);
    i
}
```

Spawning allocates a handle, finds the table for the mask, pushes a row, and records the location:

```rust
fn spawn(world: &mut World, mask: u64) -> Entity {
    let e = alloc_entity(&mut world.generations, &mut world.free_ids);
    let ti = get_or_create_table(&mut world.tables, &mut world.table_map, mask);
    let row = table_push(&mut world.tables[ti], e);
    set_location(&mut world.locations, e, Location { table: ti, row });
    e
}
```

Reading and writing a component is three checks: the handle is live, it has a location, and its table actually holds the component. Returning `Option` rather than panicking keeps the accessors composable.

```rust
fn get_position(world: &World, e: Entity) -> Option<&Position> {
    if !is_live(&world.generations, e) { return None; }
    let loc = get_location(&world.locations, e)?;
    let t = &world.tables[loc.table];
    (t.mask & POSITION != 0).then(|| &t.positions[loc.row])
}

fn get_velocity_mut(world: &mut World, e: Entity) -> Option<&mut Velocity> {
    if !is_live(&world.generations, e) { return None; }
    let loc = get_location(&world.locations, e)?;
    let t = &mut world.tables[loc.table];
    (t.mask & VELOCITY != 0).then(|| &mut t.velocities[loc.row])
}

fn get_vitality_mut(world: &mut World, e: Entity) -> Option<&mut Vitality> {
    if !is_live(&world.generations, e) { return None; }
    let loc = get_location(&world.locations, e)?;
    let t = &mut world.tables[loc.table];
    (t.mask & VITALITY != 0).then(|| &mut t.vitalities[loc.row])
}
```

These three accessors are the per-component boilerplate. Each new component type adds one more of each, and the same fan-out shows up in `table_push`, `table_swap_remove`, and everywhere else that touches columns by hand. Hold that thought; it is the reason the last section of this post exists.

At this point you can spawn, write, and read:

```rust
fn main() {
    let mut world = World::default();
    let seed = spawn(&mut world, POSITION | VELOCITY);
    get_velocity_mut(&mut world, seed).unwrap().dx = 10.0;
    println!("{:?}", get_position(&world, seed)); // Some(Position { x: 0.0, y: 0.0 })
}
```

## Despawning

Despawn removes the row with `table_swap_remove`, fixes the back-filled entity's location, clears the despawned entity's own location, and frees its slot. After it returns, `is_live` reports the handle as dead.

```rust
fn despawn(world: &mut World, e: Entity) {
    if !is_live(&world.generations, e) { return; }
    let loc = get_location(&world.locations, e).unwrap();
    if let Some(moved) = table_swap_remove(&mut world.tables[loc.table], loc.row) {
        set_location(&mut world.locations, moved, Location { table: loc.table, row: loc.row });
    }
    clear_location(&mut world.locations, e);
    free_entity(&mut world.generations, &mut world.free_ids, e);
}
```

Spawn two entities into the same table, despawn the first, and the second is still readable: its row moved, but its location was patched, so the handle still resolves.

## Structural change

Adding a component to an entity means the entity now belongs to a different archetype, which means it has to physically move to a different table. There is no in-place option, because the source table has no column to hold the new data. So a structural change is a migration: take the entity's existing component values out of the source table, push them plus any defaults into the destination table, and compact the source.

The migration primitive moves one row from `src` into `dst`. For every component the destination holds, it either moves the value over from the source (if the source had it) or default-initialises it (if the destination is adding it). Components the source has but the destination does not are simply dropped. The move uses `std::mem::take`, which swaps the value out and leaves a `Default` behind, so nothing is cloned even for components that are expensive to clone.

```rust
fn table_move_row(src: &mut Table, idx: usize, dst: &mut Table) -> (usize, Option<Entity>) {
    let entity = src.entities[idx];
    dst.entities.push(entity);
    if dst.mask & POSITION != 0 {
        dst.positions.push(if src.mask & POSITION != 0 {
            std::mem::take(&mut src.positions[idx])
        } else { Position::default() });
    }
    if dst.mask & VELOCITY != 0 {
        dst.velocities.push(if src.mask & VELOCITY != 0 {
            std::mem::take(&mut src.velocities[idx])
        } else { Velocity::default() });
    }
    if dst.mask & VITALITY != 0 {
        dst.vitalities.push(if src.mask & VITALITY != 0 {
            std::mem::take(&mut src.vitalities[idx])
        } else { Vitality::default() });
    }
    let dst_row = dst.entities.len() - 1;
    let back_filled = table_swap_remove(src, idx);
    (dst_row, back_filled)
}
```

The migration itself needs mutable access to two different tables at once. Rust will not let you take two `&mut` into the same `Vec`, so `split_at_mut` splits `world.tables` into two non-overlapping slices, one ending before the higher index and one starting at it. After the move, two locations need updating: the migrated entity now lives in the destination, and whatever `swap_remove` back-filled into the source needs its row corrected.

Here is the first version, which resolves the destination table straight through `get_or_create_table`:

```rust
fn migrate(world: &mut World, e: Entity, loc: Location, new_mask: u64) {
    let src_ti = loc.table;
    let dst_ti = get_or_create_table(&mut world.tables, &mut world.table_map, new_mask);
    assert_ne!(src_ti, dst_ti);

    let (src, dst) = if src_ti < dst_ti {
        let (left, right) = world.tables.split_at_mut(dst_ti);
        (&mut left[src_ti], &mut right[0])
    } else {
        let (left, right) = world.tables.split_at_mut(src_ti);
        (&mut right[0], &mut left[dst_ti])
    };

    let (dst_row, back_filled) = table_move_row(src, loc.row, dst);

    set_location(&mut world.locations, e, Location { table: dst_ti, row: dst_row });
    if let Some(moved) = back_filled {
        set_location(&mut world.locations, moved, Location { table: src_ti, row: loc.row });
    }
}
```

The two public operations sit on top of it. Both short-circuit the no-op case before doing any work, which is also what guarantees the `assert_ne!` above holds: by the time we call `migrate`, the source and destination masks genuinely differ.

```rust
fn add_components(world: &mut World, e: Entity, added: u64) {
    if !is_live(&world.generations, e) { return; }
    let loc = get_location(&world.locations, e).unwrap();
    let old_mask = world.tables[loc.table].mask;
    if old_mask & added == added { return; }
    migrate(world, e, loc, old_mask | added);
}

fn remove_components(world: &mut World, e: Entity, removed: u64) {
    if !is_live(&world.generations, e) { return; }
    let loc = get_location(&world.locations, e).unwrap();
    let old_mask = world.tables[loc.table].mask;
    if old_mask & removed == 0 { return; }
    migrate(world, e, loc, old_mask & !removed);
}
```

Spawn something with `POSITION | VITALITY`, give it some vitality, then `add_components(&mut world, it, VELOCITY)`. Read its vitality back afterwards: it survived the migration. Then `remove_components(&mut world, it, VELOCITY)` and it migrates back, still carrying its vitality.

## Making migration fast

Every `add_components` call currently hashes `table_map` to find the destination. For a thousand entities each gaining and losing a status effect every frame, that is two thousand hash probes a frame for nothing, because the destination of "add velocity" from a given table never changes.

So cache it on the table. From any table, adding a specific component always lands in the same place, and so does removing one. Store those destinations directly on the source table. Single-component transitions are the hot path, one status effect or one flag at a time, so they get a fixed array indexed by component, which is a plain array load with no hashing. Multi-component transitions are rarer and arbitrary, so they fall back to a map keyed on the changed bits. Add these four fields to `Table`:

```rust
    add_single:    [Option<usize>; COMPONENT_COUNT],
    remove_single: [Option<usize>; COMPONENT_COUNT],
    add_multi:     HashMap<u64, usize>,
    remove_multi:  HashMap<u64, usize>,
```

and the matching lines to its `Default`:

```rust
    add_single:    [None; COMPONENT_COUNT],
    remove_single: [None; COMPONENT_COUNT],
    add_multi:     HashMap::new(),
    remove_multi:  HashMap::new(),
```

The array is indexed by component position, so we need to turn a single-bit mask into an index:

```rust
fn component_index(single_bit: u64) -> Option<usize> {
    match single_bit {
        POSITION => Some(0),
        VELOCITY => Some(1),
        VITALITY => Some(2),
        _        => None,
    }
}
```

Now replace the one-line destination lookup in `migrate` with a cached one. The changed bits are `old_mask XOR new_mask`. Whether we are adding or removing is just `new_mask > old_mask`, because a superset mask is always numerically larger than its subset, and that holds no matter how many bits changed. If exactly one bit changed, probe the array; otherwise probe the map. On a miss, resolve through `get_or_create_table` and write the edge for next time.

```rust
    let old_mask = world.tables[src_ti].mask;
    let delta    = old_mask ^ new_mask;
    let adding   = new_mask > old_mask;

    let dst_ti = if delta.count_ones() == 1 {
        let ci = component_index(delta).unwrap();
        let cached = if adding {
            world.tables[src_ti].add_single[ci]
        } else {
            world.tables[src_ti].remove_single[ci]
        };
        cached.unwrap_or_else(|| {
            let dst = get_or_create_table(&mut world.tables, &mut world.table_map, new_mask);
            if adding { world.tables[src_ti].add_single[ci] = Some(dst); }
            else      { world.tables[src_ti].remove_single[ci] = Some(dst); }
            dst
        })
    } else {
        let cached = if adding {
            world.tables[src_ti].add_multi.get(&delta).copied()
        } else {
            world.tables[src_ti].remove_multi.get(&delta).copied()
        };
        cached.unwrap_or_else(|| {
            let dst = get_or_create_table(&mut world.tables, &mut world.table_map, new_mask);
            if adding { world.tables[src_ti].add_multi.insert(delta, dst); }
            else      { world.tables[src_ti].remove_multi.insert(delta, dst); }
            dst
        })
    };
    assert_ne!(src_ti, dst_ti);
```

The behaviour does not change. The second time the same transition is taken, it is an array index or a map hit instead of a fresh `get_or_create_table` lookup. Tables are never removed, so a cached destination index never goes stale. This is the archetype graph, the structure that turns add and remove from a hashed lookup into a pointer follow.

## Queries and systems

The last kernel piece is iteration. A query is "every table whose mask contains at least these components." With archetype storage that is a one-instruction mask test per table: `table.mask & required == required`. A system gets the list of matching tables and walks their columns directly.

Systems run that query every frame, so memoise it. Add a `query_cache` field to `World`:

```rust
    query_cache: HashMap<u64, Vec<usize>>,
```

The first call for a mask scans the tables once and stores the result; later calls return the cached slice.

```rust
fn query_tables<'a>(
    cache:    &'a mut HashMap<u64, Vec<usize>>,
    tables:   &[Table],
    required: u64,
) -> &'a [usize] {
    cache.entry(required).or_insert_with(|| {
        tables.iter().enumerate()
            .filter(|(_, t)| t.mask & required == required)
            .map(|(i, _)| i)
            .collect()
    })
}
```

A cache is only useful if it stays correct. When a new table appears, any existing query whose required mask is a subset of the new table's mask now has one more match. Patch those entries instead of clearing the whole cache:

```rust
fn on_new_table(cache: &mut HashMap<u64, Vec<usize>>, new_mask: u64, new_index: usize) {
    for (required, indices) in cache.iter_mut() {
        if new_mask & required == *required {
            indices.push(new_index);
        }
    }
}
```

`get_or_create_table` is the only place tables are born, so call `on_new_table` there. Its signature grows the cache argument:

```rust
fn get_or_create_table(
    tables:      &mut Vec<Table>,
    table_map:   &mut HashMap<u64, usize>,
    query_cache: &mut HashMap<u64, Vec<usize>>,
    mask:        u64,
) -> usize {
    if let Some(&i) = table_map.get(&mask) { return i; }
    let i = tables.len();
    tables.push(Table { mask, ..Default::default() });
    table_map.insert(mask, i);
    on_new_table(query_cache, mask, i);
    i
}
```

Every call site (in `spawn` and the two branches of `migrate`) now passes `&mut world.query_cache` as well. This is where the free-function style earns itself back: `query_tables` borrows `world.query_cache` and `world.tables` as two separate arguments, which the borrow checker allows, whereas a method on `World` would borrow the whole world and fight you.

A system is then a function over the matching tables. It calls `query_tables`, takes a snapshot of the indices with `.to_vec()` so the cache borrow ends, then borrows `world.tables` mutably for the tight inner loop:

```rust
fn wind_system(world: &mut World, dt: f32) {
    let table_indices = query_tables(&mut world.query_cache, &world.tables, POSITION | VELOCITY).to_vec();
    for ti in table_indices {
        let t = &mut world.tables[ti];
        for i in 0..t.entities.len() {
            t.positions[i].x += t.velocities[i].dx * dt;
            t.positions[i].y += t.velocities[i].dy * dt;
        }
    }
}

fn sunlight_system(world: &mut World, dt: f32) {
    let table_indices = query_tables(&mut world.query_cache, &world.tables, VITALITY).to_vec();
    for ti in table_indices {
        let t = &mut world.tables[ti];
        for v in t.vitalities.iter_mut() {
            v.hp = (v.hp + 5.0 * dt).min(100.0);
        }
    }
}
```

The inner loops are stride-1 reads over packed arrays. No per-entity dispatch, no virtual calls, no hashing. That is the payoff the whole layout was for.

That is the kernel. Spawn entities, attach and detach components at runtime, run systems over component combinations, despawn safely, and recycle handles without aliasing. The [first gist](https://gist.github.com/matthewjberger/ff6fc2aba33d94330fdadbbb99d45563) is exactly this, assembled, with a `main` that exercises every path.

## The engine layer

The kernel stores data and runs systems. A frame loop needs a few more things, and each one is a small addition on top of what you already have. We add them in this order:

1. Change detection, so a system can do work only for the entities that changed.
2. Events, so one system can message another without being wired to it.
3. Tags, for markers that flip too often to be worth an archetype migration.
4. Command buffers, so structural change can be deferred out of an iteration.
5. Resources, for state that belongs to the world rather than any entity.
6. A schedule, to run systems in order.

None of these change the data model. They are layers.

### Change detection

The render system should push only the transforms that moved this frame. To know what moved, stamp every write with a frame counter and compare against a watermark from the end of the previous frame. A slot whose stamp is newer than the watermark changed.

Give every component column a parallel `Vec<u32>` of stamps, in lockstep with the data:

```rust
    positions_changed:  Vec<u32>,
    velocities_changed: Vec<u32>,
    vitalities_changed: Vec<u32>,
```

with `Vec::new()` for each in `Table::default`. The world gains two counters:

```rust
    current_tick: u32,
    last_tick:    u32,
```

`current_tick` is the value stamped into a slot on write. `last_tick` is the watermark. A frame ends by moving both forward:

```rust
fn step(world: &mut World) {
    world.last_tick = world.current_tick;
    world.current_tick = world.current_tick.wrapping_add(1);
}
```

There is one corner to get right. `current_tick` must start at 1, not 0, so writes made during setup (before the first `step`) are strictly greater than the zero-valued watermark and are visible on the first frame. A derived `Default` gives 0, so add a constructor:

```rust
fn new_world() -> World {
    World { current_tick: 1, ..Default::default() }
}
```

Now thread the tick through the column writes. `table_push` and `table_move_row` take a `tick` argument and push it alongside each component (`table.positions_changed.push(tick)`), `table_swap_remove` swap-removes the stamp vecs in lockstep with their data, and `spawn` and `migrate` read `world.current_tick` into a local before the table borrow and pass it down. The mutable accessors stamp the slot when they hand out the reference:

```rust
fn get_velocity_mut(world: &mut World, e: Entity) -> Option<&mut Velocity> {
    if !is_live(&world.generations, e) { return None; }
    let loc = get_location(&world.locations, e)?;
    let tick = world.current_tick;
    let t = &mut world.tables[loc.table];
    (t.mask & VELOCITY != 0).then(|| { t.velocities_changed[loc.row] = tick; &mut t.velocities[loc.row] })
}
```

This stamps whether or not the caller actually writes, which is the conservative choice and avoids a guard type. A system that touches the column arrays directly, like `wind_system`, does not go through the accessor, so it stamps by hand: `t.positions_changed[i] = tick;` in the inner loop. That is the trade-off in plain sight. Ergonomic single-entity writes stamp for you; hot loops keep raw access and stamp themselves.

The query for "changed since last frame" is a walk that compares stamps to the watermark:

```rust
fn positions_changed_since_step(world: &World) -> Vec<Entity> {
    let mut out = Vec::new();
    for t in &world.tables {
        if t.mask & POSITION == 0 { continue; }
        for i in 0..t.entities.len() {
            if t.positions_changed[i] > world.last_tick {
                out.push(t.entities[i]);
            }
        }
    }
    out
}
```

Build the world with `new_world`, spawn a mover and a static rock, call `step` to close out setup, run `wind_system`, and `positions_changed_since_step` returns the mover and not the rock. No clearing pass ran between frames; the watermark moved and the old stamps went stale relative to it on their own.

### Events

A collision system finds two overlapping entities and the damage system needs to hear about it, without the two being wired together. The clean shape is a queue the sender writes and the reader drains. The only subtlety is lifetime: an event has to outlive the frame it was sent in so a system running earlier in the next frame still sees it, but it cannot live forever. Double-buffer it. An event is readable through the end of the frame after it was sent, then gone.

```rust
struct EventQueue<T> { current: Vec<T>, previous: Vec<T> }

impl<T> Default for EventQueue<T> {
    fn default() -> Self { Self { current: Vec::new(), previous: Vec::new() } }
}

impl<T> EventQueue<T> {
    fn send(&mut self, event: T) { self.current.push(event); }
    fn read(&self) -> impl Iterator<Item = &T> { self.previous.iter().chain(self.current.iter()) }
    fn drain(&mut self) -> impl Iterator<Item = T> + '_ { self.previous.drain(..).chain(self.current.drain(..)) }
    fn update(&mut self) { self.previous.clear(); std::mem::swap(&mut self.current, &mut self.previous); }
}
```

Define an event type and give the world a queue for it:

```rust
#[derive(Clone, Copy, Debug)]
struct CollisionEvent { a: Entity, b: Entity }
```

```rust
    collisions: EventQueue<CollisionEvent>,
```

The `EventQueue` is a generic type with methods, which is the one place methods read better than free functions, because the behaviour is genuinely self-contained. The world exposes thin wrappers (`send_collision`, `read_collisions`, `drain_collisions`) and `step` advances the queue by calling `world.collisions.update()` before it bumps the tick. Two `update` calls after a `send` drop the event, which is the two-frame lifetime falling out of the buffer swap.

### Tags

A tag is a marker with no data: "selected", "blooming", "took damage this frame". You could put it in the archetype mask, but then flipping it migrates the entity to a new table and back, which is pure waste for something that changes constantly. Store it outside the archetypes instead, as set membership:

```rust
    blooming: HashSet<Entity>,
```

```rust
fn add_blooming(world: &mut World, e: Entity) {
    if is_live(&world.generations, e) { world.blooming.insert(e); }
}
fn remove_blooming(world: &mut World, e: Entity) -> bool { world.blooming.remove(&e) }
fn is_blooming(world: &World, e: Entity) -> bool { world.blooming.contains(&e) }
fn query_blooming(world: &World) -> impl Iterator<Item = Entity> + '_ { world.blooming.iter().copied() }
```

Insert, remove, and membership are all constant time with no table touched. The one thing to remember is that `despawn` has to clear the entity out of every tag set, or dead handles pile up in them, so add `world.blooming.remove(&e);` to `despawn`.

### Command buffers

A system iterating over enemies cannot despawn one mid-loop: the iteration borrows the world, and despawn needs it mutably. The fix is to record the intent as data and replay it after the loop ends.

```rust
enum Command {
    Spawn(u64),
    Despawn(Entity),
    AddComponents(Entity, u64),
    RemoveComponents(Entity, u64),
}
```

```rust
    commands: Vec<Command>,
```

The queue functions push a variant; applying drains the buffer and dispatches each one. Take the buffer out with `std::mem::take` first, so a command that itself queues more commands does not fight the borrow:

```rust
fn apply_commands(world: &mut World) {
    let commands = std::mem::take(&mut world.commands);
    for command in commands {
        match command {
            Command::Spawn(mask) => { spawn(world, mask); }
            Command::Despawn(e) => despawn(world, e),
            Command::AddComponents(e, mask) => add_components(world, e, mask),
            Command::RemoveComponents(e, mask) => remove_components(world, e, mask),
        }
    }
}
```

Collect the entities to change during the read pass, queue the changes, and apply them once the loop is done. The `enum` is the list of what can be deferred, typed at compile time, no dynamic dispatch.

### Resources

Some state has no entity to live on: the frame's delta time, the input snapshot, the score. Put it in one struct on the world.

```rust
#[derive(Default)]
struct Resources { delta_time: f32 }
```

```rust
    resources: Resources,
```

A system reads `world.resources.delta_time` directly. No accessor, no ceremony. This also lets every system share one signature, which the schedule needs next, so change `wind_system` and `sunlight_system` to take only `&mut World` and read `dt` from `world.resources.delta_time` instead of as a parameter.

### A schedule

A schedule is a named, ordered list of systems run once per frame. Because every system is now `fn(&mut World)`, the list is just function pointers.

```rust
#[derive(Default)]
struct Schedule { systems: Vec<(&'static str, fn(&mut World))> }

fn schedule_push(schedule: &mut Schedule, name: &'static str, system: fn(&mut World)) {
    schedule.systems.push((name, system));
}

fn schedule_run(schedule: &Schedule, world: &mut World) {
    for (_, system) in &schedule.systems {
        system(world);
    }
}
```

The frame loop is then `schedule_run(&schedule, &mut world)` followed by `step(&mut world)`. The names are there so you can print the system list, find one, or swap it out. A production schedule grows ordering constraints and parallel execution, but an ordered list is enough to drive a frame.

The [second gist](https://gist.github.com/matthewjberger/d4c11ec250cfd1a8d761f54cb0ae51f4) is the kernel with all six layers in place and a `main` that exercises each one: change detection separating the mover from the rock, a collision event surviving exactly one `step`, a bloom tag, and a command-buffer despawn applied after a read pass.

## Where the boilerplate goes

Look back at the per-component fan-out. Every component type meant another line in `table_push`, another in `table_swap_remove`, two in `table_move_row`, a parallel stamp vec, an arm in `component_index`, and three accessors. A fourth component is a dozen edits across the file, and any one of them being wrong is a silent bug. That repetition is mechanical, which is exactly the kind of thing a compiler can write for you.

How you get it written depends on the language. The structure does not change at all; only the spelling of the fan-out does. In Rust the tool is a declarative macro: you write the component set once, and the macro stamps out every column, every accessor, and every cache update. That is what [freecs](https://github.com/matthewjberger/freecs) is. It is the same archetype graph, the same query cache, and the same watermark change detection built here, with a `macro_rules!` layer on top that turns one component declaration into the whole thing. Once the kernel makes sense, the macro is just bookkeeping, and you can read the crate without guessing at what it generates.

The data-oriented shape underneath is the part worth keeping in your head. Entities are handles, components are plain arrays grouped by archetype, systems are functions over those arrays, and everything else is a cache or a queue layered on top.
