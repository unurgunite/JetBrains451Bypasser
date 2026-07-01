#import <AppKit/AppKit.h>

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
