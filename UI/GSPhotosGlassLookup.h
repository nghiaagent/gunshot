#pragma once
#import <UIKit/UIKit.h>

// Reads the three floating bottom-bar views from a PHSTabBarController and checks that they have
// the structure the Liquid Glass overlay relies on. Returns nil when the views are usable and
// `floating_bottom_bar_not_found` otherwise. `report` is always filled with class names, booleans
// and counts only (no titles, labels, identifiers or user data) for the diagnostics export.
FOUNDATION_EXPORT id GSPhotosGlassGetter(id object, NSString *name);
FOUNDATION_EXPORT NSString *GSPhotosGlassValidateBottomBar(UIViewController *controller,
                                                           UIStackView *bar, UIControl *segments,
                                                           UIButton *search, NSDictionary **report);
