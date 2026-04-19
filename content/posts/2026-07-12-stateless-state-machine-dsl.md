+++
title = "A state machine DSL that visualizes itself"
tags = ["rust", "state-machine", "macros", "dsl", "stateless"]
categories = ["rust"]
excerpt = "Stateless is a proc-macro state machine library that separates the transition table from the behavior, and emits a Graphviz diagram of the machine for free."
draft = true
+++

The reason most state-machine documentation rots is that there are two artifacts to keep in sync: the code that defines the transitions, and the diagram a developer drew once in Visio that lives on a wiki page nobody updates. By the time you actually need the diagram (debugging a transition that should have happened but didn't), the diagram describes a machine that hasn't existed for six months.

[`stateless`](https://github.com/matthewjberger/stateless) is a small Rust library that fixes that by making the diagram a build artifact. You write the transition table in a proc-macro DSL. The macro emits the state and event enums and a transition function, plus a `dot()` method that returns a Graphviz DOT representation of the machine you just declared. The diagram is always current because it's generated from the same source as the code.

## The DSL

```rust
use stateless::statemachine;

statemachine! {
    transitions: {
        *Idle + Start = Running,
        Running + Stop = Idle,
        _ + Reset = Idle,
    }
}

let mut state = State::default();  // Idle (marked with *)
if let Some(new_state) = state.process_event(Event::Start) {
    state = new_state;
}
assert_eq!(state, State::Running);
```

That's the whole API at the small end. The `statemachine!` macro takes the transition table and generates:

- `enum State { Idle, Running }` with a `Default` impl pointing at the starred state
- `enum Event { Start, Stop, Reset }`
- `impl State { fn process_event(&self, event: Event) -> Option<State>; }` returning the new state if a transition exists, `None` otherwise
- `impl State { fn valid_events(&self) -> &[Event]; }` returning the events that have an effect from this state
- A `dot()` function that returns a Graphviz DOT string for visualization

## Where stateless sits

Stateless takes a specific approach: the macro is a pure transition table. Guards, side effects, and error handling live in your own code:

```rust
match state.process_event(Event::Start) {
    Some(new_state) => {
        if can_actually_start(&context) {
            state = new_state;
            on_started(&mut context);
        }
    }
    None => log::warn!("invalid transition from {:?}", state),
}
```

This is more verbose than embedding guards into the DSL. The trade-off is that the state machine's structure is decoupled from the behavior. You can read the DSL and know the state graph; you can read the surrounding code and know the behavior. Neither is fighting the other.

Other state machine libraries embed guards, actions, and side effects directly into their DSLs, which has clear advantages of its own (everything in one place). Stateless is the choice for the cases where you want the structure pulled out into a pure declaration.

## The Graphviz output

Every macro expansion includes a `dot()` function returning the DOT representation:

```rust
println!("{}", state.dot());
// digraph {
//   rankdir=LR;
//   node [shape=circle];
//   "Idle" [shape=doublecircle];
//   "Idle" -> "Running" [label="Start"];
//   "Running" -> "Idle" [label="Stop"];
//   "Idle" -> "Idle" [label="Reset"];
//   "Running" -> "Idle" [label="Reset"];
// }
```

Pipe that into `dot -Tpng` and you have a diagram of the machine. It's free because the macro already has all the information it needs to produce it.

For complex machines this matters more than it sounds. The diagram is the documentation. When the transition table changes, the diagram regenerates automatically. There's no separate Visio file getting stale.

## Wildcards and internal transitions

The `_` pattern matches any state:

```rust
statemachine! {
    transitions: {
        *Idle + Start = Running,
        Running + Stop = Idle,
        _ + Cancel = Idle,        // From any state, Cancel goes to Idle
        Running + Tick = _,       // Internal transition; no state change
    }
}
```

The `_` on the right side of `=` declares an internal transition: the event is valid in that state but doesn't change the state. This is useful for tracking "I received this event" without semantic state movement.

The `valid_events()` method takes wildcards into account. For each state, it computes the union of explicitly listed events plus any wildcard events.

## Optional naming

By default the generated types are `State` and `Event`. For multiple state machines in the same module:

```rust
statemachine! {
    name: TrafficLight,
    transitions: {
        *Red + Tick = Green,
        Green + Tick = Yellow,
        Yellow + Tick = Red,
    }
}
// Generates: TrafficLightState, TrafficLightEvent
```

You can also override the derive set if you need extra traits:

```rust
statemachine! {
    derive_states: [Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize],
    transitions: { /* ... */ }
}
```

## When stateless fits

State machines are everywhere: UI flow control, network protocol handlers, parser modes, animation systems. Anywhere there's a finite set of states and event-driven transitions. Stateless fits when the graph is small enough to read at a glance, when keeping structure separate from behavior is worth the extra glue code, and when writing side effects in normal Rust beats learning another DSL.

It doesn't fit when you need hierarchical or nested state machines (statecharts), when guards and actions need to live inside the transition table itself for some structural reason, or when transitions need to be modifiable at runtime. There are larger libraries that handle those cases.

## The implementation

The macro is in [`src/lib.rs`](https://github.com/matthewjberger/stateless/blob/main/src/lib.rs). The interesting piece is wildcard expansion: when you write `_ + Reset = Idle`, the macro has to expand that to a transition for every named state. That expansion happens after the named states are collected, so it sees the full state set and can avoid generating duplicates. Tests in [`tests/state_machine_dsl.rs`](https://github.com/matthewjberger/stateless/blob/main/tests/state_machine_dsl.rs); working examples (a hierarchical robot controller, a media player, a turn-based game flow) in [`examples/`](https://github.com/matthewjberger/stateless/tree/main/examples).
