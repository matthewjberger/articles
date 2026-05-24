+++
title = "Build your own retained UI (part 1), components and tree"
tags = ["rust", "ui", "ecs", "game-engine", "wgpu", "tutorial"]
categories = ["rust"]
excerpt = "A retained UI built on top of an archetype ECS. Part 1 lays down the components, the tree, and a small builder that produces a working widget hierarchy."
series = "retained-ui"
series_part = 1
series_title = "Build your own retained UI"
+++

*This is part 1 of 3 of a series.* Next → [Layout and interaction](@/posts/2026-05-02-build-your-own-retained-ui-layout-interaction.md)

A retained UI is a UI where the widget tree exists as data between frames. You build the tree once at startup, mutate slots in response to events, and the layout and rendering systems work on whatever is in the tree this frame. An immediate-mode UI does the opposite: the application code calls draw functions every frame and the UI library remembers nothing across frames except a hash table of widget state. Both designs work. Retained scales better when the UI is large, has many independent panels, or has to react to non-UI events (network messages, async loads) outside the per-frame call chain.

The standard retained-UI design hands you a tree of widget objects. `Button extends Widget`, `Panel extends Widget`, a virtual `layout()` method on each, a `paint()` method on each, the parent owns its children in a `Vec<Box<dyn Widget>>`. This works and it has the same problem an OOP entity hierarchy has. Every per-frame walk pays a v-table dispatch and an indirection per node. Adding a feature that touches every widget (a theme color, a focus ring, change tracking, accessibility metadata) means editing every subclass.

The data-oriented alternative is to make every widget an entity in an ECS world and put the widget's data on it as components. `UiNode` holds the rect and layout properties. `UiColor` holds the fill color. `UiText` holds an optional label. `UiParent` carries the tree link. `UiInteractive` carries pointer state. Layout becomes a system that walks the tree once per frame and writes resolved rects back into `UiNode`. Hit testing is a system that walks the entities with `UiInteractive` and updates their hover/pressed/clicked flags. Rendering is a system that reads the laid-out tree and produces an instance buffer. No v-table dispatch anywhere, and new capabilities are new components and new systems instead of new subclasses.

This is a deliberately uncommon choice in the Rust gamedev world, where the reflex is an immediate-mode library like egui or a bespoke per-game UI. Retained-and-ECS-backed is closer to how a browser's DOM persists across frames than to how an immediate-mode panel rebuilds itself every call, and it pays off exactly when a UI is large, long-lived, and mutated by code that does not run inside the per-frame draw loop. The rest of the series is what that choice looks like in practice.

The build covers rectangles, text, anchors, flow layout, hit testing, and clickable buttons, dropped into a wgpu-based game or tool. Part one covers the components and the tree. Layout and interaction is part two. wgpu rendering is part three. Aimed at Rust developers who want to understand how a retained UI is shaped, well enough to write one or to read a production crate without guessing.

What gets built over the series is the kernel of the retained UI in [nightshade](https://github.com/matthewjberger/nightshade), my game engine. The kernel sits on top of [freecs](https://github.com/matthewjberger/freecs), the archetype ECS I covered in the [previous three-part series](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md). Each widget is an entity, each capability is a component, and the systems walk the world the same way the physics step did in the ECS posts. A parallel Go implementation lives in [indigo](https://github.com/matthewjberger/indigo). I used it as a smaller-scale reference for the same architecture, and it's a useful cross-check that the ideas are not Rust-specific.

## Why an ECS

A widget is a combination of orthogonal capabilities glued to a hierarchy. A button is a rectangle with a fill color, a border, a label, pointer reactivity, hover and pressed states, accessibility metadata, and a focus ring when keyboard-focused. None of those things imply the others. A button without a border is still a button. A label with no fill is still a label. The retained-UI tradition tries to model this with inheritance (`InteractiveWidget extends Widget`, `LabeledInteractiveWidget extends InteractiveWidget`), and then spends as much code on the workarounds for when the combinations multiply.

Composition over `Vec<Box<dyn Widget>>` solves the modeling problem. It does not solve the per-frame access problem. The layout pass still has to dispatch through a v-table to ask each widget for its content size. The render pass still has to dispatch through a v-table to emit each widget's draw calls. With 500 widgets on screen, that is two thousand v-table dispatches per frame just to walk the tree.

The ECS-backed design replaces both. Every widget is an entity. The mix of components on the entity is the widget's capability set. A "button" is the combination `UiNode + UiColor + UiText + UiInteractive`. A "label" is `UiNode + UiText`. A "panel" is `UiNode + UiColor`. No `Button` type, no inheritance, no v-table.

Adding a new capability is a one-line addition. A `UiTooltip { text: String }` component does not require subclassing anything. Any entity with `UiInteractive + UiTooltip` gets a tooltip. The tooltip-drawing system queries for that combination and draws. Entities without the component pay nothing.

Adding a new system that touches every visible widget (theme color crossfading, focus-ring drawing, change detection for incremental rendering) does not require editing every widget type. It iterates `for_each_mut(UI_NODE, ...)` and is one function. This is the same shape that worked for `Position + Velocity` in the [archetype ECS](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md), applied to widgets.

## What "retained" actually buys

The tree persists across frames. The application code does not rebuild it every frame. Most frames touch only the components that changed. A status text changing once a second writes one `String` once a second, not 60 times. A static panel header is allocated once and re-read every frame from the same memory.

Cross-frame state is implicit. Hover, pressed, focus, drag, animation progress, all of these are components on the entity and they stay there between frames. An immediate-mode UI would have to look these up by widget ID in a side hashmap and reconcile every frame. The retained UI keeps them on the entity, in the table, next to the rest of the widget's data.

Non-UI code can mutate the UI by entity handle. The application keeps `Entity` handles to the widgets it wants to update. When a network message arrives, it writes to `world.get_ui_text_mut(self.status_label).unwrap().content = "Connected"` and the UI updates next frame. No event bus, no marshaling to the UI thread, no widget lookup.

The cost is that the application has to track the handles it wants to mutate. An immediate-mode UI gets this for free because every widget is named at every call site. A retained UI gets it back with named entities (a registry of `"loading_progress" -> Entity` lookup) or by holding handles directly.

## The `Entity` and the `UiNode`

We are using freecs entities directly. An `Entity` is a generational handle, a small `(id, generation)` pair, and the ECS world refuses to honor a handle whose generation does not match the current generation for that slot. Stale handles to despawned widgets fail closed.

The `UiNode` is the rectangle every widget carries.

```rust
#[derive(Clone, Debug, Default)]
pub struct UiNode {
    pub position: Vec2,
    pub size: Vec2,
    pub anchor: Anchor,
    pub padding: f32,
    pub spacing: f32,
    pub layout: LayoutMode,
    pub grow: f32,
    pub z_index: i32,
    pub visible: bool,
    pub clip: Option<Rect>,
    pub resolved: Rect,
}
```

`position` and `size` are the widget's intent. The author says "this button is 96 by 32, placed at (16, 16) from the top-left of its parent." The layout system reads those values and writes the final screen-space rect into `resolved`. `position` and `size` are inputs; `resolved` is the output that downstream passes consume.

`anchor` records how the widget's `position` is interpreted relative to its container. `TopLeft` means the position is an offset from the container's top-left corner. `Center` means the position is an offset from the container's center, with the widget centered on that point. `BottomRight` means the position offsets in from the bottom-right. Anchors are a small enum and the placement logic is a `match` in the layout system.

`padding` and `spacing` are flow-layout knobs. `padding` is the inset between the widget's own bounds and its first child's bounds. `spacing` is the gap between successive children when the parent is laid out as a row or a column. `grow` is the flex weight used when sibling widgets share unused space along the parent's flow axis. `layout` is a small enum: `None` for free-positioned children, `Row` for left-to-right stacking, `Column` for top-to-bottom stacking. We will use these in part two.

`z_index` is the painter's-algorithm z-order. Higher numbers draw on top. The render pass sorts by `z_index` ascending before submitting draws. `visible` is a per-frame toggle; an invisible node and its subtree skip rendering and hit testing. `clip`, when set, is an extra rect the renderer intersects against when emitting draws. Useful for scroll views and modal masks.

`resolved` defaults to a zero rect. The layout system writes to it every frame.

```rust
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum Anchor {
    #[default]
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Center,
    TopCenter,
    BottomCenter,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum LayoutMode {
    #[default]
    None,
    Row,
    Column,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Rect {
    pub min: Vec2,
    pub max: Vec2,
}

impl Rect {
    pub fn from_position_size(position: Vec2, size: Vec2) -> Self {
        Self {
            min: position,
            max: position + size,
        }
    }

    pub fn width(&self) -> f32 {
        self.max.x - self.min.x
    }

    pub fn height(&self) -> f32 {
        self.max.y - self.min.y
    }

    pub fn size(&self) -> Vec2 {
        Vec2::new(self.width(), self.height())
    }

    pub fn center(&self) -> Vec2 {
        (self.min + self.max) * 0.5
    }

    pub fn contains(&self, point: Vec2) -> bool {
        point.x >= self.min.x
            && point.x <= self.max.x
            && point.y >= self.min.y
            && point.y <= self.max.y
    }
}
```

`Rect` is `min`/`max` rather than `position`/`size` because every hit test and intersection in the layout and picking systems wants the corners directly. Converting one shape to the other on every access wastes a few additions and a subtraction per call. Storing both forms keeps the math local.

## Color, text, parent, interaction

Four more components. Each is a single struct with the minimum data its system needs.

```rust
#[derive(Clone, Copy, Debug, Default)]
pub struct UiColor {
    pub rgba: Vec4,
}

#[derive(Clone, Debug, Default)]
pub struct UiText {
    pub content: String,
    pub color: Vec4,
    pub size: f32,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct UiParent {
    pub entity: Entity,
}

#[derive(Clone, Debug, Default)]
pub struct UiInteractive {
    pub hovered: bool,
    pub pressed: bool,
    pub clicked: bool,
    pub focused: bool,
}
```

`UiColor` is the entity's fill. The render pass reads it for any entity that carries it. Entities without `UiColor` are transparent. They hold layout slots but emit no rectangle. This is how a panel-group with no background of its own (just a container for its children) works: the parent has `UiNode` only, the children have `UiNode + UiColor`.

`UiText` is the optional label. The renderer's text pass queries `UiNode + UiText` and emits glyph instances inside the resolved rect. `content` is the string, `color` is the foreground RGBA, `size` is the font height in logical pixels. Text without a node is meaningless, because the rect tells the text pass where to draw. The text pass also requires `UiNode` to be present.

`UiParent` is the tree link. An entity with `UiParent` is a child of `entity`. An entity without `UiParent` is a root. The tree is encoded entirely in these parent pointers, on the children, not on the parents. We do not store a `children: Vec<Entity>` on the parent. Instead the layout system builds a child cache per frame by walking every `UiParent`-bearing entity and bucketing them under their parent. This is the standard ECS-tree representation. Encoding the parent on the child (the "many side" of the one-to-many relationship) makes it cheap to spawn a child without touching the parent, and the system that needs the inverse cache just builds it. Encoding `children: Vec<Entity>` on the parent would require keeping that vec in sync with every spawn, despawn, and reparent, which is exactly the kind of cross-cutting bookkeeping that gets out of date.

`UiInteractive` is what marks a widget as pointer-reactive. The hit test system queries `UiNode + UiInteractive`, finds the topmost interactive widget under the cursor, and writes `hovered = true` into its interactive component. Entities without `UiInteractive` are pointer-transparent. This is the equivalent of nightshade's `pointer_events: false` default. Static labels, decorative borders, and panel containers do not block clicks. Opting into interaction is one component.

Component types are decoupled from the storage. There is no `impl Widget for UiNode` ceremony. Any struct can become a widget capability just by being declared as a component on the world. That decoupling is what makes adding a tooltip component or a tab-index component or a tooltip-on-hover component a one-line affair.

## Wiring the components into a world

If you are using freecs's declarative macro, the whole component registration is one block.

```rust
use freecs::{ecs, Entity};
use nalgebra_glm::{Vec2, Vec4};

ecs! {
    World {
        ui_node: UiNode => UI_NODE,
        ui_color: UiColor => UI_COLOR,
        ui_text: UiText => UI_TEXT,
        ui_parent: UiParent => UI_PARENT,
        ui_interactive: UiInteractive => UI_INTERACTIVE,
    }
}
```

The macro stamps out the `World` type, the per-archetype `ComponentArrays`, the typed accessors (`get_ui_node`, `set_ui_node`, `get_ui_node_mut`, `entity_has_ui_node`), and the mask constants (`UI_NODE`, `UI_COLOR`, etc.) that identify each component bit.

If you would rather hand-roll this, the equivalent is the kernel from the [first ECS post](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md), extended with one field per component on `ComponentArrays` and the matching fan-out on `spawn`, `despawn`, `move_entity`, and the getters. We are not doing it again here. The macro is the right call for this kind of fan-out.

## A small builder

The naive way to build a UI tree is to call `world.spawn(UI_NODE | UI_COLOR | UI_TEXT)` for every widget, write the component values through getters, and stash the `Entity` in a local. That works and reads poorly.

```rust
let panel = world.spawn(UI_NODE | UI_COLOR);
*world.get_ui_node_mut(panel).unwrap() = UiNode {
    position: Vec2::new(16.0, 16.0),
    size: Vec2::new(220.0, 80.0),
    layout: LayoutMode::Row,
    padding: 8.0,
    spacing: 8.0,
    ..Default::default()
};
*world.get_ui_color_mut(panel).unwrap() = UiColor {
    rgba: Vec4::new(0.10, 0.10, 0.12, 0.85),
};

let button = world.spawn(UI_NODE | UI_COLOR | UI_TEXT | UI_INTERACTIVE | UI_PARENT);
*world.get_ui_parent_mut(button).unwrap() = UiParent { entity: panel };
*world.get_ui_node_mut(button).unwrap() = UiNode {
    size: Vec2::new(96.0, 32.0),
    ..Default::default()
};
*world.get_ui_color_mut(button).unwrap() = UiColor {
    rgba: Vec4::new(0.18, 0.50, 0.80, 1.0),
};
*world.get_ui_text_mut(button).unwrap() = UiText {
    content: "Pick".to_string(),
    color: Vec4::new(1.0, 1.0, 1.0, 1.0),
    size: 14.0,
};
```

Twelve lines for a panel and one button. Building a real UI with 50 widgets this way would be 600 lines of repetitive component writes.

The fix is a builder with a current-parent stack and a fluent setter chain.

```rust
pub struct UiBuilder<'a> {
    world: &'a mut World,
    parent_stack: Vec<Entity>,
    cursor: Option<Entity>,
}

impl<'a> UiBuilder<'a> {
    pub fn new(world: &'a mut World) -> Self {
        Self {
            world,
            parent_stack: Vec::new(),
            cursor: None,
        }
    }

    pub fn world_mut(&mut self) -> &mut World {
        self.world
    }

    pub fn entity(&self) -> Option<Entity> {
        self.cursor
    }

    pub fn push(&mut self, parent: Entity) -> &mut Self {
        self.parent_stack.push(parent);
        self
    }

    pub fn pop(&mut self) -> &mut Self {
        self.parent_stack.pop();
        self
    }

    pub fn in_parent<F>(&mut self, parent: Entity, body: F) -> &mut Self
    where
        F: FnOnce(&mut Self),
    {
        self.push(parent);
        body(self);
        self.pop();
        self
    }
}
```

`UiBuilder` holds a mutable borrow of the world for the duration of the build, a stack of parent entities, and a cursor pointing at the most recently created entity. `push` and `pop` manage the parent stack manually; `in_parent` is the closure-scoped form that pushes for the body and pops on return, impossible to mismatch.

The node creation method spawns the entity, writes the parent if one is active on the stack, and stashes the cursor.

```rust
impl<'a> UiBuilder<'a> {
    pub fn node(&mut self, node: UiNode) -> &mut Self {
        let mut mask = UI_NODE;
        if !self.parent_stack.is_empty() {
            mask |= UI_PARENT;
        }
        let entity = self.world.spawn(mask);
        if let Some(slot) = self.world.get_ui_node_mut(entity) {
            *slot = node;
        }
        if let Some(&parent) = self.parent_stack.last() {
            if let Some(slot) = self.world.get_ui_parent_mut(entity) {
                *slot = UiParent { entity: parent };
            }
        }
        self.cursor = Some(entity);
        self
    }

    pub fn color(&mut self, color: UiColor) -> &mut Self {
        let Some(entity) = self.cursor else {
            return self;
        };
        self.world.add_components(entity, UI_COLOR);
        if let Some(slot) = self.world.get_ui_color_mut(entity) {
            *slot = color;
        }
        self
    }

    pub fn text(&mut self, text: UiText) -> &mut Self {
        let Some(entity) = self.cursor else {
            return self;
        };
        self.world.add_components(entity, UI_TEXT);
        if let Some(slot) = self.world.get_ui_text_mut(entity) {
            *slot = text;
        }
        self
    }

    pub fn interactive(&mut self) -> &mut Self {
        let Some(entity) = self.cursor else {
            return self;
        };
        self.world.add_components(entity, UI_INTERACTIVE);
        self
    }
}
```

The setter chain (`color`, `text`, `interactive`) operates on the cursor. Each setter migrates the cursor entity into the right archetype if it does not already have the component, then writes the value through the typed accessor. Adding components to an existing entity is the structural-change machinery from [part two of the ECS series](@/posts/2026-04-12-build-your-own-ecs-structural-change.md). The entity moves from `UI_NODE` to `UI_NODE | UI_COLOR` on the first `.color(...)` call, then to `UI_NODE | UI_COLOR | UI_TEXT` on the first `.text(...)`. By the time the chain ends, the entity sits in exactly the archetype its declared components imply.

This is a one-time per-entity cost paid at build time, not a per-frame cost. The runtime sees the entity in its final archetype.

A composite setter for the common case "button" collapses the four calls.

```rust
impl<'a> UiBuilder<'a> {
    pub fn button(
        &mut self,
        node: UiNode,
        fill: UiColor,
        label: &str,
        label_color: Vec4,
    ) -> &mut Self {
        self.node(node)
            .color(fill)
            .interactive()
            .text(UiText {
                content: label.to_string(),
                color: label_color,
                size: 14.0,
            })
    }
}
```

The composite is a one-liner that calls the primitives. The primitives stay available for cases the composite does not cover. The same pattern scales to `panel`, `label`, `slider`, `checkbox`, and every other widget the application wants. Each composite is a small function that calls the same four primitives in the right order.

## Building a real tree

The example from earlier collapses.

```rust
let mut world = World::default();
let mut builder = UiBuilder::new(&mut world);

let panel = builder
    .node(UiNode {
        position: Vec2::new(16.0, 16.0),
        size: Vec2::new(220.0, 80.0),
        layout: LayoutMode::Row,
        padding: 8.0,
        spacing: 8.0,
        visible: true,
        ..Default::default()
    })
    .color(UiColor {
        rgba: Vec4::new(0.10, 0.10, 0.12, 0.85),
    })
    .entity()
    .unwrap();

builder.in_parent(panel, |child| {
    child.button(
        UiNode {
            size: Vec2::new(96.0, 32.0),
            visible: true,
            ..Default::default()
        },
        UiColor {
            rgba: Vec4::new(0.18, 0.50, 0.80, 1.0),
        },
        "Pick",
        Vec4::new(1.0, 1.0, 1.0, 1.0),
    );
    child.button(
        UiNode {
            size: Vec2::new(96.0, 32.0),
            visible: true,
            ..Default::default()
        },
        UiColor {
            rgba: Vec4::new(0.50, 0.18, 0.18, 1.0),
        },
        "Cancel",
        Vec4::new(1.0, 1.0, 1.0, 1.0),
    );
});
```

Twenty-something lines for a panel with two buttons. The `in_parent` closure makes the parent scope obvious and impossible to leak. The chained setters read top to bottom. Every widget is an entity, the world holds the data, and the builder is just a writer.

The tree at this point.

```
panel (UI_NODE | UI_COLOR)
├── pick   (UI_NODE | UI_COLOR | UI_TEXT | UI_INTERACTIVE | UI_PARENT -> panel)
└── cancel (UI_NODE | UI_COLOR | UI_TEXT | UI_INTERACTIVE | UI_PARENT -> panel)
```

Inside the ECS, three entities, each in an archetype matching its component set. The two buttons share an archetype and live in the same table. The panel sits in a different table. A query for "every entity with `UI_NODE + UI_COLOR + UI_INTERACTIVE`" hits exactly the buttons. A query for "every entity with `UI_NODE`" hits all three. That is what the layout system is going to consume.

## Mutating widgets after they exist

The whole point of retained is that the application keeps handles and mutates components directly. The setters above are also the public API for runtime mutation.

```rust
fn set_status(world: &mut World, label: Entity, message: &str) {
    if let Some(text) = world.get_ui_text_mut(label) {
        text.content = message.to_string();
    }
}

fn set_visible(world: &mut World, entity: Entity, visible: bool) {
    if let Some(node) = world.get_ui_node_mut(entity) {
        node.visible = visible;
    }
}

fn set_alpha(world: &mut World, entity: Entity, alpha: f32) {
    if let Some(color) = world.get_ui_color_mut(entity) {
        color.rgba.w = alpha;
    }
}
```

Each is a free function that takes the world and an entity handle. The application writes its own helpers for the per-widget operations it does most. There is no widget API to memorize, only the typed accessors on `World` and whatever wrappers the application puts in front of them.

For widgets the application wants to mutate but does not want to thread the handle through every function, the named-entity pattern works.

```rust
#[derive(Default)]
pub struct UiRegistry {
    pub names: HashMap<&'static str, Entity>,
}

impl<'a> UiBuilder<'a> {
    pub fn named(&mut self, name: &'static str, registry: &mut UiRegistry) -> &mut Self {
        if let Some(entity) = self.cursor {
            registry.names.insert(name, entity);
        }
        self
    }
}
```

Used at build time:

```rust
builder
    .button(node, fill, "Save", text_color)
    .named("save_button", registry);
```

Used at runtime:

```rust
if let Some(&entity) = registry.names.get("save_button") {
    set_alpha(&mut world, entity, 0.4);
}
```

The registry is plain data the application owns.

## What we built

```
World  (component types registered)
├── UiNode         rect, layout, anchor, z-order, resolved rect
├── UiColor        fill RGBA
├── UiText         content, color, size
├── UiParent       link to parent entity (encodes the tree)
└── UiInteractive  hover/pressed/clicked/focused state

UiBuilder
├── world          mutable borrow of the ECS world
├── parent_stack   active parent for newly created entities
├── cursor         most recently created entity
└── methods        node, color, text, interactive, in_parent, button
```

Operations. `UiBuilder::node(node)` creates an entity. `.color(color)`, `.text(text)`, `.interactive()` chain components onto the cursor. `.in_parent(entity, |child| { ... })` opens a parent scope. `.button(...)` is the composite for the common case. Free functions like `set_status` and `set_visible` are the runtime-mutation API, plus the typed `get_*_mut` accessors freecs generates.

The tree itself is encoded entirely on the children, with `UiParent` carrying the link. The layout system will build the inverse child cache when it walks the tree next part.

## What is missing

There are no systems yet. We have built the storage and the construction API. Nothing in the world does anything per frame. The buttons cannot be hovered, cannot be clicked, and have no resolved rects. The panel is at `(16, 16)` because the author wrote it there, but the children inside have `position: (0, 0)` and no system has placed them yet.

There is no layout. Children of the panel sit on top of each other at the panel's origin until something computes their flow-driven position. Anchors do not do anything yet. The `LayoutMode::Row` on the panel is recorded and unused.

There is no hit testing. `UiInteractive` is a component the buttons carry but no system updates its flags. A click anywhere on the screen does nothing.

There is no rendering. We have not opened a wgpu surface, allocated an instance buffer, or written a shader. The ECS world is a complete UI tree as data and nothing has turned it into pixels.

Part two adds the layout and interaction systems. Walking the tree from roots, resolving anchors and flow placement, building a per-frame child cache from the parent components, hit testing with the resolved rects, updating per-entity interaction state, and emitting events. Part three writes the wgpu rendering: an instance buffer of laid-out rectangles, an SDF rect shader with rounded corners and borders, a bitmap text atlas, and the pass setup that ties it into a render graph.

## The full file

The full file is the snippets from this post assembled in order: the component structs, the `Rect` helpers, the `UiBuilder`, and the example tree at the end. Around 250 lines, depending only on `freecs` and `nalgebra_glm`. Assembled, they describe a panel with two buttons as three entities across two archetypes, the buttons sharing a table and the panel in its own. These are [nightshade](https://github.com/matthewjberger/nightshade)'s UI kernel reduced to the parts that matter for the tree, meant to be read rather than dropped in as a binary.

Nothing draws yet. Part two makes the widgets sit where the author intended and react to the mouse. Part three makes them visible.
