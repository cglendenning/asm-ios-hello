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

// Plain C strings: runtime-registered selectors, method type encodings, the
// runtime class name, the block signature, and the UTF-8 backing for the
// NSString literals. Each literal's end label lets the assembler compute its
// own length, so the CFString structures below cannot drift out of sync.
	.section __TEXT,__cstring,cstring_literals
Lstr_AppDelegate:	.asciz "AppDelegate"
Lstr_selDidFinish:	.asciz "application:didFinishLaunchingWithOptions:"
Lstr_selWindow:		.asciz "window"
Lstr_selSetWindow:	.asciz "setWindow:"
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

	.section __DATA,__data
	.p2align 3
LgWindow:	.quad 0
LgLabel:	.quad 0
LgButton:	.quad 0

// Tells the Objective-C runtime this image contains ObjC metadata to fix up.
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
L_OBJC_IMAGE_INFO:
	.long	0
	.long	64
