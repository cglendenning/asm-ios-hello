# Hello ASM

An iOS application written entirely in hand-written ARM64 assembly. No Swift,
no Objective-C, no C. The only tool that touches the source is the assembler,
which translates mnemonics to machine code one-for-one, plus the static linker.

**[Install page](https://cglendenning.github.io/asm-ios-hello/)** (open in
Safari on a provisioned device).

## What it does

Launches and displays "Hello World" centred on screen over a slowly drifting
gradient cloud, above a pull-down menu of six colours. Picking one recolours
the text.

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
- **The cloud is eight radial `CAGradientLayer`s.** Each ramps over three
  stops — full strength, three-quarters, transparent — at locations 0, 0.45
  and 1. That broad middle plateau is what stops a blob looking lit from a
  pin-prick and lets neighbours read as overlapping sheets rather than
  discrete circles. No blur pass and no offscreen render. The frames are
  ellipses and several are wider than the screen, so no blob shows an edge.
- **Colours are 8-bit component triples**, not `UIColor` class methods, which
  keeps the palette open-ended and sidesteps any deployment-target question
  about which system colours exist. `systemIndigo`, `systemPurple`,
  `systemTeal` and `systemBlue` appear at their exact values, alongside cyan,
  mint, magenta, amber and coral.
- **Seven animations per blob** — scale x, scale y, opacity, position x,
  position y, `startPoint`, and a colour cross-fade — every one on a different
  period, so the blobs never re-sync and the composition never repeats.
  `position` is animated rather than `transform.translation` so it cannot
  contend with the scale animations for the layer's transform. Animating
  `startPoint` slides the gradient's own centre around inside the blob, which
  is what makes the colour look like it is flowing through the shape —
  animated together with `endPoint`, over the same period and timing curve, so
  their difference stays pinned at 0.40625. A radial `CAGradientLayer`'s
  extent *is* `endPoint - startPoint`; moving `startPoint` alone swells that
  radius past 0.5, the ramp is still part-way up when it meets the layer's
  rectangular bounds, and the blob flashes a hard-edged rectangle. Holding the
  radius constant and leaving margin inside the layer keeps the fade complete
  in every direction.
- **The animations are re-armed on `didBecomeActive`.** iOS strips every
  `CAAnimation` off a layer when an app is backgrounded and does not put them
  back, so an app that only animates at launch looks frozen the next time you
  return to it. `LanimateBlob` is deliberately stateless — it re-reads the
  screen bounds and recomputes the blob's centre — so it can be called again
  at any time, and adding an animation under a key already in use replaces it,
  which makes re-arming idempotent.
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

Measured like-for-like: all three implement the *same* app — the label, the
six-colour pull-down, and the same five-blob `CAGradientLayer` cloud with the
same animations — and are packaged identically, with the same `Info.plist`,
embedded provisioning profile, signing identity and zip settings.

| | assembly | Swift + UIKit | SwiftUI |
|---|---|---|---|
| `__text` (machine code) | **2,740 B** | 19,940 B | 21,076 B |
| instructions | **685** | 4,985 | 5,269 |
| executable, signed | **70,896 B** | 133,168 B | 125,776 B |
| IPA | **17,828 B** | 35,450 B | 35,666 B |

The executable and IPA figures are dominated by fixed overhead rather than by
code: iOS uses 16 KB pages, so the smallest possible executable is already
several pages, and the embedded provisioning profile alone is 12 KB. The
`__text` row is the honest comparison, and there the gap is 7.3×.

Cumulative cost of each layer of the assembly build, in machine code:

| | bytes | instructions |
|---|---|---|
| plain "Hello World" | 760 | 190 |
| \+ the colour menu | 1,288 | 322 |
| \+ the animated cloud | 2,740 | 685 |

The gap narrows as features are added — it was 11.6× for just the label and
menu, and 7.3× with the cloud — because the cloud is mostly Core Animation
setup calls, and a message send costs about the same however you write it.
The ratio reflects how much scaffolding a language puts around those calls,
and the cloud is unusually light on scaffolding.

It is also worth noting that the cloud then runs for free in all three: Core
Animation hands the animations to the render server, so nothing in any of
these binaries executes again after launch.

Note that none of the three embeds a Swift runtime. Swift's ABI has been
stable since iOS 12.2, so the runtime ships with the OS. Targeting an older
deployment version would add roughly 30 MB of runtime dylibs to the Swift
builds and change the comparison entirely.
