#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// The canary can authorize only while the console is already unlocked.
// This is a loader/policy probe, never a production screen-unlock grant.
#define SR_CANARY_DIRECTORY "/var/db/com.joeyteng.sofaremote.unlock-canary"
#define SR_CANARY_RIGHT "com.joeyteng.sofaremote.unlock.canary"
#define SR_CANARY_BUNDLE_ID "com.joeyteng.sofaremote.unlock.canary-plugin"
#define SR_CANARY_MAX_LIFETIME 5.0

typedef struct {
    bool known;
    bool loggedIn;
    bool locked;
    uint32_t userID;
    char sessionUUID[37];
    char bootUUID[37];
} SRConsoleSnapshot;

typedef struct {
    uint8_t magic[8];
    uint32_t version;
    uint32_t userID;
    char sessionUUID[37];
    char bootUUID[37];
    uint8_t reserved[6];
    double issued;
    double expires;
    uint8_t nonce[16];
} SRCanaryGrant;

SRConsoleSnapshot SRReadConsole(void);
double SRContinuousTime(void);
bool SRCanaryEligible(SRConsoleSnapshot snapshot);
bool SRCanaryMatches(const SRCanaryGrant *grant, SRConsoleSnapshot snapshot, double now);
bool SRCreateCanaryGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot,
                         double now);
bool SRConsumeCanaryGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot,
                          double now);
bool SRRevokeCanaryGrant(const char *directory, uid_t owner);
bool SRConsumeCurrentCanaryGrant(const char *directory, uid_t owner);
