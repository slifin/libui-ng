// 28 april 2015
#import "uipriv_darwin.h"

struct uiMenu {
	NSMenu *menu;
	NSMenuItem *item;
};

struct uiMenuItem {
	uiprivMenuItem *item;
	int type;
	int role;
	BOOL disabled;
	void (*onClicked)(uiMenuItem *, uiWindow *, void *);
	void *onClickedData;
};

enum uiprivMenuItemType {
	typeRegular,
	typeCheckbox,
	typeQuit,
	typePreferences,
	typeAbout,
	typeRole,
};

struct uiprivMenuItemRoleInfo {
	const char *title;
	SEL action;
	NSString *key;
	NSEventModifierFlags modifiers;
	BOOL edit;
};

// Which Edit commands the program put in a menu. AppKit owns a command's key
// once it has a menu item for it, but a program that registers only some of
// them must keep the fallback for the rest.
static NSMutableSet *editRoleActions = nil;

static struct uiprivMenuItemRoleInfo roleInfo(uiDarwinMenuItemRole role)
{
	struct uiprivMenuItemRoleInfo info;

	info.title = "";
	info.action = NULL;
	info.key = @"";
	info.modifiers = 0;
	info.edit = NO;

	switch (role) {
	case uiDarwinMenuItemRoleClose:
		info.title = "Close";
		info.action = @selector(performClose:);
		info.key = @"w";
		info.modifiers = NSCommandKeyMask;
		break;
	case uiDarwinMenuItemRoleMinimize:
		info.title = "Minimize";
		info.action = @selector(performMiniaturize:);
		info.key = @"m";
		info.modifiers = NSCommandKeyMask;
		break;
	case uiDarwinMenuItemRoleZoom:
		info.title = "Zoom";
		info.action = @selector(performZoom:);
		break;
	case uiDarwinMenuItemRoleBringAllToFront:
		info.title = "Bring All to Front";
		info.action = @selector(arrangeInFront:);
		break;
	case uiDarwinMenuItemRoleUndo:
		info.title = "Undo";
		info.action = @selector(undo:);
		info.key = @"z";
		info.modifiers = NSCommandKeyMask;
		info.edit = YES;
		break;
	case uiDarwinMenuItemRoleRedo:
		info.title = "Redo";
		info.action = @selector(redo:);
		info.key = @"z";
		info.modifiers = NSCommandKeyMask | NSShiftKeyMask;
		info.edit = YES;
		break;
	case uiDarwinMenuItemRoleCut:
		info.title = "Cut";
		info.action = @selector(cut:);
		info.key = @"x";
		info.modifiers = NSCommandKeyMask;
		info.edit = YES;
		break;
	case uiDarwinMenuItemRoleCopy:
		info.title = "Copy";
		info.action = @selector(copy:);
		info.key = @"c";
		info.modifiers = NSCommandKeyMask;
		info.edit = YES;
		break;
	case uiDarwinMenuItemRolePaste:
		info.title = "Paste";
		info.action = @selector(paste:);
		info.key = @"v";
		info.modifiers = NSCommandKeyMask;
		info.edit = YES;
		break;
	case uiDarwinMenuItemRoleSelectAll:
		info.title = "Select All";
		info.action = @selector(selectAll:);
		info.key = @"a";
		info.modifiers = NSCommandKeyMask;
		info.edit = YES;
		break;
	default:
		uiprivUserBug("Unknown uiDarwinMenuItemRole %d.", (int) role);
		break;
	}

	return info;
}

static NSEventModifierFlags toNSModifiers(uiModifiers modifiers)
{
	NSEventModifierFlags flags;

	flags = 0;
	if ((modifiers & uiModifierCtrl) != 0)
		flags |= NSControlKeyMask;
	if ((modifiers & uiModifierAlt) != 0)
		flags |= NSAlternateKeyMask;
	if ((modifiers & uiModifierShift) != 0)
		flags |= NSShiftKeyMask;
	if ((modifiers & uiModifierSuper) != 0)
		flags |= NSCommandKeyMask;
	return flags;
}

@interface uiprivMenu : NSMenu {
@public
	uiMenu *menu;
}
@end

@implementation uiprivMenu
- (id)initWithTitle:(NSString *)title uiMenu:(uiMenu *)m
{
	self = [super initWithTitle:title];
	if (self) {
		self->menu = m;
	}
	return self;
}
@end

@implementation uiprivMenuItem
- (id)initWithTitle:(NSString *)title uiMenuItem:(uiMenuItem *)i
{
	self = [super initWithTitle:title action:@selector(onClicked:) keyEquivalent:@""];
	if (self) {
		self->item = i;

		[self setTarget:self];
	}
	return self;
}

// Standard AppKit commands are dispatched through the responder chain, so the
// target stays nil and AppKit validates the item against the responder that
// implements the action.
- (id)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key modifiers:(NSEventModifierFlags)modifiers uiMenuItem:(uiMenuItem *)i
{
	self = [super initWithTitle:title action:action keyEquivalent:key];
	if (self) {
		self->item = i;

		[self setKeyEquivalentModifierMask:modifiers];
		[self setTarget:nil];
	}
	return self;
}

- (IBAction)onClicked:(id)sender
{
	// System menu item (Quit/Preferences/About) that has not been user created (yet)
	if (self->item == NULL) {
		uiprivImplBug("Clicked nonexistent uiMenuItem which should be impossible");
		return;
	}

	switch (self->item->type) {
	case typeQuit:
		if (uiprivShouldQuit())
			uiQuit();
		return;
	case typeCheckbox:
		uiMenuItemSetChecked(self->item, !uiMenuItemChecked(self->item));
		// fall through
	default:
		// use the key window as the source of the menu event; it's the active window
		(*(self->item->onClicked))(self->item, uiprivWindowFromNSWindow([uiprivNSApp() keyWindow]),
			self->item->onClickedData);
		break;
	}
}

- (void)setUiMenuItem:(uiMenuItem *)i
{
	self->item = i;
}

// Manually enable/disable menu items
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	uiprivMenuItem *i = (uiprivMenuItem *)menuItem;

	// System menu item (Quit/Preferences/About) that has not been user created (yet)
	if (i->item == NULL)
		return NO;

	return !i->item->disabled;
}

@end

@implementation uiprivMenuManager

- (id)init
{
	self = [super init];
	if (self) {
		self->hasQuit = NO;
		self->hasPreferences = NO;
		self->hasAbout = NO;
		self->finalized = NO;
	}
	return self;
}

- (BOOL)finalized
{
	return self->finalized;
}

- (void)finalize
{
	self->finalized = YES;
}

- (void)dealloc
{
	uiprivUninitMenus();
	[super dealloc];
}

- (void)register:(enum uiprivMenuItemType)type
{
	switch (type) {
	case typeQuit:
		if (self->hasQuit)
			uiprivUserBug("You can't have multiple Quit menu items in one program.");
		self->hasQuit = YES;
		break;
	case typePreferences:
		if (self->hasPreferences)
			uiprivUserBug("You can't have multiple Preferences menu items in one program.");
		self->hasPreferences = YES;
		break;
	case typeAbout:
		if (self->hasAbout)
			uiprivUserBug("You can't have multiple About menu items in one program.");
		self->hasAbout = YES;
		break;
	}
}

// Cocoa constructs the default application menu by hand for each program; that's what MainMenu.[nx]ib does
- (void)buildApplicationMenu:(NSMenu *)menubar
{
	NSString *appName;
	NSMenuItem *appMenuItem;
	NSMenu *appMenu;
	NSMenuItem *item;
	uiprivMenuItem *pitem;
	NSString *title;
	NSMenu *servicesMenu;

	// note: no need to call setAppleMenu: on this anymore; see https://developer.apple.com/library/mac/releasenotes/AppKit/RN-AppKitOlderNotes/#X10_6Notes
	appName = [[NSProcessInfo processInfo] processName];
	appMenuItem = [[[NSMenuItem alloc] initWithTitle:appName action:NULL keyEquivalent:@""] autorelease];
	appMenu = [[[NSMenu alloc] initWithTitle:appName] autorelease];
	[appMenuItem setSubmenu:appMenu];
	[menubar addItem:appMenuItem];
	self.applicationMenuItem = appMenuItem;

	// first is About
	title = [@"About " stringByAppendingString:appName];
	pitem = [[[uiprivMenuItem alloc] initWithTitle:title uiMenuItem:NULL] autorelease];
	[appMenu addItem:pitem];
	self.aboutItem = pitem;

	[appMenu addItem:[NSMenuItem separatorItem]];

	// next is Preferences
	pitem = [[[uiprivMenuItem alloc] initWithTitle:@"Preferences\u2026" uiMenuItem:NULL] autorelease];
	[pitem setKeyEquivalent:@","];
	[pitem setKeyEquivalentModifierMask:NSCommandKeyMask];
	[appMenu addItem:pitem];
	self.preferencesItem = pitem;

	[appMenu addItem:[NSMenuItem separatorItem]];

	// next is Services
	item = [[[NSMenuItem alloc] initWithTitle:@"Services" action:NULL keyEquivalent:@""] autorelease];
	servicesMenu = [[[NSMenu alloc] initWithTitle:@"Services"] autorelease];
	[item setSubmenu:servicesMenu];
	[uiprivNSApp() setServicesMenu:servicesMenu];
	[appMenu addItem:item];

	[appMenu addItem:[NSMenuItem separatorItem]];

	// next are the three hiding options
	title = [@"Hide " stringByAppendingString:appName];
	item = [[[NSMenuItem alloc] initWithTitle:title action:@selector(hide:) keyEquivalent:@"h"] autorelease];
	// the .xib file says they go to -1 ("First Responder", which sounds wrong...)
	// to do that, we simply leave the target as nil
	[appMenu addItem:item];
	self.hideItem = item;
	item = [[[NSMenuItem alloc] initWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"] autorelease];
	[item setKeyEquivalentModifierMask:(NSAlternateKeyMask | NSCommandKeyMask)];
	[appMenu addItem:item];
	item = [[[NSMenuItem alloc] initWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""] autorelease];
	[appMenu addItem:item];

	[appMenu addItem:[NSMenuItem separatorItem]];

	// and finally Quit
	// DON'T use @selector(terminate:) as the action; we handle termination ourselves
	title = [@"Quit " stringByAppendingString:appName];
	pitem = [[[uiprivMenuItem alloc] initWithTitle:title uiMenuItem:NULL] autorelease];
	[pitem setKeyEquivalent:@"q"];
	[pitem setKeyEquivalentModifierMask:NSCommandKeyMask];
	[appMenu addItem:pitem];
	self.quitItem = pitem;
}

- (void)setApplicationName:(NSString *)name
{
	if ([name length] == 0)
		return;
	[self.applicationMenuItem setTitle:name];
	[[self.applicationMenuItem submenu] setTitle:name];
	[self.aboutItem setTitle:[@"About " stringByAppendingString:name]];
	[self.hideItem setTitle:[@"Hide " stringByAppendingString:name]];
	[self.quitItem setTitle:[@"Quit " stringByAppendingString:name]];
}

- (NSMenu *)makeMenubar
{
	NSMenu *menubar;

	menubar = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	[self buildApplicationMenu:menubar];
	return menubar;
}

@end

static void defaultOnClicked(uiMenuItem *item, uiWindow *w, void *data)
{
	// do nothing
}

void uiMenuItemEnable(uiMenuItem *item)
{
	item->disabled = NO;
	// we don't need to explicitly update the menus here; they'll be updated the next time they're opened (thanks mikeash in irc.freenode.net/#macdev)
}

void uiMenuItemDisable(uiMenuItem *item)
{
	item->disabled = YES;
}

void uiMenuItemOnClicked(uiMenuItem *item, void (*f)(uiMenuItem *, uiWindow *, void *), void *data)
{
	if (item->type == typeQuit)
		uiprivUserBug("You can't call uiMenuItemOnClicked() on a Quit item; use uiOnShouldQuit() instead.");
	if (item->type == typeRole)
		uiprivUserBug("You can't call uiMenuItemOnClicked() on a standard role item; the system handles it.");
	item->onClicked = f;
	item->onClickedData = data;
}

void uiMenuItemSetShortcut(uiMenuItem *item, const char *key, uiModifiers modifiers)
{
	@autoreleasepool {

	NSString *equivalent;

	if (item->type == typeRole)
		uiprivUserBug("You can't call uiMenuItemSetShortcut() on a standard role item; it already has the system shortcut.");
	if (item->type == typeQuit || item->type == typePreferences || item->type == typeAbout)
		uiprivUserBug("You can't call uiMenuItemSetShortcut() on a Quit, Preferences or About item; it already has the system shortcut.");

	if (key == NULL || *key == '\0') {
		[item->item setKeyEquivalent:@""];
		[item->item setKeyEquivalentModifierMask:0];
		return;
	}

	equivalent = uiprivToNSString(key);
	if ([equivalent length] != 1)
		uiprivUserBug("A menu item shortcut key must be exactly one character; got \"%s\".", key);

	[item->item setKeyEquivalent:equivalent];
	[item->item setKeyEquivalentModifierMask:toNSModifiers(modifiers)];

	} // @autoreleasepool
}

int uiMenuItemChecked(uiMenuItem *item)
{
	return [item->item state] != NSOffState;
}

void uiMenuItemSetChecked(uiMenuItem *item, int checked)
{
	NSInteger state;

	state = NSOffState;
	if (checked)
		state = NSOnState;
	[item->item setState:state];
}

static uiMenuItem *newItem(uiMenu *m, int type, const char *name)
{
	@autoreleasepool {

	uiMenuItem *item;

	if ([uiprivAppDelegate().menuManager finalized])
		uiprivUserBug("You can't create a new menu item after menus have been finalized.");

	item = uiprivNew(uiMenuItem);

	item->type = type;
	switch (item->type) {
	case typeQuit:
		item->item = uiprivAppDelegate().menuManager.quitItem;
		[item->item setUiMenuItem:item];
		break;
	case typePreferences:
		item->item = uiprivAppDelegate().menuManager.preferencesItem;
		[item->item setUiMenuItem:item];
		break;
	case typeAbout:
		item->item = uiprivAppDelegate().menuManager.aboutItem;
		[item->item setUiMenuItem:item];
		break;
	default:
		item->item = [[uiprivMenuItem alloc] initWithTitle:uiprivToNSString(name) uiMenuItem:item];
		[m->menu addItem:item->item];
		break;
	}

	[uiprivAppDelegate().menuManager register:item->type];
	// typeQuit is handled via uiprivShouldQuit()
	if (item->type != typeQuit)
		uiMenuItemOnClicked(item, defaultOnClicked, NULL);

	return item;

	} // @autoreleasepool
}

uiMenuItem *uiMenuAppendItem(uiMenu *m, const char *name)
{
	return newItem(m, typeRegular, name);
}

uiMenuItem *uiMenuAppendCheckItem(uiMenu *m, const char *name)
{
	return newItem(m, typeCheckbox, name);
}

uiMenuItem *uiMenuAppendQuitItem(uiMenu *m)
{
	return newItem(m, typeQuit, NULL);
}

uiMenuItem *uiMenuAppendPreferencesItem(uiMenu *m)
{
	return newItem(m, typePreferences, NULL);
}

uiMenuItem *uiMenuAppendAboutItem(uiMenu *m)
{
	return newItem(m, typeAbout, NULL);
}

uiMenuItem *uiDarwinMenuAppendRoleItem(uiMenu *m, uiDarwinMenuItemRole role)
{
	@autoreleasepool {

	uiMenuItem *item;
	struct uiprivMenuItemRoleInfo info;

	if ([uiprivAppDelegate().menuManager finalized])
		uiprivUserBug("You can't create a new menu item after menus have been finalized.");

	info = roleInfo(role);

	item = uiprivNew(uiMenuItem);
	item->type = typeRole;
	item->role = (int) role;
	item->onClicked = defaultOnClicked;
	item->onClickedData = NULL;
	item->item = [[uiprivMenuItem alloc] initWithTitle:uiprivToNSString(info.title)
		action:info.action
		keyEquivalent:info.key
		modifiers:info.modifiers
		uiMenuItem:item];
	[m->menu addItem:item->item];

	if (info.edit) {
		if (editRoleActions == nil)
			editRoleActions = [[NSMutableSet alloc] init];
		[editRoleActions addObject:NSStringFromSelector(info.action)];
	}

	return item;

	} // @autoreleasepool
}

void uiDarwinMenuSetRole(uiMenu *m, uiDarwinMenuRole role)
{
	switch (role) {
	case uiDarwinMenuRoleWindow:
		[uiprivNSApp() setWindowsMenu:m->menu];
		break;
	case uiDarwinMenuRoleHelp:
		[uiprivNSApp() setHelpMenu:m->menu];
		break;
	default:
		uiprivUserBug("Unknown uiDarwinMenuRole %d.", (int) role);
		break;
	}
}

BOOL uiprivMenuHasEditRoleItem(SEL action)
{
	if (editRoleActions == nil)
		return NO;
	return [editRoleActions containsObject:NSStringFromSelector(action)];
}

void uiMenuAppendSeparator(uiMenu *m)
{
	[m->menu addItem:[NSMenuItem separatorItem]];
}

uiMenu *uiNewMenu(const char *name)
{
	@autoreleasepool {

	uiMenu *m;

	if ([uiprivAppDelegate().menuManager finalized])
		uiprivUserBug("You can't create a new menu after menus have been finalized.");

	m = uiprivNew(uiMenu);

	m->menu = [[uiprivMenu alloc] initWithTitle:uiprivToNSString(name) uiMenu:m];
	// use automatic menu item enabling for all menus for consistency's sake

	m->item = [[NSMenuItem alloc] initWithTitle:uiprivToNSString(name) action:NULL keyEquivalent:@""];
	[m->item setSubmenu:m->menu];

	[[uiprivNSApp() mainMenu] addItem:m->item];

	return m;

	} // @autoreleasepool
}

void uiprivFinalizeMenus(void)
{
	[uiprivAppDelegate().menuManager finalize];
}

void uiprivUninitMenus(void)
{
	NSMenuItem *mi;
	NSMenu *sm;
	NSMenuItem *smi;

	[editRoleActions release];
	editRoleActions = nil;
	for (mi in [[uiprivNSApp() mainMenu] itemArray]) {
		if ([mi hasSubmenu]) {
			sm = [mi submenu];
			for (smi in [sm itemArray]) {
				if ([smi isKindOfClass:[uiprivMenuItem class]]) {
					uiprivMenuItem *x = (uiprivMenuItem *)smi;
					if (x->item != NULL)
						uiprivFree(x->item);
				}
			}
			if ([sm isKindOfClass:[uiprivMenu class]]) {
				uiprivMenu *x = (uiprivMenu *)sm;
				uiprivFree(x->menu);
			}
		}
	}
}
