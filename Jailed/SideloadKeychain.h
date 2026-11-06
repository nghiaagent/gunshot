#pragma once
#import <Foundation/Foundation.h>
void GSInstallSideloadKeychain(void);
// iCloudPartialStateHooks / Calls are ordered: phenotype enable flag, phenotype allocation,
// ssoauth enable flag, ssoauth allocation, backfill, read-write state.
NSDictionary *GSSideloadKeychainSnapshot(void);
