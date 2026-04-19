+++
title = "Five ways a Rust enum should never have been hand-written"
tags = ["rust", "macros", "derive", "enum2", "no_std"]
categories = ["rust"]
excerpt = "A Rust enum is a finite set of typed variants. Most of the work around them is mechanical conversion to other representations. Each conversion deserves a derive macro."
draft = true
+++

A Rust enum is a finite set of typed variants. Almost everything you write around an enum is a conversion to or from some other representation: an integer code over the wire, a string for display, a topic for a message bus, a UI control, an array index. Each conversion is mechanical. Each one is exactly the kind of code humans shouldn't be typing.

I have written each of these by hand more times than I'd like to admit. So I derived them.

## enum2repr: numeric codes

The case: a network protocol where opcodes arrive as `u8` and need to become typed enum values. You write a `TryFrom<u8>` impl. You write the inverse `From<MyEnum> for u8`. You change the enum, you update both impls. Repeat per protocol.

```rust
#[derive(EnumRepr)]
#[repr(u8)]
enum Color { Red = 1, Green = 2, Blue = 3 }

let c: Color = 2_u8.try_into().unwrap();
assert_eq!(c, Color::Green);
```

The macro reads the `#[repr(T)]` attribute and generates both directions. Supports the full set of integer types: `u8` through `u128`, `i8` through `i128`, `usize`, and `isize`.

## enum2str: Display impls

The case: an enum where you want pretty-printed names for logging, plus a few variants that should print differently from their identifier.

```rust
#[derive(EnumStr)]
enum Direction {
    North,
    South,
    #[enum2str("left")]
    West,
    #[enum2str("right")]
    East,
}
```

Default uses the variant name. The attribute overrides per variant. A `FromStr` impl rounds-trips for free. The point isn't to be clever; it's to delete the `match self { Variant => "Variant", ... }` arm you've written a hundred times.

## enum2contract: pub/sub message contracts

The case: producer and consumer tasks agreeing on a typed message bus. Both sides need to know the topic format and the payload schema. Hand-writing means manual sync between two pieces of code.

```rust
#[derive(EnumContract, Serialize, Deserialize)]
enum Telemetry {
    #[topic("sensor/{id}/temperature")]
    Temperature { id: u32, celsius: f32 },
    #[topic("sensor/{id}/humidity")]
    Humidity { id: u32, percent: f32 },
}

let msg = Telemetry::Temperature { id: 7, celsius: 22.5 };
let topic = msg.topic();      // "sensor/7/temperature"
let payload = msg.payload();   // serialized body
```

The topic template embeds variant fields. JSON and binary serialization come along. Producer and consumer import the same enum, and the contract can't drift because both sides are generated from one declaration. `no_std` compatible, which matters for embedded use.

## enum2egui: UI databindings

The case: a struct that represents some internal state, and you want a debug or tooling UI that lets you inspect and edit it. You'd write the egui code by hand for every field, every nested struct, every collection.

```rust
#[derive(Default, Gui)]
struct PlayerStats {
    name: String,
    level: u32,
    health: f32,
    inventory: Vec<String>,
}

ui.gui(&mut stats);  // Done.
```

The macro walks the type. Strings get text inputs, numbers get drag-values, vectors get add/remove controls, enums get dropdowns, nested structs recurse. The whole point of an internal tooling UI vanishes as a chore.

## enum2pos: index lookup

The case: an enum that needs to round-trip through a position-based representation. A tab number in a UI, an index into a parallel array, a position in a sequence.

```rust
#[derive(EnumPos)]
enum Suit { Clubs, Diamonds, Hearts, Spades }

assert_eq!(Suit::Hearts.to_index(), 2);
```

`to_index()` and `from_index()`. That's the whole derive.

## The pattern

Five different conversions, one underlying shape: an enum represents a finite set of values, and there's some other representation you need to map to or from. The mapping is regular. Writing it by hand is a thing you do once and resent every time you change the enum.

Each derive macro is small. None of them is doing anything individually impressive. Together they remove an entire class of boilerplate from the kind of Rust code I write most.

If you find yourself writing one of these conversions by hand more than twice, derive it.
