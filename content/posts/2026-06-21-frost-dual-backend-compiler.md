+++
title = "A small language with two backends: bytecode for development, Cranelift for production"
tags = ["rust", "compiler", "cranelift", "language-design", "frost"]
categories = ["rust"]
excerpt = "Frost is a hobby language with two compilation paths from one IR. A bytecode VM for development friction, a Cranelift backend for production output."
draft = true
+++

A small language without an established library ecosystem has a chicken-and-egg problem with toolchains. The kind of person who tries an unfamiliar language wants to install one binary, write `hello world`, and see output. They do not want to install a system linker, set up `cc`, debug a missing C runtime, and watch their first program fail to link. But if you only ship the easy path, no one can ship anything serious built with the language.

[`frost`](https://github.com/matthewjberger/frost), my hobby language in Rust, takes both paths. The same source compiles to a typed IR. From that IR, either a bytecode VM runs the program immediately (no toolchain required) or a Cranelift backend produces a real native object file ready to link into an executable.

## The pipeline

```
source → lexer → tokens → parser → AST → typechecker → typed AST → IR
                                                                    ├── bytecode VM      (frost run)
                                                                    └── Cranelift codegen (frost build)
```

The split happens after IR generation. Both backends consume the same IR.

## What each backend is for

The bytecode VM has no Cranelift dependency, no object-file emission, no linker invocation. It runs immediately. Compile a `.frost` file, see the result. The REPL uses this path. Edit, save, see output, repeat. No round trip through the system linker.

The Cranelift backend is for the case where you actually want to ship something. It emits real native object files via `cranelift-object`, which the system linker turns into an executable through the `cc` crate. Performance is closer to what an optimizing native compiler produces. Not LLVM-tier, but Cranelift is tuned for fast compilation, and for a small language without an established library ecosystem the compile-time-fast trade-off is the right one.

## Why both, not one

For a serious language with a mature ecosystem, the VM doesn't pull its weight. Users would just install the build tool and run the native output. But frost has a tiny stdlib, no package manager, and no LSP. Installing it for the first time and getting any kind of program running needs to be friction-free. The VM gives that. You don't have to have a working linker, a system C toolchain, or any of the rest of the build infrastructure that real compilers depend on.

For users who do want production output, the native backend is there. Same source, same IR, same semantics, optimized output. Importantly: the IR being shared between backends means there's no semantic drift between "what the REPL does" and "what the binary does." A bug in one becomes a bug in the other.

## The IR is deliberately not SSA

Frost's IR is a tree of typed expressions, lowered from the AST after typechecking. Each node carries its inferred type and its ownership annotation.

SSA conversion is something the Cranelift backend does internally when it lowers IR to CLIF. The bytecode VM doesn't need SSA at all. Putting SSA in the shared IR would force the VM to consume something more complex than it needs, for no benefit to the VM side and no benefit to the native side either (since Cranelift would re-do the conversion regardless).

This is the kind of choice that only makes sense in context. A compiler with a single backend would absolutely use SSA. A compiler with two backends where one is a stack-machine interpreter wouldn't.

## References are second-class

The most opinionated thing about frost's design is that references are second-class: they can be passed to functions but not stored in structs or returned. This eliminates lifetime annotations entirely.

There's a real expressivity loss in this. Some patterns that Rust handles cleanly require workarounds in frost. The benefit is that the analysis becomes intra-procedural: a function signature is enough to know what's borrowed and for how long. There's no equivalent of `'a` propagating across call boundaries.

The type system distinguishes `Type::Ref` and `Type::RefMut` for shared and mutable references, with `Borrow` and `BorrowMut` expressions producing them. Because references can't escape the function that creates them, the typechecker doesn't have to track their lifetimes across calls.

## What's missing

Frost is a hobby language. It has no standard library beyond primitives, no traits or generics (the type system is monomorphic), no proper module system, no package manager, no LSP, no debugger. Whether any of that gets built depends on whether I keep wanting to use it for real.

The dual-backend architecture is the part I'd carry forward into anything else, though. Splitting at IR with one fast development path and one production-quality output path is more useful than I expected when I started.

The repository is at [github.com/matthewjberger/frost](https://github.com/matthewjberger/frost). The bytecode VM is at [`src/typed_vm.rs`](https://github.com/matthewjberger/frost/blob/main/src/typed_vm.rs); the Cranelift backend at [`src/codegen.rs`](https://github.com/matthewjberger/frost/blob/main/src/codegen.rs). The REPL is `cargo run --release -p repl`.
