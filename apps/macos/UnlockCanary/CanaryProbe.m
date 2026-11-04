#import "CanaryGrant.h"
#import <Foundation/Foundation.h>
#import <Security/Authorization.h>
#include <string.h>
#include <unistd.h>

static int report(NSString *status, NSString *category) {
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:@{@"status" : status, @"category" : category}
                                        options:NSJSONWritingSortedKeys
                                          error:NULL];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return [status isEqual:@"passed"] ? 0 : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return report(@"failed", @"one-fixed-operation-required");
        if (!strcmp(argv[1], "state")) {
            SRConsoleSnapshot state = SRReadConsole();
            return report(state.known ? @"passed" : @"failed", !state.known ? @"unknown-console"
                                                               : state.locked
                                                                   ? @"locked-console"
                                                                   : @"unlocked-console");
        }
        if (!strcmp(argv[1], "evaluate")) {
            AuthorizationRef reference = NULL;
            OSStatus status =
                AuthorizationCreate(NULL, NULL, kAuthorizationFlagDefaults, &reference);
            if (status != errAuthorizationSuccess)
                return report(@"failed", @"authorization-create-failed");
            AuthorizationItem item = {SR_CANARY_RIGHT, 0, NULL, 0};
            AuthorizationRights rights = {1, &item};
            status = AuthorizationCopyRights(reference, &rights, NULL,
                                             kAuthorizationFlagExtendRights, NULL);
            AuthorizationFree(reference, kAuthorizationFlagDestroyRights);
            return report(status == errAuthorizationSuccess ? @"passed" : @"failed",
                          status == errAuthorizationSuccess ? @"canary-allowed"
                                                            : @"canary-denied-or-unavailable");
        }
        if (geteuid() != 0)
            return report(@"failed", @"administrator-required");
        if (!strcmp(argv[1], "arm")) {
            bool result =
                SRCreateCanaryGrant(SR_CANARY_DIRECTORY, 0, SRReadConsole(), SRContinuousTime());
            return report(result ? @"passed" : @"failed",
                          result ? @"canary-armed" : @"canary-arm-refused");
        }
        if (!strcmp(argv[1], "revoke")) {
            bool result = SRRevokeCanaryGrant(SR_CANARY_DIRECTORY, 0);
            return report(result ? @"passed" : @"failed",
                          result ? @"canary-revoked" : @"canary-revoke-refused");
        }
        return report(@"failed", @"unknown-operation");
    }
}
