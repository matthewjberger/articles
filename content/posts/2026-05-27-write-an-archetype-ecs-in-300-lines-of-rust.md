+++
title = "Write an archetype ECS in 300 lines of Rust"
tags = ["rust", "ecs", "game-engine", "data-oriented", "tutorial"]
categories = ["rust"]
excerpt = "An archetype ECS built from nothing: generational handles, struct-of-arrays tables, runtime component migration, and two caches. Then the engine layer on top. No proc-macros, no unsafe, std only."
+++

```rust
#[derive(Default, Clone, Debug)]
struct Position { x: f32, y: f32 }

#[derive(Default, Clone, Debug)]
struct Velocity { dx: f32, dy: f32 }

#[derive(Default, Clone, Debug)]
struct Vitality { hp: f32 }

const POSITION: u64 = 1 << 0;
const VELOCITY: u64 = 1 << 1;
const VITALITY: u64 = 1 << 2;
const COMPONENT_COUNT: usize = 3;
```

Components are plain structs. `Default` is needed because a row is zero-filled when an entity gains a component it lacked. Each component owns one bit, and a set of components is a `u64` with those bits set: the archetype's mask.

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct Entity { index: u32, generation: u32 }

#[derive(Clone, Copy, Debug)]
struct Location { table: usize, row: usize }
```

An entity is an index plus a generation. The index is a slot; the generation distinguishes successive occupants of that slot, so a handle held past a despawn is detectably stale instead of pointing at whatever reused the slot. A location is where an entity's data sits, and because every column in a table shares the row index, the pair locates all its components at once.

```rust
use std::collections::HashMap;

struct Table {
    mask:          u64,
    entities:      Vec<Entity>,
    positions:     Vec<Position>,
    velocities:    Vec<Velocity>,
    vitalities:    Vec<Vitality>,
    add_single:    [Option<usize>; COMPONENT_COUNT],
    remove_single: [Option<usize>; COMPONENT_COUNT],
    add_multi:     HashMap<u64, usize>,
    remove_multi:  HashMap<u64, usize>,
}

impl Default for Table {
    fn default() -> Self {
        Self {
            mask: 0, entities: Vec::new(),
            positions: Vec::new(), velocities: Vec::new(), vitalities: Vec::new(),
            add_single: [None; COMPONENT_COUNT], remove_single: [None; COMPONENT_COUNT],
            add_multi: HashMap::new(), remove_multi: HashMap::new(),
        }
    }
}
```

A table holds every entity of one mask, with each component stored as its own contiguous `Vec` in lockstep with `entities`. That is the whole point of archetypes: a system reads one packed column at a time, and adding a component is a move to another table rather than a per-access cost. The four edge fields are the migration cache, unused until structural change below.

```rust
#[derive(Default)]
struct World {
    tables:      Vec<Table>,
    table_map:   HashMap<u64, usize>,
    query_cache: HashMap<u64, Vec<usize>>,
    locations:   Vec<Option<Location>>,
    generations: Vec<u32>,
    free_ids:    Vec<u32>,
}
```

The world is a bag of `Vec`s and `HashMap`s with no methods. Every operation below is a free function that takes the world or its fields, which keeps the borrow checker happy: a function can borrow two fields separately where a method would borrow the whole world. `locations`, `generations`, and `free_ids` are indexed by entity index, so they are `Vec`s, not maps.

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

The allocator reuses a freed index if one waits, handing it back with the generation written when it was freed; otherwise it grows by a fresh slot. Freeing bumps the generation, which is what makes every old handle to that slot stale. `is_live` is one indexed read.

```rust
fn main() {
    let (mut generations, mut free_ids) = (Vec::new(), Vec::new());
    let first = alloc_entity(&mut generations, &mut free_ids);
    free_entity(&mut generations, &mut free_ids, first);
    let second = alloc_entity(&mut generations, &mut free_ids);
    println!("{} {} {}", first.index == second.index, is_live(&generations, first), is_live(&generations, second));
}
```

This runs on its own and prints `true false true`: the new entity reused the slot, the old handle is dead, the new one is live. It is the one part worth checking by hand.

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

Locations live in a `Vec<Option<Location>>` indexed by entity index, so a lookup is one indexed load.

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

Pushing a row appends a default to each column the mask holds. Removing a row swaps the last row into the gap to stay packed, and returns the entity that moved so the caller can fix its location.

```rust
fn get_or_create_table(
    tables: &mut Vec<Table>, table_map: &mut HashMap<u64, usize>,
    query_cache: &mut HashMap<u64, Vec<usize>>, mask: u64,
) -> usize {
    if let Some(&i) = table_map.get(&mask) { return i; }
    let i = tables.len();
    tables.push(Table { mask, ..Default::default() });
    table_map.insert(mask, i);
    for (required, indices) in query_cache.iter_mut() {
        if mask & required == *required { indices.push(i); }
    }
    i
}
```

Tables are created on demand, one per mask ever used. A new table also patches every cached query whose mask it now satisfies, so the query cache stays correct without a full rebuild.

```rust
fn spawn(world: &mut World, mask: u64) -> Entity {
    let e = alloc_entity(&mut world.generations, &mut world.free_ids);
    let ti = get_or_create_table(&mut world.tables, &mut world.table_map, &mut world.query_cache, mask);
    let row = table_push(&mut world.tables[ti], e);
    set_location(&mut world.locations, e, Location { table: ti, row });
    e
}

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

Spawn allocates a handle, finds the table, pushes a row, records the location. Despawn reverses it: swap-remove, fix the moved entity, clear the location, free the slot.

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
```

Three checks per accessor: live handle, has a location, table holds the component. `Vitality` is the same shape. That one-pair-per-component repetition, plus a line per component in every table function, is the cost of writing this by hand; it is the last section.

```rust
fn table_move_row(src: &mut Table, idx: usize, dst: &mut Table) -> (usize, Option<Entity>) {
    let entity = src.entities[idx];
    dst.entities.push(entity);
    if dst.mask & POSITION != 0 {
        dst.positions.push(if src.mask & POSITION != 0 { std::mem::take(&mut src.positions[idx]) } else { Position::default() });
    }
    if dst.mask & VELOCITY != 0 {
        dst.velocities.push(if src.mask & VELOCITY != 0 { std::mem::take(&mut src.velocities[idx]) } else { Velocity::default() });
    }
    if dst.mask & VITALITY != 0 {
        dst.vitalities.push(if src.mask & VITALITY != 0 { std::mem::take(&mut src.vitalities[idx]) } else { Vitality::default() });
    }
    let dst_row = dst.entities.len() - 1;
    let back_filled = table_swap_remove(src, idx);
    (dst_row, back_filled)
}
```

Adding a component moves the entity to a different archetype, because the source table has no column for the new data. This is the migration primitive: it carries each shared value across with `std::mem::take` (which moves it out and leaves a `Default`, so nothing is cloned), defaults the new ones, and drops the rest.

```rust
fn component_index(single_bit: u64) -> Option<usize> {
    match single_bit { POSITION => Some(0), VELOCITY => Some(1), VITALITY => Some(2), _ => None }
}

fn migrate(world: &mut World, e: Entity, loc: Location, new_mask: u64) {
    let src_ti = loc.table;
    let old_mask = world.tables[src_ti].mask;
    let delta = old_mask ^ new_mask;
    let adding = new_mask > old_mask;

    let dst_ti = if delta.count_ones() == 1 {
        let ci = component_index(delta).unwrap();
        let cached = if adding { world.tables[src_ti].add_single[ci] } else { world.tables[src_ti].remove_single[ci] };
        cached.unwrap_or_else(|| {
            let dst = get_or_create_table(&mut world.tables, &mut world.table_map, &mut world.query_cache, new_mask);
            if adding { world.tables[src_ti].add_single[ci] = Some(dst); } else { world.tables[src_ti].remove_single[ci] = Some(dst); }
            dst
        })
    } else {
        let cached = if adding { world.tables[src_ti].add_multi.get(&delta).copied() } else { world.tables[src_ti].remove_multi.get(&delta).copied() };
        cached.unwrap_or_else(|| {
            let dst = get_or_create_table(&mut world.tables, &mut world.table_map, &mut world.query_cache, new_mask);
            if adding { world.tables[src_ti].add_multi.insert(delta, dst); } else { world.tables[src_ti].remove_multi.insert(delta, dst); }
            dst
        })
    };

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

From a given table the destination of "add velocity" never changes, so cache it on the table instead of re-hashing every time. The changed bits are `old ^ new`, and `new > old` tells add from remove because a superset mask is numerically larger. A single-bit change hits a fixed array, the hot path of one status effect at a time; a multi-bit change hits a map. `split_at_mut` hands out two mutable table references at once, which a plain index into one `Vec` cannot.

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

Both short-circuit the no-op case, which also guarantees `migrate` always moves between two different tables.

```rust
fn query_tables<'a>(cache: &'a mut HashMap<u64, Vec<usize>>, tables: &[Table], required: u64) -> &'a [usize] {
    cache.entry(required).or_insert_with(|| {
        tables.iter().enumerate().filter(|(_, t)| t.mask & required == required).map(|(i, _)| i).collect()
    })
}

fn wind_system(world: &mut World, dt: f32) {
    let tables = query_tables(&mut world.query_cache, &world.tables, POSITION | VELOCITY).to_vec();
    for ti in tables {
        let t = &mut world.tables[ti];
        for i in 0..t.entities.len() {
            t.positions[i].x += t.velocities[i].dx * dt;
            t.positions[i].y += t.velocities[i].dy * dt;
        }
    }
}
```

A query is "every table whose mask contains these bits", one mask test per table, memoized because systems run it every frame. A system snapshots the matching indices, then walks the columns directly: stride-1 reads, no hashing, no dispatch. That is the kernel. The [first gist](https://gist.github.com/matthewjberger/ff6fc2aba33d94330fdadbbb99d45563) is exactly this with a `main` that exercises every path. Paste it into the [playground](https://play.rust-lang.org) and run it.

## The engine layer

A frame loop wants six more things, each a small layer on the kernel. The [full gist](https://gist.github.com/matthewjberger/d4c11ec250cfd1a8d761f54cb0ae51f4) has them assembled; here is what each adds.

```rust
(t.mask & VELOCITY != 0).then(|| { t.velocities_changed[loc.row] = tick; &mut t.velocities[loc.row] })

fn step(world: &mut World) {
    world.last_tick = world.current_tick;
    world.current_tick = world.current_tick.wrapping_add(1);
}
```

**Change detection.** Give every column a parallel `Vec<u32>` of write ticks and the world a `current_tick` and `last_tick`. A write stamps `current_tick` (the accessor line above), and a slot changed if its stamp beats `last_tick`. `table_push` and `table_move_row` take a `tick` and push it beside each value, `table_swap_remove` removes the stamp vecs in lockstep, and `step` advances both counters at frame end. Start `current_tick` at 1 so setup writes are visible on frame zero. No clearing pass runs; the watermark moves and old stamps go stale on their own.

```rust
struct EventQueue<T> { current: Vec<T>, previous: Vec<T> }
impl<T> EventQueue<T> {
    fn send(&mut self, e: T) { self.current.push(e); }
    fn read(&self) -> impl Iterator<Item = &T> { self.previous.iter().chain(self.current.iter()) }
    fn update(&mut self) { self.previous.clear(); std::mem::swap(&mut self.current, &mut self.previous); }
}
```

**Events.** A double-buffered queue per event type, a field on the world. An event sent on frame N is readable through N+1 and gone by N+2, so order between systems does not matter. `step` calls `update` on each.

```rust
    blooming: HashSet<Entity>,
```

**Tags.** A marker with no data, like "selected". A mask bit would migrate the entity every flip, so store membership in a set instead: O(1) insert with no table touched. Insert, remove, and `contains` are the whole API, and `despawn` clears the entity from each set.

```rust
enum Command { Spawn(u64), Despawn(Entity), AddComponents(Entity, u64), RemoveComponents(Entity, u64) }

fn apply_commands(world: &mut World) {
    for command in std::mem::take(&mut world.commands) {
        match command {
            Command::Spawn(mask) => { spawn(world, mask); }
            Command::Despawn(e) => despawn(world, e),
            Command::AddComponents(e, mask) => add_components(world, e, mask),
            Command::RemoveComponents(e, mask) => remove_components(world, e, mask),
        }
    }
}
```

**Command buffers.** You cannot despawn mid-iteration, since the loop borrows the world. Record the intent as data and replay it after. `mem::take` swaps the buffer out first, so a command that queues more commands does not fight the borrow.

```rust
#[derive(Default)]
struct Resources { delta_time: f32 }
```

**Resources.** State with no entity owner (delta time, input, score). One struct on the world, read as `world.resources.delta_time`. This also lets every system share one signature.

```rust
#[derive(Default)]
struct Schedule { systems: Vec<(&'static str, fn(&mut World))> }

fn schedule_run(schedule: &Schedule, world: &mut World) {
    for (_, system) in &schedule.systems { system(world); }
}
```

**Schedule.** With resources carrying the inputs, systems take only `&mut World`, so a schedule is a named, ordered list of function pointers. The frame loop is `schedule_run` then `step`.

## Where the boilerplate goes

Every new component is another line in `table_push`, in `table_swap_remove`, two in `table_move_row`, a stamp vec, an arm in `component_index`, and an accessor. A dozen edits, all mechanical, which is exactly what a compiler can write for you. How depends on the language; the structure does not change, only the spelling of the fan-out. In Rust the tool is a declarative macro: declare the component set once and it stamps out every column, accessor, and cache update. That is what [freecs](https://github.com/matthewjberger/freecs) is, the same archetype graph and query cache and change detection built here under a `macro_rules!` layer. The shape underneath is the part to keep: handles, arrays grouped by archetype, functions over those arrays, and caches and queues on top.
