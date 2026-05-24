+++
title = "Build your own retained UI (part 2), layout and interaction"
tags = ["rust", "ui", "ecs", "game-engine", "wgpu", "tutorial"]
categories = ["rust"]
excerpt = "Resolving the tree into screen-space rectangles, anchors, row and column flow layout, hit testing, per-entity interaction state, and the event queue that makes buttons clickable."
series = "retained-ui"
series_part = 2
+++

*This is part 2 of 3 of a series.* ← [Components and tree](@/posts/2026-04-27-build-your-own-retained-ui-components.md) | Next → [Rendering with wgpu](@/posts/2026-05-07-build-your-own-retained-ui-wgpu-rendering.md)

[Part 1](@/posts/2026-04-27-build-your-own-retained-ui-components.md) built the storage. A `UiNode` on every widget, optional `UiColor`/`UiText`/`UiInteractive` for the capabilities, a `UiParent` on every child that encodes the tree, and a builder that constructs a small hierarchy. By the end of it you had a panel with two buttons inside it as ECS entities, but no system did anything with them. The buttons did not have resolved screen positions and a mouse click anywhere on the window produced nothing.

This post adds the two systems that turn the storage into something interactive. The layout system walks the tree once per frame and writes each entity's resolved screen-space rect into `UiNode::resolved`. The interaction system reads those rects, finds the topmost widget under the cursor, and writes per-entity hover/pressed/clicked flags plus a global event queue. A button becomes clickable when both systems run.

The layout system handles three placement strategies. Roots placed by anchor against the viewport. Children placed by their parent's flow logic (row, column, or free positioning). And a small flex-grow pass that lets children share unused space along the parent's flow axis. The interaction system is hit testing plus an event queue.

After this post you can build a UI, run two systems per frame, and consume `UiEvent::Clicked { entity }` from anywhere in your application. Rendering is part three.

Start from the file at the end of part 1.

## Building the inverse child cache

The tree is encoded on the children, not on the parents. A child carries `UiParent { entity: parent }`. To do anything useful in the layout system, we need to walk the tree top-down, from roots to leaves, and that means we need the inverse: for a given parent, the list of its children. Building that cache at the start of every layout pass is cheap and keeps the data layout simple.

```rust
#[derive(Default)]
pub struct LayoutState {
    pub roots: Vec<Entity>,
    pub children: HashMap<Entity, Vec<Entity>>,
    pub order: Vec<Entity>,
    pub depths: HashMap<Entity, u32>,
    pub dirty: bool,
}
```

`roots` is the list of entities with `UI_NODE` and no `UI_PARENT`. `children` maps each parent entity to its direct children. `order` is every UI entity in the world. `depths` records each entity's depth in the tree (0 for roots) so the placement pass can sort by depth. `dirty` is the gate that skips the whole pass when nothing changed.

`LayoutState` is a world resource, not a component. It is reset and rebuilt each frame, and it would not benefit from per-entity archetype storage. Resources hang off `world.resources` and are direct field access. We extend the `ecs!` declaration from part one with a `Resources` block, and the macro stamps out the `Resources` struct and the `resources: Resources` field on `World`:

```rust
ecs! {
    World {
        ui_node: UiNode => UI_NODE,
        ui_color: UiColor => UI_COLOR,
        ui_text: UiText => UI_TEXT,
        ui_parent: UiParent => UI_PARENT,
        ui_interactive: UiInteractive => UI_INTERACTIVE,
    }
    Resources {
        layout: LayoutState,
        pointer: PointerState,
        events: Vec<UiEvent>,
        viewport: Vec2,
    }
}
```

`LayoutState`, `PointerState`, and `UiEvent` are defined below as plain structs and an enum. The macro registers them as the field types of the generated `Resources`.

The layout system rebuilds `LayoutState` from a single pass over every `UI_NODE` entity.

```rust
pub fn ui_layout_build_cache(world: &mut World) {
    let entities: Vec<Entity> = world.query_entities(UI_NODE).collect();
    let parents: Vec<Option<Entity>> = entities
        .iter()
        .map(|&entity| world.get_ui_parent(entity).map(|parent| parent.entity))
        .collect();

    let state = &mut world.resources.layout;
    state.roots.clear();
    state.children.clear();
    state.order.clear();
    state.depths.clear();

    for (index, &entity) in entities.iter().enumerate() {
        state.order.push(entity);
        match parents[index] {
            None => {
                state.roots.push(entity);
                state.depths.insert(entity, 0);
            }
            Some(parent_entity) => {
                state
                    .children
                    .entry(parent_entity)
                    .or_default()
                    .push(entity);
            }
        }
    }

    fn assign_depth(state: &mut LayoutState, entity: Entity, depth: u32) {
        state.depths.insert(entity, depth);
        let children = state.children.get(&entity).cloned().unwrap_or_default();
        for child in children {
            assign_depth(state, child, depth + 1);
        }
    }

    let roots = state.roots.clone();
    for root in roots {
        assign_depth(state, root, 0);
    }
}
```

Two passes over the world followed by the cache update. The first pass collects entities and their parent links into local `Vec`s. These reads borrow `world` immutably, and once they are done the borrow ends, so the third block can take a mutable borrow of `world.resources.layout` without conflict. The recursive `assign_depth` walks the freshly-built parent-to-children map and stamps depths. The `cloned()` inside `assign_depth` is a hot-loop allocation we accept for clarity. `LayoutState` is a `&mut` borrow during the recursion and we cannot iterate `state.children[&entity]` while also writing to `state.depths`. A production layout caches the children in a flat `Vec<u32>` indexed by node, which avoids the per-recursion clone, but the trade-off is the cache itself becomes a parallel data structure to keep in sync. We pay the clone here.

The `state.dirty` check is the per-frame skip. The whole layout pass runs only when something changed: a widget was spawned or despawned, a `UiNode`'s `position`/`size`/`layout` was mutated, the viewport resized, or the application called `mark_layout_dirty`. Most frames change nothing and the layout system returns immediately.

```rust
pub fn ui_layout_system(world: &mut World) {
    if !world.resources.layout.dirty {
        return;
    }
    world.resources.layout.dirty = false;
    ui_layout_build_cache(world);
    ui_layout_place(world);
}
```

`mark_layout_dirty` is a one-line free function:

```rust
pub fn mark_layout_dirty(world: &mut World) {
    world.resources.layout.dirty = true;
}
```

Every mutator the application uses (`set_status`, `set_visible`, the typed `get_ui_node_mut`) should call `mark_layout_dirty` when it changes something that affects placement. A tighter design would invalidate the cache from inside the mutator itself, hooked into the change-detection ticks from [part three of the ECS series](@/posts/2026-04-17-build-your-own-ecs-events-changes-tags-commands.md). The hand-rolled approach is to call `mark_layout_dirty` at the call site. We will take the simpler route.

## Placing the roots

A root has no parent. Its position is interpreted against the viewport, modified by its anchor. The placement is one helper.

```rust
fn anchored_origin(node: &UiNode, viewport: Vec2) -> Vec2 {
    match node.anchor {
        Anchor::TopLeft => Vec2::new(node.position.x, node.position.y),
        Anchor::TopRight => Vec2::new(
            viewport.x - node.size.x - node.position.x,
            node.position.y,
        ),
        Anchor::BottomLeft => Vec2::new(
            node.position.x,
            viewport.y - node.size.y - node.position.y,
        ),
        Anchor::BottomRight => Vec2::new(
            viewport.x - node.size.x - node.position.x,
            viewport.y - node.size.y - node.position.y,
        ),
        Anchor::Center => Vec2::new(
            (viewport.x - node.size.x) * 0.5 + node.position.x,
            (viewport.y - node.size.y) * 0.5 + node.position.y,
        ),
        Anchor::TopCenter => Vec2::new(
            (viewport.x - node.size.x) * 0.5 + node.position.x,
            node.position.y,
        ),
        Anchor::BottomCenter => Vec2::new(
            (viewport.x - node.size.x) * 0.5 + node.position.x,
            viewport.y - node.size.y - node.position.y,
        ),
    }
}
```

For each anchor, `node.position` is the *offset from the anchor's reference corner*. `TopRight` with `position: (16, 16)` means 16 pixels in from the right edge, 16 pixels down from the top. `Center` with `position: (0, 0)` means centered exactly. `Center` with `position: (50, 0)` means centered horizontally then shifted right 50 pixels.

The function is total and pure. Every anchor variant has a closed-form expression. No constraint solving, no sibling lookup, no two-pass iteration. The same property holds for nightshade's base layouts: every base placement is dependency-local, computable from the parent's rect and the node's own values. The whole layout pass collapses to a single top-down walk.

The placement pass walks the roots, places each one, then recurses into its children.

```rust
fn ui_layout_place(world: &mut World) {
    let viewport = world.resources.viewport;
    let roots = world.resources.layout.roots.clone();

    for root in roots {
        let node = world
            .get_ui_node(root)
            .cloned()
            .unwrap_or_default();
        if !node.visible {
            continue;
        }
        let origin = anchored_origin(&node, viewport);
        if let Some(slot) = world.get_ui_node_mut(root) {
            slot.resolved = Rect::from_position_size(origin, node.size);
        }
        place_children(world, root);
    }
}
```

The root walk is short. Read the node, compute the anchored origin, write the resolved rect, then recurse. The recursion is in `place_children`, which does the meaningful work.

## Placing children

A parent's `layout` field determines how children are placed. Three modes: `None` (the child sits at `parent.padding + child.position` inside the parent), `Row` (children stack left-to-right with `parent.spacing` gaps), `Column` (children stack top-to-bottom). The closed-form expression is different per mode, but the structure is the same: compute the cursor, place each child, advance the cursor.

```rust
fn place_children(world: &mut World, parent: Entity) {
    let children = world
        .resources
        .layout
        .children
        .get(&parent)
        .cloned()
        .unwrap_or_default();
    if children.is_empty() {
        return;
    }

    let parent_node = world.get_ui_node(parent).cloned().unwrap_or_default();
    if !parent_node.visible {
        return;
    }

    match parent_node.layout {
        LayoutMode::Row => place_row(world, &parent_node, &children),
        LayoutMode::Column => place_column(world, &parent_node, &children),
        LayoutMode::None => place_none(world, &parent_node, &children),
    }

    for child in children {
        place_children(world, child);
    }
}
```

The match dispatches to a per-mode helper, then the recursion walks every placed child. Each helper writes the resolved rect for every child in the slice, then returns. The recursion is unconditional after dispatch.

`place_none` is the simplest. Each child's local position becomes its resolved position inside the parent.

```rust
fn place_none(world: &mut World, parent: &UiNode, children: &[Entity]) {
    let origin = Vec2::new(
        parent.resolved.min.x + parent.padding,
        parent.resolved.min.y + parent.padding,
    );
    for &child in children {
        let Some(slot) = world.get_ui_node_mut(child) else {
            continue;
        };
        if !slot.visible {
            continue;
        }
        let child_origin = origin + slot.position;
        slot.resolved = Rect::from_position_size(child_origin, slot.size);
    }
}
```

`place_row` is more interesting. Children stack left to right. The horizontal cursor starts at `parent.min.x + parent.padding` and advances by `child.size.x + parent.spacing` after each child. The flex-grow distribution is what makes the row useful for responsive layouts: children with `grow > 0` share whatever horizontal space the row has left over after the explicit widths and gaps.

```rust
fn place_row(world: &mut World, parent: &UiNode, children: &[Entity]) {
    let inner_width = (parent.resolved.width() - parent.padding * 2.0).max(0.0);
    let visible_children: Vec<Entity> = children
        .iter()
        .copied()
        .filter(|&child| {
            world
                .get_ui_node(child)
                .map(|node| node.visible)
                .unwrap_or(false)
        })
        .collect();

    let mut used = 0.0;
    let mut total_grow = 0.0;
    for &child in &visible_children {
        let Some(node) = world.get_ui_node(child) else {
            continue;
        };
        used += node.size.x;
        total_grow += node.grow;
    }
    let gap_count = visible_children.len().saturating_sub(1) as f32;
    let gap = parent.spacing * gap_count;
    let extra = (inner_width - used - gap).max(0.0);

    let mut cursor = parent.resolved.min.x + parent.padding;
    let y = parent.resolved.min.y + parent.padding;
    for &child in &visible_children {
        let Some(slot) = world.get_ui_node_mut(child) else {
            continue;
        };
        let mut width = slot.size.x;
        if total_grow > 0.0 && slot.grow > 0.0 {
            width += extra * (slot.grow / total_grow);
        }
        let origin = Vec2::new(cursor + slot.position.x, y + slot.position.y);
        slot.resolved = Rect::from_position_size(origin, Vec2::new(width, slot.size.y));
        cursor += width + parent.spacing;
    }
}
```

Two passes over the children. The first totals the explicit widths and grow weights. The second walks again with the cursor and writes each child's resolved rect. The `child.position` is added on top of the cursor. It lets a child shift its position relative to the slot the row would otherwise give it, which is useful for hand-tuning. The `child.grow` weight distributes the leftover horizontal space proportionally: a child with `grow: 2.0` next to a child with `grow: 1.0` gets twice the leftover width.

The column form is the same code rotated 90 degrees.

```rust
fn place_column(world: &mut World, parent: &UiNode, children: &[Entity]) {
    let inner_height = (parent.resolved.height() - parent.padding * 2.0).max(0.0);
    let visible_children: Vec<Entity> = children
        .iter()
        .copied()
        .filter(|&child| {
            world
                .get_ui_node(child)
                .map(|node| node.visible)
                .unwrap_or(false)
        })
        .collect();

    let mut used = 0.0;
    let mut total_grow = 0.0;
    for &child in &visible_children {
        let Some(node) = world.get_ui_node(child) else {
            continue;
        };
        used += node.size.y;
        total_grow += node.grow;
    }
    let gap_count = visible_children.len().saturating_sub(1) as f32;
    let gap = parent.spacing * gap_count;
    let extra = (inner_height - used - gap).max(0.0);

    let x = parent.resolved.min.x + parent.padding;
    let mut cursor = parent.resolved.min.y + parent.padding;
    for &child in &visible_children {
        let Some(slot) = world.get_ui_node_mut(child) else {
            continue;
        };
        let mut height = slot.size.y;
        if total_grow > 0.0 && slot.grow > 0.0 {
            height += extra * (slot.grow / total_grow);
        }
        let origin = Vec2::new(x + slot.position.x, cursor + slot.position.y);
        slot.resolved = Rect::from_position_size(origin, Vec2::new(slot.size.x, height));
        cursor += height + parent.spacing;
    }
}
```

Two copies of nearly-identical code is the cost of not generalizing the axis. A more general implementation would parametrize the helper over an axis enum and write the placement once. The duplication keeps each pass tight and obvious about what changes. nightshade's production layout reaches for [taffy](https://crates.io/crates/taffy) under the hood for flex and grid, which is the right call when the layout language has to handle wrap, justify-content variants, basis vs grow vs shrink, and the full CSS flex behavior. For a self-contained retained UI with two flow modes, this hand-rolled placement is enough.

## When does the layout actually re-run

The dirty flag is the only thing that determines whether the placement pass runs. The application sets the flag, the system clears it on entry, and the next call returns immediately until something flips the flag again. The structural mutations that need to flip it.

- Spawning a new UI entity (the builder marks dirty after spawn).
- Despawning a UI entity (the despawn helper marks dirty).
- Changing any node's `position`, `size`, `padding`, `spacing`, `anchor`, `layout`, `grow`, or `visible`.
- Changing the parent link of any entity (rare in retained UIs).
- Viewport resize.

The mutators are short. Every typed `get_*_mut` accessor could mark the cache dirty automatically if it stamped the node version on return, which is the approach nightshade takes with its global layout version counter. For now we add a thin layer of explicit helpers.

```rust
pub fn set_position(world: &mut World, entity: Entity, position: Vec2) {
    if let Some(node) = world.get_ui_node_mut(entity) {
        if node.position != position {
            node.position = position;
            world.resources.layout.dirty = true;
        }
    }
}

pub fn set_visible(world: &mut World, entity: Entity, visible: bool) {
    if let Some(node) = world.get_ui_node_mut(entity) {
        if node.visible != visible {
            node.visible = visible;
            world.resources.layout.dirty = true;
        }
    }
}

pub fn on_viewport_resize(world: &mut World, viewport: Vec2) {
    if world.resources.viewport != viewport {
        world.resources.viewport = viewport;
        world.resources.layout.dirty = true;
    }
}
```

The application uses these helpers instead of the raw `get_ui_node_mut`. Anything that bypasses them and writes the node directly is responsible for setting the dirty flag itself. The trade-off is that the application has one extra rule to remember; the alternative is a write-stamp on every mutation, which has its own cost.

## Pointer state

The interaction system needs to know where the cursor is and which buttons are pressed this frame. The application's main loop produces that data from raw input and writes it into a resource.

```rust
#[derive(Clone, Default)]
pub struct PointerState {
    pub position: Vec2,
    pub left_down: bool,
    pub left_just_pressed: bool,
    pub left_just_released: bool,
    pub right_down: bool,
    pub right_just_pressed: bool,
    pub right_just_released: bool,
    pub over_ui: bool,
    pub focused_entity: Option<Entity>,
    pub pressed_entity: Option<Entity>,
}
```

`position` is the cursor in window-pixel coordinates. `left_down` is the current state. `left_just_pressed` and `left_just_released` are the edges, set for one frame on the transition. `over_ui` is an output flag: the interaction system writes it `true` when the cursor is over any interactive UI widget, so the rest of the application's input handling can suppress 3D world interactions when the user is clicking UI. `focused_entity` is the last widget that received a left-press, used to route keyboard input to text fields. `pressed_entity` is internal bookkeeping for the press-release click detection.

The main loop snapshot looks like this: read winit events, update the booleans, run the schedule.

```rust
fn update_pointer_from_input(pointer: &mut PointerState, raw: &RawInput) {
    pointer.position = raw.cursor_position;
    let was_down = pointer.left_down;
    pointer.left_down = raw.left_mouse_pressed;
    pointer.left_just_pressed = pointer.left_down && !was_down;
    pointer.left_just_released = !pointer.left_down && was_down;
}
```

`RawInput` is a placeholder for the application's input plumbing. The detail that matters is that `left_just_pressed` is set for exactly one frame on the press edge and `left_just_released` is set for exactly one frame on the release edge. Both clear the next frame.

## Hit testing

The hit test is: find the topmost interactive widget under the cursor. Topmost is well-defined here because every node has a `z_index` and the layout system has computed a `resolved` rect. Walk the visible interactive widgets, find the ones whose `resolved` contains the cursor, pick the one with the highest `z_index` (with a tiebreaker that we will discuss).

```rust
fn hit_test(world: &World, cursor: Vec2) -> Option<Entity> {
    let mut best: Option<(Entity, i32, f32)> = None;

    for entity in world.query_entities(UI_NODE | UI_INTERACTIVE) {
        let Some(node) = world.get_ui_node(entity) else {
            continue;
        };
        if !node.visible || !node.resolved.contains(cursor) {
            continue;
        }
        let z = node.z_index;
        let area = node.resolved.width() * node.resolved.height();
        let candidate = match best {
            None => true,
            Some((_, best_z, best_area)) => {
                z > best_z || (z == best_z && area < best_area)
            }
        };
        if candidate {
            best = Some((entity, z, area));
        }
    }

    best.map(|(entity, _, _)| entity)
}
```

This is a brute-force scan over every visible interactive widget. `query_entities(mask)` yields exactly the entities whose archetype contains every bit in the mask, walking the matching tables. The body filters further by visibility and point-in-rect, then keeps the topmost. The tiebreaker is "smaller rect wins". If two widgets have the same `z_index` and both contain the cursor, the smaller one is more specific. A popup item inside a popup panel both contain the cursor; without the area tiebreaker, the panel (added later for z-order reasons) would shadow its own items. With the tiebreaker, the item wins because its rect is smaller.

For a UI with a few dozen interactive widgets, the brute force is fine. Each frame does a few dozen point-in-rect tests, which is nothing. Scaling beyond a few hundred starts to cost. The standard answer is a spatial grid: at the end of the layout pass, bucket every interactive widget's `resolved` rect into a grid of cells, then on hit test, only check the cell the cursor is in.

```rust
pub struct PickingGrid {
    pub cells: Vec<Vec<PickingEntry>>,
    pub cell_size: f32,
    pub columns: usize,
    pub rows: usize,
}

pub struct PickingEntry {
    pub entity: Entity,
    pub z_index: i32,
    pub area: f32,
    pub resolved: Rect,
}
```

Construction is a single pass at the end of layout. For each visible interactive widget, find the cells its `resolved` overlaps (by dividing the rect's bounds by the cell size and clamping to the grid), and push an entry into each of those cells.

```rust
impl PickingGrid {
    pub fn new(viewport: Vec2, cell_size: f32) -> Self {
        let columns = ((viewport.x / cell_size).ceil() as usize).max(1);
        let rows = ((viewport.y / cell_size).ceil() as usize).max(1);
        Self {
            cells: (0..columns * rows).map(|_| Vec::new()).collect(),
            cell_size,
            columns,
            rows,
        }
    }

    pub fn insert(&mut self, entry: PickingEntry) {
        let rect = entry.resolved;
        let col_start = (rect.min.x / self.cell_size).floor().max(0.0) as usize;
        let col_end =
            ((rect.max.x / self.cell_size).ceil() as usize).min(self.columns);
        let row_start = (rect.min.y / self.cell_size).floor().max(0.0) as usize;
        let row_end =
            ((rect.max.y / self.cell_size).ceil() as usize).min(self.rows);
        for row in row_start..row_end {
            for col in col_start..col_end {
                self.cells[row * self.columns + col].push(PickingEntry {
                    entity: entry.entity,
                    z_index: entry.z_index,
                    area: entry.area,
                    resolved: entry.resolved,
                });
            }
        }
    }

    pub fn query(&self, point: Vec2) -> Option<Entity> {
        let col = (point.x / self.cell_size).floor() as isize;
        let row = (point.y / self.cell_size).floor() as isize;
        if col < 0 || row < 0 || col >= self.columns as isize || row >= self.rows as isize {
            return None;
        }
        let cell = &self.cells[row as usize * self.columns + col as usize];

        let mut best: Option<(Entity, i32, f32)> = None;
        for entry in cell {
            if !entry.resolved.contains(point) {
                continue;
            }
            let candidate = match best {
                None => true,
                Some((_, best_z, best_area)) => {
                    entry.z_index > best_z
                        || (entry.z_index == best_z && entry.area < best_area)
                }
            };
            if candidate {
                best = Some((entry.entity, entry.z_index, entry.area));
            }
        }
        best.map(|(entity, _, _)| entity)
    }
}
```

The grid is a per-frame structure rebuilt by the layout system. Cell size of 64 pixels is a reasonable default; smaller cells reduce the per-cell list at the cost of more cells the larger widgets need to insert into. nightshade uses 64.

`query` walks one cell, which has at most a handful of entries. The same tiebreaker logic from the brute-force path applies. For most UIs the brute force is enough; the grid is what production-quality retained UIs use, and the cost is one extra system that runs once per layout change.

## Updating interaction state

With the hit-test result, the interaction system walks every interactive widget and updates its state. The hit entity gets `hovered = true`, everything else gets cleared, the press-release cycle drives `pressed` and `clicked`.

```rust
pub fn ui_interaction_system(world: &mut World) {
    let pointer = world.resources.pointer.clone();
    let hit = hit_test(world, pointer.position);

    let entities: Vec<Entity> = world.query_entities(UI_NODE | UI_INTERACTIVE).collect();
    for entity in &entities {
        if let Some(interactive) = world.get_ui_interactive_mut(*entity) {
            interactive.hovered = false;
            interactive.pressed = false;
            interactive.clicked = false;
        }
    }

    if let Some(hit_entity) = hit {
        if let Some(interactive) = world.get_ui_interactive_mut(hit_entity) {
            interactive.hovered = true;
            if pointer.left_down {
                interactive.pressed = true;
            }
        }
    }

    let previous_pressed = world.resources.pointer.pressed_entity;

    world.resources.pointer.over_ui = hit.is_some();
    if pointer.left_just_pressed {
        world.resources.pointer.pressed_entity = hit;
        world.resources.pointer.focused_entity = hit;
    }

    if pointer.left_just_released {
        if let (Some(pressed), Some(hit_entity)) = (previous_pressed, hit) {
            if pressed == hit_entity {
                if let Some(interactive) = world.get_ui_interactive_mut(hit_entity) {
                    interactive.clicked = true;
                }
                world
                    .resources
                    .events
                    .push(UiEvent::Clicked { entity: hit_entity });
            }
        }
        world.resources.pointer.pressed_entity = None;
    }
}
```

Five phases. Clear every widget's hover/pressed/clicked. Set hover/pressed on the hit widget. Update `over_ui`. On press, latch the pressed entity and update focus. On release, fire `Clicked` if the press-release stayed on the same entity, and emit the event. The `previous_pressed` snapshot is read out before the press updates touch `world.resources.pointer`, so the release branch can compare against the value that was latched on the previous frame's press without holding a borrow across the event push.

The `pressed_entity` latching is what defines a click. A click is *press on entity X, release on the same entity X*. If the user presses on a button and drags off before releasing, no click fires. If the user presses outside any button and drags into one before releasing, no click fires. The latching is what produces both behaviors at once.

`hovered` is set every frame from the hit-test result. `pressed` is set every frame the mouse button is down over the widget. `clicked` is set for *exactly one frame*, the frame the release happens. The application reads `interactive.clicked` once and the flag is gone next frame.

## The event queue

Per-entity flags work for the simple case (poll `interactive.clicked` for every button the application cares about). For systems that react to clicks without tracking individual entities, an event queue is cleaner. The interaction system writes events; consumers drain or read.

```rust
#[derive(Clone, Debug)]
pub enum UiEvent {
    Clicked { entity: Entity },
    DoubleClicked { entity: Entity },
    RightClicked { entity: Entity },
    Hovered { entity: Entity },
    HoverEnded { entity: Entity },
    Focused { entity: Entity },
}
```

The events are sent into `world.resources.events` and stay there until the application drains them at the end of the frame.

```rust
pub fn drain_ui_events(world: &mut World) -> Vec<UiEvent> {
    std::mem::take(&mut world.resources.events)
}
```

`mem::take` swaps out the entire vec for an empty one in O(1), no element copies. The application consumes the drained events and processes whatever needs to fire.

```rust
let events = drain_ui_events(&mut world);
for event in events {
    match event {
        UiEvent::Clicked { entity } if entity == save_button => save(),
        UiEvent::Clicked { entity } if entity == cancel_button => cancel(),
        UiEvent::DoubleClicked { entity } => println!("double click on {entity:?}"),
        _ => {}
    }
}
```

Same idea as the [double-buffered event queue from part three of the ECS series](@/posts/2026-04-17-build-your-own-ecs-events-changes-tags-commands.md), simplified for the UI case. The UI event queue does not need the two-frame readability rule because the events are produced and consumed within the same frame. Drained at the end of the frame, fresh at the start.

A production retained UI would generalize this into a typed event system (`world.send_event(SliderChanged { value })`, `world.drain_events::<SliderChanged>()`) so that different event types do not all share one heterogenous `UiEvent` enum. The macro layer in nightshade's `ecs!` declaration handles that fan-out. We are doing it by hand with a single enum.

## Double-click, right-click, focus changes

Double-click detection is the obvious extension. Track the last click's entity, timestamp, and position. If the next click happens on the same entity within a short window and within a short distance, fire a `DoubleClicked` instead of a `Clicked`.

```rust
#[derive(Default)]
pub struct InteractionExtras {
    pub last_click: Option<(Entity, f64, Vec2)>,
}

const DOUBLE_CLICK_TIME_SECONDS: f64 = 0.3;
const DOUBLE_CLICK_DISTANCE: f32 = 4.0;

fn process_release(
    world: &mut World,
    extras: &mut InteractionExtras,
    pressed: Entity,
    hit: Entity,
    cursor: Vec2,
    current_time: f64,
) {
    if pressed != hit {
        return;
    }
    let is_double = matches!(
        extras.last_click,
        Some((prev_entity, prev_time, prev_pos))
            if prev_entity == hit
            && (current_time - prev_time) < DOUBLE_CLICK_TIME_SECONDS
            && (cursor - prev_pos).magnitude() < DOUBLE_CLICK_DISTANCE
    );
    if is_double {
        world.resources.events.push(UiEvent::DoubleClicked { entity: hit });
        extras.last_click = None;
    } else {
        world.resources.events.push(UiEvent::Clicked { entity: hit });
        extras.last_click = Some((hit, current_time, cursor));
    }
}
```

`InteractionExtras` is another world resource holding the single-bit history needed for double-click. The thresholds (300 ms, 4 pixels) match platform conventions.

Right-click is the same code with `right_just_released` and a `RightClicked` event variant. Focus changes work the same way: when the press updates `pointer.focused_entity`, compare against the previous value and fire `Focused { entity }` on change.

Both extensions follow the same pattern: a small piece of per-resource state and an extra branch in the interaction system. No new components and no new tables. The interactive widget stays four boolean flags.

## The button click cycle

The complete cycle for a button click in this design.

1. Frame N. The application updates `pointer.position` from the cursor's window-pixel coordinates. The user is hovering over the button.
2. The interaction system runs. Hit test finds the button. The button's `interactive.hovered` flips to `true`. The render pass (part three) sees `hovered: true` and may draw the button with a hover tint.
3. Frame N+1. The user presses the left mouse button. `pointer.left_down: true`, `pointer.left_just_pressed: true`.
4. Interaction system runs. Hit test still finds the button. `interactive.pressed: true`. `pointer.pressed_entity: Some(button)`. `pointer.focused_entity: Some(button)`.
5. Frame N+M. The user releases the left mouse button over the same button. `pointer.left_just_released: true`. `pointer.left_down: false`.
6. Interaction system runs. Hit test finds the button. `pointer.pressed_entity == Some(button) == hit`, so the click fires. `interactive.clicked: true` for this frame. `UiEvent::Clicked { entity: button }` is pushed onto `world.resources.events`.
7. The application reads `interactive.clicked` directly or drains the event queue. The button's action runs.
8. Frame N+M+1. `clicked` is back to `false`. `pointer.pressed_entity` is back to `None`. The next click cycle is independent.

Two systems and one resource per frame. The button is the same six fields it has been since part one. No subclassing, no virtual dispatch, no widget trait.

## What we built

```
World resources  (new)
├── layout: LayoutState           per-frame cache + dirty flag
├── pointer: PointerState         cursor and button state
├── events: Vec<UiEvent>          drained at end of frame
└── viewport: Vec2                current window size

Systems  (new)
├── ui_layout_system              builds child cache + places every node
└── ui_interaction_system         hit tests and updates interactive state

Free helpers
├── set_position / set_visible / on_viewport_resize  mutators that mark dirty
├── mark_layout_dirty                                 flag flip
└── drain_ui_events                                   end-of-frame consumer
```

New operations. `set_position(world, entity, pos)`, `set_visible(world, entity, bool)`, and `on_viewport_resize(world, viewport)` mutate the tree and mark the cache dirty. `mark_layout_dirty(world)` is the explicit escape hatch when the application writes through `get_ui_node_mut` directly. `drain_ui_events(world)` is the end-of-frame consumer.

The schedule for a frame.

```rust
fn run_ui_frame(world: &mut World) {
    ui_layout_system(world);
    ui_interaction_system(world);
}
```

Two calls. The layout system writes `resolved` rects into every visible node. The interaction system reads those rects, updates per-entity flags, and pushes events. After both, the application drains events and decides what to do with them.

## What is missing

Nothing is rendered yet. Every `UiNode::resolved` is correct, every `UiInteractive::hovered` is up to date, but the GPU has not seen any of this data. The application still has a blank window.

There is no text-input handling beyond the focused-entity tracking. A focused entity with a `UiText` field cannot type into it because no system is consuming keyboard events and writing them into the text. The extension is small: a `UiTextInput` component with a `buffer: String` and `caret: usize`, plus a system that appends typed runes when the entity is focused. The storage and the layout do not change.

There is no drag-and-drop, no scrolling, no tab navigation, no command palette, no modal dialogs. These are all production-retained-UI features that live on top of what is here. Each one is a few additional components and a system, none of them require revisiting the storage or the layout.

There is no animation. Hover and pressed states snap on and off, which is fine for a tutorial and looks robotic in production. Adding a state-weight system that crossfades between hover-on and hover-off over a hundred milliseconds is exactly what nightshade's `UiStateWeights` and `StateTransition` do; the shape is per-state weights stored on the entity, advanced toward targets each frame, used to blend the rendered color.

There is no clipping or scrolling. The `clip` field on `UiNode` is recorded and unused. Implementing it means intersecting children's `resolved` rects against the parent's clip rect during layout (so picked-against the same clip), and feeding the clip rect into the render pass so the GPU does scissor-based culling. Both pieces are mechanical.

Part three handles the rendering, which is where most of the GPU-specific work lives. The instance buffer that the render pass uploads to the GPU, the rect shader that draws every UI rectangle as an SDF rounded rectangle in one instanced draw, the text pass with a bitmap font atlas, and the layer-based draw ordering that respects `z_index`.

## The full file

The layout system, the interaction system, the picking grid, and the event queue are the snippets above, around 450 lines on top of the part-one file. With them assembled and running, you can move the (still-invisible) cursor over the (still-invisible) buttons, press, release, and watch the event queue collect `UiEvent::Clicked { entity }` entries. Print them in the main loop and the cycle is visible:

```
[hover] entity Entity { id: 1, generation: 0 }
[press] entity Entity { id: 1, generation: 0 }
[click] entity Entity { id: 1, generation: 0 }
```

The UI is alive in the ECS world. Part three gives it pixels.
