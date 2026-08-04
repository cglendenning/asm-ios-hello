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

.macro	SELREF name			// -> x1 = SEL
	adrp	x8, Lsel_\name@PAGE
	ldr	x1, [x8, Lsel_\name@PAGEOFF]
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
// Builds the entire UI: window -> view controller -> label.
//===========================================================================
	.p2align 2
LAppDelegate_didFinishLaunching:
	stp	x29, x30, [sp, #-80]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	d8,  d9,  [sp, #48]		// screen bounds must survive the calls
	stp	d10, d11, [sp, #64]

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
	mov	x19, x0
	adrp	x8, LgWindow@PAGE		// the window is owned for the life of
	str	x19, [x8, LgWindow@PAGEOFF]	// the process, so it is simply retained

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

	// UILabel *label = [[UILabel alloc] initWithFrame:bounds];
	CLASSREF UILabel
	MSGSEND	alloc
	fmov	d0, d8
	fmov	d1, d9
	fmov	d2, d10
	fmov	d3, d11
	MSGSEND	initWithFrame
	mov	x22, x0

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

	// [root addSubview:label];
	mov	x0, x21
	mov	x2, x22
	MSGSEND	addSubview

	// [window setRootViewController:vc];
	mov	x0, x19
	mov	x2, x20
	MSGSEND	setRootViewController

	// [window makeKeyAndVisible];
	mov	x0, x19
	MSGSEND	makeKeyAndVisible

	mov	w0, #1				// return YES
	ldp	d10, d11, [sp, #64]
	ldp	d8,  d9,  [sp, #48]
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
	adrp	x8, LgWindow@PAGE
	ldr	x0, [x8, LgWindow@PAGEOFF]
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
Lmn_setText:			.asciz "setText:"
Lmn_setTextAlignment:		.asciz "setTextAlignment:"
Lmn_setTextColor:		.asciz "setTextColor:"
Lmn_systemFontOfSize:		.asciz "systemFontOfSize:"
Lmn_setFont:			.asciz "setFont:"
Lmn_setAutoresizingMask:	.asciz "setAutoresizingMask:"
Lmn_addSubview:			.asciz "addSubview:"
Lmn_setRootViewController:	.asciz "setRootViewController:"
Lmn_makeKeyAndVisible:		.asciz "makeKeyAndVisible"

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
Lsel_setText:			.quad Lmn_setText
Lsel_setTextAlignment:		.quad Lmn_setTextAlignment
Lsel_setTextColor:		.quad Lmn_setTextColor
Lsel_systemFontOfSize:		.quad Lmn_systemFontOfSize
Lsel_setFont:			.quad Lmn_setFont
Lsel_setAutoresizingMask:	.quad Lmn_setAutoresizingMask
Lsel_addSubview:		.quad Lmn_addSubview
Lsel_setRootViewController:	.quad Lmn_setRootViewController
Lsel_makeKeyAndVisible:		.quad Lmn_makeKeyAndVisible

// Plain C strings: runtime-registered selectors, method type encodings,
// the runtime class name, and the UTF-8 backing for the NSString literals.
	.section __TEXT,__cstring,cstring_literals
Lstr_AppDelegate:	.asciz "AppDelegate"
Lstr_Hello:		.asciz "Hello World"
Lstr_selDidFinish:	.asciz "application:didFinishLaunchingWithOptions:"
Lstr_selWindow:		.asciz "window"
Lstr_selSetWindow:	.asciz "setWindow:"
Lstr_typeDidFinish:	.asciz "B@:@@"		// BOOL (id, SEL, id, id)
Lstr_typeWindow:	.asciz "@@:"		// id   (id, SEL)
Lstr_typeSetWindow:	.asciz "v@:@"		// void (id, SEL, id)

// Constant NSStrings, laid out by hand in CoreFoundation's documented shape:
//   { isa, flags, cstring pointer, length }.  0x7c8 marks an 8-bit,
//   NUL-terminated, immortal constant string.
	.section __DATA,__cfstring
	.p2align 3
Lcfstr_AppDelegate:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Lstr_AppDelegate
	.quad	11
Lcfstr_Hello:
	.quad	___CFConstantStringClassReference
	.long	0x7c8
	.space	4
	.quad	Lstr_Hello
	.quad	11

	.section __TEXT,__literal8,8byte_literals
	.p2align 3
Ldbl_fontSize:	.double 44.0

	.section __DATA,__data
	.p2align 3
LgWindow:	.quad 0

// Tells the Objective-C runtime this image contains ObjC metadata to fix up.
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
L_OBJC_IMAGE_INFO:
	.long	0
	.long	64
