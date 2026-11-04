#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// Existing-session unlock only. The inert canary remains a separate bundle.
#define SR_UNLOCK_DIRECTORY "/var/db/com.joeyteng.sofaremote.unlock-runtime"
#define SR_UNLOCK_RIGHT "com.joeyteng.sofaremote.unlock.runtime"
#define SR_UNLOCK_BUNDLE_ID "com.joeyteng.sofaremote.unlock.runtime-plugin"
#define SR_UNLOCK_MAX_LIFETIME 5.0

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
    uint8_t generation[16];
    double issued;
    double expires;
    uint8_t nonce[16];
} SRUnlockGrant;

// A broker retains this descriptor's exclusive lock for its entire lifetime.
// Closing it invalidates all grants from that broker generation.
int SRStartUnlockLease(const char *directory, uid_t owner);
bool SRSetUnlockEnabled(const char *directory, uid_t owner, bool enabled);

SRConsoleSnapshot SRReadConsole(void);
double SRContinuousTime(void);
bool SRUnlockEligible(SRConsoleSnapshot snapshot);
bool SRUnlockMatches(const SRUnlockGrant *grant, SRConsoleSnapshot snapshot, double now);
bool SRCreateUnlockGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot,
                         double now);
bool SRConsumeUnlockGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot,
                          double now);
bool SRRevokeUnlockGrant(const char *directory, uid_t owner);
bool SRConsumeCurrentUnlockGrant(const char *directory, uid_t owner);
