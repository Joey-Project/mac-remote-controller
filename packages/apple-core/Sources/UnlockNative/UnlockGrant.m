#import "UnlockGrant.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const uint8_t magic[8] = {'S', 'R', 'U', 'N', 'L', '0', '0', '1'};
_Static_assert(sizeof(SRUnlockGrant) == 144, "The local unlock format must stay fixed size");

static bool validUUID(const char value[37]) {
    if (value[36] != '\0')
        return false;
    for (size_t index = 0; index < 36; index++) {
        char c = value[index];
        bool separator = index == 8 || index == 13 || index == 18 || index == 23;
        if (separator ? c != '-' : !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) {
            return false;
        }
    }
    return true;
}

double SRContinuousTime(void) {
    mach_timebase_info_data_t base;
    if (mach_timebase_info(&base) != KERN_SUCCESS || base.denom == 0)
        return NAN;
    // Continuous time includes sleep, so suspension cannot extend a grant.
    return (double)((long double)mach_continuous_time() * base.numer / base.denom / 1e9L);
}

bool SRUnlockEligible(SRConsoleSnapshot snapshot) {
    return snapshot.known && snapshot.loggedIn && snapshot.locked && snapshot.userID > 0 &&
           snapshot.userID != UINT32_MAX && validUUID(snapshot.sessionUUID) &&
           validUUID(snapshot.bootUUID);
}

SRConsoleSnapshot SRReadConsole(void) {
    SRConsoleSnapshot result = {0};
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root)
        return result;
    id locked =
        CFBridgingRelease(IORegistryEntryCreateCFProperty(root, CFSTR("IOConsoleLocked"), NULL, 0));
    id users =
        CFBridgingRelease(IORegistryEntryCreateCFProperty(root, CFSTR("IOConsoleUsers"), NULL, 0));
    IOObjectRelease(root);
    if (![locked isKindOfClass:NSNumber.class] ||
        !([locked isEqual:@YES] || [locked isEqual:@NO]) || ![users isKindOfClass:NSArray.class])
        return result;
    NSDictionary *active = nil;
    for (id user in users) {
        if (![user isKindOfClass:NSDictionary.class])
            return result;
        id onConsole = user[@"kCGSSessionOnConsoleKey"];
        id loggedIn = user[@"kCGSessionLoginDoneKey"];
        if (![onConsole isKindOfClass:NSNumber.class] || ![loggedIn isKindOfClass:NSNumber.class])
            return result;
        if ([onConsole isEqual:@YES] && [loggedIn isEqual:@YES]) {
            if (active)
                return result;
            active = user;
        }
    }
    id uid = active[@"kCGSSessionUserIDKey"];
    id session = active[@"CGSSessionUniqueSessionUUID"];
    if (![uid isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)uid) == CFBooleanGetTypeID() ||
        !isfinite([uid doubleValue]) || [uid doubleValue] < 1 || [uid doubleValue] >= UINT32_MAX ||
        [uid doubleValue] != [uid unsignedIntValue] || ![session isKindOfClass:NSString.class])
        return result;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:session];
    if (!uuid)
        return result;
    char boot[128] = {0};
    size_t size = sizeof(boot);
    if (sysctlbyname("kern.bootsessionuuid", boot, &size, NULL, 0) ||
        !memchr(boot, '\0', sizeof(boot)))
        return result;
    NSUUID *bootUUID = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:boot]];
    if (!bootUUID)
        return result;
    memcpy(result.sessionUUID, uuid.UUIDString.UTF8String, 37);
    memcpy(result.bootUUID, bootUUID.UUIDString.UTF8String, 37);
    result.userID = [uid unsignedIntValue];
    result.loggedIn = true;
    result.locked = [locked boolValue];
    result.known = true;
    return result;
}

bool SRUnlockMatches(const SRUnlockGrant *grant, SRConsoleSnapshot snapshot, double now) {
    static const uint8_t zero[6] = {0};
    return grant && SRUnlockEligible(snapshot) && memcmp(grant->magic, magic, sizeof(magic)) == 0 &&
           grant->version == 1 && grant->userID == snapshot.userID &&
           memcmp(grant->sessionUUID, snapshot.sessionUUID, 37) == 0 &&
           memcmp(grant->bootUUID, snapshot.bootUUID, 37) == 0 &&
           memcmp(grant->reserved, zero, sizeof(zero)) == 0 && isfinite(now) &&
           isfinite(grant->issued) && isfinite(grant->expires) && grant->issued >= 0 &&
           now >= grant->issued && now < grant->expires && grant->expires > grant->issued &&
           grant->expires - grant->issued <= SR_UNLOCK_MAX_LIFETIME;
}

static bool sameObject(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

static int privateDirectory(const char *path, uid_t owner) {
    struct stat initial, opened;
    if (lstat(path, &initial) || !S_ISDIR(initial.st_mode) || initial.st_uid != owner ||
        (initial.st_mode & 07777) != 0700)
        return -1;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return -1;
    if (fstat(fd, &opened) || !sameObject(initial, opened) || opened.st_uid != owner ||
        (opened.st_mode & 07777) != 0700) {
        close(fd);
        return -1;
    }
    // Hold one nonblocking operation lock before opening any grant. This keeps
    // publication, claim and revocation ordered without waiting in authd.
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool privateGrant(struct stat value, uid_t owner) {
    return S_ISREG(value.st_mode) && value.st_uid == owner && (value.st_mode & 07777) == 0600 &&
           value.st_nlink == 1 && value.st_size == sizeof(SRUnlockGrant);
}

static bool readLease(int parent, uid_t owner, uint8_t generation[16]) {
    int fd = openat(parent, "lease", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return false;
    struct stat info;
    bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == owner &&
                 (info.st_mode & 07777) == 0600 && info.st_nlink == 1 && info.st_size == 16 &&
                 pread(fd, generation, 16, 0) == 16;
    // Shared acquisition succeeds when no broker owns the exclusive lease.
    // Concurrent readers cannot mistake each other's shared locks for a broker.
    if (valid) {
        int result = flock(fd, LOCK_SH | LOCK_NB);
        valid = result != 0 && (errno == EWOULDBLOCK || errno == EAGAIN);
    }
    close(fd);
    return valid;
}

static bool enabledAt(int parent, uid_t owner) {
    int fd = openat(parent, "enabled", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return false;
    struct stat info;
    char value = 0;
    bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == owner &&
                 (info.st_mode & 07777) == 0600 && info.st_nlink == 1 && info.st_size == 1 &&
                 read(fd, &value, 1) == 1 && value == '1';
    close(fd);
    return valid;
}

static bool admitPending(int parent, uid_t owner, const char *name) {
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW))
        return errno == ENOENT;
    if (!strcmp(name, "enabled"))
        return enabledAt(parent, owner);
    if (!privateGrant(info, owner))
        return false;
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return false;
    struct stat opened;
    SRUnlockGrant grant;
    bool valid = fstat(fd, &opened) == 0 && sameObject(info, opened) &&
                 privateGrant(opened, owner) && read(fd, &grant, sizeof(grant)) == sizeof(grant) &&
                 !memcmp(grant.magic, magic, sizeof(magic)) && grant.version == 1;
    close(fd);
    return valid;
}

static bool clearPending(int parent, uid_t owner) {
    if (!admitPending(parent, owner, "grant") || !admitPending(parent, owner, "enabled"))
        return false;
    bool valid = unlinkat(parent, "grant", 0) == 0 || errno == ENOENT;
    if (unlinkat(parent, "enabled", 0) && errno != ENOENT)
        valid = false;
    return valid;
}

int SRStartUnlockLease(const char *directory, uid_t owner) {
    if (owner != geteuid())
        return -1;
    int parent = privateDirectory(directory, owner);
    if (parent < 0)
        return -1;
    if (!admitPending(parent, owner, "grant") || !admitPending(parent, owner, "enabled")) {
        close(parent);
        return -1;
    }
    int fd = openat(parent, "lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != owner ||
        (info.st_mode & 07777) != 0600 || info.st_nlink != 1 || info.st_size > 16 ||
        flock(fd, LOCK_EX | LOCK_NB)) {
        if (fd >= 0)
            close(fd);
        close(parent);
        return -1;
    }
    uint8_t generation[16];
    arc4random_buf(generation, sizeof(generation));
    bool valid = ftruncate(fd, 0) == 0 && write(fd, generation, 16) == 16 && fsync(fd) == 0;
    // A restarted broker never inherits pending authority or enablement.
    if (!clearPending(parent, owner))
        valid = false;
    close(parent);
    if (!valid) {
        close(fd);
        return -1;
    }
    return fd;
}

bool SRSetUnlockEnabled(const char *directory, uid_t owner, bool enabled) {
    if (owner != geteuid())
        return false;
    int parent = privateDirectory(directory, owner);
    if (parent < 0)
        return false;
    bool valid;
    if (enabled) {
        uint8_t generation[16];
        valid = readLease(parent, owner, generation);
        int fd = valid ? openat(parent, "enabled",
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)
                       : -1;
        if (fd >= 0) {
            valid = write(fd, "1", 1) == 1 && fsync(fd) == 0;
            close(fd);
        } else
            valid = valid && errno == EEXIST && enabledAt(parent, owner);
    } else {
        valid = clearPending(parent, owner);
    }
    close(parent);
    return valid;
}

bool SRCreateUnlockGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot,
                         double now) {
    if (!SRUnlockEligible(snapshot) || !isfinite(now) || now < 0 || owner != geteuid())
        return false;
    int parent = privateDirectory(directory, owner);
    if (parent < 0)
        return false;
    SRUnlockGrant grant = {0};
    if (!enabledAt(parent, owner) || !readLease(parent, owner, grant.generation)) {
        close(parent);
        return false;
    }
    memcpy(grant.magic, magic, sizeof(magic));
    grant.version = 1;
    grant.userID = snapshot.userID;
    memcpy(grant.sessionUUID, snapshot.sessionUUID, 37);
    memcpy(grant.bootUUID, snapshot.bootUUID, 37);
    grant.issued = now;
    grant.expires = now + SR_UNLOCK_MAX_LIFETIME;
    arc4random_buf(grant.nonce, sizeof(grant.nonce));
    char temporary[64];
    snprintf(temporary, sizeof(temporary), ".pending-%s", NSUUID.UUID.UUIDString.UTF8String);
    int fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    bool success = false;
    if (fd >= 0) {
        success = write(fd, &grant, sizeof(grant)) == sizeof(grant) && fsync(fd) == 0;
        if (close(fd))
            success = false;
        if (success)
            success = renameatx_np(parent, temporary, parent, "grant", RENAME_EXCL) == 0;
        if (!success)
            unlinkat(parent, temporary, 0);
    }
    close(parent);
    return success;
}

static bool consumeGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot, double now,
                         bool observeCurrentSession) {
    int parent = privateDirectory(directory, owner);
    if (parent < 0)
        return false;
    int fd = openat(parent, "grant", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        close(parent);
        return false;
    }
    struct stat initial;
    if (fstat(fd, &initial) || !privateGrant(initial, owner)) {
        close(fd);
        close(parent);
        return false;
    }
    char claimed[64];
    snprintf(claimed, sizeof(claimed), ".consumed-%s", NSUUID.UUID.UUIDString.UTF8String);
    if (renameatx_np(parent, "grant", parent, claimed, RENAME_EXCL)) {
        close(fd);
        close(parent);
        return false;
    }
    struct stat moved, final;
    bool ownClaim =
        fstatat(parent, claimed, &moved, AT_SYMLINK_NOFOLLOW) == 0 && sameObject(initial, moved);
    SRUnlockGrant grant = {0};
    bool readOK = ownClaim && pread(fd, &grant, sizeof(grant), 0) == sizeof(grant) &&
                  fstat(fd, &final) == 0 && sameObject(initial, final) &&
                  privateGrant(final, owner);
    uint8_t generation[16];
    readOK = readOK && enabledAt(parent, owner) && readLease(parent, owner, generation) &&
             memcmp(grant.generation, generation, 16) == 0;
    if (observeCurrentSession) {
        // Recheck at the decision, after claiming the selected grant under lock.
        snapshot = SRReadConsole();
        now = SRContinuousTime();
    }
    close(fd);
    if (ownClaim)
        unlinkat(parent, claimed, 0);
    close(parent);
    // The selected property is object identity/access policy; timestamps are irrelevant.
    // Files are immutable publications from the cooperating root-only writer.
    return readOK && SRUnlockMatches(&grant, snapshot, now);
}

bool SRConsumeUnlockGrant(const char *directory, uid_t owner, SRConsoleSnapshot snapshot,
                          double now) {
    return consumeGrant(directory, owner, snapshot, now, false);
}

bool SRConsumeCurrentUnlockGrant(const char *directory, uid_t owner) {
    return consumeGrant(directory, owner, (SRConsoleSnapshot){0}, NAN, true);
}

bool SRRevokeUnlockGrant(const char *directory, uid_t owner) {
    int parent = privateDirectory(directory, owner);
    if (parent < 0)
        return false;
    struct stat item;
    bool success = fstatat(parent, "grant", &item, AT_SYMLINK_NOFOLLOW) == 0 &&
                   privateGrant(item, owner) && unlinkat(parent, "grant", 0) == 0;
    close(parent);
    return success;
}
