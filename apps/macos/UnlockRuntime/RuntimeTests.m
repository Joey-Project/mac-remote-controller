#import "UnlockGrant.h"
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks;
static void check(bool condition, const char *name) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}
static SRConsoleSnapshot fixture(void) {
    SRConsoleSnapshot value = {.known = true, .loggedIn = true, .locked = true, .userID = 501};
    strcpy(value.sessionUUID, "00000000-0000-4000-8000-000000000001");
    strcpy(value.bootUUID, "00000000-0000-4000-8000-000000000002");
    return value;
}
static NSString *directory(NSString *parent) {
    NSString *path = [parent stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check(mkdir(path.fileSystemRepresentation, 0700) == 0, "private fixture");
    return path;
}
static int start(NSString *path) {
    int lease = SRStartUnlockLease(path.fileSystemRepresentation, getuid());
    check(lease >= 0, "start broker lease");
    check(SRSetUnlockEnabled(path.fileSystemRepresentation, getuid(), true), "enable generation");
    return lease;
}
static void arm(NSString *path) {
    check(SRCreateUnlockGrant(path.fileSystemRepresentation, getuid(), fixture(), 100),
          "arm fixture");
}
static bool consume(NSString *path, SRConsoleSnapshot state, double now) {
    return SRConsumeUnlockGrant(path.fileSystemRepresentation, getuid(), state, now);
}
typedef struct {
    const char *path;
    atomic_uint winners;
} Race;
static void *consumer(void *context) {
    @autoreleasepool {
        Race *race = context;
        if (SRConsumeUnlockGrant(race->path, getuid(), fixture(), 101))
            atomic_fetch_add(&race->winners, 1);
    }
    return NULL;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        check(geteuid() != 0 && argc == 2, "ordinary-user isolated tests only");
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        check(mkdir(root.fileSystemRepresentation, 0700) == 0, "new test root");
        NSString *path = directory(root);
        check(!SRCreateUnlockGrant(path.fileSystemRepresentation, getuid(), fixture(), 100),
              "no broker denied");
        int lease = start(path);
        arm(path);
        check(consume(path, fixture(), 101), "fresh grant allowed");
        check(!consume(path, fixture(), 101), "replay denied");
        arm(path);
        check(!consume(path, fixture(), 105), "exact expiry denied");
        arm(path);
        close(lease);
        check(!consume(path, fixture(), 101), "broker exit invalidates pending grant");
        lease = start(path);
        arm(path);
        NSData *old =
            [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"grant"]];
        check(old.length == 144, "fixed grant format");
        close(lease);
        lease = start(path);
        check([old writeToFile:[path stringByAppendingPathComponent:@"grant"] atomically:NO],
              "old generation fixture");
        check(chmod([path stringByAppendingPathComponent:@"grant"].fileSystemRepresentation,
                    0600) == 0,
              "private old fixture");
        check(!consume(path, fixture(), 101), "restarted broker rejects old generation");
        arm(path);
        check(SRSetUnlockEnabled(path.fileSystemRepresentation, getuid(), false),
              "disable revokes");
        check(!consume(path, fixture(), 101), "disabled grant denied");
        check(!SRCreateUnlockGrant(path.fileSystemRepresentation, getuid(), fixture(), 100),
              "disabled arm denied");
        check(SRSetUnlockEnabled(path.fileSystemRepresentation, getuid(), true), "re-enable");
        SRConsoleSnapshot state = fixture();
        state.locked = false;
        check(!SRCreateUnlockGrant(path.fileSystemRepresentation, getuid(), state, 100),
              "already unlocked denied");
        arm(path);
        state = fixture();
        state.userID++;
        check(!consume(path, state, 101), "different user denied");
        arm(path);
        state = fixture();
        state.sessionUUID[0] = 'A';
        check(!consume(path, state, 101), "different session denied");
        arm(path);
        state = fixture();
        state.bootUUID[0] = 'A';
        check(!consume(path, state, 101), "different boot denied");
        arm(path);
        check(!consume(path, fixture(), NAN), "invalid clock denied");
        arm(path);
        Race race = {.path = path.fileSystemRepresentation, .winners = 0};
        pthread_t workers[16];
        for (size_t index = 0; index < 16; index++)
            check(!pthread_create(&workers[index], NULL, consumer, &race), "start consumer");
        for (size_t index = 0; index < 16; index++)
            check(!pthread_join(workers[index], NULL), "join consumer");
        check(atomic_load(&race.winners) == 1, "one concurrent winner");
        close(lease);
        NSString *foreign = directory(root);
        NSString *marker = [foreign stringByAppendingPathComponent:@"enabled"];
        check([[@"foreign" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:marker
                                                                    atomically:NO],
              "foreign marker fixture");
        check(chmod(marker.fileSystemRepresentation, 0600) == 0, "private foreign marker");
        check(SRStartUnlockLease(foreign.fileSystemRepresentation, getuid()) < 0,
              "foreign marker blocks start");
        check(!SRSetUnlockEnabled(foreign.fileSystemRepresentation, getuid(), false),
              "foreign marker blocks cleanup");
        check([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding
                                            error:NULL] isEqualToString:@"foreign"],
              "foreign marker preserved");
        check([[NSFileManager defaultManager] removeItemAtPath:root error:NULL],
              "remove owned fixtures");
        printf("Passed %u runtime grant checks.\n", checks);
    }
}
