+++
title = "Build your own ECS (part 2), structural change and queries"
tags = ["rust", "ecs", "game-engine", "tutorial"]
categories = ["rust"]
excerpt = "Adding and removing components at runtime by migrating entities between archetypes, walking tables to satisfy queries, and the two caches that make both operations fast."
+++

*This is part 2 of 3 of a series.* ← [Archetype storage](@/posts/2026-07-26-build-your-own-ecs-archetype-storage.md) | Next → [Change detection, events, tags, and commands](@/posts/2026-08-09-build-your-own-ecs-events-changes-tags-commands.md)

[Part 1](@/posts/2026-07-26-build-your-own-ecs-archetype-storage.md) built the storage. Generational entity handles, archetype tables, and the routing layer that ties them together. By the end of it you could spawn entities into a specific archetype, read and write their components, and despawn them safely. What you could *not* do was change an entity's components after spawn time, and you had no way to ask the world "give me every entity that has X."

This post fixes both. The core mechanic is the same as before. Archetypes are defined by their component set, so changing an entity's component set means physically moving the entity to a different table. Once that move is in place, queries are almost trivial. They are a walk over the tables whose mask satisfies the query.

The naive implementations of both operations are O(N) in the number of tables, which is fine until you have a few dozen archetypes and several hundred queries per frame. The second half of the post adds two caches, an archetype graph for migration and a query cache for iteration, that turn both operations into near-constant time without changing the surface API.

Start from the file at the end of part 1. We will add to it.

## Adding a component means moving the entity

If an entity is in a table with mask `POSITION`, and we want to add `VELOCITY` to it, the entity needs to end up in a table with mask `POSITION | VELOCITY`. There is no in-place option. The `POSITION`-only table has no `velocities` vec to push into, and the `velocities` slot is only present in tables whose mask includes the velocity bit. So adding a component is mechanically a migration.

1. Find or create the destination table.
2. Take each existing component value out of the source table at the entity's slot.
3. Push those values, plus defaults for the newly-added components, into the destination table.
4. Update the entity's location to point at the destination table.
5. `swap_remove` the entity's slot from the source table, updating the swapped-in entity's location.

Step 2 is the interesting one. We do not want to clone the components. A `Position` may be cheap to clone, but the same machinery has to handle `Vec<Mesh>` and `Box<MaterialHandle>` and other components that are expensive or impossible to clone. We also do not want to allocate. The standard library has the tool we need. `std::mem::take` swaps a value out, leaving `Default::default()` in its place. This is why every component must implement `Default`. Not because spawning needs defaults (though it does), but because migration needs them.

```rust
impl World {
    pub fn move_entity(
        &mut self,
        entity: Entity,
        from_table: usize,
        from_index: usize,
        to_table: usize,
    ) {
        let from_mask = self.tables[from_table].mask;

        let position = if from_mask & POSITION != 0 {
            Some(std::mem::take(&mut self.tables[from_table].positions[from_index]))
        } else {
            None
        };
        let velocity = if from_mask & VELOCITY != 0 {
            Some(std::mem::take(&mut self.tables[from_table].velocities[from_index]))
        } else {
            None
        };

        let to_array_index = {
            let to = &mut self.tables[to_table];
            let array_index = to.entities.len();
            to.entities.push(entity);
            if to.mask & POSITION != 0 {
                to.positions.push(position.unwrap_or_default());
            }
            if to.mask & VELOCITY != 0 {
                to.velocities.push(velocity.unwrap_or_default());
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
        }
        if from.mask & VELOCITY != 0 {
            from.velocities.swap_remove(from_index);
        }

        if let Some(moved) = swapped {
            self.entity_locations.set(moved, from_table, from_index);
        }
    }
}
```

The first block pulls every component the source table holds out of the entity's slot, leaving `Default::default()` behind temporarily. The second block pushes those values into the destination table, defaulting any components that are present in the destination but were not in the source. The third block compacts the source table with the same swap-remove dance as despawn.

`unwrap_or_default()` is what makes adding a brand-new component to an entity work. The source table did not have a velocity, so `velocity` is `None`. The destination has velocity, so we push a default. The same line handles the case where the destination has a component the source already had. `Some(value).unwrap_or_default()` is `value`, no default involved.

One precondition `move_entity` does not check. `from_table != to_table`. The bottom `swap_remove` block would clobber the slot we just pushed if they were the same. The public callers `add_components` and `remove_components` short-circuit on no-op masks before they reach `move_entity`, so the precondition holds in practice. A reader copying `move_entity` somewhere else should re-establish it with an assert or an early return.

## add_components and remove_components

With `move_entity` in place, the public operations are short.

```rust
impl World {
    pub fn add_components(&mut self, entity: Entity, mask: u64) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };
        let current_mask = self.tables[table_index].mask;
        if current_mask & mask == mask {
            return true;
        }
        let new_mask = current_mask | mask;
        let new_table_index = self.get_or_create_table(new_mask);
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
        let new_mask = current_mask & !mask;
        let new_table_index = self.get_or_create_table(new_mask);
        self.move_entity(entity, table_index, array_index, new_table_index);
        true
    }
}
```

Both short-circuit when the operation would be a no-op. Adding components that the entity already has does nothing. Removing components the entity does not have does nothing. The mask test happens before we do any work, so an idempotent call costs a vec lookup and a bitwise check.

Both accept a multi-component mask. If we had a third component `HEALTH`, then `add_components(entity, VELOCITY | HEALTH)` would do a single migration to the table for `current_mask | VELOCITY | HEALTH`. Two separate calls would do two migrations and re-copy the unchanged components twice. One combined call is meaningfully faster.

While we are here, a couple of conveniences. A `set_position` that adds the component if it is missing makes scripting code much nicer to write. A spawn variant that takes an initial value avoids the `spawn(...); world.get_position_mut(e).unwrap() = ...` two-step.

```rust
impl World {
    pub fn set_position(&mut self, entity: Entity, value: Position) {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return;
        };
        if self.tables[table_index].mask & POSITION != 0 {
            self.tables[table_index].positions[array_index] = value;
            return;
        }
        self.add_components(entity, POSITION);
        if let Some((table_index, array_index)) = self.entity_locations.get(entity) {
            self.tables[table_index].positions[array_index] = value;
        }
    }

    pub fn set_velocity(&mut self, entity: Entity, value: Velocity) {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return;
        };
        if self.tables[table_index].mask & VELOCITY != 0 {
            self.tables[table_index].velocities[array_index] = value;
            return;
        }
        self.add_components(entity, VELOCITY);
        if let Some((table_index, array_index)) = self.entity_locations.get(entity) {
            self.tables[table_index].velocities[array_index] = value;
        }
    }
}
```

The structure is the same for both. Fast path if the component is already present, otherwise migrate and then write. The location must be re-fetched after migration because the entity is no longer in the same table.

A second convenience worth adding is a builder that spawns an entity with a chosen set of components in one call. So far every spawn that wants specific component values has been a two-step. Call `world.spawn(POSITION | VELOCITY)` to get an entity, then write `world.get_position_mut(entity).unwrap() = Position { x: 1.0, y: 2.0 }` and the same for velocity. That works and it reads awkwardly. The default values the spawn put in exist only to be overwritten on the next line.

A small builder collapses it.

```rust
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
```

Usage:

```rust
let mover = EntityBuilder::new()
    .with_position(Position { x: 1.0, y: 2.0 })
    .with_velocity(Velocity { x: 0.5, y: 0.25 })
    .spawn(&mut world);
```

The builder figures out the archetype mask from which fields were set, calls `world.spawn(mask)` to create the entity in the right archetype directly, then writes each value through `world.set_position` and `world.set_velocity`. Going through the public setters rather than reaching into the tables directly means that any bookkeeping the setters do (the change-detection tick stamping we add in part 3, for example) the builder picks up automatically with no extra wiring.

## Queries

A query is "give me every entity that has at least this set of components." With archetype storage it is a walk over the tables. For each table, if its mask is a superset of the query mask, every entity in it satisfies the query. The mask comparison `table.mask & query_mask == query_mask` is one CPU instruction.

The simplest entity-yielding query is an iterator.

```rust
impl World {
    pub fn query_entities(&self, mask: u64) -> impl Iterator<Item = Entity> + '_ {
        self.tables
            .iter()
            .filter(move |table| table.mask & mask == mask)
            .flat_map(|table| table.entities.iter().copied())
    }
}
```

Using it.

```rust
for entity in world.query_entities(POSITION | VELOCITY) {
    let position = world.get_position(entity).unwrap();
    let velocity = world.get_velocity(entity).unwrap();
    println!("{entity:?}: ({}, {}) v=({}, {})", position.x, position.y, velocity.x, velocity.y);
}
```

This works, and for read-only loops it is the most ergonomic API. But it pays for each component access by going through the location map. For tight inner loops (the physics step, the AI tick) you want direct access to the underlying vecs, where the index into one vec is the index into the others. The pattern is a callback that gets called with the entity, the table, and the slot index.

```rust
impl World {
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
        for table in &mut self.tables {
            if table.mask & include != include || table.mask & exclude != 0 {
                continue;
            }
            for array_index in 0..table.entities.len() {
                let entity = table.entities[array_index];
                f(entity, table, array_index);
            }
        }
    }
}
```

The physics step then looks like the following.

```rust
world.for_each_mut(POSITION | VELOCITY, 0, |_entity, table, index| {
    table.positions[index].x += table.velocities[index].x;
    table.positions[index].y += table.velocities[index].y;
});
```

`include` is the mask of components the entity must have. `exclude` is the mask of components the entity must *not* have, useful for "every entity with `POSITION` that is not a `PLAYER`" once we have tags. Passing `0` for exclude is the common case.

The closure receives the whole `ComponentArrays`, not a tuple of `&mut Position, &mut Velocity`. The reason is the same as the earlier complaint about boilerplate. Extracting tuples of borrowed components requires either generics with associated types or a macro, and we are deliberately doing neither. Direct table access is uglier at the call site but stays trivial in the implementation.

## Making the migration fast

`add_components(entity, VELOCITY)` currently does this.

1. Look up the entity's current table via the location map (`entity_locations.get`).
2. Compute `new_mask = current_mask | VELOCITY`.
3. Look up the destination table by mask (`get_or_create_table`, which hits `table_lookup`).
4. Migrate.

Step 3 is the slow one. It is a hashmap lookup, and it fires on every structural change. If a thousand entities each take and release a "stunned" component each frame, that is two thousand hashmap probes per frame just for the table lookups. Step 1 is already fast (vec indexed by id). The migration itself is fundamental work.

Notice the structure of step 3. From a given source table, the destination after adding *any specific component* is fixed. The table for `POSITION` plus the velocity bit is always the table for `POSITION | VELOCITY`. So we can store, on each table, an array of "if you add component bit N, here is the destination table index", and another for removal. Lookup becomes an array index, no hashing.

```rust
pub const COMPONENT_COUNT: usize = 2;

#[derive(Default, Clone)]
pub struct TableEdges {
    pub add_edges: [Option<usize>; COMPONENT_COUNT],
    pub remove_edges: [Option<usize>; COMPONENT_COUNT],
}
```

The array is indexed by *component bit position*, not by mask. Bit 0 is position, bit 1 is velocity. To turn a single-bit mask into its bit position we need a small helper.

```rust
pub fn component_index(mask: u64) -> Option<usize> {
    match mask {
        POSITION => Some(0),
        VELOCITY => Some(1),
        _ => None,
    }
}
```

This only handles single-bit masks. Multi-bit adds (adding more than one component in a single call) cannot be represented as a single edge in the graph, because the destination depends on the combination of bits added together. We will treat those as a slow-path miss.

Storing one `TableEdges` per table.

```rust
#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
}
```

The edges need to be populated. There are two ways, lazily on first traversal or eagerly when a new table is created. Eager is simpler because the edge information stays correct without ever needing to invalidate. The cost is a small scan over existing tables when a new table appears.

```rust
impl World {
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
}
```

Two loops. The first walks the existing tables and sets edges *into* the new table from any older table that is one bit-flip away. The second walks the component bits and sets edges *out of* the new table to any older table that is one bit-flip away in the other direction. For each component bit, the add-side destination is `mask | bit` and the remove-side destination is `mask & !bit` (only meaningful when the bit was set in `mask`). The lookups are hashmap gets, but they happen once per bit at table-creation time rather than every time an entity migrates.

The second loop exists because the first one is one-directional. A future table creation will wire its own incoming edges from the older tables that were around when it appeared, but it will not reach back and fill outgoing edges on those older tables. So the new table's outgoing edges have one opportunity to be set, and that opportunity is now. Filling them on creation makes every cached migration path hot from the moment both endpoints exist.

Now `add_components` for a single-bit mask hits the edge cache.

```rust
impl World {
    pub fn add_components(&mut self, entity: Entity, mask: u64) -> bool {
        let Some((table_index, array_index)) = self.entity_locations.get(entity) else {
            return false;
        };
        let current_mask = self.tables[table_index].mask;
        if current_mask & mask == mask {
            return true;
        }

        let cached = if mask.count_ones() == 1 {
            component_index(mask).and_then(|index| self.table_edges[table_index].add_edges[index])
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
}
```

For a single-component add or remove, the cached array lookup replaces the hashmap lookup. Multi-component changes still hit `get_or_create_table`, which is fine because they are rare and the hashmap is the only sensible structure for arbitrary masks. A real implementation would add a secondary cache per source table for common multi-bit transitions. The single-bit case is what fires every time a status effect is added or removed, so it earns the optimization.

## Making the query fast

`for_each_mut(POSITION | VELOCITY, 0, ...)` scans every table to find the ones whose mask matches. With a few dozen archetypes and a few hundred query invocations per frame, that scan adds up.

The fix is the same idea as the edge cache. Memoize. Map each query mask to the list of table indices that satisfy it.

```rust
#[derive(Default)]
pub struct World {
    pub allocator: EntityAllocator,
    pub entity_locations: EntityLocations,
    pub tables: Vec<ComponentArrays>,
    pub table_lookup: HashMap<u64, usize>,
    pub table_edges: Vec<TableEdges>,
    pub query_cache: HashMap<u64, Vec<usize>>,
}
```

The cache fills on first use.

```rust
impl World {
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
}
```

It needs to stay correct as new tables are created. The simplest invalidation strategy would be to clear the whole cache on every new table, but that is overly conservative. Most existing cache entries are still correct, and only those whose query mask is a subset of the new table's mask need updating. We can do that surgically inside `get_or_create_table`.

```rust
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
}
```

Called from `get_or_create_table` right after the table is pushed.

```rust
impl World {
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
}
```

`for_each_mut` consults the cache instead of scanning.

```rust
impl World {
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
}
```

The `.to_vec()` copy is needed because `cached_tables` borrows the cache mutably (to fill it on miss) and then we want to borrow `self.tables` mutably to call `f`. A handful of `usize` copied to the stack is cheap.

The read-only `for_each` does not have the borrow problem, but it also cannot fill the cache, because the cache write requires `&mut self`. A fuller implementation would either expose a `warm_query(mask)` method that fills the cache eagerly during setup, or use a `RefCell` inside the cache so the read-only path can still write. The warm-up route is what production crates usually take because it avoids interior mutability on the hot read path. For this post the read-only path scans the tables every time.

## What we built

```
World  (new fields)
├── table_edges: Vec<TableEdges>           archetype graph for O(1) migration
└── query_cache: HashMap<u64, Vec<usize>>  memoized "which tables match this mask"

TableEdges  (one per table, indexed by component bit position)
├── add_edges: [Option<usize>; N]          which table to land in when adding bit N
└── remove_edges: [Option<usize>; N]       which table to land in when removing bit N
```

New operations on `World`. `add_components(entity, mask)`, `remove_components(entity, mask)`, `set_position`/`set_velocity` (write or add-then-write), `query_entities(mask)`, `for_each(include, exclude, ...)`, `for_each_mut(include, exclude, ...)`. Migrations and queries both hit the caches on the common path and fall back to the hashmap on misses.

## What is missing

You can build a small game with what we have so far. The core loop is here. Spawn, attach components, run systems over component combinations, change components in response to events, despawn. But there are real limitations.

There is no way for a system to know which entities changed. The render system has to walk every entity with a transform every frame, even if nothing moved. The networking system has to serialize every component, not just the dirty ones. Change detection (recording when each component was last modified, and offering an "only iterate the recently-changed ones" query) is the single biggest performance win for systems that do incremental work.

There is no event system. Collision detection wants to *emit* "A hit B" and have damage application *consume* that message later in the frame. Today the only way to do this is to scribble it into a component, which is fine for one-off cases and a mess in aggregate.

There is no notion of a tag. A lightweight marker like "this entity is a player" or "this entity is selected." We could add a unit component `Player;` and put it in the archetype mask, but then adding the player tag to an entity migrates it to a new archetype, and removing it migrates it back. For markers that change frequently (think "selected" in an RTS), the migration cost is wasted. The standard solution is to store tags outside the archetype storage, in a side structure.

There is no way to safely make structural changes during iteration. A system iterating over enemies cannot despawn them mid-loop without invalidating the iteration. The standard solution is a command buffer. Queue the changes, apply them at the end.

Part 3 adds all four (change detection, events, sparse-set tags, and command buffers) and finishes with a small system schedule that ties everything together into a frame loop.

## The full file

Same shape as the part 1 checkpoint, dropping into `src/main.rs` of a fresh project. Available as a [gist](https://gist.github.com/matthewjberger/20fdef019ff97edc5ae60a961fcde6ab). `cargo run` should show the mover advancing while the landmark stays put, then both entities listed by the final `query_entities` loop. The mover went through three archetypes during execution. `POSITION` at spawn, `POSITION | VELOCITY` after the add, and back to `POSITION` after the remove. It kept its data the whole way.

