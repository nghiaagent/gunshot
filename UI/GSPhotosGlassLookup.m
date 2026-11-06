#import "GSPhotosGlassLookup.h"
#import "../Shared/GSPhotosCompatibility.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const NSUInteger GSLookupClassLimit = 8;

id GSPhotosGlassGetter(id object, NSString *name) {
    if (!object || !GSPhotosHasMethod(object_getClass(object), name, "@16@0:8"))
        return nil;
    return ((id(*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static NSString *GSLookupClassName(id object) {
    return object ? NSStringFromClass(object_getClass(object)) : nil;
}

static NSString *GSLookupGetterState(id controller, NSString *name) {
    Method method = controller ? class_getInstanceMethod(object_getClass(controller),
                                                         NSSelectorFromString(name))
                               : NULL;
    if (!method)
        return @"missing";
    return strcmp(method_getTypeEncoding(method), "@16@0:8") == 0 ? @"present" : @"abi_mismatch";
}

static NSArray<NSString *> *GSLookupClassNames(NSArray *views) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id view in views) {
        if (names.count == GSLookupClassLimit)
            break;
        [names addObject:GSLookupClassName(view) ?: @"nil"];
    }
    return names;
}

static NSDictionary *GSLookupViewReport(id controller, NSString *getter, UIView *view,
                                        UIStackView *bar) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"getter"] = GSLookupGetterState(controller, getter);
    entry[@"nil"] = @(view == nil);
    if (!view)
        return entry;
    entry[@"class"] = GSLookupClassName(view);
    entry[@"hasWindow"] = @(view.window != nil);
    UIView *superview = view.superview;
    entry[@"superviewClass"] = GSLookupClassName(superview) ?: NSNull.null;
    entry[@"superviewIsBar"] = @(bar && superview == bar);
    entry[@"inArrangedSubviews"] =
        @([bar isKindOfClass:UIStackView.class] && [bar.arrangedSubviews containsObject:view]);
    return entry;
}

NSString *GSPhotosGlassValidateBottomBar(UIViewController *controller, UIStackView *bar,
                                         UIControl *segments, UIButton *search,
                                         NSDictionary **report) {
    Class segmentsClass = NSClassFromString(@"PHSSegmentedControl");
    Class m3cClass = NSClassFromString(@"M3CButton");
    BOOL barIsStack = [bar isKindOfClass:UIStackView.class];
    BOOL segmentsOK = [segments isKindOfClass:UIControl.class] && segmentsClass &&
                      [segments isKindOfClass:segmentsClass];
    BOOL searchIsButton = [search isKindOfClass:UIButton.class];
    BOOL searchIsM3C = searchIsButton && m3cClass && [search isKindOfClass:m3cClass];
    BOOL hierarchyOK = barIsStack && bar.superview && segments.superview == bar &&
                       search.superview == bar && [bar.arrangedSubviews containsObject:segments] &&
                       [bar.arrangedSubviews containsObject:search];

    NSString *failed = nil, *searchKind = nil;
    if (barIsStack && segmentsOK && searchIsM3C && hierarchyOK) {
        // Google Photos 7.x: the search button is an M3CButton.
        searchKind = @"m3c_button";
    } else if (barIsStack && segmentsOK && searchIsButton && hierarchyOK &&
               bar.arrangedSubviews.count == 2 && bar.arrangedSubviews[0] == segments &&
               bar.arrangedSubviews[1] == search) {
        // Google Photos 8.0.0 builds the search button with +[UIButton
        // buttonWithConfiguration:primaryAction:] whenever M3CLiquidGlass is available, so it is
        // a plain UIButton. The bar must still be exactly [segments, search].
        searchKind = @"plain_button";
    } else if (!controller) {
        failed = @"controller.nil";
    } else if (!bar) {
        failed = @"bar.nil";
    } else if (!barIsStack) {
        failed = @"bar.not_stack_view";
    } else if (!segments) {
        failed = @"segments.nil";
    } else if (!segmentsOK) {
        failed = @"segments.class";
    } else if (!search) {
        failed = @"search.nil";
    } else if (!searchIsButton) {
        failed = @"search.not_button";
    } else if (!bar.superview) {
        failed = @"bar.no_superview";
    } else if (segments.superview != bar) {
        failed = @"segments.superview_not_bar";
    } else if (search.superview != bar) {
        failed = @"search.superview_not_bar";
    } else if (![bar.arrangedSubviews containsObject:segments]) {
        failed = @"segments.not_arranged";
    } else if (![bar.arrangedSubviews containsObject:search]) {
        failed = @"search.not_arranged";
    } else {
        failed = @"bar.arrangement_not_segments_search";
    }

    if (report) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"result"] = failed ? @"failed" : @"ok";
        result[@"failedCheck"] = failed ?: NSNull.null;
        result[@"searchKind"] = searchKind ?: NSNull.null;
        result[@"controllerClass"] = GSLookupClassName(controller) ?: NSNull.null;
        NSMutableDictionary *barReport =
            [GSLookupViewReport(controller, @"floatingBottomTabBar", bar, nil) mutableCopy];
        barReport[@"isStackView"] = @(barIsStack);
        barReport[@"hasSuperview"] = @(bar.superview != nil);
        if (barIsStack) {
            barReport[@"arrangedCount"] = @(bar.arrangedSubviews.count);
            barReport[@"arrangedClasses"] = GSLookupClassNames(bar.arrangedSubviews);
        }
        result[@"bar"] = barReport;
        NSMutableDictionary *segmentsReport =
            [GSLookupViewReport(controller, @"floatingSegmentedControl", segments, bar)
                mutableCopy];
        segmentsReport[@"isPHSSegmentedControl"] = @(segmentsOK);
        if (segmentsOK &&
            GSPhotosHasMethod(object_getClass(segments), @"numberOfSegments", "q16@0:8"))
            segmentsReport[@"numberOfSegments"] = @(((NSInteger(*)(id, SEL))objc_msgSend)(
                segments, NSSelectorFromString(@"numberOfSegments")));
        result[@"segments"] = segmentsReport;
        NSMutableDictionary *searchReport =
            [GSLookupViewReport(controller, @"floatingSearchButton", search, bar) mutableCopy];
        searchReport[@"isButton"] = @(searchIsButton);
        searchReport[@"isM3CButton"] = @(searchIsM3C);
        result[@"search"] = searchReport;
        if (failed)
            result[@"controllerViewSubviewClasses"] =
                GSLookupClassNames(controller.viewIfLoaded.subviews);
        *report = result;
    }
    return failed ? @"floating_bottom_bar_not_found" : nil;
}
