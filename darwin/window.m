// 15 august 2015
#import "uipriv_darwin.h"

#define defaultStyleMask (NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask)

struct uiWindow {
	uiDarwinControl c;
	NSWindow *window;
	uiControl *child;
	int margined;
	int (*onClosing)(uiWindow *, void *);
	void *onClosingData;
	uiprivSingleChildConstraints constraints;
	void (*onContentSizeChanged)(uiWindow *, void *);
	void *onContentSizeChangedData;
	BOOL suppressSizeChanged;
	void (*onFocusChanged)(uiWindow*, void *);
	void *onFocusChangedData;
	void (*onPositionChanged)(uiWindow*, void *);
	void *onPositionChangedData;
	BOOL suppressPositionChanged;
	int fullscreen;
	int borderless;
	int resizeable;
	int focused;
	NSScrollView *magnifier;
	NSView *magnifiedContent;
	double minMagnification;
	double maxMagnification;
};

// The view libui's child is constrained against. With magnification enabled
// this is the magnifying scroll view's document view, so every constraint stays
// inside the magnified coordinate system and none crosses the clip view's
// scaled bounds.
static NSView *windowContentContainer(uiWindow *w)
{
	if (w->magnifier != nil)
		return w->magnifiedContent;
	return [w->window contentView];
}

// The document view keeps the window's unmagnified content size, so magnifying
// reveals part of an unchanged layout and scrolls, rather than reflowing it.
static void resizeMagnifiedContent(uiWindow *w)
{
	NSRect frame;

	if (w->magnifier == nil)
		return;
	frame = [w->magnifier frame];
	frame.origin = NSZeroPoint;
	[w->magnifiedContent setFrame:frame];
}


@implementation uiprivNSWindow

- (void)uiprivDoMove:(NSEvent *)initialEvent
{
	uiprivDoManualMove(self, initialEvent);
}

- (void)uiprivDoResize:(NSEvent *)initialEvent on:(uiWindowResizeEdge)edge
{
	uiprivDoManualResize(self, initialEvent, edge);
}

- (id)initWithWidth:(CGFloat)width height:(CGFloat)height uiWindow:(uiWindow *)w
{
	self = [super initWithContentRect:NSMakeRect(0, 0, width, height)
		styleMask:defaultStyleMask
		backing:NSBackingStoreBuffered
		defer:YES];

	if (self) {
		self->window = w;

		// Do NOT release when closed, we manually do so by calling
		// uiWindowDestroy()
		[self setReleasedWhenClosed:NO];

		[self setDelegate:self];
	}
	return self;
}

- (BOOL)windowShouldClose:(id)sender
{
	uiWindow *w = self->window;

	if ((*(w->onClosing))(w, w->onClosingData))
		uiControlDestroy(uiControl(w));
	return NO;
}

- (void)windowDidResize:(NSNotification *)note
{
	uiWindow *w = self->window;

	resizeMagnifiedContent(w);
	if (!w->suppressSizeChanged)
		(*(w->onContentSizeChanged))(w, w->onContentSizeChangedData);
}

- (void)windowDidMove:(NSNotification *)note
{
	uiWindow *w = self->window;

	if (!w->suppressPositionChanged)
		(*(w->onPositionChanged))(w, w->onPositionChangedData);
}

- (void)windowDidEnterFullScreen:(NSNotification *)note
{
	uiWindow *w = self->window;

	if (!w->suppressSizeChanged)
		w->fullscreen = 1;
}

- (void)windowDidExitFullScreen:(NSNotification *)note
{
	uiWindow *w = self->window;

	if (!w->suppressSizeChanged)
		w->fullscreen = 0;
}

- (void)windowDidBecomeKey:(NSNotification *)note
{
	uiWindow *w = self->window;

	w->focused = 1;
	(*(w->onFocusChanged))(w, w->onFocusChangedData);
}

- (void)windowDidResignKey:(NSNotification *)note
{
	uiWindow *w = self->window;

	w->focused = 0;
	(*(w->onFocusChanged))(w, w->onFocusChangedData);
}

- (uiWindow *)window
{
	return self->window;
}

@end

static void removeConstraints(uiWindow *w)
{
	NSView *cv;

	cv = windowContentContainer(w);
	uiprivSingleChildConstraintsRemove(&(w->constraints), cv);
}

static void uiWindowDestroy(uiControl *c)
{
	uiWindow *w = uiWindow(c);

	// hide the window
	[w->window orderOut:w->window];
	removeConstraints(w);
	if (w->child != NULL) {
		uiControlSetParent(w->child, NULL);
		uiDarwinControlSetSuperview(uiDarwinControl(w->child), nil);
		uiControlDestroy(w->child);
	}
	[w->window release];
	uiFreeControl(uiControl(w));
}

uiDarwinControlDefaultHandle(uiWindow, window)

uiControl *uiWindowParent(uiControl *c)
{
	return NULL;
}

void uiWindowSetParent(uiControl *c, uiControl *parent)
{
	uiUserBugCannotSetParentOnToplevel("uiWindow");
}

static int uiWindowToplevel(uiControl *c)
{
	return 1;
}

static int uiWindowVisible(uiControl *c)
{
	uiWindow *w = uiWindow(c);

	return [w->window isVisible];
}

static void uiWindowShow(uiControl *c)
{
	uiWindow *w = uiWindow(c);

	[w->window makeKeyAndOrderFront:w->window];
}

static void uiWindowHide(uiControl *c)
{
	uiWindow *w = uiWindow(c);

	[w->window orderOut:w->window];
}

uiDarwinControlDefaultEnabled(uiWindow, window)
uiDarwinControlDefaultEnable(uiWindow, window)
uiDarwinControlDefaultDisable(uiWindow, window)

static void uiWindowSyncEnableState(uiDarwinControl *c, int enabled)
{
	uiWindow *w = uiWindow(c);

	if (uiDarwinShouldStopSyncEnableState(uiDarwinControl(w), enabled))
		return;
	if (w->child != NULL)
		uiDarwinControlSyncEnableState(uiDarwinControl(w->child), enabled);
}

static void uiWindowSetSuperview(uiDarwinControl *c, NSView *superview)
{
	// TODO
}

static void windowRelayout(uiWindow *w)
{
	NSView *childView;
	NSView *contentView;

	removeConstraints(w);
	if (w->child == NULL)
		return;
	childView = (NSView *) uiControlHandle(w->child);
	contentView = windowContentContainer(w);
	uiprivSingleChildConstraintsEstablish(&(w->constraints),
		contentView, childView,
		uiDarwinControlHugsTrailingEdge(uiDarwinControl(w->child)),
		uiDarwinControlHugsBottom(uiDarwinControl(w->child)),
		w->margined,
		@"uiWindow");
}

uiDarwinControlDefaultHugsTrailingEdge(uiWindow, window)
uiDarwinControlDefaultHugsBottom(uiWindow, window)

static void uiWindowChildEdgeHuggingChanged(uiDarwinControl *c)
{
	uiWindow *w = uiWindow(c);

	windowRelayout(w);
}

// TODO
uiDarwinControlDefaultHuggingPriority(uiWindow, window)
uiDarwinControlDefaultSetHuggingPriority(uiWindow, window)
// end TODO

static void uiWindowChildVisibilityChanged(uiDarwinControl *c)
{
	uiWindow *w = uiWindow(c);

	windowRelayout(w);
}

char *uiWindowTitle(uiWindow *w)
{
	return uiDarwinNSStringToText([w->window title]);
}

void uiWindowSetTitle(uiWindow *w, const char *title)
{
	[w->window setTitle:uiprivToNSString(title)];
}

void uiWindowPosition(uiWindow *w, int *x, int *y)
{
	NSRect screen;
	NSRect window;
	int screenHeightSansMenu;

	screen = [[w->window screen] visibleFrame];
	// Visible screen (no menu, no dock) + dock height
	screenHeightSansMenu = screen.size.height + screen.origin.y;

	window = [w->window frame];
	*x = window.origin.x;
	*y = screenHeightSansMenu - window.origin.y - window.size.height;
}

void uiWindowSetPosition(uiWindow *w, int x, int y)
{
	NSRect screen;
	int screenHeightSansMenu;

	screen = [[w->window screen] visibleFrame];
	// Visible screen (no menu, no dock) + dock height
	screenHeightSansMenu = screen.size.height + screen.origin.y;

	y = screenHeightSansMenu - y;

	w->suppressPositionChanged = YES;
	[w->window setFrameTopLeftPoint:NSMakePoint(x, y)];
	w->suppressPositionChanged = NO;
}

void uiWindowOnPositionChanged(uiWindow *w, void (*f)(uiWindow *, void *), void *data)
{
	w->onPositionChanged = f;
	w->onPositionChangedData = data;
}

void uiWindowContentSize(uiWindow *w, int *width, int *height)
{
	NSRect r;

	r = [w->window contentRectForFrameRect:[w->window frame]];
	*width = r.size.width;
	*height = r.size.height;
}

void uiWindowSetContentSize(uiWindow *w, int width, int height)
{
	w->suppressSizeChanged = YES;
	[w->window setContentSize:NSMakeSize(width, height)];
	w->suppressSizeChanged = NO;
}

int uiWindowFullscreen(uiWindow *w)
{
	return w->fullscreen;
}

void uiWindowSetFullscreen(uiWindow *w, int fullscreen)
{
	if (w->fullscreen && fullscreen)
		return;
	if (!w->fullscreen && !fullscreen)
		return;
	w->fullscreen = fullscreen;
	if (w->fullscreen && w->borderless)		// borderless doesn't play nice with fullscreen; don't toggle while borderless
		return;
	w->suppressSizeChanged = YES;
	[w->window toggleFullScreen:w->window];
	w->suppressSizeChanged = NO;
	if (!w->fullscreen && w->borderless)		// borderless doesn't play nice with fullscreen; restore borderless after removing
		[w->window setStyleMask:NSBorderlessWindowMask];
}

void uiWindowOnContentSizeChanged(uiWindow *w, void (*f)(uiWindow *, void *), void *data)
{
	w->onContentSizeChanged = f;
	w->onContentSizeChangedData = data;
}

void uiWindowOnFocusChanged(uiWindow *w, void (*f)(uiWindow *, void *), void *data)
{
	w->onFocusChanged = f;
	w->onFocusChangedData = data;
}

int uiWindowFocused(uiWindow *w)
{
	return w->focused;
}

void uiWindowFocus(uiWindow *w)
{
	// NSRunningApplication is used rather than -[NSApplication activateIgnoringOtherApps:]
	// because the latter is deprecated as of macOS 14.
	[[NSRunningApplication currentApplication]
		activateWithOptions:NSApplicationActivateIgnoringOtherApps];
	[w->window makeKeyAndOrderFront:w->window];
}

void uiWindowOnClosing(uiWindow *w, int (*f)(uiWindow *, void *), void *data)
{
	w->onClosing = f;
	w->onClosingData = data;
}

int uiWindowBorderless(uiWindow *w)
{
	return w->borderless;
}

void uiWindowSetBorderless(uiWindow *w, int borderless)
{
	w->borderless = borderless;
	if (w->borderless) {
		// borderless doesn't play nice with fullscreen; wait for later
		if (!w->fullscreen)
			[w->window setStyleMask:NSBorderlessWindowMask];
	} else {
		[w->window setStyleMask:defaultStyleMask];
		// borderless doesn't play nice with fullscreen; restore state
		if (w->fullscreen) {
			w->suppressSizeChanged = YES;
			[w->window toggleFullScreen:w->window];
			w->suppressSizeChanged = NO;
		}
	}
}

void uiWindowSetChild(uiWindow *w, uiControl *child)
{
	if (w->child != NULL) {
		uiDarwinControlSetSuperview(uiDarwinControl(w->child), nil);
		uiControlSetParent(w->child, NULL);
	}
	w->child = child;
	if (w->child != NULL) {
		uiControlSetParent(w->child, uiControl(w));
		uiDarwinControlSetSuperview(uiDarwinControl(w->child), windowContentContainer(w));
		uiDarwinControlSyncEnableState(uiDarwinControl(w->child), uiControlEnabledToUser(uiControl(w)));
	}
	windowRelayout(w);
}

void uiDarwinWindowSetMagnificationEnabled(uiWindow *w, int enabled)
{
	NSView *content;

	if ((w->magnifier != nil) == (enabled != 0))
		return;

	if (enabled) {
		NSScrollView *sv;
		NSView *document;

		content = [w->window contentView];
		sv = [[NSScrollView alloc] initWithFrame:[content bounds]];
		document = [[NSView alloc] initWithFrame:[content bounds]];

		[sv setAllowsMagnification:YES];
		[sv setMinMagnification:w->minMagnification];
		[sv setMaxMagnification:w->maxMagnification];
		[sv setHasHorizontalScroller:YES];
		[sv setHasVerticalScroller:YES];
		[sv setAutohidesScrollers:YES];
		[sv setBorderType:NSNoBorder];
		[sv setDrawsBackground:NO];
		[sv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
		[sv setDocumentView:document];
		[document release];

		removeConstraints(w);
		if (w->child != NULL)
			uiDarwinControlSetSuperview(uiDarwinControl(w->child), nil);
		w->magnifier = sv;
		w->magnifiedContent = document;
		[w->window setContentView:sv];
		[sv release];
		resizeMagnifiedContent(w);
	} else {
		removeConstraints(w);
		if (w->child != NULL)
			uiDarwinControlSetSuperview(uiDarwinControl(w->child), nil);
		w->magnifier = nil;
		w->magnifiedContent = nil;
		content = [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
		[w->window setContentView:content];
	}

	if (w->child != NULL)
		uiDarwinControlSetSuperview(uiDarwinControl(w->child), windowContentContainer(w));
	windowRelayout(w);
}

int uiDarwinWindowMagnificationEnabled(uiWindow *w)
{
	return w->magnifier != nil;
}

void uiDarwinWindowSetMagnification(uiWindow *w, double magnification)
{
	if (w->magnifier == nil)
		uiprivUserBug("You must call uiDarwinWindowSetMagnificationEnabled() before magnifying a uiWindow.");
	if (magnification < w->minMagnification)
		magnification = w->minMagnification;
	if (magnification > w->maxMagnification)
		magnification = w->maxMagnification;
	[w->magnifier setMagnification:magnification];
}

double uiDarwinWindowMagnification(uiWindow *w)
{
	if (w->magnifier == nil)
		return 1.0;
	return [w->magnifier magnification];
}

void uiDarwinWindowSetMagnificationLimits(uiWindow *w, double minimum, double maximum)
{
	if (minimum <= 0 || maximum < minimum)
		uiprivUserBug("Invalid magnification limits %g and %g.", minimum, maximum);
	w->minMagnification = minimum;
	w->maxMagnification = maximum;
	if (w->magnifier != nil) {
		[w->magnifier setMinMagnification:minimum];
		[w->magnifier setMaxMagnification:maximum];
	}
}

int uiWindowMargined(uiWindow *w)
{
	return w->margined;
}

void uiWindowSetMargined(uiWindow *w, int margined)
{
	w->margined = margined;
	uiprivSingleChildConstraintsSetMargined(&(w->constraints), w->margined);
}

int uiWindowResizeable(uiWindow *w)
{
	return w->resizeable;
}

void uiWindowSetResizeable(uiWindow *w, int resizeable)
{
	w->resizeable = resizeable;
	if(resizeable) {
		[w->window setStyleMask:[w->window styleMask] | NSResizableWindowMask];
	} else {
		[w->window setStyleMask:[w->window styleMask] & ~NSResizableWindowMask];
	}
}

static int defaultOnClosing(uiWindow *w, void *data)
{
	return 0;
}

static void defaultOnPositionContentSizeChanged(uiWindow *w, void *data)
{
	// do nothing
}

static void defaultOnFocusChanged(uiWindow *w, void *data)
{
	// do nothing
}

uiWindow *uiNewWindow(const char *title, int width, int height, int hasMenubar)
{
	uiWindow *w;

	uiprivFinalizeMenus();

	uiDarwinNewControl(uiWindow, w);

	w->window = [[uiprivNSWindow alloc] initWithWidth:(CGFloat)width
		height:(CGFloat)height
		uiWindow:w];
	uiWindowSetTitle(w, title);
	uiWindowSetResizeable(w, 1);

	w->minMagnification = 0.75;
	w->maxMagnification = 2.0;

	uiWindowOnClosing(w, defaultOnClosing, NULL);
	uiWindowOnFocusChanged(w, defaultOnFocusChanged, NULL);
	uiWindowOnContentSizeChanged(w, defaultOnPositionContentSizeChanged, NULL);
	uiWindowOnPositionChanged(w, defaultOnPositionContentSizeChanged, NULL);

	return w;
}

// utility function for menus
uiWindow *uiprivWindowFromNSWindow(NSWindow *w)
{
	if (w == nil)
		return NULL;
	// Apparently we might get called with a "fake" window prior to us creating
	// any window - at least this is what the previous comments here suggested.
	if (![w isKindOfClass:[uiprivNSWindow class]])
		return NULL;

	return [(uiprivNSWindow *)w window];
}
