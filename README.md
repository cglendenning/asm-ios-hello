# Hello ASM

An iOS application written entirely in hand-written ARM64 assembly. No Swift,
no Objective-C, no C. The only tool that touches the source is the assembler,
which translates mnemonics to machine code one-for-one, plus the static linker.

**[Install page](https://cglendenning.github.io/asm-ios-hello/)** (open in
Safari on a provisioned device).

## What it does

Launches and displays "Hello World" centred on screen, above a pull-down menu
of six colours. Picking one recolours the text.

## How it works

An iOS app cannot avoid UIKit — the framework owns the screen, the render
server connection, and the event loop. What it *can* avoid is a compiler.
`hello.s` calls into UIKit through the Objective-C runtime's plain C entry
points, which is precisely what a Swift or Objective-C compiler emits
underneath. The difference is that here every instruction and every metadata
structure is written out by hand:

- **The app delegate class is fabricated at runtime.** There is no compiled
  class. `main` calls `objc_allocateClassPair` to make a `UIResponder`
  subclass, attaches three plain functions to it with `class_addMethod`,
  registers it, and hands the name to `UIApplicationMain`.
- **Message sends are direct `objc_msgSend` calls.** Selector and class
  references live in hand-written `__objc_selrefs` and `__objc_classrefs`
  sections; the runtime rewrites those slots at load time, so a plain load
  yields a live `SEL` or `Class`.
- **`NSString` literals are laid out by hand** in `__DATA,__cfstring` using
  CoreFoundation's documented shape: `{ isa, 0x7c8, char *, length }`.
- **`CGRect` is passed in registers.** It is a four-double homogeneous
  aggregate, so screen bounds travel in `d0`–`d3` and are parked in the
  callee-saved `d8`–`d11` across calls.
- **The menu's blocks are hand-built.** `UIMenu` is driven by `UIAction`, and
  `UIAction` takes a block — so the six block literals, their shared
  descriptor and their invoke functions are laid out by hand to the block ABI:
  `isa = __NSConcreteGlobalBlock`, flags `0x50000000`
  (`BLOCK_IS_GLOBAL | BLOCK_HAS_SIGNATURE`), a 32-byte literal and a
  `{ reserved, size, signature, layout }` descriptor. Each block's invoke
  function is a two-instruction trampoline that loads its colour index and
  jumps to one shared handler, which keeps every block capture-free and
  therefore exactly the size the ABI specifies.

## Verification

`hello.s` assembles unchanged for `arm64-apple-ios-simulator`, so everything
is checked on the host before anything is signed. Beyond "it launches and
looks right", two self-tests confirmed that UIKit really does accept the
hand-built blocks:

1. Attaching one of the `UIAction`s to the button with
   `addAction:forControlEvents:` and firing it with
   `sendActionsForControlEvents:` — UIKit copied and invoked the block, and
   the label changed colour. This is the same stored block a menu tap runs.
2. Reading the menu back out as `button.menu.children[5].title` — confirming
   `setMenu:` took, the `NSArray` survived, and the actions carry the right
   titles in the right order.

## Build

```sh
./build.sh device   # signed .app + .ipa for a real iPhone
./build.sh sim      # build, install and launch on the iOS Simulator
```

The simulator target is worth keeping: it is the same `hello.s`, assembled for
`arm64-apple-ios-simulator`, so the logic can be verified on the host before
signing anything.

## Size

Measured like-for-like — same `Info.plist`, same embedded provisioning
profile, same signing identity, same zip.

| | assembly | Swift + UIKit | SwiftUI |
|---|---|---|---|
| `__text` (machine code) | **1,288 B** | 14,996 B | 14,628 B |
| instructions | **322** | 3,749 | 3,657 |
| executable, signed | **70,416 B** | 114,688 B | 114,816 B |
| IPA | **16,508 B** | 31,629 B | 28,361 B |

The executable and IPA figures are dominated by fixed overhead rather than by
code: iOS uses 16 KB pages, so the smallest possible executable is already
several pages, and the embedded provisioning profile alone is 12 KB. The
`__text` row is the honest comparison, and there the gap is roughly 11.6×.

The whole colour menu — six blocks, the action table, the button, the layout
arithmetic — cost 528 bytes and 132 instructions on top of the plain
"Hello World", which was 760 bytes and 190 instructions.

Note that none of the three embeds a Swift runtime. Swift's ABI has been
stable since iOS 12.2, so the runtime ships with the OS. Targeting an older
deployment version would add roughly 30 MB of runtime dylibs to the Swift
builds and change the comparison entirely.
