#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Forward declaration of libui's uiQuit
extern void uiQuit(void);

// Small helper class to handle Quit action (avoids libui's terminate: override)
@interface JBUpdaterHelper : NSObject
- (void)quitApp:(id)sender;
@end

@implementation JBUpdaterHelper
- (void)quitApp:(id)sender {
  uiQuit();
}
@end

void* create_width_constraint(void* item, void* relative_to, double multiplier) {
  return (__bridge void*)[NSLayoutConstraint
    constraintWithItem:(__bridge id)item
    attribute:NSLayoutAttributeWidth
    relatedBy:NSLayoutRelationEqual
    toItem:(__bridge id)relative_to
    attribute:NSLayoutAttributeWidth
    multiplier:multiplier
    constant:0];
}

void add_constraint_to_view(void* view, void* constraint) {
  [(__bridge NSView*)view addConstraint:(__bridge NSLayoutConstraint*)constraint];
}

void set_app_icon(const char* icns_path) {
  @autoreleasepool {
    NSString *path = [NSString stringWithUTF8String:icns_path];
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:path];
    if (icon) {
      [NSApp setApplicationIconImage:icon];
    }
  }
}

void setup_menu_bar(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    static JBUpdaterHelper *helper = nil;
    helper = [[JBUpdaterHelper alloc] init];

    NSMenu *mainMenu = [[NSMenu alloc] init];

    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];

    // Close Window — cmd+W
    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close Window"
                                                       action:@selector(performClose:)
                                                keyEquivalent:@"w"];
    [closeItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    [closeItem setTarget:nil];
    [fileMenu addItem:closeItem];

    [fileMenu addItem:[NSMenuItem separatorItem]];

    // Quit — cmd+Q (uses helper to bypass libui's terminate: override)
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                      action:@selector(quitApp:)
                                               keyEquivalent:@"q"];
    [quitItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    [quitItem setTarget:helper];
    [fileMenu addItem:quitItem];

    [NSApp setMainMenu:mainMenu];
  });
}
