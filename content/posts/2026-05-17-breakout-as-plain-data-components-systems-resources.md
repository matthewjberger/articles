+++
title = "Breakout as plain data (part 1), components, systems, resources"
tags = ["rust", "ecs", "game-design", "data-oriented", "tutorial"]
categories = ["rust"]
excerpt = "A whole Breakout, modeled with no objects. Bodies are plain data structs, behavior is free functions over queries, and the game's globals are a handful of resources. Part 1 builds the base game."
series = "breakout"
series_part = 1
series_title = "Breakout as plain data"
+++

*This is part 1 of 2 of a series.* Next → [Power-ups as data](@/posts/2026-05-22-breakout-as-plain-data-power-ups.md)

There is no `GameObject` in this Breakout. The ball does not own an `update()`. A brick is not a subclass of anything. The paddle has no methods. What exists instead is data, functions that read and write that data, and a small set of globals. A thing in the game is nothing more than the set of components attached to its entity, and what a thing *does* is decided by which systems happen to match it.

That is the ECS shape, applied to a game small enough to hold in your head all at once. This post models the base game: the field, the paddle, the bricks, the ball, the bounce, and the win and loss conditions. [Part 2](@/posts/2026-05-22-breakout-as-plain-data-power-ups.md) adds the power-ups, which is where modeling by data instead of by class hierarchy actually pays for itself.

The code here is real, lifted from `breakr`, a Breakout built on [nightshade](https://github.com/matthewjberger/nightshade). It uses [freecs](https://github.com/matthewjberger/freecs) for the ECS, which is the same kernel the [Build your own ECS](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md) series builds by hand. None of the modeling depends on those choices. The components are plain structs, the systems are plain functions, and you could carry the whole design to bevy, to hecs, or to an ECS you wrote yourself, with a different renderer underneath. Rendering is left out on purpose. nightshade draws these entities one way; your engine will draw them another. The game logic never names a draw call.

## Why not objects

The object-oriented reflex is a `GameObject` base class with a `position` and a virtual `update()`, subclassed into `Ball`, `Paddle`, `Brick`, and `Wall`. It models Breakout as a taxonomy, and the taxonomy is the problem. A wall and a brick are both solid boxes, but a brick breaks and a wall does not. The paddle is a solid box too, except it moves and bends the bounce. By the time part 2 adds a brick that catches fire and a brick that drops a power-up, the differences are orthogonal traits bolted onto "brick," and inheritance only models one axis at a time. The [ECS series](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md) makes the general version of this argument; this post is the concrete one.

The data-oriented answer is to stop asking "what kind of thing is this" and start asking "what data does this thing have." A wall has a position, a size, a color, and a marker that says it is solid. A brick has all of that plus a marker that says it is breakable. A ball has a position, a velocity, and a radius. The thing *is* its components. Behavior is not attached to the thing at all. It lives in functions that select entities by the components they carry.

## Components are data, and only data

Here is the entire vocabulary of the base game. Every one is a plain struct with public fields and no methods.

```rust
#[derive(Default, Clone, Copy, Debug)]
pub struct Position {
    pub value: Vec2,
}

#[derive(Default, Clone, Copy, Debug)]
pub struct Velocity {
    pub value: Vec2,
}

#[derive(Default, Clone, Copy, Debug)]
pub struct HalfExtents {
    pub value: Vec2,
}

#[derive(Default, Clone, Copy, Debug)]
pub struct Radius {
    pub value: f32,
}

#[derive(Default, Clone, Copy, Debug)]
pub struct Tint {
    pub color: [f32; 4],
    pub dirty: bool,
}
```

`Position` and `Velocity` are the obvious ones. `HalfExtents` is the half-width and half-height of a box, which is the natural form for an axis-aligned box collision test. `Radius` is for the ball, which is a circle. `Tint` carries a color and a `dirty` flag the rendering side reads to know when the color changed, which is the one concession to "there is a renderer somewhere," and even that is just data.

Then there are markers, components with no fields:

```rust
#[derive(Default, Clone, Copy, Debug)]
pub struct PlayerControlled;

#[derive(Default, Clone, Copy, Debug)]
pub struct Solid;

#[derive(Default, Clone, Copy, Debug)]
pub struct Breakable;
```

A marker carries no data. Its presence on an entity is the data. `Solid` means "a ball bounces off this." `Breakable` means "destroy this when a ball hits it." `PlayerControlled` means "the input system moves this." A system asks whether an entity has a marker the same way it asks whether the entity has a `Position`.

Nothing here knows how to move, bounce, or break. These structs are inert. That is the point.

## The world declares the set up front

An entity is a handle, a small id, with no data of its own. The world stores the components, grouped by which set of components an entity has, with each component type kept in its own contiguous column. The [first post in the ECS series](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md) explains why that layout is fast and how it is built. For this game, the relevant part is the declaration. freecs takes the full component set as a macro and generates the storage and the typed accessors:

```rust
freecs::ecs! {
    GameWorld {
        position: Position => POSITION,
        velocity: Velocity => VELOCITY,
        half_extents: HalfExtents => HALF_EXTENTS,
        radius: Radius => RADIUS,
        tint: Tint => TINT,
        player_controlled: PlayerControlled => PLAYER_CONTROLLED,
        solid: Solid => SOLID,
        breakable: Breakable => BREAKABLE,
    }
    Resources {
        game: GameState,
        events: GameEvents,
        bodies: Bodies,
        rng: Rng,
        field: Field,
    }
}
```

Each line names a field, its type, and a bitmask constant. `POSITION`, `SOLID`, and the rest are single-bit flags. The set of components an entity has is the bitwise OR of those flags, and that combined mask is, in effect, the entity's type. A query for "everything solid with a position and a size" is a mask test, not a class check.

In a real engine there is one more component on these entities, a handle linking the game entity to whatever the renderer spawned for it. In `breakr` that is an `EngineEntity` bridging into nightshade. It is plumbing, not game design, so it is left out here. The game logic never reads it.

## The mask is the type

This is the center of the whole design. Walls, the paddle, and bricks are all the same data, a position, a size, and a color, and they differ only in which markers they carry. One spawn helper builds all of them:

```rust
fn spawn_rectangle(
    game_world: &mut GameWorld,
    center: Vec2,
    half_extents: Vec2,
    color: [f32; 4],
    role_mask: u64,
) -> Entity {
    let entity = game_world.spawn_entities(
        POSITION | HALF_EXTENTS | TINT | role_mask,
        1,
    )[0];
    game_world.set_position(entity, Position { value: center });
    game_world.set_half_extents(entity, HalfExtents { value: half_extents });
    game_world.set_tint(entity, Tint { color, dirty: true });
    entity
}
```

The `role_mask` argument is the entire difference between a wall, a brick, and a paddle. Each caller passes a different set of markers:

```rust
// a wall: solid, nothing else
spawn_rectangle(game_world, center, vertical_half, WALL_COLOR, SOLID);

// a brick: solid and breakable
spawn_rectangle(game_world, center, brick_half, color, SOLID | BREAKABLE);

// the paddle: solid and player-controlled
let paddle = spawn_rectangle(
    game_world,
    vec2(0.0, paddle_y),
    vec2(PADDLE_HALF_WIDTH, PADDLE_HALF_HEIGHT),
    PADDLE_COLOR,
    SOLID | PLAYER_CONTROLLED,
);
```

| Body   | Mask                              | What it means                              |
|--------|-----------------------------------|--------------------------------------------|
| Wall   | `SOLID`                           | the ball bounces, nothing else happens     |
| Brick  | `SOLID \| BREAKABLE`              | the ball bounces and the brick is destroyed |
| Paddle | `SOLID \| PLAYER_CONTROLLED`      | the ball bounces and input moves it        |

There is no `Wall` type, no `Brick` type, no `Paddle` type. There is `spawn_rectangle` and a mask. Adding a kind of body later, a bumper that adds score without breaking, an indestructible steel brick, is a new combination of existing markers (plus maybe one new marker), not a new branch in a hierarchy.

The ball is the one body that is genuinely different data, a circle that moves, so it gets its own helper and its own mask:

```rust
pub fn spawn_ball(
    game_world: &mut GameWorld,
    center: Vec2,
    velocity: Vec2,
    color: [f32; 4],
) -> Entity {
    let entity = game_world.spawn_entities(
        POSITION | VELOCITY | RADIUS | TINT,
        1,
    )[0];
    game_world.set_position(entity, Position { value: center });
    game_world.set_velocity(entity, Velocity { value: velocity });
    game_world.set_radius(entity, Radius { value: BALL_RADIUS });
    game_world.set_tint(entity, Tint { color, dirty: true });
    entity
}
```

A ball has `VELOCITY` and `RADIUS` and lacks `SOLID`. A brick has `SOLID` and lacks `VELOCITY`. The collision system tells them apart by exactly that.

The level itself is a loop over a grid, spawning a brick wherever the layout says one should be:

```rust
for row in 0..rows {
    let center_y = top_center_y - row as f32 * row_step;
    let color = brick_row_color(row);
    for column in 0..columns {
        if !brick_present(level, row, column, rows, columns) {
            continue;
        }
        let center_x = first_center_x + column as f32 * (brick_width + BRICK_GAP);
        spawn_rectangle(
            game_world,
            vec2(center_x, center_y),
            vec2(brick_half_width, BRICK_HALF_HEIGHT),
            color,
            SOLID | BREAKABLE,
        );
    }
}
```

## Systems are functions over queries

A system is a free function. It takes the world, asks for the entities matching a set of components, and reads or writes their data. It does not live on any entity, and entities do not call it.

The simplest one moves everything that has a velocity and a radius, which is to say the balls:

```rust
pub fn integrate(game_world: &mut GameWorld, delta_time: f32) {
    game_world
        .query_mut()
        .with(RADIUS | VELOCITY | POSITION)
        .iter(|_, table, index| {
            let step = table.velocity[index].value * delta_time;
            table.position[index].value += step;
        });
}
```

That is the whole motion system. `query_mut().with(...)` selects the matching archetypes, and `iter` walks them, handing each call a column-major `table` and the row `index` of the current entity. `table.position[index]` is a direct array access, not a hash lookup, because the storage groups entities by mask and lays each component out as a packed column.

Motion runs inside a fixed substep loop, so a fast ball cannot tunnel through a thin brick in one frame:

```rust
pub fn step(game_world: &mut GameWorld, world: &mut World) {
    if game_world.resources.game.phase != Phase::Playing {
        return;
    }

    let delta_time = world.resources.window.timing.delta_time;
    let travel = ball_speed(game_world.resources.field.half_width) * delta_time;
    let substeps = (travel / COLLISION_SUBSTEP).ceil().max(1.0) as u32;
    let sub_delta = delta_time / substeps as f32;

    for _ in 0..substeps {
        motion::integrate(game_world, sub_delta);
        collision::resolve(game_world, world);
    }
}
```

`delta_time` is read straight from the frame timing here. That is the one line part 2 will change: the slow-motion power-up multiplies it by a time scale before it is divided into substeps, and nothing else in this function has to know.

Collision is the longest system in the base game, but its shape is simple. Gather the balls. Gather the solid bodies. For each ball, bounce it off the field walls, then find the deepest box it overlaps and respond to that. The gather step is two queries:

```rust
let mut balls: Vec<BallState> = Vec::new();
game_world
    .query()
    .with(RADIUS | VELOCITY | POSITION)
    .iter(|entity, table, index| {
        balls.push(BallState {
            game_entity: entity,
            position: table.position[index].value,
            velocity: table.velocity[index].value,
            radius: table.radius[index].value,
        });
    });

let mut solids: Vec<SolidBody> = Vec::new();
game_world
    .query()
    .with(SOLID | POSITION | HALF_EXTENTS)
    .iter(|entity, table, index| {
        solids.push(SolidBody {
            game_entity: entity,
            center: table.position[index].value,
            half_extents: table.half_extents[index].value,
            breakable: table.mask & BREAKABLE != 0,
            paddle: table.mask & PLAYER_CONTROLLED != 0,
        });
    });
```

Notice the last two fields. The collision response needs to know whether a body is breakable and whether it is the paddle, and it reads both straight off the mask with `table.mask & BREAKABLE`. The markers carry the branch.

The response is the standard circle-versus-box test. Clamp the ball center to the box to find the closest point, and if it is within the radius, reflect the velocity across the surface normal. The paddle is the one body that bends the bounce instead of mirroring it, so where the ball lands on the paddle steers where it goes, and the branch is the `paddle` flag pulled off the mask a moment ago:

```rust
if body.paddle {
    let offset = ((position.x - body.center.x) / body.half_extents.x).clamp(-1.0, 1.0);
    let angle = offset * MAX_BOUNCE_ANGLE;
    let speed = velocity.magnitude().max(ball_speed(half_width));
    velocity = vec2(speed * angle.sin(), speed * angle.cos());
} else {
    if body.breakable {
        breaks.push(body.game_entity);
    }
    let normal = surface_normal(position, body.center, body.half_extents, radius);
    let normal_speed = velocity.dot(&normal);
    if normal_speed < 0.0 {
        velocity -= normal * (2.0 * normal_speed);
    }
}
```

A breakable body gets pushed onto a list to destroy after the loop, because mutating the world while iterating it is how you get bugs. The destroy happens afterward, and each broken brick leaves behind an event, which the next section covers.

Input is its own system. It reads the keyboard, computes a direction, and writes the paddle's position, clamped to the field:

```rust
pub fn update(game_world: &mut GameWorld, world: &mut World) {
    let delta_time = world.resources.window.timing.delta_time;
    let keyboard = &world.resources.input.keyboard;
    let move_left = keyboard.is_key_pressed(KeyCode::ArrowLeft);
    let move_right = keyboard.is_key_pressed(KeyCode::ArrowRight);

    let direction = (move_right as i32 - move_left as i32) as f32;
    let half_width = game_world.resources.field.half_width;
    let paddle = game_world.resources.bodies.paddle;

    let Some(half_extents) = game_world.get_half_extents(paddle) else {
        return;
    };
    let limit = half_width - half_extents.value.x;
    if let Some(position) = game_world.get_position_mut(paddle) {
        let next = position.value.x + direction * PADDLE_SPEED * delta_time;
        position.value.x = next.clamp(-limit, limit);
    }
}
```

The input system does not know what a paddle is. It knows there is one entity recorded in a resource, and that entity has a `Position` it is allowed to write. The thing being moved is identified by a handle in a global, not by a type.

## Resources are the globals

Some state does not belong to any single entity. The score is not a property of a brick. The current phase of the game, serving, playing, won, lost, is not a property of the ball. Those live in resources, which are plain structs the world owns one of each.

```rust
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    #[default]
    Serving,
    Playing,
    Won,
    Lost,
}

pub struct GameState {
    pub score: u32,
    pub lives: u32,
    pub level: u32,
    pub phase: Phase,
    pub bricks_remaining: u32,
    pub level_transition: f32,
}
```

`Field` holds the play area bounds the collision and input systems clamp against. `Bodies` holds the one handle the input system needs, the paddle. `Rng` is a small deterministic generator, which part 2 leans on for power-up drops.

```rust
pub struct Field {
    pub half_width: f32,
    pub half_height: f32,
}

pub struct Bodies {
    pub paddle: Entity,
}
```

A resource is just data with a single owner, the same way a component is just data with one per entity. Systems read and write resources directly, `game_world.resources.game.score += BRICK_ROW_SCORE`. There is no manager object, no singleton with methods. The frame loop calls the systems in order, and the order is the schedule:

```rust
if self.game_world.resources.screen == Screen::Playing {
    input::update(&mut self.game_world, world);
    simulate::step(&mut self.game_world, world);
    rules::apply(&mut self.game_world, world);
}
```

Read top to bottom, that is the game: take input, move and collide, then apply the consequences.

## Systems talk through an event queue

Collision detects that a brick was hit, but collision should not be the place that adds to the score, decrements lives, or decides the level is cleared. Those are different concerns that run later. The decoupling is an event queue, one more resource:

```rust
#[derive(Clone, Copy, Debug)]
pub enum GameEvent {
    BrickCleared { position: Vec2, color: [f32; 4] },
    BallLost { position: Vec2 },
    PaddleHit { position: Vec2 },
}

#[derive(Default)]
pub struct GameEvents {
    pub pending: Vec<GameEvent>,
}
```

When collision breaks a brick or a ball falls past the bottom, it pushes an event and moves on. The `rules` system drains the queue and reacts:

```rust
pub fn apply(game_world: &mut GameWorld, world: &mut World) {
    let events = std::mem::take(&mut game_world.resources.events.pending);
    let mut ball_lost = false;
    for event in events {
        match event {
            GameEvent::BrickCleared { .. } => {
                game_world.resources.game.score += BRICK_ROW_SCORE;
                game_world.resources.game.bricks_remaining =
                    game_world.resources.game.bricks_remaining.saturating_sub(1);
            }
            GameEvent::BallLost { .. } => ball_lost = true,
            GameEvent::PaddleHit { .. } => {}
        }
    }

    if game_world.resources.game.bricks_remaining == 0
        && game_world.resources.game.phase == Phase::Playing
    {
        game_world.resources.game.phase = Phase::Won;
        return;
    }

    if ball_lost && game_world.query_entities(RADIUS).count() == 0 {
        let remaining = game_world.resources.game.lives.saturating_sub(1);
        game_world.resources.game.lives = remaining;
        game_world.resources.game.phase =
            if remaining == 0 { Phase::Lost } else { Phase::Serving };
    }
}
```

The win check is a query. `bricks_remaining == 0` says the field is clear. The loss check is also a query, `query_entities(RADIUS).count() == 0`, every ball is gone. Game state is read off the world, not tracked in a tangle of callbacks. Collision never imports `rules`, and `rules` never imports `collision`. They share a queue and a frame order, nothing else.

## What part 1 leaves you

A complete game, modeled without a single class hierarchy. Bodies are masks over shared data. Behavior is six or seven functions that select entities by component and read or write their fields. The globals, score, lives, phase, the play field, sit in resources. Systems coordinate through an event queue rather than through references to one another.

The design has not yet been stressed. Breakout's bricks and paddle are a clean taxonomy, the kind of problem inheritance handles fine on a good day. [Part 2](@/posts/2026-05-22-breakout-as-plain-data-power-ups.md) adds power-ups, a multi-ball drop, a paddle that widens for a while, a slow-motion field, bricks that catch fire, lasers. Each one cuts across the neat categories, and each one turns out to be the same move: a little more data, one more small system, and nothing already written has to change.
