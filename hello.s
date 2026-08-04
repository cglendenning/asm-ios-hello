//===========================================================================
// hello.s - "Hello World" for iOS, hand-written ARM64 assembly.
//
// No Swift, no Objective-C, no C. The only tool used on this file is the
// assembler (a 1:1 mnemonic-to-machine-code translator) and the static linker.
//
// The app talks to UIKit the only way anything can: through the Objective-C
// runtime's C entry points (objc_msgSend and friends), which is exactly what
// a Swift or Objective-C compiler emits underneath. The difference is that
// here every instruction and every data structure is written out by hand.
//
// A pull-down menu on a button lets you recolour the text. UIMenu is driven
// by UIAction, and UIAction takes a *block* - so the block literals, their
// descriptor and their invoke functions are all laid out by hand too.
//
// Behind it all, eight radial CAGradientLayers drift, breathe and cross-fade
// to make a soft glowing cloud. Core Animation runs those on the render
// server, so the animation costs no CPU once it has been set up.
//
// AAPCS64 / Apple ARM64 ABI reminders used throughout:
//   x0..x7   integer/pointer arguments and return value
//   d0..d7   floating-point arguments and return value
//   x8       scratch (used here to materialise page-relative addresses)
//   x19..x28 callee-saved
//   d8..d15  callee-saved (low 64 bits only)
//   CGFloat is a double; CGRect is a 4-double HFA, so it is passed and
//   returned entirely in d0..d3 - never on the stack, never by pointer.
//
//   objc_msgSend(id self, SEL op, ...) -> x0 = self, x1 = SEL, x2.. = args
//===========================================================================

// The platform (iOS device vs. iOS Simulator) and deployment target come from
// the assembler/linker command line, so this one source builds for both.

	.set	NCOLORS, 6			// entries in the colour menu
	.set	BLOCK_SIZE, 32			// bytes per global block literal
	.set	NBLOBS, 8			// gradient blobs making up the cloud
	.set	NANIMS, 3			// shared per-blob scalar animations

//---------------------------------------------------------------------------
// Macros: load a class reference / send a message.
//
// Class and selector references live in the __objc_classrefs and
// __objc_selrefs sections. dyld binds the class pointers at load time, and
// the Objective-C runtime rewrites each __objc_selrefs slot from "pointer to
// a name string" into "unique SEL" before main() runs. So by the time this
// code executes, a plain load from those slots yields a live Class / SEL.
//---------------------------------------------------------------------------

.macro	CLASSREF name			// -> x0 = Class
	adrp	x8, Lcls_\name@PAGE
	ldr	x0, [x8, Lcls_\name@PAGEOFF]
.endm

.macro	MSGSEND name			// x0 and x2.. must already be set
	adrp	x8, Lsel_\name@PAGE
	ldr	x1, [x8, Lsel_\name@PAGEOFF]
	bl	_objc_msgSend
.endm

.macro	LEA reg, sym			// -> reg = &sym
	adrp	\reg, \sym@PAGE
	add	\reg, \reg, \sym@PAGEOFF
.endm

.macro	GOTREF reg, sym			// -> reg = external data symbol sym
	adrp	x8, \sym@GOTPAGE
	ldr	x8, [x8, \sym@GOTPAGEOFF]
	ldr	\reg, [x8]
.endm

.macro	LOADG reg, sym			// -> reg = global variable sym
	adrp	x8, \sym@PAGE
	ldr	\reg, [x8, \sym@PAGEOFF]
.endm

.macro	STOREG reg, sym			// global variable sym = reg
	adrp	x8, \sym@PAGE
	str	\reg, [x8, \sym@PAGEOFF]
.endm

// One two-instruction trampoline per menu entry. Each block's invoke function
// is just "load my index, jump to the shared handler", which keeps every
// block capture-free and therefore exactly the 32-byte global literal that
// the block ABI specifies.
.macro	COLOR_INVOKE idx
	.p2align 2
LcolorInvoke_\idx:
	mov	x0, #\idx
	b	LapplyColor
.endm

.macro	COLOR_BLOCK idx
	.p2align 3
Lblock_\idx:
	.quad	__NSConcreteGlobalBlock
	.long	0x50000000			// BLOCK_IS_GLOBAL | BLOCK_HAS_SIGNATURE
	.long	0				// reserved
	.quad	LcolorInvoke_\idx
	.quad	Lblock_descriptor
.endm


	.section __TEXT,__text,regular,pure_instructions
	.p2align 2

//===========================================================================
// main - the process entry point (LC_MAIN target).
//
// UIApplicationMain needs an app-delegate class, and a class is just a data
// structure the runtime can build for us. So instead of compiling one from a
// source language, we fabricate it at runtime: allocate a subclass of
// UIResponder, bolt three C functions onto it as methods, register it, and
// hand its name to UIKit.
//===========================================================================
	.globl	_main
	.p2align 2
_main:
	stp	x29, x30, [sp, #-48]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	str	x21, [sp, #32]
	mov	x19, x0				// argc  (must survive to UIApplicationMain)
	mov	x20, x1				// argv

	// Class cls = objc_allocateClassPair([UIResponder class], "AppDelegate", 0);
	CLASSREF UIResponder
	LEA	x1, Lstr_AppDelegate
	mov	x2, #0				// no extra ivar bytes: state lives in __DATA
	bl	_objc_allocateClassPair
	mov	x21, x0				// cls

	// class_addMethod(cls, @selector(application:didFinishLaunchingWithOptions:),
	//                 (IMP)AppDelegate_didFinishLaunching, "B@:@@");
	LEA	x0, Lstr_selDidFinish
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	LEA	x2, LAppDelegate_didFinishLaunching
	LEA	x3, Lstr_typeDidFinish
	bl	_class_addMethod

	// class_addMethod(cls, @selector(window), (IMP)AppDelegate_window, "@@:");
	LEA	x0, Lstr_selWindow
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	LEA	x2, LAppDelegate_window
	LEA	x3, Lstr_typeWindow
	bl	_class_addMethod

	// class_addMethod(cls, @selector(setWindow:), (IMP)AppDelegate_setWindow, "v@:@");
	LEA	x0, Lstr_selSetWindow
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	LEA	x2, LAppDelegate_setWindow
	LEA	x3, Lstr_typeSetWindow
	bl	_class_addMethod

	// class_addMethod(cls, @selector(cloudDidBecomeActive:),
	//                 (IMP)AppDelegate_becameActive, "v@:@");
	LEA	x0, Lstr_selBecameActive
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	LEA	x2, LAppDelegate_becameActive
	LEA	x3, Lstr_typeSetWindow		// same encoding: void (id, SEL, id)
	bl	_class_addMethod

	// objc_registerClassPair(cls);
	mov	x0, x21
	bl	_objc_registerClassPair

	// UIApplicationMain(argc, argv, nil, @"AppDelegate");
	// Does not return: it takes over the thread and runs the event loop.
	mov	x0, x19
	mov	x1, x20
	mov	x2, #0				// nil -> default principal class UIApplication
	LEA	x3, Lcfstr_AppDelegate
	bl	_UIApplicationMain

	// Unreachable in practice, but a function must be able to return.
	ldr	x21, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #48
	ret


//===========================================================================
// BOOL -[AppDelegate application:didFinishLaunchingWithOptions:]
//
//   x0 = self, x1 = _cmd, x2 = UIApplication *, x3 = NSDictionary *
//
// Builds the whole UI: window -> view controller -> label + menu button.
//
// Stack frame (144 bytes):
//   [  0] x29, x30      [ 16] x19 window,  x20 view controller
//   [ 32] x21 root view, x22 label        [ 48] x23, x24 scratch
//   [ 64] d8, d9        [ 80] d10, d11    (screen bounds)
//   [ 96] UIAction *actions[NCOLORS]
//===========================================================================
	.p2align 2
LAppDelegate_didFinishLaunching:
	stp	x29, x30, [sp, #-144]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	x23, x24, [sp, #48]
	stp	d8,  d9,  [sp, #64]		// screen bounds must survive the calls
	stp	d10, d11, [sp, #80]
	STOREG	x0, LgDelegate			// the notification observer

	// CGRect bounds = [[UIScreen mainScreen] bounds];
	CLASSREF UIScreen
	MSGSEND	mainScreen
	MSGSEND	bounds
	fmov	d8,  d0				// origin.x
	fmov	d9,  d1				// origin.y
	fmov	d10, d2				// size.width
	fmov	d11, d3				// size.height

	// UIWindow *window = [[UIWindow alloc] initWithFrame:bounds];
	CLASSREF UIWindow
	MSGSEND	alloc
	fmov	d0, d8
	fmov	d1, d9
	fmov	d2, d10
	fmov	d3, d11
	MSGSEND	initWithFrame
	mov	x19, x0				// the window is owned for the life of
	STOREG	x19, LgWindow			// the process, so it is simply retained

	// [window setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
	// The cloud only glows against a dark backdrop, and pinning the style
	// keeps labelColor white in both system appearances.
	mov	x0, x19
	mov	x2, #2
	MSGSEND	setOverrideUserInterfaceStyle

	// UIViewController *vc = [[UIViewController alloc] init];
	CLASSREF UIViewController
	MSGSEND	alloc
	MSGSEND	init
	mov	x20, x0

	// UIView *root = [vc view];   (forces the view to load)
	mov	x0, x20
	MSGSEND	view
	mov	x21, x0

	// [root setBackgroundColor:[UIColor systemBackgroundColor]];
	CLASSREF UIColor
	MSGSEND	systemBackgroundColor
	mov	x2, x0
	mov	x0, x21
	MSGSEND	setBackgroundColor

	// Lay the cloud straight into the root view's layer. Sublayers added
	// here sit *below* every layer that addSubview: appends later, so the
	// label and the button stay in front of it without any extra work.
	mov	x0, x21
	fmov	d0, d10
	fmov	d1, d11
	bl	LbuildCloud

	// [[NSNotificationCenter defaultCenter]
	//        addObserver:self
	//           selector:@selector(cloudDidBecomeActive:)
	//               name:UIApplicationDidBecomeActiveNotification
	//             object:nil];
	CLASSREF NSNotificationCenter
	MSGSEND	defaultCenter
	mov	x24, x0
	LOADG	x2, LgDelegate
	adrp	x8, Lsel_cloudDidBecomeActive@PAGE
	ldr	x3, [x8, Lsel_cloudDidBecomeActive@PAGEOFF]
	GOTREF	x4, _UIApplicationDidBecomeActiveNotification
	mov	x5, #0
	mov	x0, x24
	MSGSEND	addObserverSelectorNameObject

	//-------------------------------------------------------------------
	// The label
	//-------------------------------------------------------------------

	// UILabel *label = [[UILabel alloc] initWithFrame:bounds];
	CLASSREF UILabel
	MSGSEND	alloc
	fmov	d0, d8
	fmov	d1, d9
	fmov	d2, d10
	fmov	d3, d11
	MSGSEND	initWithFrame
	mov	x22, x0
	STOREG	x22, LgLabel			// the menu handler recolours this

	// [label setText:@"Hello World"];
	LEA	x2, Lcfstr_Hello
	mov	x0, x22
	MSGSEND	setText

	// [label setTextAlignment:NSTextAlignmentCenter];
	mov	x0, x22
	mov	x2, #1
	MSGSEND	setTextAlignment

	// [label setTextColor:[UIColor labelColor]];
	CLASSREF UIColor
	MSGSEND	labelColor
	mov	x2, x0
	mov	x0, x22
	MSGSEND	setTextColor

	// [label setFont:[UIFont systemFontOfSize:44.0]];
	CLASSREF UIFont
	adrp	x8, Ldbl_fontSize@PAGE		// 44.0 is outside the fmov immediate
	ldr	d0, [x8, Ldbl_fontSize@PAGEOFF]	// encoding, so load it from __literal8
	MSGSEND	systemFontOfSize
	mov	x2, x0
	mov	x0, x22
	MSGSEND	setFont

	// [label setAutoresizingMask:FlexibleWidth|FlexibleHeight];  (2 | 16)
	mov	x0, x22
	mov	x2, #18
	MSGSEND	setAutoresizingMask

	// A soft drop shadow guarantees the text reads over any blob colour.
	// [label.layer setShadowColor:[UIColor blackColor].CGColor];
	CLASSREF UIColor
	MSGSEND	blackColor
	MSGSEND	CGColor
	mov	x24, x0
	mov	x0, x22
	MSGSEND	layer
	mov	x2, x24
	MSGSEND	setShadowColor
	// [label.layer setShadowOpacity:0.5];  (float -> s0)
	mov	x0, x22
	MSGSEND	layer
	fmov	s0, #0.5
	MSGSEND	setShadowOpacity
	// [label.layer setShadowRadius:12.0];
	mov	x0, x22
	MSGSEND	layer
	mov	w8, #12
	scvtf	d0, w8
	MSGSEND	setShadowRadius

	// [root addSubview:label];
	mov	x0, x21
	mov	x2, x22
	MSGSEND	addSubview

	//-------------------------------------------------------------------
	// The colour menu
	//
	// for (i = 0; i < NCOLORS; i++)
	//     actions[i] = [UIAction actionWithTitle:Lcolors[i].title
	//                                      image:nil
	//                                 identifier:nil
	//                                    handler:&Lblocks[i]];
	//-------------------------------------------------------------------
	mov	x23, #0				// i
Lmenu_loop:
	LEA	x24, Lcolors
	add	x24, x24, x23, lsl #4		// &Lcolors[i]   (16 bytes per entry)
	ldr	x2, [x24]			// title
	mov	x3, #0				// image      = nil
	mov	x4, #0				// identifier = nil
	LEA	x5, Lblocks
	mov	x9, #BLOCK_SIZE
	madd	x5, x23, x9, x5			// handler    = &Lblocks[i]
	CLASSREF UIAction
	MSGSEND	actionWithTitleImageIdentifierHandler
	add	x9, sp, #96
	str	x0, [x9, x23, lsl #3]		// actions[i] = action
	add	x23, x23, #1
	cmp	x23, #NCOLORS
	b.lt	Lmenu_loop

	// NSArray *children = [NSArray arrayWithObjects:actions count:NCOLORS];
	add	x2, sp, #96
	mov	x3, #NCOLORS
	CLASSREF NSArray
	MSGSEND	arrayWithObjectsCount
	mov	x24, x0

	// UIMenu *menu = [UIMenu menuWithTitle:@"Text Color" children:children];
	LEA	x2, Lcfstr_TextColor
	mov	x3, x24
	CLASSREF UIMenu
	MSGSEND	menuWithTitleChildren
	mov	x24, x0

	// UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	CLASSREF UIButton
	mov	x2, #1				// UIButtonTypeSystem
	MSGSEND	buttonWithType
	mov	x23, x0
	STOREG	x23, LgButton			// the menu handler retitles this

	// [button setTitle:@"Text Color" forState:UIControlStateNormal];
	mov	x0, x23
	LEA	x2, Lcfstr_TextColor
	mov	x3, #0				// UIControlStateNormal
	MSGSEND	setTitleForState

	// Give the chooser a translucent pill so it never disappears into a
	// bright patch of cloud.
	// [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	CLASSREF UIColor
	MSGSEND	whiteColor
	mov	x2, x0
	mov	x3, #0
	mov	x0, x23
	MSGSEND	setTitleColorForState
	// [button setBackgroundColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15625]];
	CLASSREF UIColor
	MSGSEND	whiteColor
	fmov	d0, #0.15625
	MSGSEND	colorWithAlphaComponent
	mov	x2, x0
	mov	x0, x23
	MSGSEND	setBackgroundColor
	// [button.layer setCornerRadius:25]; [button.layer setMasksToBounds:YES];
	mov	x0, x23
	MSGSEND	layer
	mov	w8, #25
	scvtf	d0, w8
	MSGSEND	setCornerRadius
	mov	x0, x23
	MSGSEND	layer
	mov	x2, #1
	MSGSEND	setMasksToBounds

	// [button setMenu:menu];
	mov	x0, x23
	mov	x2, x24
	MSGSEND	setMenu

	// [button setShowsMenuAsPrimaryAction:YES];
	//   ...so a single tap pulls the menu down, with no long press.
	mov	x0, x23
	mov	x2, #1
	MSGSEND	setShowsMenuAsPrimaryAction

	// [button setFrame:CGRectMake((width - 240) / 2, height - 160, 240, 50)];
	// Built with scvtf rather than loaded from memory: these are small
	// integers, so converting them is cheaper than a literal pool.
	mov	w8, #240
	scvtf	d4, w8
	fsub	d0, d10, d4			// width - 240
	fmov	d5, #2.0
	fdiv	d0, d0, d5			// x = (width - 240) / 2
	mov	w8, #160
	scvtf	d5, w8
	fsub	d1, d11, d5			// y = height - 160
	fmov	d2, d4				// w = 240
	mov	w8, #50
	scvtf	d3, w8				// h = 50
	mov	x0, x23
	MSGSEND	setFrame

	// [button setAutoresizingMask:FlexibleLeftMargin|FlexibleRightMargin
	//                             |FlexibleTopMargin];   (1 | 4 | 32)
	mov	x0, x23
	mov	x2, #37
	MSGSEND	setAutoresizingMask

	// [root addSubview:button];
	mov	x0, x21
	mov	x2, x23
	MSGSEND	addSubview

	//-------------------------------------------------------------------
	// Present
	//-------------------------------------------------------------------

	// [window setRootViewController:vc];
	mov	x0, x19
	mov	x2, x20
	MSGSEND	setRootViewController

	// [window makeKeyAndVisible];
	mov	x0, x19
	MSGSEND	makeKeyAndVisible

	mov	w0, #1				// return YES
	ldp	d10, d11, [sp, #80]
	ldp	d8,  d9,  [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #144
	ret


//===========================================================================
// LapplyColor - shared body of every menu block.
//
//   x0 = index into Lcolors
//
// Reached by a `b` from a block's invoke function, so the return here goes
// straight back to whoever called the block.
//===========================================================================
	.p2align 2
LapplyColor:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	str	x19, [sp, #16]

	LEA	x19, Lcolors
	add	x19, x19, x0, lsl #4		// &Lcolors[index]

	// UIColor *c = [UIColor <the entry's class-method selector>];
	// Field 1 holds the *address* of a __objc_selrefs slot, because the
	// runtime rewrites those slots in place - so the SEL has to be loaded
	// through the slot at call time, never baked in here.
	ldr	x1, [x19, #8]
	ldr	x1, [x1]
	CLASSREF UIColor
	bl	_objc_msgSend

	// [gLabel setTextColor:c];
	mov	x2, x0
	LOADG	x0, LgLabel
	MSGSEND	setTextColor

	// [gButton setTitle:<the entry's name> forState:UIControlStateNormal];
	ldr	x2, [x19]
	mov	x3, #0
	LOADG	x0, LgButton
	MSGSEND	setTitleForState

	ldr	x19, [sp, #16]
	ldp	x29, x30, [sp], #32
	ret

// The six block invoke functions.
	COLOR_INVOKE 0
	COLOR_INVOKE 1
	COLOR_INVOKE 2
	COLOR_INVOKE 3
	COLOR_INVOKE 4
	COLOR_INVOKE 5


//===========================================================================
// LbuildCloud - lay the glowing blobs into a view's layer.
//
//   x0 = UIView *root, d0 = width, d1 = height
//
// Each blob is a CAGradientLayer in radial mode. Rather than a single hot
// point fading straight to nothing, the colours run over three stops - full
// strength, three-quarters, then transparent - placed at 0, 0.45 and 1. That
// broad middle plateau is what removes the "lit from a pin-prick" look and
// lets neighbouring blobs read as overlapping sheets of colour instead of
// discrete circles. The frames are ellipses, not squares, and several are
// wider than the screen, so no blob shows an edge.
//===========================================================================
	.p2align 2
LbuildCloud:
	stp	x29, x30, [sp, #-112]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	x23, x24, [sp, #48]
	stp	d8,  d9,  [sp, #64]
	str	d10,      [sp, #80]
	fmov	d8, d0				// width
	fmov	d9, d1				// height

	MSGSEND	layer				// x0 is already the root view
	mov	x19, x0				// root.layer

	// The stop positions are the same for every blob, so build the array
	// once: @[ @0.0, @0.45, @1.0 ].
	fmov	d0, xzr
	bl	LnumD
	str	x0, [sp, #88]
	adrp	x8, Ldbl_mid@PAGE
	ldr	d0, [x8, Ldbl_mid@PAGEOFF]
	bl	LnumD
	str	x0, [sp, #96]
	fmov	d0, #1.0
	bl	LnumD
	str	x0, [sp, #104]
	add	x2, sp, #88
	mov	x3, #3
	CLASSREF NSArray
	MSGSEND	arrayWithObjectsCount
	STOREG	x0, LgLocations

	mov	x21, #0				// blob index
Lblob_loop:
	LEA	x20, Lblobs
	add	x20, x20, x21, lsl #5		// &Lblobs[i]   (32 bytes per entry)

	// CAGradientLayer *g = [CAGradientLayer layer];
	CLASSREF CAGradientLayer
	MSGSEND	layer
	mov	x22, x0

	// [g setType:kCAGradientLayerRadial];
	GOTREF	x2, _kCAGradientLayerRadial
	mov	x0, x22
	MSGSEND	setType

	// [g setColors:<three stops of the base colour>];
	mov	x0, x20
	bl	LmakeStops
	mov	x2, x0
	mov	x0, x22
	MSGSEND	setColors

	// [g setLocations:@[ @0.0, @0.45, @1.0 ]];
	LOADG	x2, LgLocations
	mov	x0, x22
	MSGSEND	setLocations

	mov	x0, x22
	fmov	d0, #0.5
	fmov	d1, #0.5
	MSGSEND	setStartPoint
	mov	x0, x22
	fmov	d0, #1.0
	fmov	d1, #1.0
	MSGSEND	setEndPoint

	// Width and height are independent percentages, so the blobs are
	// ellipses of differing proportion rather than a row of circles.
	//   w = width * w% / 100 ,  h = width * h% / 100
	//   cx = width * x% / 100 , cy = height * y% / 100
	ldrsh	w9,  [x20, #8]			// x%
	ldrsh	w10, [x20, #10]			// y%
	ldrsh	w11, [x20, #12]			// w%
	ldrsh	w12, [x20, #14]			// h%
	mov	w13, #100
	scvtf	d5, w13
	scvtf	d4, w11
	fmul	d4, d8, d4
	fdiv	d4, d4, d5			// blob width
	scvtf	d6, w12
	fmul	d6, d8, d6
	fdiv	d6, d6, d5			// blob height
	scvtf	d7, w9
	fmul	d7, d8, d7
	fdiv	d7, d7, d5			// centre x
	scvtf	d16, w10
	fmul	d16, d9, d16
	fdiv	d16, d16, d5			// centre y
	fmov	d17, #2.0
	fdiv	d18, d4, d17
	fdiv	d19, d6, d17
	fsub	d0, d7, d18			// frame.origin.x
	fsub	d1, d16, d19			// frame.origin.y
	fmov	d2, d4				// frame.size.width
	fmov	d3, d6				// frame.size.height
	mov	x0, x22
	MSGSEND	setFrame

	// [root.layer addSublayer:g];
	mov	x0, x19
	mov	x2, x22
	MSGSEND	addSublayer

	// Keep the layer so the animations can be re-armed later. The
	// superlayer owns it, so a bare pointer is enough.
	LEA	x8, LgBlobLayers
	str	x22, [x8, x21, lsl #3]

	mov	x0, x22
	mov	x1, x20
	bl	LanimateBlob

	add	x21, x21, #1
	cmp	x21, #NBLOBS
	b.lt	Lblob_loop

	ldr	d10,      [sp, #80]
	ldp	d8,  d9,  [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #112
	ret


//===========================================================================
// LanimateBlob - arm (or re-arm) every animation on one blob.
//
//   x0 = CAGradientLayer *, x1 = &Lblobs[i]
//
// Deliberately stateless: it re-reads the screen bounds and recomputes the
// blob's centre, so it can be called again at any time. Adding an animation
// under a key that is already in use replaces it, which makes this idempotent.
//===========================================================================
	.p2align 2
LanimateBlob:
	stp	x29, x30, [sp, #-112]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	x23, x24, [sp, #48]
	stp	d8,  d9,  [sp, #64]
	stp	d10, d11, [sp, #80]
	stp	d12, d13, [sp, #96]
	mov	x19, x0				// layer
	mov	x20, x1				// entry

	CLASSREF UIScreen
	MSGSEND	mainScreen
	MSGSEND	bounds
	fmov	d8, d2				// width
	fmov	d9, d3				// height

	ldrsh	w9,  [x20, #8]
	ldrsh	w10, [x20, #10]
	mov	w13, #100
	scvtf	d5, w13
	scvtf	d6, w9
	fmul	d6, d8, d6
	fdiv	d12, d6, d5			// centre x
	scvtf	d7, w10
	fmul	d7, d9, d7
	fdiv	d13, d7, d5			// centre y

	ldrsh	w8, [x20, #16]
	scvtf	d10, w8				// this blob's base period, seconds

	// The three whose endpoints are the same for every blob: scale x,
	// scale y and opacity. Only the period differs, which is what stops
	// the blobs pulsing in lockstep.
	mov	x21, #0
Lanim_loop:
	LEA	x22, LanimTable
	add	x22, x22, x21, lsl #5
	ldr	d0, [x22, #8]
	bl	LnumD
	mov	x23, x0
	ldr	d0, [x22, #16]
	bl	LnumD
	mov	x24, x0
	ldrsh	w8, [x22, #24]
	scvtf	d0, w8
	fadd	d0, d0, d10
	ldr	x1, [x22]
	mov	x2, x23
	mov	x3, x24
	mov	x0, x19
	bl	LaddAnim
	add	x21, x21, #1
	cmp	x21, #NANIMS
	b.lt	Lanim_loop

	// Drift. position.x / position.y rather than transform.translation, so
	// they never contend with the scale animations for the transform.
	mov	w8, #44
	scvtf	d11, w8
	fsub	d0, d12, d11
	bl	LnumD
	mov	x23, x0
	fadd	d0, d12, d11
	bl	LnumD
	mov	x24, x0
	mov	w8, #6
	scvtf	d0, w8
	fadd	d0, d0, d10
	LEA	x1, Lcfstr_kpPositionX
	mov	x2, x23
	mov	x3, x24
	mov	x0, x19
	bl	LaddAnim

	mov	w8, #36
	scvtf	d11, w8
	fadd	d0, d13, d11
	bl	LnumD
	mov	x23, x0
	fsub	d0, d13, d11
	bl	LnumD
	mov	x24, x0
	mov	w8, #9
	scvtf	d0, w8
	fadd	d0, d0, d10
	LEA	x1, Lcfstr_kpPositionY
	mov	x2, x23
	mov	x3, x24
	mov	x0, x19
	bl	LaddAnim

	// Slide the gradient's own centre around inside the blob. This is what
	// makes the colour look like it is flowing through the shape rather
	// than radiating from a fixed pin-prick.
	fmov	d0, #0.375
	fmov	d1, #0.40625
	bl	LvalPoint
	mov	x23, x0
	fmov	d0, #0.625
	fmov	d1, #0.59375
	bl	LvalPoint
	mov	x24, x0
	mov	w8, #4
	scvtf	d0, w8
	fadd	d0, d0, d10
	LEA	x1, Lcfstr_kpStartPoint
	mov	x2, x23
	mov	x3, x24
	mov	x0, x19
	bl	LaddAnim

	// The colour cross-fade, at half the rate of everything else.
	mov	x0, x20
	bl	LmakeStops
	mov	x23, x0
	add	x0, x20, #4
	bl	LmakeStops
	mov	x24, x0
	fmov	d0, #2.0
	fmul	d0, d10, d0
	LEA	x1, Lcfstr_kpColors
	mov	x2, x23
	mov	x3, x24
	mov	x0, x19
	bl	LaddAnim

	ldp	d12, d13, [sp, #96]
	ldp	d10, d11, [sp, #80]
	ldp	d8,  d9,  [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #112
	ret


//===========================================================================
// void -[AppDelegate cloudDidBecomeActive:]   (x0 = self, x1 = _cmd, x2 = note)
//
// iOS strips every CAAnimation off a layer when the app is backgrounded and
// does not put them back, so an app that only animates once at launch appears
// frozen the next time you return to it. Re-arming on didBecomeActive is the
// fix, and it is why the cloud kept moving in the simulator but not on a
// phone that had been switched away from.
//===========================================================================
	.p2align 2
LAppDelegate_becameActive:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	str	x19, [sp, #16]
	mov	x19, #0
Lrearm_loop:
	LEA	x8, LgBlobLayers
	ldr	x0, [x8, x19, lsl #3]
	cbz	x0, Lrearm_next			// nothing built yet
	LEA	x1, Lblobs
	add	x1, x1, x19, lsl #5
	bl	LanimateBlob
Lrearm_next:
	add	x19, x19, #1
	cmp	x19, #NBLOBS
	b.lt	Lrearm_loop
	ldr	x19, [sp, #16]
	ldp	x29, x30, [sp], #32
	ret


//===========================================================================
// LmakeStops - the three-stop colour ramp for one blob.
//
//   x0 = address of a { red, green, blue, peak alpha } byte quad
//   -> x0 = NSArray *{ CGColor@peak, CGColor@0.75*peak, CGColor@0 }
//
// NSArray happily holds CGColorRefs: they are CF objects, so the retain the
// array sends them lands on CFRetain.
//===========================================================================
	.p2align 2
LmakeStops:
	stp	x29, x30, [sp, #-64]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	str	d8,  [sp, #32]
	mov	x19, x0

	ldrb	w8, [x19, #3]
	scvtf	d8, w8
	adrp	x9, Ldbl_255@PAGE
	ldr	d0, [x9, Ldbl_255@PAGEOFF]
	fdiv	d8, d8, d0			// peak alpha, 0..1

	mov	x0, x19
	fmov	d0, d8
	bl	LmakeCGColor
	str	x0, [sp, #40]

	mov	x0, x19
	fmov	d1, #0.75
	fmul	d0, d8, d1
	bl	LmakeCGColor
	str	x0, [sp, #48]

	mov	x0, x19
	fmov	d0, xzr				// fmov cannot encode 0.0 as an
	bl	LmakeCGColor			// immediate, so move it from xzr
	str	x0, [sp, #56]

	add	x2, sp, #40
	mov	x3, #3
	CLASSREF NSArray
	MSGSEND	arrayWithObjectsCount

	ldr	d8,  [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #64
	ret


//===========================================================================
// LmakeCGColor - one CGColor from a byte triple and an alpha.
//
//   x0 = address of { red, green, blue, .. } bytes, d0 = alpha
//
// Colours come from a table of 8-bit components rather than UIColor class
// methods, which keeps the palette open-ended and free of any deployment
// target question about which system colours exist.
//===========================================================================
	.p2align 2
LmakeCGColor:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	str	d8, [sp, #16]
	fmov	d8, d0				// alpha
	ldrb	w9,  [x0]
	ldrb	w10, [x0, #1]
	ldrb	w11, [x0, #2]
	adrp	x8, Ldbl_255@PAGE
	ldr	d4, [x8, Ldbl_255@PAGEOFF]
	scvtf	d0, w9
	fdiv	d0, d0, d4
	scvtf	d1, w10
	fdiv	d1, d1, d4
	scvtf	d2, w11
	fdiv	d2, d2, d4
	fmov	d3, d8
	CLASSREF UIColor
	MSGSEND	colorWithRedGreenBlueAlpha
	MSGSEND	CGColor
	ldr	d8, [sp, #16]
	ldp	x29, x30, [sp], #32
	ret


//===========================================================================
// LvalPoint - box a CGPoint.   d0 = x, d1 = y  ->  x0 = NSValue *
//===========================================================================
	.p2align 2
LvalPoint:
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	CLASSREF NSValue
	MSGSEND	valueWithCGPoint
	ldp	x29, x30, [sp], #16
	ret


//===========================================================================
// LnumD - box a double.   d0 -> x0 = NSNumber *
//===========================================================================
	.p2align 2
LnumD:
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	CLASSREF NSNumber
	MSGSEND	numberWithDouble
	ldp	x29, x30, [sp], #16
	ret


//===========================================================================
// LaddAnim - attach one infinitely repeating, auto-reversing animation.
//
//   x0 = CALayer *, x1 = key path, x2 = fromValue, x3 = toValue, d0 = period
//
// The key path doubles as the animation's key, which is unique per layer and
// keeps a second call on the same property from stacking up.
//===========================================================================
	.p2align 2
LaddAnim:
	stp	x29, x30, [sp, #-80]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	str	x23, [sp, #48]
	str	d8,  [sp, #64]
	mov	x19, x0				// layer
	mov	x20, x1				// key path
	mov	x21, x2				// fromValue
	mov	x22, x3				// toValue
	fmov	d8, d0				// period

	// CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:keyPath];
	mov	x2, x20
	CLASSREF CABasicAnimation
	MSGSEND	animationWithKeyPath
	mov	x23, x0

	mov	x0, x23
	mov	x2, x21
	MSGSEND	setFromValue
	mov	x0, x23
	mov	x2, x22
	MSGSEND	setToValue
	mov	x0, x23
	fmov	d0, d8
	MSGSEND	setDuration
	mov	x0, x23
	mov	x2, #1
	MSGSEND	setAutoreverses

	// [a setRepeatCount:INFINITY];  repeatCount is a float, so it goes in s0,
	// and +inf is just the raw bit pattern 0x7f800000.
	mov	x0, x23
	movz	w8, #0x7f80, lsl #16
	fmov	s0, w8
	MSGSEND	setRepeatCount

	// [a setTimingFunction:[CAMediaTimingFunction
	//        functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
	GOTREF	x2, _kCAMediaTimingFunctionEaseInEaseOut
	CLASSREF CAMediaTimingFunction
	MSGSEND	functionWithName
	mov	x2, x0
	mov	x0, x23
	MSGSEND	setTimingFunction

	// [layer addAnimation:a forKey:keyPath];
	mov	x0, x19
	mov	x2, x23
	mov	x3, x20
	MSGSEND	addAnimationForKey

	ldr	d8,  [sp, #64]
	ldr	x23, [sp, #48]
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #80
	ret


//===========================================================================
// id -[AppDelegate window]            (x0 = self, x1 = _cmd)
// void -[AppDelegate setWindow:]      (x0 = self, x1 = _cmd, x2 = UIWindow *)
//
// UIKit's pre-scene lifecycle probes the delegate for a -window property.
// Backing it with one global is enough - there is exactly one delegate.
//===========================================================================
	.p2align 2
LAppDelegate_window:
	LOADG	x0, LgWindow
	ret

	.p2align 2
LAppDelegate_setWindow:
	adrp	x8, LgWindow@PAGE
	str	x2, [x8, LgWindow@PAGEOFF]
	ret


//===========================================================================
// Data
//===========================================================================

// Class references. dyld binds each slot to the live Class object at load.
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
Lcls_UIResponder:		.quad _OBJC_CLASS_$_UIResponder
Lcls_UIScreen:			.quad _OBJC_CLASS_$_UIScreen
Lcls_UIWindow:			.quad _OBJC_CLASS_$_UIWindow
Lcls_UIViewController:		.quad _OBJC_CLASS_$_UIViewController
Lcls_UILabel:			.quad _OBJC_CLASS_$_UILabel
Lcls_UIColor:			.quad _OBJC_CLASS_$_UIColor
Lcls_UIFont:			.quad _OBJC_CLASS_$_UIFont
Lcls_UIButton:			.quad _OBJC_CLASS_$_UIButton
Lcls_UIAction:			.quad _OBJC_CLASS_$_UIAction
Lcls_UIMenu:			.quad _OBJC_CLASS_$_UIMenu
Lcls_NSArray:			.quad _OBJC_CLASS_$_NSArray
Lcls_NSNumber:			.quad _OBJC_CLASS_$_NSNumber
Lcls_CAGradientLayer:		.quad _OBJC_CLASS_$_CAGradientLayer
Lcls_CABasicAnimation:		.quad _OBJC_CLASS_$_CABasicAnimation
Lcls_CAMediaTimingFunction:	.quad _OBJC_CLASS_$_CAMediaTimingFunction
Lcls_NSValue:			.quad _OBJC_CLASS_$_NSValue
Lcls_NSNotificationCenter:	.quad _OBJC_CLASS_$_NSNotificationCenter

// Selector name strings.
	.section __TEXT,__objc_methname,cstring_literals
Lmn_alloc:			.asciz "alloc"
Lmn_init:			.asciz "init"
Lmn_mainScreen:			.asciz "mainScreen"
Lmn_bounds:			.asciz "bounds"
Lmn_initWithFrame:		.asciz "initWithFrame:"
Lmn_view:			.asciz "view"
Lmn_setBackgroundColor:		.asciz "setBackgroundColor:"
Lmn_systemBackgroundColor:	.asciz "systemBackgroundColor"
Lmn_labelColor:			.asciz "labelColor"
Lmn_systemRedColor:		.asciz "systemRedColor"
Lmn_systemOrangeColor:		.asciz "systemOrangeColor"
Lmn_systemGreenColor:		.asciz "systemGreenColor"
Lmn_systemBlueColor:		.asciz "systemBlueColor"
Lmn_systemPurpleColor:		.asciz "systemPurpleColor"
Lmn_setText:			.asciz "setText:"
Lmn_setTextAlignment:		.asciz "setTextAlignment:"
Lmn_setTextColor:		.asciz "setTextColor:"
Lmn_systemFontOfSize:		.asciz "systemFontOfSize:"
Lmn_setFont:			.asciz "setFont:"
Lmn_setAutoresizingMask:	.asciz "setAutoresizingMask:"
Lmn_setFrame:			.asciz "setFrame:"
Lmn_addSubview:			.asciz "addSubview:"
Lmn_setRootViewController:	.asciz "setRootViewController:"
Lmn_makeKeyAndVisible:		.asciz "makeKeyAndVisible"
Lmn_buttonWithType:		.asciz "buttonWithType:"
Lmn_setTitleForState:		.asciz "setTitle:forState:"
Lmn_setMenu:			.asciz "setMenu:"
Lmn_setShowsMenuAsPrimaryAction:	.asciz "setShowsMenuAsPrimaryAction:"
Lmn_menuWithTitleChildren:	.asciz "menuWithTitle:children:"
Lmn_arrayWithObjectsCount:	.asciz "arrayWithObjects:count:"
Lmn_actionWithTitleImageIdentifierHandler:
				.asciz "actionWithTitle:image:identifier:handler:"
Lmn_systemPinkColor:	.asciz "systemPinkColor"
Lmn_systemTealColor:	.asciz "systemTealColor"
Lmn_systemIndigoColor:	.asciz "systemIndigoColor"
Lmn_whiteColor:	.asciz "whiteColor"
Lmn_blackColor:	.asciz "blackColor"
Lmn_CGColor:	.asciz "CGColor"
Lmn_colorWithAlphaComponent:	.asciz "colorWithAlphaComponent:"
Lmn_layer:	.asciz "layer"
Lmn_addSublayer:	.asciz "addSublayer:"
Lmn_setType:	.asciz "setType:"
Lmn_setColors:	.asciz "setColors:"
Lmn_setStartPoint:	.asciz "setStartPoint:"
Lmn_setEndPoint:	.asciz "setEndPoint:"
Lmn_numberWithDouble:	.asciz "numberWithDouble:"
Lmn_animationWithKeyPath:	.asciz "animationWithKeyPath:"
Lmn_setFromValue:	.asciz "setFromValue:"
Lmn_setToValue:	.asciz "setToValue:"
Lmn_setDuration:	.asciz "setDuration:"
Lmn_setAutoreverses:	.asciz "setAutoreverses:"
Lmn_setRepeatCount:	.asciz "setRepeatCount:"
Lmn_setTimingFunction:	.asciz "setTimingFunction:"
Lmn_functionWithName:	.asciz "functionWithName:"
Lmn_addAnimationForKey:	.asciz "addAnimation:forKey:"
Lmn_setOverrideUserInterfaceStyle:	.asciz "setOverrideUserInterfaceStyle:"
Lmn_setTitleColorForState:	.asciz "setTitleColor:forState:"
Lmn_setCornerRadius:	.asciz "setCornerRadius:"
Lmn_setMasksToBounds:	.asciz "setMasksToBounds:"
Lmn_setShadowColor:	.asciz "setShadowColor:"
Lmn_setShadowOpacity:	.asciz "setShadowOpacity:"
Lmn_setShadowRadius:	.asciz "setShadowRadius:"
Lmn_colorWithRedGreenBlueAlpha:	.asciz "colorWithRed:green:blue:alpha:"
Lmn_setLocations:	.asciz "setLocations:"
Lmn_valueWithCGPoint:	.asciz "valueWithCGPoint:"
Lmn_defaultCenter:	.asciz "defaultCenter"
Lmn_addObserverSelectorNameObject:	.asciz "addObserver:selector:name:object:"
Lmn_cloudDidBecomeActive:	.asciz "cloudDidBecomeActive:"

// Selector references. The runtime rewrites each slot in place, name -> SEL.
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
Lsel_alloc:			.quad Lmn_alloc
Lsel_init:			.quad Lmn_init
Lsel_mainScreen:		.quad Lmn_mainScreen
Lsel_bounds:			.quad Lmn_bounds
Lsel_initWithFrame:		.quad Lmn_initWithFrame
Lsel_view:			.quad Lmn_view
Lsel_setBackgroundColor:	.quad Lmn_setBackgroundColor
Lsel_systemBackgroundColor:	.quad Lmn_systemBackgroundColor
Lsel_labelColor:		.quad Lmn_labelColor
Lsel_systemRedColor:		.quad Lmn_systemRedColor
Lsel_systemOrangeColor:		.quad Lmn_systemOrangeColor
Lsel_systemGreenColor:		.quad Lmn_systemGreenColor
Lsel_systemBlueColor:		.quad Lmn_systemBlueColor
Lsel_systemPurpleColor:		.quad Lmn_systemPurpleColor
Lsel_setText:			.quad Lmn_setText
Lsel_setTextAlignment:		.quad Lmn_setTextAlignment
Lsel_setTextColor:		.quad Lmn_setTextColor
Lsel_systemFontOfSize:		.quad Lmn_systemFontOfSize
Lsel_setFont:			.quad Lmn_setFont
Lsel_setAutoresizingMask:	.quad Lmn_setAutoresizingMask
Lsel_setFrame:			.quad Lmn_setFrame
Lsel_addSubview:		.quad Lmn_addSubview
Lsel_setRootViewController:	.quad Lmn_setRootViewController
Lsel_makeKeyAndVisible:		.quad Lmn_makeKeyAndVisible
Lsel_buttonWithType:		.quad Lmn_buttonWithType
Lsel_setTitleForState:		.quad Lmn_setTitleForState
Lsel_setMenu:			.quad Lmn_setMenu
Lsel_setShowsMenuAsPrimaryAction:	.quad Lmn_setShowsMenuAsPrimaryAction
Lsel_menuWithTitleChildren:	.quad Lmn_menuWithTitleChildren
Lsel_arrayWithObjectsCount:	.quad Lmn_arrayWithObjectsCount
Lsel_actionWithTitleImageIdentifierHandler:
				.quad Lmn_actionWithTitleImageIdentifierHandler
Lsel_systemPinkColor:	.quad Lmn_systemPinkColor
Lsel_systemTealColor:	.quad Lmn_systemTealColor
Lsel_systemIndigoColor:	.quad Lmn_systemIndigoColor
Lsel_whiteColor:	.quad Lmn_whiteColor
Lsel_blackColor:	.quad Lmn_blackColor
Lsel_CGColor:	.quad Lmn_CGColor
Lsel_colorWithAlphaComponent:	.quad Lmn_colorWithAlphaComponent
Lsel_layer:	.quad Lmn_layer
Lsel_addSublayer:	.quad Lmn_addSublayer
Lsel_setType:	.quad Lmn_setType
Lsel_setColors:	.quad Lmn_setColors
Lsel_setStartPoint:	.quad Lmn_setStartPoint
Lsel_setEndPoint:	.quad Lmn_setEndPoint
Lsel_numberWithDouble:	.quad Lmn_numberWithDouble
Lsel_animationWithKeyPath:	.quad Lmn_animationWithKeyPath
Lsel_setFromValue:	.quad Lmn_setFromValue
Lsel_setToValue:	.quad Lmn_setToValue
Lsel_setDuration:	.quad Lmn_setDuration
Lsel_setAutoreverses:	.quad Lmn_setAutoreverses
Lsel_setRepeatCount:	.quad Lmn_setRepeatCount
Lsel_setTimingFunction:	.quad Lmn_setTimingFunction
Lsel_functionWithName:	.quad Lmn_functionWithName
Lsel_addAnimationForKey:	.quad Lmn_addAnimationForKey
Lsel_setOverrideUserInterfaceStyle:	.quad Lmn_setOverrideUserInterfaceStyle
Lsel_setTitleColorForState:	.quad Lmn_setTitleColorForState
Lsel_setCornerRadius:	.quad Lmn_setCornerRadius
Lsel_setMasksToBounds:	.quad Lmn_setMasksToBounds
Lsel_setShadowColor:	.quad Lmn_setShadowColor
Lsel_setShadowOpacity:	.quad Lmn_setShadowOpacity
Lsel_setShadowRadius:	.quad Lmn_setShadowRadius
Lsel_colorWithRedGreenBlueAlpha:	.quad Lmn_colorWithRedGreenBlueAlpha
Lsel_setLocations:	.quad Lmn_setLocations
Lsel_valueWithCGPoint:	.quad Lmn_valueWithCGPoint
Lsel_defaultCenter:	.quad Lmn_defaultCenter
Lsel_addObserverSelectorNameObject:	.quad Lmn_addObserverSelectorNameObject
Lsel_cloudDidBecomeActive:	.quad Lmn_cloudDidBecomeActive

// Plain C strings: runtime-registered selectors, method type encodings, the
// runtime class name, the block signature, and the UTF-8 backing for the
// NSString literals. Each literal's end label lets the assembler compute its
// own length, so the CFString structures below cannot drift out of sync.
	.section __TEXT,__cstring,cstring_literals
Lstr_AppDelegate:	.asciz "AppDelegate"
Lstr_selDidFinish:	.asciz "application:didFinishLaunchingWithOptions:"
Lstr_selWindow:		.asciz "window"
Lstr_selSetWindow:	.asciz "setWindow:"
Lstr_selBecameActive:	.asciz "cloudDidBecomeActive:"
Lstr_typeDidFinish:	.asciz "B@:@@"		// BOOL (id, SEL, id, id)
Lstr_typeWindow:	.asciz "@@:"		// id   (id, SEL)
Lstr_typeSetWindow:	.asciz "v@:@"		// void (id, SEL, id)
Lstr_blockSig:		.asciz "v16@?0@8"	// void (^)(UIAction *)

Ltext_AppDelegate:	.asciz "AppDelegate"
Ltext_AppDelegate_e:
Ltext_Hello:		.asciz "Hello World"
Ltext_Hello_e:
Ltext_TextColor:	.asciz "Text Color"
Ltext_TextColor_e:
Ltext_Default:		.asciz "Default"
Ltext_Default_e:
Ltext_Red:		.asciz "Red"
Ltext_Red_e:
Ltext_Orange:		.asciz "Orange"
Ltext_Orange_e:
Ltext_Green:		.asciz "Green"
Ltext_Green_e:
Ltext_Blue:		.asciz "Blue"
Ltext_Blue_e:
Ltext_Purple:		.asciz "Purple"
Ltext_Purple_e:
Ltext_kpScaleX:	.asciz "transform.scale.x"
Ltext_kpScaleX_e:
Ltext_kpScaleY:	.asciz "transform.scale.y"
Ltext_kpScaleY_e:
Ltext_kpOpacity:	.asciz "opacity"
Ltext_kpOpacity_e:
Ltext_kpPositionX:	.asciz "position.x"
Ltext_kpPositionX_e:
Ltext_kpPositionY:	.asciz "position.y"
Ltext_kpPositionY_e:
Ltext_kpColors:	.asciz "colors"
Ltext_kpColors_e:
Ltext_kpStartPoint:	.asciz "startPoint"
Ltext_kpStartPoint_e:

// Constant NSStrings, laid out by hand in CoreFoundation's documented shape:
//   { isa, flags, cstring pointer, length }.  0x7c8 marks an 8-bit,
//   NUL-terminated, immortal constant string.
	.section __DATA,__cfstring
	.p2align 3
Lcfstr_AppDelegate:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_AppDelegate
	.quad	Ltext_AppDelegate_e - Ltext_AppDelegate - 1
Lcfstr_Hello:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Hello
	.quad	Ltext_Hello_e - Ltext_Hello - 1
Lcfstr_TextColor:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_TextColor
	.quad	Ltext_TextColor_e - Ltext_TextColor - 1
Lcfstr_Default:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Default
	.quad	Ltext_Default_e - Ltext_Default - 1
Lcfstr_Red:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Red
	.quad	Ltext_Red_e - Ltext_Red - 1
Lcfstr_Orange:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Orange
	.quad	Ltext_Orange_e - Ltext_Orange - 1
Lcfstr_Green:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Green
	.quad	Ltext_Green_e - Ltext_Green - 1
Lcfstr_Blue:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Blue
	.quad	Ltext_Blue_e - Ltext_Blue - 1
Lcfstr_Purple:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_Purple
	.quad	Ltext_Purple_e - Ltext_Purple - 1
Lcfstr_kpScaleX:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpScaleX
	.quad	Ltext_kpScaleX_e - Ltext_kpScaleX - 1
Lcfstr_kpScaleY:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpScaleY
	.quad	Ltext_kpScaleY_e - Ltext_kpScaleY - 1
Lcfstr_kpOpacity:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpOpacity
	.quad	Ltext_kpOpacity_e - Ltext_kpOpacity - 1
Lcfstr_kpPositionX:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpPositionX
	.quad	Ltext_kpPositionX_e - Ltext_kpPositionX - 1
Lcfstr_kpPositionY:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpPositionY
	.quad	Ltext_kpPositionY_e - Ltext_kpPositionY - 1
Lcfstr_kpColors:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpColors
	.quad	Ltext_kpColors_e - Ltext_kpColors - 1
Lcfstr_kpStartPoint:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Ltext_kpStartPoint
	.quad	Ltext_kpStartPoint_e - Ltext_kpStartPoint - 1

// The menu table: one 16-byte entry per colour, { title, &selref }.
// Field 1 is the address of the selector-reference slot rather than a SEL,
// because the runtime fixes those slots up at load time.
	.section __DATA,__const
	.p2align 3
Lcolors:
	.quad	Lcfstr_Default,	Lsel_labelColor
	.quad	Lcfstr_Red,	Lsel_systemRedColor
	.quad	Lcfstr_Orange,	Lsel_systemOrangeColor
	.quad	Lcfstr_Green,	Lsel_systemGreenColor
	.quad	Lcfstr_Blue,	Lsel_systemBlueColor
	.quad	Lcfstr_Purple,	Lsel_systemPurpleColor

// The cloud: one 32-byte entry per blob.
//   { r,g,b,peak alpha }  { r,g,b,peak alpha of the colour it fades toward }
//   x%, y%, width%, height%, period
// Positions and sizes are percentages, so the layout holds on any screen.
// Width and height are both fractions of the screen *width*, which keeps the
// blobs elliptical instead of stretching with the aspect ratio. Several are
// wider than 100%, so their edges fall outside the screen and the cloud reads
// as continuous rather than as a group of circles.
//
// Components are 8-bit, which means the palette is not limited to the system
// colours - the first two rows are systemIndigo/systemPurple and
// systemTeal/systemBlue exactly, and the rest reach past them into cyan,
// mint, magenta, amber and coral.
	.p2align 3
Lblobs:
	.byte	88, 86, 214, 110		// systemIndigo
	.byte	175, 82, 222, 110		// systemPurple
	.short	48, 24, 200, 155
	.short	17, 0
	.space	12

	.byte	48, 176, 199, 105		// systemTeal
	.byte	0, 122, 255, 105		// systemBlue
	.short	52, 78, 195, 150
	.short	21, 0
	.space	12

	.byte	255, 45, 85, 140		// systemPink
	.byte	214, 44, 164, 140		// magenta
	.short	22, 20, 112, 96
	.short	13, 0
	.space	12

	.byte	0, 122, 255, 135		// systemBlue
	.byte	50, 173, 230, 135		// cyan
	.short	80, 32, 120, 102
	.short	15, 0
	.space	12

	.byte	175, 82, 222, 125		// systemPurple
	.byte	88, 86, 214, 125		// systemIndigo
	.short	44, 52, 132, 118
	.short	19, 0
	.space	12

	.byte	0, 199, 190, 130		// mint
	.byte	48, 176, 199, 130		// systemTeal
	.short	18, 66, 108, 94
	.short	14, 0
	.space	12

	.byte	255, 149, 0, 132		// systemOrange
	.byte	255, 45, 85, 132		// systemPink
	.short	84, 74, 104, 90
	.short	16, 0
	.space	12

	.byte	255, 204, 0, 120		// amber
	.byte	255, 111, 74, 120		// coral
	.short	64, 56, 90, 80
	.short	12, 0
	.space	12

// The animations every blob shares: one 32-byte entry per animation.
//   { key path, fromValue, toValue, seconds added to the blob's period }
// Scale x and y run at different rates, so a blob is never quite the same
// ellipse twice - that is what reads as the shape slowly changing.
	.p2align 3
LanimTable:
	.quad	Lcfstr_kpScaleX
	.double	0.72
	.double	1.38
	.short	0
	.space	6
	.quad	Lcfstr_kpScaleY
	.double	1.34
	.double	0.78
	.short	3
	.space	6
	.quad	Lcfstr_kpOpacity
	.double	0.45
	.double	1.00
	.short	1
	.space	6

// Block descriptor, shared by all six literals:
//   { reserved, literal size, signature, layout }
	.p2align 3
Lblock_descriptor:
	.quad	0
	.quad	BLOCK_SIZE
	.quad	Lstr_blockSig
	.quad	0

// The six block literals, laid out back to back so index i is at
// Lblocks + i * BLOCK_SIZE.
	.section __DATA,__data
	.p2align 3
Lblocks:
	COLOR_BLOCK 0
	COLOR_BLOCK 1
	COLOR_BLOCK 2
	COLOR_BLOCK 3
	COLOR_BLOCK 4
	COLOR_BLOCK 5

	.section __TEXT,__literal8,8byte_literals
	.p2align 3
Ldbl_fontSize:	.double 44.0
Ldbl_255:	.double 255.0
Ldbl_mid:	.double 0.45

	.section __DATA,__data
	.p2align 3
LgWindow:	.quad 0
LgLabel:	.quad 0
LgButton:	.quad 0
LgDelegate:	.quad 0
LgLocations:	.quad 0
LgBlobLayers:	.space 8 * NBLOBS

// Tells the Objective-C runtime this image contains ObjC metadata to fix up.
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
L_OBJC_IMAGE_INFO:
	.long	0
	.long	64
