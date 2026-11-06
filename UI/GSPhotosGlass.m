#import "GSPhotosGlass.h"
#import "GSPhotosGlassLookup.h"
#import "../Shared/GSPhotosCompatibility.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const GSPhotosGlassPreference = @"GSPhotosBottomBarLiquidGlass";
static NSString *const GSDesignCompatibilityOverride = @"com.apple.SwiftUI.IgnoreSolariumOptOut";
static char GSGlassPairKey;
static BOOL GSInstalled, GSBootGlassEnabled, GSRestartRequired, GSDesignOverrideApplied;
static NSHashTable *GSControllers, *GSPairs;
static NSString *GSLastSkip;
static NSDictionary *GSLastLookup;
static NSUInteger GSLookupAttempts;

@class GSPhotosGlassPair;
static void GSRefreshOverlayVisibility(GSPhotosGlassPair *pair);

@interface GSPhotosGlassValueChangeProbe : NSObject
@property (nonatomic) BOOL fired;
- (void)valueChanged:(id)sender;
@end
@implementation GSPhotosGlassValueChangeProbe
- (void)valueChanged:(id)sender {
    self.fired = YES;
}
@end

@interface GSPhotosGlassOverlayWindow : UIWindow
@property (nonatomic, weak) UITabBarController *tabController;
@property (nonatomic, weak) GSPhotosGlassPair *pair;
@property (nonatomic) BOOL contentSuppressed;
@property (nonatomic) BOOL refreshScheduled;
- (void)scheduleVisibilityRefresh;
@end
@implementation GSPhotosGlassOverlayWindow
- (void)scheduleVisibilityRefresh {
    if (self.refreshScheduled)
        return;
    self.refreshScheduled = YES;
    __weak GSPhotosGlassOverlayWindow *weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(),
        ^{
            GSPhotosGlassOverlayWindow *strongSelf = weakSelf;
            if (!strongSelf)
                return;
            strongSelf.refreshScheduled = NO;
            GSPhotosGlassPair *pair = strongSelf.pair;
            if (pair)
                GSRefreshOverlayVisibility(pair);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               GSPhotosGlassPair *later = weakSelf.pair;
                               if (later)
                                   GSRefreshOverlayVisibility(later);
                           });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               GSPhotosGlassPair *later = weakSelf.pair;
                               if (later)
                                   GSRefreshOverlayVisibility(later);
                           });
        });
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    [self scheduleVisibilityRefresh];
    UITabBar *tabBar = self.tabController.tabBar;
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled ||
        self.contentSuppressed || self.tabController.view.hidden || !tabBar || tabBar.hidden ||
        tabBar.alpha <= 0.01 || !tabBar.window)
        return NO;
    CGRect hitFrame = [tabBar convertRect:tabBar.bounds toView:self];
    hitFrame = CGRectInset(hitFrame, -12.0, -12.0);
    return CGRectContainsPoint(hitFrame, point);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self pointInside:point withEvent:event])
        return nil;
    return [super hitTest:point withEvent:event];
}
@end

@interface GSPhotosGlassClearController : UIViewController
@end
@implementation GSPhotosGlassClearController
- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.userInteractionEnabled = NO;
    self.view = view;
}
@end

@interface GSPhotosGlassPair : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) UIStackView *bar;
@property (nonatomic, weak) UIControl *segments;
@property (nonatomic, weak) UIButton *search;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) GSPhotosGlassOverlayWindow *overlayWindow;
@property (nonatomic, strong) UITabBarController *nativeTabController;
@property (nonatomic, strong) NSArray *regularTabs;
@property (nonatomic, strong) id searchTab;
@property (nonatomic) CGFloat segmentsAlpha, searchAlpha;
@property (nonatomic) BOOL segmentsInteraction, searchInteraction;
@property (nonatomic) BOOL segmentsAccessibilityHidden, searchAccessibilityHidden, changing;
- (void)forwardSearch;
@end

static NSInteger GSInteger(id object, NSString *name) {
    return ((NSInteger(*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static void GSSetInteger(id object, NSString *name, NSInteger value) {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, NSSelectorFromString(name), value);
}
BOOL GSPhotosGlassEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:GSPhotosGlassPreference];
}

static BOOL GSPhotosGlassHostVersionSupported(void) {
    if (!GSPhotosHostSupported())
        return NO;
    id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:NSString.class] ||
        [version rangeOfString:@"^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$" options:NSRegularExpressionSearch]
                .location == NSNotFound)
        return NO;
    return [version compare:@"7.92" options:NSNumericSearch] != NSOrderedAscending;
}

static void GSWriteDesignCompatibilityOverride(BOOL enabled) {
    if (!GSPhotosHostSupported())
        return;
    if (@available(iOS 26.0, *)) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (enabled && GSPhotosGlassHostVersionSupported())
            [defaults setBool:YES forKey:GSDesignCompatibilityOverride];
        else
            [defaults removeObjectForKey:GSDesignCompatibilityOverride];
        [defaults synchronize];
    }
}

static BOOL GSPhotosGlassActiveThisLaunch(void) {
    return GSPhotosGlassEnabled() && !GSRestartRequired && GSDesignOverrideApplied;
}

static NSString *GSUnavailableReason(void) {
    if (@available(iOS 26.0, *)) {
        if (!GSPhotosHostSupported())
            return @"unsupported_host";
        id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (![version isKindOfClass:NSString.class] ||
            [version rangeOfString:@"^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$"
                           options:NSRegularExpressionSearch]
                    .location == NSNotFound)
            return @"unknown_version";
        if (!GSPhotosGlassHostVersionSupported())
            return @"requires_photos_7_92";
        for (NSArray *entry in @[
                 @[ @"PHSTabBarController", @"viewDidLayoutSubviews", @"v16@0:8" ],
                 @[ @"PHSTabBarController", @"floatingBottomTabBar", @"@16@0:8" ],
                 @[ @"PHSTabBarController", @"floatingSegmentedControl", @"@16@0:8" ],
                 @[ @"PHSTabBarController", @"floatingSearchButton", @"@16@0:8" ],
                 @[ @"PHSSegmentedControl", @"layoutSubviews", @"v16@0:8" ],
                 @[ @"PHSSegmentedControl", @"numberOfSegments", @"q16@0:8" ],
                 @[ @"PHSSegmentedControl", @"selectedSegmentIndex", @"q16@0:8" ],
                 @[ @"PHSSegmentedControl", @"setSelectedSegmentIndex:", @"v24@0:8q16" ],
                 @[ @"M3CButton", @"layoutSubviews", @"v16@0:8" ]
             ])
            if (!GSPhotosHasMethod(NSClassFromString(entry[0]), entry[1], [entry[2] UTF8String]))
                return [NSString stringWithFormat:@"missing_contract:%@.%@", entry[0], entry[1]];
        Class tabClass = NSClassFromString(@"UITab"),
              searchTabClass = NSClassFromString(@"UISearchTab");
        if (!tabClass || !searchTabClass ||
            ![tabClass instancesRespondToSelector:
                           NSSelectorFromString(
                               @"initWithTitle:image:identifier:viewControllerProvider:")] ||
            ![searchTabClass instancesRespondToSelector:NSSelectorFromString(
                                                            @"initWithViewControllerProvider:")] ||
            ![UITabBarController
                instancesRespondToSelector:NSSelectorFromString(@"initWithTabs:")] ||
            ![UITabBarController instancesRespondToSelector:NSSelectorFromString(@"setTabs:")] ||
            ![UITabBarController
                instancesRespondToSelector:NSSelectorFromString(@"setSelectedTab:")])
            return @"missing_native_tab_api";
        return nil;
    }
    return @"requires_ios_26";
}
BOOL GSPhotosGlassAvailable(void) {
    return GSUnavailableReason() == nil;
}

static BOOL GSViewVisibleInHostWindow(UIView *view, UIWindow *hostWindow) {
    if (!view || !hostWindow || view.window != hostWindow)
        return NO;
    for (UIView *node = view; node && node != hostWindow; node = node.superview)
        if (node.hidden || node.alpha <= 0.01)
            return NO;
    CGRect sourceRect = [view convertRect:view.bounds toView:hostWindow];
    if (CGRectIsNull(sourceRect) || CGRectIsEmpty(sourceRect))
        return NO;
    CGRect visibleRect = CGRectIntersection(sourceRect, hostWindow.bounds);
    return !CGRectIsNull(visibleRect) && !CGRectIsEmpty(visibleRect) &&
           CGRectGetWidth(visibleRect) > 1.0 && CGRectGetHeight(visibleRect) > 1.0;
}

static BOOL GSHostPointStillBelongsToBar(GSPhotosGlassPair *pair, UIView *source,
                                         UIWindow *hostWindow) {
    if (!source || !pair.bar || source.window != hostWindow)
        return NO;
    CGPoint point =
        [source convertPoint:CGPointMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds))
                      toView:hostWindow];
    if (!CGRectContainsPoint(hostWindow.bounds, point))
        return NO;
    UIView *hit = [hostWindow hitTest:point withEvent:nil];
    return hit && (hit == pair.bar || [hit isDescendantOfView:pair.bar]);
}

static BOOL GSBarIsFrontmost(GSPhotosGlassPair *pair, UIWindow *hostWindow) {
    if (!GSViewVisibleInHostWindow(pair.bar, hostWindow))
        return NO;
    return GSHostPointStillBelongsToBar(pair, pair.segments, hostWindow) &&
           GSHostPointStillBelongsToBar(pair, pair.search, hostWindow);
}

static BOOL GSControllerTreeHasPresentedOverlay(UIViewController *controller,
                                                UIWindow *hostWindow) {
    if (!controller)
        return NO;
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) {
        if (!presented.isViewLoaded ||
            (!presented.view.hidden && presented.view.alpha > 0.01 &&
             (presented.view.window == hostWindow || presented.view.window == nil)))
            return YES;
    }
    for (UIViewController *child in controller.childViewControllers)
        if (GSControllerTreeHasPresentedOverlay(child, hostWindow))
            return YES;
    return NO;
}

static BOOL GSHostSourceVisible(GSPhotosGlassPair *pair, UIWindow *hostWindow) {
    if (!pair || !hostWindow ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return NO;
    if (pair.controller.view.window != hostWindow || pair.controller.view.hidden ||
        pair.controller.view.alpha <= 0.01)
        return NO;
    if (pair.bar.window != hostWindow || pair.bar.hidden || pair.bar.alpha <= 0.01)
        return NO;
    if (GSControllerTreeHasPresentedOverlay(hostWindow.rootViewController, hostWindow))
        return NO;
    return GSBarIsFrontmost(pair, hostWindow);
}

static void GSApplyOverlayVisibility(GSPhotosGlassPair *pair, BOOL visible) {
    if (!pair.overlayWindow || !pair.nativeTabController)
        return;
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    pair.overlayWindow.hidden = !active;
    pair.overlayWindow.contentSuppressed = !visible;
    pair.nativeTabController.view.hidden = !visible;
    if (visible) {
        [pair.nativeTabController.view setNeedsLayout];
        [pair.nativeTabController.view layoutIfNeeded];
    }
}

static void GSRefreshOverlayVisibility(GSPhotosGlassPair *pair) {
    if (!pair || pair.changing || !pair.hostWindow || !pair.overlayWindow ||
        !pair.nativeTabController)
        return;
    BOOL visible = GSHostSourceVisible(pair, pair.hostWindow);
    GSApplyOverlayVisibility(pair, visible);
    if (visible)
        GSLastSkip = nil;
}

static void GSCollectVisibleLabels(UIView *view, UIControl *segments,
                                   NSMutableArray<NSDictionary *> *items) {
    if (view != segments && (view.hidden || view.alpha <= 0.01))
        return;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length && text.length < 48) {
            CGPoint center = [view
                convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                      toView:segments];
            [items addObject:@{@"title" : text, @"x" : @(center.x)}];
        }
    }
    for (UIView *child in view.subviews)
        GSCollectVisibleLabels(child, segments, items);
}
static void GSCollectAccessibilityLabels(UIView *view, NSMutableArray<NSString *> *labels) {
    NSString *label = view.accessibilityLabel;
    if (view.isAccessibilityElement && label.length && label.length < 48 &&
        ![labels containsObject:label] &&
        [label rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location == NSNotFound)
        [labels addObject:label];
    for (UIView *child in view.subviews)
        GSCollectAccessibilityLabels(child, labels);
}
static NSArray<NSString *> *GSTabTitles(UIControl *segments) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    GSCollectVisibleLabels(segments, segments, items);
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"x"] compare:b[@"x"]];
    }];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:3];
    for (NSDictionary *item in items) {
        NSString *title = item[@"title"];
        if (![titles containsObject:title])
            [titles addObject:title];
        if (titles.count == 3)
            break;
    }
    if (titles.count < 3) {
        NSMutableArray<NSString *> *accessible = [NSMutableArray array];
        GSCollectAccessibilityLabels(segments, accessible);
        for (NSString *title in accessible) {
            if (![titles containsObject:title])
                [titles addObject:title];
            if (titles.count == 3)
                break;
        }
    }
    return titles.count == 3 ? titles : @[ @"Photos", @"Collections", @"Create" ];
}

static UIViewController *GSNewClearTabController(id tab) {
    return [GSPhotosGlassClearController new];
}

static UITabBarController *GSCreateNativeTabController(GSPhotosGlassPair *pair) {
    if (@available(iOS 18.0, *)) {
        NSArray<NSString *> *titles = GSTabTitles(pair.segments);
        NSArray<NSString *> *symbols =
            @[ @"photo.on.rectangle.angled", @"rectangle.stack", @"plus.circle" ];
        NSMutableArray<UITab *> *regular = [NSMutableArray arrayWithCapacity:3];
        for (NSInteger i = 0; i < 3; i++) {
            NSString *identifier =
                [NSString stringWithFormat:@"dev.tqmane.gunshot.photos.%ld", (long)i];
            UITab *tab = [[UITab alloc] initWithTitle:titles[i]
                                                image:[UIImage systemImageNamed:symbols[i]]
                                           identifier:identifier
                               viewControllerProvider:^UIViewController *(UITab *providerTab) {
                                   return GSNewClearTabController(providerTab);
                               }];
            if (!tab)
                return nil;
            [regular addObject:tab];
        }
        UISearchTab *search = [[UISearchTab alloc]
            initWithViewControllerProvider:^UIViewController *(UITab *providerTab) {
                return GSNewClearTabController(providerTab);
            }];
        if (!search)
            return nil;
        SEL autoSearch = NSSelectorFromString(@"setAutomaticallyActivatesSearch:");
        if ([search respondsToSelector:autoSearch])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(search, autoSearch, NO);
        NSMutableArray<UITab *> *all = [regular mutableCopy];
        [all addObject:search];
        UITabBarController *tabs = [[UITabBarController alloc] initWithTabs:all];
        tabs.mode = UITabBarControllerModeTabBar;
        tabs.delegate = (id<UITabBarControllerDelegate>)pair;
        tabs.view.backgroundColor = UIColor.clearColor;
        tabs.view.opaque = NO;
        tabs.view.clipsToBounds = NO;
        pair.regularTabs = regular.copy;
        pair.searchTab = search;
        NSInteger selected = GSInteger(pair.segments, @"selectedSegmentIndex");
        if (selected >= 0 && selected < (NSInteger)pair.regularTabs.count)
            ((void (*)(id, SEL, id))objc_msgSend)(tabs, NSSelectorFromString(@"setSelectedTab:"),
                                                  pair.regularTabs[selected]);
        return tabs;
    }
    return nil;
}

static id GSSelectedNativeTab(UITabBarController *tabs) {
    SEL selector = NSSelectorFromString(@"selectedTab");
    return [tabs respondsToSelector:selector] ? ((id(*)(id, SEL))objc_msgSend)(tabs, selector)
                                              : nil;
}
static void GSSyncTabSelection(GSPhotosGlassPair *pair) {
    if (!pair.nativeTabController || !pair.segments || pair.regularTabs.count != 3)
        return;
    NSInteger selected = GSInteger(pair.segments, @"selectedSegmentIndex");
    if (selected < 0 || selected >= (NSInteger)pair.regularTabs.count)
        return;
    id target = pair.regularTabs[selected];
    if (GSSelectedNativeTab(pair.nativeTabController) == target)
        return;
    BOOL changing = pair.changing;
    pair.changing = YES;
    ((void (*)(id, SEL, id))objc_msgSend)(pair.nativeTabController,
                                          NSSelectorFromString(@"setSelectedTab:"), target);
    pair.changing = changing;
}

static BOOL GSSelectGoogleTab(GSPhotosGlassPair *pair, NSInteger index) {
    if (!pair.segments || index < 0 || index >= GSInteger(pair.segments, @"numberOfSegments"))
        return NO;
    NSInteger before = GSInteger(pair.segments, @"selectedSegmentIndex");
    if (before == index)
        return YES;
    GSPhotosGlassValueChangeProbe *probe = [GSPhotosGlassValueChangeProbe new];
    [(UIControl *)pair.segments addTarget:probe
                                   action:@selector(valueChanged:)
                         forControlEvents:UIControlEventValueChanged];
    BOOL changing = pair.changing;
    pair.changing = YES;
    GSSetInteger(pair.segments, @"setSelectedSegmentIndex:", index);
    pair.changing = changing;
    [(UIControl *)pair.segments removeTarget:probe
                                      action:@selector(valueChanged:)
                            forControlEvents:UIControlEventValueChanged];
    NSInteger after = GSInteger(pair.segments, @"selectedSegmentIndex");
    if (after != before && after == index && !probe.fired)
        [(UIControl *)pair.segments sendActionsForControlEvents:UIControlEventValueChanged];
    GSSyncTabSelection(pair);
    return after == index;
}

static void GSTearDownOverlay(GSPhotosGlassPair *pair) {
    pair.nativeTabController.delegate = nil;
    pair.overlayWindow.pair = nil;
    pair.overlayWindow.hidden = YES;
    pair.overlayWindow.tabController = nil;
    pair.overlayWindow.rootViewController = nil;
    pair.overlayWindow = nil;
    pair.nativeTabController = nil;
    pair.regularTabs = nil;
    pair.searchTab = nil;
    pair.hostWindow = nil;
}

static BOOL GSEnsureOverlay(GSPhotosGlassPair *pair, UIWindow *hostWindow) {
    if (!pair || !hostWindow.windowScene)
        return NO;
    if (pair.overlayWindow && pair.hostWindow == hostWindow &&
        pair.overlayWindow.windowScene == hostWindow.windowScene && pair.nativeTabController)
        return YES;
    GSTearDownOverlay(pair);
    UITabBarController *tabs = GSCreateNativeTabController(pair);
    if (!tabs)
        return NO;
    GSPhotosGlassOverlayWindow *overlay =
        [[GSPhotosGlassOverlayWindow alloc] initWithWindowScene:hostWindow.windowScene];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.userInteractionEnabled = YES;
    overlay.windowLevel = hostWindow.windowLevel + 1.0;
    overlay.frame = hostWindow.windowScene.coordinateSpace.bounds;
    overlay.rootViewController = tabs;
    overlay.tabController = tabs;
    overlay.pair = pair;
    overlay.tintColor = hostWindow.tintColor;
    overlay.overrideUserInterfaceStyle = hostWindow.overrideUserInterfaceStyle;
    pair.hostWindow = hostWindow;
    pair.nativeTabController = tabs;
    pair.overlayWindow = overlay;
    overlay.hidden = NO;
    overlay.contentSuppressed = NO;
    tabs.view.hidden = NO;
    [tabs.view setNeedsLayout];
    [tabs.view layoutIfNeeded];
    return YES;
}

static void GSRestore(GSPhotosGlassPair *pair) {
    if (!pair || pair.changing)
        return;
    pair.changing = YES;
    for (id object in @[
             pair.controller ?: NSNull.null, pair.segments ?: NSNull.null,
             pair.search ?: NSNull.null
         ])
        if (object != NSNull.null && objc_getAssociatedObject(object, &GSGlassPairKey) == pair)
            objc_setAssociatedObject(object, &GSGlassPairKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GSTearDownOverlay(pair);
    pair.segments.alpha = pair.segmentsAlpha;
    pair.segments.userInteractionEnabled = pair.segmentsInteraction;
    pair.segments.accessibilityElementsHidden = pair.segmentsAccessibilityHidden;
    pair.search.alpha = pair.searchAlpha;
    pair.search.userInteractionEnabled = pair.searchInteraction;
    pair.search.accessibilityElementsHidden = pair.searchAccessibilityHidden;
    [GSPairs removeObject:pair];
    pair.changing = NO;
}

static BOOL GSLayoutNativeControls(GSPhotosGlassPair *pair) {
    if (!pair || pair.changing)
        return NO;
    if (!pair.bar || !pair.bar.superview || pair.segments.superview != pair.bar ||
        pair.search.superview != pair.bar ||
        ![pair.bar.arrangedSubviews containsObject:pair.segments] ||
        ![pair.bar.arrangedSubviews containsObject:pair.search]) {
        GSRestore(pair);
        GSLastSkip = @"bottom_bar_hierarchy_changed";
        return NO;
    }
    UIWindow *hostWindow = pair.controller.view.window ?: pair.bar.window;
    if (!hostWindow || !hostWindow.windowScene) {
        if (pair.overlayWindow)
            pair.overlayWindow.hidden = YES;
        GSLastSkip = @"waiting_for_host_window";
        return NO;
    }
    if (!GSEnsureOverlay(pair, hostWindow)) {
        GSLastSkip = @"native_tab_overlay_creation_failed";
        return NO;
    }
    pair.changing = YES;
    [pair.bar layoutIfNeeded];
    pair.segments.alpha = 0;
    pair.segments.userInteractionEnabled = NO;
    pair.segments.accessibilityElementsHidden = YES;
    pair.search.alpha = 0;
    pair.search.userInteractionEnabled = NO;
    pair.search.accessibilityElementsHidden = YES;
    pair.overlayWindow.windowLevel = hostWindow.windowLevel + 1.0;
    pair.overlayWindow.frame = hostWindow.windowScene.coordinateSpace.bounds;
    pair.overlayWindow.tintColor = hostWindow.tintColor;
    pair.overlayWindow.overrideUserInterfaceStyle = hostWindow.overrideUserInterfaceStyle;
    BOOL sourceVisible = GSHostSourceVisible(pair, hostWindow);
    GSApplyOverlayVisibility(pair, sourceVisible);
    GSSyncTabSelection(pair);
    pair.changing = NO;
    if (sourceVisible)
        GSLastSkip = nil;
    return sourceVisible;
}

@implementation GSPhotosGlassPair
- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectTab:(id)tab {
    if (tabBarController != self.nativeTabController || self.changing)
        return YES;
    if (tab == self.searchTab) {
        [self forwardSearch];
        return NO;
    }
    NSUInteger index = [self.regularTabs indexOfObjectIdenticalTo:tab];
    if (index == NSNotFound)
        return YES;
    return GSSelectGoogleTab(self, (NSInteger)index);
}
- (BOOL)tabBarController:(UITabBarController *)tabBarController
    shouldSelectViewController:(UIViewController *)viewController {
    if (tabBarController != self.nativeTabController || self.changing)
        return YES;
    SEL viewControllerSelector = NSSelectorFromString(@"viewController");
    id searchViewController =
        [self.searchTab respondsToSelector:viewControllerSelector]
            ? ((id(*)(id, SEL))objc_msgSend)(self.searchTab, viewControllerSelector)
            : nil;
    if (viewController == searchViewController) {
        [self forwardSearch];
        return NO;
    }
    for (NSUInteger index = 0; index < self.regularTabs.count; index++) {
        id tab = self.regularTabs[index];
        id candidate = [tab respondsToSelector:viewControllerSelector]
                           ? ((id(*)(id, SEL))objc_msgSend)(tab, viewControllerSelector)
                           : nil;
        if (viewController == candidate)
            return GSSelectGoogleTab(self, (NSInteger)index);
    }
    return YES;
}
- (void)forwardSearch {
    if (!self.search)
        return;
    GSApplyOverlayVisibility(self, NO);
    [self.search sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self.overlayWindow scheduleVisibilityRefresh];
}
@end

static void GSUpdateController(UIViewController *controller) {
    [GSControllers addObject:controller];
    GSPhotosGlassPair *previous = objc_getAssociatedObject(controller, &GSGlassPairKey);
    if (!GSPhotosGlassActiveThisLaunch()) {
        GSRestore(previous);
        return;
    }
    if (previous.changing)
        return;
    UIStackView *bar = GSPhotosGlassGetter(controller, @"floatingBottomTabBar");
    UIControl *segments = GSPhotosGlassGetter(controller, @"floatingSegmentedControl");
    UIButton *search = GSPhotosGlassGetter(controller, @"floatingSearchButton");
    if (previous && previous.bar == bar && previous.segments == segments &&
        previous.search == search) {
        GSLayoutNativeControls(previous);
        return;
    }
    GSRestore(previous);
    NSDictionary *lookup = nil;
    NSString *notFound = GSPhotosGlassValidateBottomBar(controller, bar, segments, search, &lookup);
    NSMutableDictionary *recorded = [lookup mutableCopy] ?: [NSMutableDictionary dictionary];
    recorded[@"attempt"] = @(++GSLookupAttempts);
    if (notFound) {
        GSLastLookup = recorded.copy;
        GSLastSkip = notFound;
        return;
    }
    if (GSInteger(segments, @"numberOfSegments") != 3) {
        recorded[@"result"] = @"failed";
        recorded[@"failedCheck"] = @"segments.count_not_3";
        GSLastLookup = recorded.copy;
        GSLastSkip = @"unexpected_segment_count";
        return;
    }
    if (objc_getAssociatedObject(segments, &GSGlassPairKey) ||
        objc_getAssociatedObject(search, &GSGlassPairKey)) {
        recorded[@"result"] = @"failed";
        recorded[@"failedCheck"] = @"views.already_owned";
        GSLastLookup = recorded.copy;
        GSLastSkip = @"bottom_bar_already_owned";
        return;
    }
    GSLastLookup = recorded.copy;
    GSPhotosGlassPair *pair = [GSPhotosGlassPair new];
    pair.controller = controller;
    pair.bar = bar;
    pair.segments = segments;
    pair.search = search;
    pair.segmentsAlpha = segments.alpha;
    pair.searchAlpha = search.alpha;
    pair.segmentsInteraction = segments.userInteractionEnabled;
    pair.searchInteraction = search.userInteractionEnabled;
    pair.segmentsAccessibilityHidden = segments.accessibilityElementsHidden;
    pair.searchAccessibilityHidden = search.accessibilityElementsHidden;
    for (id object in @[ controller, segments, search ])
        objc_setAssociatedObject(object, &GSGlassPairKey, pair, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [GSPairs addObject:pair];
    if (!GSLayoutNativeControls(pair) &&
        [GSLastSkip isEqual:@"native_tab_overlay_creation_failed"]) {
        GSRestore(pair);
        return;
    }
}
static void GSVisitController(UIViewController *controller, NSMutableSet *seen) {
    if (!controller || [seen containsObject:controller])
        return;
    [seen addObject:controller];
    if (controller.isViewLoaded &&
        [controller isKindOfClass:NSClassFromString(@"PHSTabBarController")])
        GSUpdateController(controller);
    for (UIViewController *child in controller.childViewControllers)
        GSVisitController(child, seen);
    GSVisitController(controller.presentedViewController, seen);
}
static void GSDiscoverControllers(void) {
    if (!GSInstalled)
        return;
    NSMutableSet *seen = [NSMutableSet set];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *window in ((UIWindowScene *)scene).windows)
                GSVisitController(window.rootViewController, seen);
}
static IMP GSHook(Class cls, NSString *name, IMP replacement) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        return NULL;
    IMP original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return original;
}
void GSInstallPhotosGlass(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GSInstallPhotosGlass();
        });
        return;
    }
    if (GSInstalled || !GSPhotosGlassAvailable())
        return;
    GSControllers = NSHashTable.weakObjectsHashTable;
    GSPairs = NSHashTable.weakObjectsHashTable;
    Class cls = NSClassFromString(@"PHSTabBarController");
    SEL controllerLayoutSel = @selector(viewDidLayoutSubviews);
    IMP controllerLayout =
        method_getImplementation(class_getInstanceMethod(cls, controllerLayoutSel));
    GSHook(cls, @"viewDidLayoutSubviews",
           imp_implementationWithBlock(^(UIViewController *controller) {
               ((void (*)(id, SEL))controllerLayout)(controller, controllerLayoutSel);
               GSUpdateController(controller);
           }));
    cls = NSClassFromString(@"PHSSegmentedControl");
    SEL segmentLayoutSel = @selector(layoutSubviews);
    IMP segmentLayout = method_getImplementation(class_getInstanceMethod(cls, segmentLayoutSel));
    GSHook(cls, @"layoutSubviews", imp_implementationWithBlock(^(UIView *view) {
               ((void (*)(id, SEL))segmentLayout)(view, segmentLayoutSel);
               GSLayoutNativeControls(objc_getAssociatedObject(view, &GSGlassPairKey));
           }));
    SEL setIndexSel = NSSelectorFromString(@"setSelectedSegmentIndex:");
    IMP setIndex = method_getImplementation(class_getInstanceMethod(cls, setIndexSel));
    GSHook(cls,
           @"setSelectedSegmentIndex:", imp_implementationWithBlock(^(id control, NSInteger index) {
               ((void (*)(id, SEL, NSInteger))setIndex)(control, setIndexSel, index);
               GSPhotosGlassPair *pair = objc_getAssociatedObject(control, &GSGlassPairKey);
               if (pair && !pair.changing)
                   GSSyncTabSelection(pair);
           }));
    cls = NSClassFromString(@"M3CButton");
    SEL buttonLayoutSel = @selector(layoutSubviews);
    IMP buttonLayout = method_getImplementation(class_getInstanceMethod(cls, buttonLayoutSel));
    GSHook(cls, @"layoutSubviews", imp_implementationWithBlock(^(UIView *button) {
               ((void (*)(id, SEL))buttonLayout)(button, buttonLayoutSel);
               GSLayoutNativeControls(objc_getAssociatedObject(button, &GSGlassPairKey));
           }));
    GSInstalled = YES;
    GSDiscoverControllers();
}
void GSSetPhotosGlass(BOOL enabled) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GSSetPhotosGlass(enabled);
        });
        return;
    }
    GSInstallPhotosGlass();
    if (enabled && !GSInstalled)
        return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GSPhotosGlassPreference];
    GSWriteDesignCompatibilityOverride(enabled);
    GSRestartRequired = enabled != GSBootGlassEnabled;
    GSLastSkip = GSRestartRequired ? @"restart_required" : nil;
    if (!enabled || GSRestartRequired)
        for (GSPhotosGlassPair *pair in GSPairs.allObjects)
            GSRestore(pair);
    if (enabled && !GSRestartRequired) {
        GSDiscoverControllers();
        for (UIViewController *controller in GSControllers.allObjects)
            GSUpdateController(controller);
    }
}
NSDictionary *GSPhotosGlassSnapshot(void) {
    if (!NSThread.isMainThread) {
        __block NSDictionary *snapshot;
        dispatch_sync(dispatch_get_main_queue(), ^{
            snapshot = GSPhotosGlassSnapshot();
        });
        return snapshot;
    }
    NSUInteger attached = 0, visible = 0;
    for (GSPhotosGlassPair *pair in GSPairs.allObjects)
        if (pair.overlayWindow && pair.nativeTabController && pair.segments.superview == pair.bar &&
            pair.search.superview == pair.bar) {
            attached++;
            if (!pair.overlayWindow.hidden && !pair.overlayWindow.contentSuppressed &&
                !pair.nativeTabController.view.hidden)
                visible++;
        }
    NSString *unavailable = GSUnavailableReason();
    return @{@"enabled":@(GSPhotosGlassEnabled()),@"activeThisLaunch":@(GSPhotosGlassActiveThisLaunch()),@"available":@(unavailable==nil),@"hooksInstalled":@(GSInstalled),
  @"designCompatibilityOverride":@(GSDesignOverrideApplied),@"restartRequired":@(GSRestartRequired),@"controllersSeen":@(GSControllers.count),@"attachedBars":@(attached),@"visibleOverlays":@(visible),
  @"reason":unavailable?:(GSRestartRequired?@"restart_required":attached?@"attached":GSLastSkip?:(GSPhotosGlassEnabled()?@"waiting_for_bottom_bar":@"disabled")),@"lastSkipReason":GSLastSkip?:NSNull.null,@"lastLookup":GSLastLookup?:NSNull.null};
}
__attribute__((constructor)) static void GSLoadPhotosGlass(void) {
    @autoreleasepool {
        GSBootGlassEnabled =
            [NSUserDefaults.standardUserDefaults boolForKey:GSDesignCompatibilityOverride];
        GSDesignOverrideApplied = GSBootGlassEnabled;
        if (!GSPhotosHostSupported())
            return;
        GSBootGlassEnabled = GSPhotosGlassEnabled() && GSPhotosGlassHostVersionSupported();
        GSWriteDesignCompatibilityOverride(GSBootGlassEnabled);
        GSDesignOverrideApplied = GSBootGlassEnabled;
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        GSInstallPhotosGlass();
                        GSDiscoverControllers();
                        for (GSPhotosGlassPair *pair in GSPairs.allObjects)
                            GSLayoutNativeControls(pair);
                    }];
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        for (GSPhotosGlassPair *pair in GSPairs.allObjects)
                            pair.overlayWindow.hidden = YES;
                    }];
        dispatch_async(dispatch_get_main_queue(), ^{
            GSInstallPhotosGlass();
        });
    }
}