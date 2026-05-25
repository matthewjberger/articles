+++
title = "Breakout as plain data (part 2), power-ups as data"
tags = ["rust", "ecs", "game-design", "data-oriented", "tutorial"]
categories = ["rust"]
excerpt = "Multi-ball, a widening paddle, slow motion, burning bricks, lasers. Every power-up is the same move: a bit more data plus one small system, and nothing already written changes."
series = "breakout"
series_part = 2
series_title = "Breakout as plain data"
+++

*This is part 2 of 2 of a series.* ← [Components, systems, resources](@/posts/2026-05-17-breakout-as-plain-data-components-systems-resources.md)

[Part 1](@/posts/2026-05-17-breakout-as-plain-data-components-systems-resources.md) built Breakout with no objects. Bodies were masks over shared data, behavior was free functions over queries, and the globals lived in resources. The bricks-and-paddle taxonomy was clean, so the design was not really tested.

Power-ups test it. A multi-ball drop spawns more balls. A wide-paddle pickup changes the paddle for a few seconds and then changes it back. Slow motion alters how time passes for everything. Some bricks catch fire and burn their neighbors. A laser power-up lets the paddle shoot. Each one cuts across the categories at every angle. Here each is the same small move, and the move never disturbs what already works.

There turn out to be three places a power-up can put its data, and the right one depends on what the power-up actually changes. This post walks all three.

## A power-up is a falling entity

Before a power-up does anything, it is a thing falling down the screen waiting to be caught. So it is an entity, with the components that describe a falling, spinning, catchable box:

```rust
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerupKind {
    #[default]
    MultiBall,
    WidePaddle,
    Shield,
    SlowMo,
    Laser,
}

#[derive(Default, Clone, Copy, Debug)]
pub struct Pickup {
    pub kind: PowerupKind,
    pub label: Entity,
}
```

`PowerupKind` is the only thing distinguishing one pickup from another while it falls. They all fall the same way, spin the same way, and are caught the same way. A pickup is spawned with the motion components from part 1 plus a `Pickup` and a downward velocity:

```rust
let entity = game_world.spawn_entities(
    POSITION | VELOCITY | SPIN | TINT | HALF_EXTENTS | PICKUP,
    1,
)[0];
game_world.set_velocity(entity, Velocity { value: vec2(0.0, -POWERUP_FALL_SPEED) });
game_world.set_spin(entity, Spin { angle: 0.0, speed: POWERUP_SPIN_SPEED });
game_world.set_pickup(entity, Pickup { kind, label });
```

It falls because it has a `Velocity` and the motion system moves things with velocity. It spins because it has a `Spin` and a system advances spin angles. Neither of those systems knows what a power-up is. The pickup got falling and spinning for free, by carrying the components those systems already look for.

Catching it is one more system. It queries the pickups, tests each against the paddle with an axis-aligned overlap, and on a hit despawns the pickup and applies its effect:

```rust
game_world
    .query()
    .with(PICKUP | POSITION | HALF_EXTENTS)
    .iter(|entity, table, index| {
        let position = table.position[index].value;
        let half = table.half_extents[index].value;
        let overlap = (position.x - paddle_position.x).abs() <= paddle_half.x + half.x
            && (position.y - paddle_position.y).abs() <= paddle_half.y + half.y;
        if overlap {
            caught.push(Caught { game_entity: entity, kind: table.pickup[index].kind, position });
        } else if position.y < -half_height {
            missed.push(entity);
        }
    });

for catch in caught {
    game_world.despawn_entities(&[catch.game_entity]);
    apply_powerup(game_world, world, catch.kind, catch.position);
}
```

`apply_powerup` is the one place that fans out by kind. Everything before it is generic. Everything after it depends on what the power-up does, and that is where the three storage choices appear.

## Choice one: a flag with a timer, in a resource

Most power-ups change a global condition for a while. Slow motion makes everything move slower. A wide paddle is wider until it is not. The laser arms the paddle for a few seconds. None of these belongs to a single entity, so they live in a resource, a duration counting down:

```rust
#[derive(Default, Clone, Copy)]
pub struct Effects {
    pub wide_remaining: f32,
    pub laser_remaining: f32,
}

#[derive(Default, Clone, Copy)]
pub struct TimeWarp {
    pub remaining: f32,
}
```

Applying one of these is setting a field, and sometimes an immediate change to go with it:

```rust
fn apply_powerup(game_world: &mut GameWorld, world: &mut World, kind: PowerupKind, position: Vec2) {
    match kind {
        PowerupKind::WidePaddle => {
            game_world.resources.effects.wide_remaining = POWERUP_WIDE_DURATION;
            set_paddle_width(game_world, PADDLE_WIDE_HALF_WIDTH);
        }
        PowerupKind::SlowMo => {
            game_world.resources.time_warp.remaining = POWERUP_SLOWMO_DURATION;
        }
        PowerupKind::Laser => {
            game_world.resources.effects.laser_remaining = POWERUP_LASER_DURATION;
        }
        // ...
    }
}
```

The timer is ticked by a small system, which reverts the change when it hits zero:

```rust
fn update_wide_timer(game_world: &mut GameWorld, world: &mut World) {
    let remaining = game_world.resources.effects.wide_remaining;
    if remaining <= 0.0 {
        return;
    }
    let next = remaining - world.resources.window.timing.delta_time;
    game_world.resources.effects.wide_remaining = next.max(0.0);
    if next <= 0.0 {
        set_paddle_width(game_world, PADDLE_HALF_WIDTH);
    }
}
```

The wide paddle never became a new kind of paddle. It is the same paddle entity from part 1 with its `HalfExtents.x` written wider, plus a number in a resource that says when to write it back. `set_paddle_width` reaches the paddle through the same handle the input system uses:

```rust
fn set_paddle_width(game_world: &mut GameWorld, half_width: f32) {
    let paddle = game_world.resources.bodies.paddle;
    if let Some(half_extents) = game_world.get_half_extents_mut(paddle) {
        half_extents.value.x = half_width;
    }
}
```

Slow motion is the clearest case of a global flag doing real work without anyone reaching for it. The simulation systems already compute a `scaled_delta`, and the scale is one read of the resource:

```rust
let scale = if game_world.resources.time_warp.remaining > 0.0 {
    SLOWMO_SCALE
} else {
    1.0
};
let scaled_delta = delta_time * scale;
```

That is the entire mechanism. The slow-motion power-up sets `time_warp.remaining`, a tick system counts it down, and every system that integrates motion reads the flag and scales its step. The power-up "changes how time passes for the whole game" without a single object knowing it has been slowed. It is a global condition, so it is a global, read where it matters.

`laser_remaining` works the same way with a different reader. A laser system checks the flag each frame, and while it is positive a fire button spawns laser shots. That is where this choice hands off to the next one: the flag is the global condition, and the shots it produces are entities.

## Choice two: spawn more entities

Some power-ups are not a condition at all. Multi-ball does not change a flag, it makes balls. So its `apply_powerup` arm spawns them, reusing the `spawn_ball` from part 1:

```rust
fn spawn_extra_balls(game_world: &mut GameWorld, world: &mut World) {
    let mut source: Option<(Vec2, Vec2)> = None;
    game_world
        .query()
        .with(RADIUS | POSITION | VELOCITY)
        .iter(|_, table, index| {
            if source.is_none() {
                source = Some((table.position[index].value, table.velocity[index].value));
            }
        });

    let (position, base_velocity) = match source {
        Some(values) => values,
        None => return,
    };
    let speed = base_velocity.magnitude().max(ball_speed(game_world.resources.field.half_width));
    let base_angle = base_velocity.y.atan2(base_velocity.x);

    for index in 0..MULTIBALL_EXTRA {
        let sign = if index % 2 == 0 { 1.0 } else { -1.0 };
        let spread = (index as f32 / 2.0 + 1.0) * 0.4 * sign;
        let angle = base_angle + spread;
        let velocity = vec2(angle.cos() * speed, angle.sin() * speed);
        setup::spawn_ball(game_world, world, position, velocity, BALL_COLOR);
    }
}
```

The new balls are not special balls. They have exactly the components a ball has, so the motion system moves them, the collision system bounces them, and the rules system from part 1 already handles "lives lost only when every ball is gone," because it counts entities with a `RADIUS`. Multi-ball needed zero changes to any existing system. It added entities the existing systems already knew how to drive.

The shield and the laser shots work the same way. A shield is a solid body spawned near the bottom of the field, which means the collision system bounces balls off it with no new code. A laser shot is an entity with a `Velocity` and a `Laser` marker, moved by motion and checked against bricks by a small laser system. New entities, old systems.

## Choice three: add components to an entity that already exists

The third place data can go is onto an entity that is already in the world. Bricks are the example. Most bricks are the plain `SOLID | BREAKABLE` boxes from part 1. But some bricks should drop a power-up when destroyed, and some should catch fire. Those are extra, independent traits on a brick, and here they are two more markers added at spawn time:

```rust
#[derive(Default, Clone, Copy, Debug)]
pub struct Burns;

#[derive(Default, Clone, Copy, Debug)]
pub struct Reward {
    pub kind: PowerupKind,
    pub label: Entity,
}
```

When the level is built, each brick rolls the dice and may gain one or both:

```rust
let brick = spawn_rectangle(game_world, center, half, color, SOLID | BREAKABLE);
if game_world.resources.rng.unit() < BURNABLE_CHANCE {
    game_world.add_components(brick, BURNS);
}
if game_world.resources.rng.unit() < REWARD_CHANCE {
    let kind = random_kind(game_world);
    game_world.add_components(brick, REWARD);
    game_world.set_reward(brick, Reward { kind, label });
}
```

`add_components` migrates the entity to the archetype that includes the new marker. (The [structural-change post](@/posts/2026-04-12-build-your-own-ecs-structural-change.md) covers what that migration costs and why it is a move between tables rather than an in-place edit.) After it runs, a burning-capable brick that drops a power-up has the mask `SOLID | BREAKABLE | BURNS | REWARD`, and that mask is a complete description of everything it does. It is still just a brick, carrying more components.

The collision system reads these the same way it read `BREAKABLE` and `PLAYER_CONTROLLED` in part 1, straight off the mask, and decides what to emit:

```rust
let reward = if table.mask & REWARD != 0 {
    Some((table.reward[index].kind, table.reward[index].label))
} else {
    None
};
solids.push(SolidBody {
    // ...
    breakable: table.mask & BREAKABLE != 0,
    burns: table.mask & BURNS != 0,
    reward,
});
```

When a brick with `REWARD` breaks, the break code spawns the pickup falling from the brick's position. When a brick with `BURNS` breaks, it emits a `BrickBurned` event that ignites neighbors. A brick without those markers does neither, and the branch is a flag test, not a type check.

## The generic systems that make this work

The reason a falling power-up "just falls" is that the systems for motion, spin, and lifetime do not select balls or pickups by name. They select by component, so anything carrying the right components is swept along.

Balls are integrated inside the collision substep from part 1, so everything else that moves needs its own pass. That pass is a sibling of `motion::integrate`: same idea, opposite filter. Where the ball loop matched `RADIUS | VELOCITY | POSITION`, this one takes everything with a position and velocity that is *not* a ball, and applies the slow-motion scale on the way:

```rust
game_world
    .query_mut()
    .with(POSITION | VELOCITY)
    .without(RADIUS)
    .iter(|_, table, index| {
        let step = table.velocity[index].value * scaled_delta;
        table.position[index].value += step;
    });

game_world.query_mut().with(SPIN).iter(|_, table, index| {
    table.spin[index].angle += table.spin[index].speed * scaled_delta;
});
```

`without(RADIUS)` is the whole distinction between "a ball, handled by collision" and "everything else that moves," and it is a mask exclusion, not a class. The spin pass does not even ask what it is spinning. If it has a `Spin`, its angle advances.

Lifetime is the cleanup counterpart. Laser shots, particle bursts, and floating score labels should disappear after a while, so they carry a `Lifetime { remaining }`, and one system counts it down and despawns whatever hits zero:

```rust
#[derive(Default, Clone, Copy, Debug)]
pub struct Lifetime {
    pub remaining: f32,
}
```

Anything that wants to live for a fixed time gets a `Lifetime` and is then forgotten by its spawner. The lifetime system is the only code that ever needs to think about it again, and it thinks about all of them at once, regardless of what they are.

## Adding a power-up is addition

Walk through what a brand-new power-up costs. Say a "sticky paddle" that catches the ball instead of bouncing it.

Add a `StickyPaddle` variant to `PowerupKind`. Add an arm to `apply_powerup` that sets a `sticky_remaining` timer in `Effects`. Add a tick system that counts it down, the twin of `update_wide_timer`. Read the flag in the one spot in collision where the paddle bounce happens, and when it is set, zero the velocity and pin the ball to the paddle instead of reflecting. Done.

What did not happen matters as much as what did. No existing system was rewritten. The collision system gained a single branch behind a flag it already read. New behavior came out to some data, one small function, and one conditional, the same shape every power-up in this post took, whether the data lived in a resource, in spawned entities, or in components added to a brick.

That is what the clean base game in part 1 could not demonstrate by itself. Modeling a game this way does not make the base shorter; it keeps each later feature an addition instead of a rewrite of decisions fixed before you knew what the game needed.

If you want to see the storage that all of this sits on, built from nothing, the [Build your own ECS](@/posts/2026-04-07-build-your-own-ecs-archetype-storage.md) series is the companion to this one: that series builds the kernel, this one uses it to make a game.
