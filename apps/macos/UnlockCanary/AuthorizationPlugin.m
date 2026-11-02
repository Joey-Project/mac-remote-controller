#import "CanaryGrant.h"
#import <Security/AuthorizationPlugin.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    const AuthorizationCallbacks *callbacks;
} SRPlugin;
typedef struct {
    SRPlugin *plugin;
    AuthorizationEngineRef engine;
} SRMechanism;

static OSStatus destroy(AuthorizationPluginRef plugin) {
    free(plugin);
    return errAuthorizationSuccess;
}

static OSStatus create(AuthorizationPluginRef plugin, AuthorizationEngineRef engine,
                       AuthorizationMechanismId name, AuthorizationMechanismRef *result) {
    if (!plugin || !engine || !name || !result || strcmp(name, "canary"))
        return errAuthorizationInternal;
    SRMechanism *mechanism = calloc(1, sizeof(*mechanism));
    if (!mechanism)
        return errAuthorizationInternal;
    mechanism->plugin = plugin;
    mechanism->engine = engine;
    *result = mechanism;
    return errAuthorizationSuccess;
}

static OSStatus invoke(AuthorizationMechanismRef reference) {
    @autoreleasepool {
        SRMechanism *mechanism = reference;
        bool allowed = geteuid() == 0 && SRConsumeCanaryGrant(SR_CANARY_DIRECTORY, 0,
                                                              SRReadConsole(), SRContinuousTime());
        return mechanism->plugin->callbacks->SetResult(
            mechanism->engine, allowed ? kAuthorizationResultAllow : kAuthorizationResultDeny);
    }
}

static OSStatus deactivate(AuthorizationMechanismRef reference) {
    SRMechanism *mechanism = reference;
    return mechanism->plugin->callbacks->DidDeactivate(mechanism->engine);
}

static OSStatus destroyMechanism(AuthorizationMechanismRef reference) {
    free(reference);
    return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface interface = {
    kAuthorizationPluginInterfaceVersion, destroy, create, invoke, deactivate, destroyMechanism};

__attribute__((visibility("default"))) OSStatus
AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *result,
                          const AuthorizationPluginInterface **functions) {
    if (!callbacks || callbacks->version != kAuthorizationCallbacksVersion ||
        !callbacks->SetResult || !callbacks->DidDeactivate || !result || !functions)
        return errAuthorizationInternal;
    SRPlugin *plugin = calloc(1, sizeof(*plugin));
    if (!plugin)
        return errAuthorizationInternal;
    plugin->callbacks = callbacks;
    *result = plugin;
    *functions = &interface;
    return errAuthorizationSuccess;
}
