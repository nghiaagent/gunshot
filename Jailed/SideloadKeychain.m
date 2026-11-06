#import "SideloadKeychain.h"
#import "../Shared/GSPhotosCompatibility.h"
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <stdlib.h>

enum { GSICloudHookCount = 6 };
static atomic_bool GSPrivateModeHook, GSICloudInstalled[GSICloudHookCount];
static atomic_ulong GSPrivateModeCalls, GSICloudCalls[GSICloudHookCount];

static _Bool GSUsePrivateKeychain(id object, SEL selector) {
    atomic_fetch_add(&GSPrivateModeCalls, 1);
    return 1;
}

// Google Photos 8.0.0 adds an iCloud partial-state feature to SSO. It builds its own shared
// Keychain access group (kSecAttrSynchronizable) and ignores usePrivateKeychain, so a re-signed
// app that lacks the group fails with errSecMissingEntitlement. Switch the feature off: the
// experiment flags report disabled, the backfill does nothing and the service is not read-write.
// A hook is installed only when its class has the exact selector and type encoding.
// One entry point per hook so each reports its own call count; no arguments are read.
#define GSICLOUD_HOOK(index, type)                                                                 \
    static type GSICloudHook##index(id object, SEL selector) {                                     \
        atomic_fetch_add(&GSICloudCalls[index], 1);                                                \
        return 0;                                                                                  \
    }
GSICLOUD_HOOK(0, _Bool)
GSICLOUD_HOOK(1, long)
GSICLOUD_HOOK(2, _Bool)
GSICLOUD_HOOK(3, long)
static void GSICloudHook4(id object, SEL selector) {
    atomic_fetch_add(&GSICloudCalls[4], 1);
}
GSICLOUD_HOOK(5, _Bool)

static const struct {
    const char *cls, *selector, *abi;
    IMP imp;
} GSICloudHooks[GSICloudHookCount] = {
    {"SSOPhenotypeFlagsServiceImpl", "enableICloudPartialStateExperimentKeychainAccess", "B16@0:8",
     (IMP)GSICloudHook0},
    {"SSOPhenotypeFlagsServiceImpl", "iCloudPartialStatePerArmAllocationBPS", "q16@0:8",
     (IMP)GSICloudHook1},
    {"SSOSsoauthIosImpl",
     "IcloudPartialStateAccounts__enable_icloud_partial_state_experiment_keychain_access",
     "B16@0:8", (IMP)GSICloudHook2},
    {"SSOSsoauthIosImpl", "IcloudPartialStateAccounts__icloud_partial_state_per_arm_allocation_bps",
     "q16@0:8", (IMP)GSICloudHook3},
    {"SSOService", "maybePerformICloudPartialStateBackfill", "v16@0:8", (IMP)GSICloudHook4},
    {"SSOICloudPartialStateServiceImpl", "isReadWriteEnabled", "B16@0:8", (IMP)GSICloudHook5},
};

static void GSInstallICloudHooks(void) {
    for (int index = 0; index < GSICloudHookCount; index++) {
        if (atomic_load(&GSICloudInstalled[index]))
            continue;
        Class cls = NSClassFromString(@(GSICloudHooks[index].cls));
        NSString *selector = @(GSICloudHooks[index].selector);
        if (!GSPhotosHasMethod(cls, selector, GSICloudHooks[index].abi))
            continue;
        class_replaceMethod(cls, NSSelectorFromString(selector), GSICloudHooks[index].imp,
                            GSICloudHooks[index].abi);
        atomic_store(&GSICloudInstalled[index], YES);
    }
}

void GSInstallSideloadKeychain(void) {
    const char *liveContainer = getenv("LC_HOME_PATH");
    if ((liveContainer && *liveContainer) || !GSPhotosHostSupported())
        return;
    Class configuration = NSClassFromString(@"SSOConfiguration");
    Class helper = NSClassFromString(@"SSOKeychainHelper");
    if (!GSPhotosHasMethod(configuration, @"usePrivateKeychain", "B16@0:8") ||
        !GSPhotosHasMethod(object_getClass(helper), @"sharedAccessGroup", "@16@0:8"))
        return;
    @synchronized(configuration) {
        static BOOL installed = NO;
        if (installed) {
            // Later-loaded SSO classes can still receive their hooks; no probe is repeated.
            GSInstallICloudHooks();
            return;
        }
        id group = nil;
        @try {
            group =
                ((id(*)(id, SEL))objc_msgSend)(helper, NSSelectorFromString(@"sharedAccessGroup"));
        } @catch (NSException *exception) {
            return;
        }
        if (![group isKindOfClass:NSString.class] || ![group length])
            return;
        // Check access only: no credentials, item attributes, or authentication UI.
        LAContext *context = [LAContext new];
        context.interactionNotAllowed = YES;
        NSDictionary *query = @{
            (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccessGroup : group,
            (__bridge id)kSecAttrService : @"dev.tqmane.gunshot.sso-access-probe",
            (__bridge id)kSecAttrAccount : @"access-group-check",
            (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
            (__bridge id)kSecUseAuthenticationContext : context
        };
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL) != errSecMissingEntitlement)
            return;
        // The signed app lacks this shared group. Use SSO's own private mode.
        class_replaceMethod(configuration, NSSelectorFromString(@"usePrivateKeychain"),
                            (IMP)GSUsePrivateKeychain, "B16@0:8");
        atomic_store(&GSPrivateModeHook, YES);
        GSInstallICloudHooks();
        installed = YES;
    }
}
NSDictionary *GSSideloadKeychainSnapshot(void) {
    // Status and counters only: no group, item, account or credential data.
    NSMutableArray *installed = [NSMutableArray new], *calls = [NSMutableArray new];
    for (int index = 0; index < GSICloudHookCount; index++) {
        [installed addObject:@(atomic_load(&GSICloudInstalled[index]))];
        [calls addObject:@(atomic_load(&GSICloudCalls[index]))];
    }
    return @{
        @"privateKeychainHook" : @(atomic_load(&GSPrivateModeHook)),
        @"privateKeychainCalls" : @(atomic_load(&GSPrivateModeCalls)),
        @"iCloudPartialStateHooks" : installed,
        @"iCloudPartialStateCalls" : calls
    };
}
