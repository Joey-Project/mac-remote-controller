#import "CanaryGrant.h"
#import <Foundation/Foundation.h>
#import <Security/AuthorizationPlugin.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *, AuthorizationPluginRef *,
                                          const AuthorizationPluginInterface **);

static unsigned checks;
static void check(bool condition, const char *label) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", label);
        exit(1);
    }
}

static SRConsoleSnapshot fixture(void) {
    SRConsoleSnapshot state = {.known = true, .loggedIn = true, .locked = false, .userID = 501};
    strcpy(state.sessionUUID, "00000000-0000-4000-8000-000000000001");
    strcpy(state.bootUUID, "00000000-0000-4000-8000-000000000002");
    return state;
}

static NSString *newDirectory(NSString *parent) {
    NSString *path = [parent stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check(mkdir(path.fileSystemRepresentation, 0700) == 0, "create fixture directory");
    return path;
}

static NSString *newGrant(NSString *parent) {
    NSString *directory = newDirectory(parent);
    check(SRCreateCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 100),
          "create grant");
    return directory;
}

static SRCanaryGrant readGrant(NSString *directory) {
    NSData *data =
        [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"grant"]];
    SRCanaryGrant grant;
    check(data.length == sizeof(grant), "fixed grant size");
    memcpy(&grant, data.bytes, sizeof(grant));
    return grant;
}

static void writeGrant(NSString *directory, const SRCanaryGrant *grant) {
    int fd = open([directory stringByAppendingPathComponent:@"grant"].fileSystemRepresentation,
                  O_WRONLY | O_TRUNC);
    check(fd >= 0 && write(fd, grant, sizeof(*grant)) == sizeof(*grant), "write modified fixture");
    check(close(fd) == 0, "close modified fixture");
}

static void semanticCases(NSString *parent) {
    NSString *directory = newGrant(parent);
    SRCanaryGrant grant = readGrant(directory);
    SRConsoleSnapshot state = fixture();
    check(SRCanaryMatches(&grant, state, 100), "fresh grant accepted");
    check(SRCanaryMatches(&grant, state, 104.999), "before expiry accepted");
    check(!SRCanaryMatches(&grant, state, 105), "exact expiry denied");
    check(!SRCanaryMatches(&grant, state, 99), "time before issuance denied");
    check(!SRCanaryMatches(&grant, state, NAN), "unknown clock denied");
    check(!SRCanaryMatches(&grant, state, INFINITY), "infinite clock denied");
    state.known = false;
    check(!SRCanaryMatches(&grant, state, 101), "unknown console denied");
    state = fixture();
    state.loggedIn = false;
    check(!SRCanaryMatches(&grant, state, 101), "initial login denied");
    state = fixture();
    state.locked = true;
    check(!SRCanaryMatches(&grant, state, 101), "canary can never unlock a locked session");
    state = fixture();
    state.userID++;
    check(!SRCanaryMatches(&grant, state, 101), "different user denied");
    state = fixture();
    state.sessionUUID[0] = 'A';
    check(!SRCanaryMatches(&grant, state, 101), "different session denied");
    state = fixture();
    state.bootUUID[0] = 'A';
    check(!SRCanaryMatches(&grant, state, 101), "different boot denied");
    state = fixture();
    state.userID = 0;
    check(!SRCanaryMatches(&grant, state, 101), "root console denied");
    state = fixture();
    state.sessionUUID[36] = 'X';
    check(!SRCanaryMatches(&grant, state, 101), "unterminated identity denied");
    grant.expires = 106;
    check(!SRCanaryMatches(&grant, fixture(), 101), "overlong grant denied");
    grant.expires = NAN;
    check(!SRCanaryMatches(&grant, fixture(), 101), "invalid expiry denied");
    grant.expires = 105;
    grant.issued = -1;
    check(!SRCanaryMatches(&grant, fixture(), 101), "negative issuance denied");
    grant.issued = 100;
    grant.version = 2;
    check(!SRCanaryMatches(&grant, fixture(), 101), "unknown format denied");
    grant.version = 1;
    grant.reserved[0] = 1;
    check(!SRCanaryMatches(&grant, fixture(), 101), "unknown reserved flags denied");
    grant.reserved[0] = 0;
    grant.magic[0] = 'X';
    check(!SRCanaryMatches(&grant, fixture(), 101), "foreign grant denied");
}

static void fileCases(NSString *parent) {
    NSString *directory = newGrant(parent);
    check(SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "first consumption succeeds");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "replay denied");
    directory = newGrant(parent);
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 106),
          "expired file denied");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "failed attempt consumes authority");
    directory = newGrant(parent);
    SRCanaryGrant original = readGrant(directory);
    check(!SRCreateCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "writer never replaces live authority");
    SRCanaryGrant retained = readGrant(directory);
    check(memcmp(&original, &retained, sizeof(original)) == 0, "existing grant unchanged");
    check(SRRevokeCanaryGrant(directory.fileSystemRepresentation, getuid()),
          "explicit cancellation");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "cancelled grant denied");
    directory = newGrant(parent);
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid() + 1, fixture(), 101),
          "wrong directory owner denied");
    check(chmod(directory.fileSystemRepresentation, 0755) == 0, "fixture permissions changed");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "broad directory permissions denied");
    check(chmod(directory.fileSystemRepresentation, 0700) == 0, "restore fixture permissions");
    NSString *path = [directory stringByAppendingPathComponent:@"grant"];
    check(chmod(path.fileSystemRepresentation, 0644) == 0, "broaden grant permissions");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "broad grant permissions denied");
    check(chmod(path.fileSystemRepresentation, 0600) == 0, "restore grant permissions");
    NSString *alias = [directory stringByAppendingPathComponent:@"alias"];
    check(link(path.fileSystemRepresentation, alias.fileSystemRepresentation) == 0,
          "create hard link fixture");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "hard link denied");
    directory = newGrant(parent);
    path = [directory stringByAppendingPathComponent:@"grant"];
    check(truncate(path.fileSystemRepresentation, 127) == 0, "truncate fixture");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "short file denied");
    check(truncate(path.fileSystemRepresentation, 129) == 0, "extend fixture");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "oversized file denied");
    directory = newDirectory(parent);
    path = [directory stringByAppendingPathComponent:@"grant"];
    check(mkfifo(path.fileSystemRepresentation, 0600) == 0, "create FIFO fixture");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "FIFO refused without blocking");
    NSString *other = newGrant(parent);
    directory = newDirectory(parent);
    path = [directory stringByAppendingPathComponent:@"grant"];
    check(symlink([other stringByAppendingPathComponent:@"grant"].fileSystemRepresentation,
                  path.fileSystemRepresentation) == 0,
          "create symlink fixture");
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "symlink grant denied");
    check(SRConsumeCanaryGrant(other.fileSystemRepresentation, getuid(), fixture(), 101),
          "symlink target was not consumed");
    NSString *directoryAlias = [parent stringByAppendingPathComponent:@"directory-alias"];
    check(symlink(other.fileSystemRepresentation, directoryAlias.fileSystemRepresentation) == 0,
          "create directory alias");
    check(!SRConsumeCanaryGrant(directoryAlias.fileSystemRepresentation, getuid(), fixture(), 101),
          "directory alias denied");
    directory = newGrant(parent);
    path = [directory stringByAppendingPathComponent:@"benign-child"];
    check([@"metadata churn" writeToFile:path
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:NULL],
          "benign child creation");
    check(SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "directory timestamp changes do not revoke an unchanged grant");
    directory = newGrant(parent);
    SRCanaryGrant changed = readGrant(directory);
    changed.magic[0] = 'X';
    writeGrant(directory, &changed);
    check(!SRConsumeCanaryGrant(directory.fileSystemRepresentation, getuid(), fixture(), 101),
          "same-sized foreign content denied");
}

typedef struct {
    const char *path;
    atomic_uint winners;
} Race;
static void *consume(void *argument) {
    @autoreleasepool {
        Race *race = argument;
        if (SRConsumeCanaryGrant(race->path, getuid(), fixture(), 101))
            atomic_fetch_add(&race->winners, 1);
    }
    return NULL;
}

static void concurrencyCase(NSString *parent) {
    NSString *directory = newGrant(parent);
    Race race = {.path = directory.fileSystemRepresentation, .winners = 0};
    pthread_t workers[16];
    for (size_t index = 0; index < 16; index++)
        check(pthread_create(&workers[index], NULL, consume, &race) == 0, "start consumer");
    for (size_t index = 0; index < 16; index++)
        check(pthread_join(workers[index], NULL) == 0, "join consumer");
    check(atomic_load(&race.winners) == 1, "one winner among concurrent consumers");
}

static AuthorizationResult lastResult;
static OSStatus captureResult(AuthorizationEngineRef engine, AuthorizationResult result) {
    (void)engine;
    lastResult = result;
    return errAuthorizationSuccess;
}
static OSStatus captureDeactivation(AuthorizationEngineRef engine) {
    (void)engine;
    return errAuthorizationSuccess;
}

static void callbackCases(void) {
    AuthorizationCallbacks callbacks = {.version = kAuthorizationCallbacksVersion,
                                        .SetResult = captureResult,
                                        .DidDeactivate = captureDeactivation};
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *functions = NULL;
    AuthorizationCallbacks invalidCallbacks = callbacks;
    invalidCallbacks.SetResult = NULL;
    check(AuthorizationPluginCreate(&invalidCallbacks, &plugin, &functions) !=
              errAuthorizationSuccess,
          "invalid callback table denied");
    check(AuthorizationPluginCreate(&callbacks, &plugin, &functions) == errAuthorizationSuccess,
          "SDK entry point creates plugin");
    AuthorizationMechanismRef mechanism = NULL;
    AuthorizationEngineRef engine = (AuthorizationEngineRef)(uintptr_t)1;
    check(functions->MechanismCreate(plugin, engine, "unlock", &mechanism) !=
              errAuthorizationSuccess,
          "real unlock mechanism is unavailable in canary");
    check(functions->MechanismCreate(plugin, engine, "canary", &mechanism) ==
              errAuthorizationSuccess,
          "canary mechanism creates");
    lastResult = kAuthorizationResultAllow;
    check(functions->MechanismInvoke(mechanism) == errAuthorizationSuccess &&
              lastResult == kAuthorizationResultDeny,
          "non-root callback always denies");
    check(functions->MechanismDeactivate(mechanism) == errAuthorizationSuccess,
          "mechanism deactivates");
    check(functions->MechanismDestroy(mechanism) == errAuthorizationSuccess, "mechanism destroyed");
    check(functions->PluginDestroy(plugin) == errAuthorizationSuccess, "plugin destroyed");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2 || geteuid() == 0) {
            fputs("Run tests as a regular user with one private fixture directory.\n", stderr);
            return 1;
        }
        NSString *parent = [NSString stringWithUTF8String:argv[1]];
        check(mkdir(parent.fileSystemRepresentation, 0700) == 0, "create test root");
        semanticCases(parent);
        fileCases(parent);
        concurrencyCase(parent);
        callbackCases();
        check([[NSFileManager defaultManager] removeItemAtPath:parent error:NULL],
              "remove owned fixtures");
        printf("Passed %u native canary checks, including 16 concurrent consumers.\n", checks);
    }
    return 0;
}
