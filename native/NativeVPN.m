#import "Bridge.h"
#import <NetworkExtension/NetworkExtension.h>
#import <Security/Authorization.h>
#import <dlfcn.h>

// Unsupported macOS declarations stay in this file. Never bypass authorization.
@interface NEVPN : NSObject
@property(copy) NEVPNProtocol *protocol;
@property(getter=isEnabled) BOOL enabled;
@property(getter=isOnDemandEnabled) BOOL onDemandEnabled;
@property(getter=isDisconnectOnDemandEnabled) BOOL disconnectOnDemandEnabled;
@end
@interface NEConfiguration : NSObject
- (instancetype)initWithName:(NSString *)name grade:(NSInteger)grade;
@property(readonly) NSUUID *identifier;
@property(copy) NSString *name;
@property(copy) NSString *application;
@property(copy) NSString *applicationName;
@property(copy) NEVPN *VPN;
@end
@interface NEConfigurationManager : NSObject
- (void)setAuthorization:(AuthorizationRef)authorization;
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)queue handler:(void (^)(NSArray *, NSError *))handler;
- (void)saveConfiguration:(NEConfiguration *)configuration withCompletionQueue:(dispatch_queue_t)queue handler:(void (^)(NSError *))handler;
@end

typedef void *Session;
typedef Session (*CreateSession)(const unsigned char *, int);
typedef void (*SessionAction)(Session);
typedef void (*SessionStatus)(Session, dispatch_queue_t, void (^)(int));
typedef void (*SessionEvents)(Session, dispatch_queue_t, void (^)(int, void *));

static NSError *failure(NSString *message) {
    return [NSError errorWithDomain:@"Meridian" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation NativeVPN {
    CreateSession _create;
    SessionAction _start, _stop, _cancel, _release;
    SessionStatus _getStatus;
    SessionEvents _setEvents;
    Session _session;
    NSInteger _status;
    NSUInteger _operation, _epoch;
    BOOL _available, _suppressStatus, _starting, _sawProgress;
    AuthorizationRef _authorization;
    void (^_stopped)(NSError *);
    void (^_connected)(NSError *);
    NEConfigurationManager *_writer;
}

- (instancetype)init {
    if ((self = [super init])) {
        (void)[NEVPNProtocolIKEv2 class];
        Class manager = NSClassFromString(@"NEConfigurationManager");
        _available = manager && [manager instancesRespondToSelector:@selector(setAuthorization:)]
            && [manager instancesRespondToSelector:@selector(loadConfigurationsWithCompletionQueue:handler:)]
            && [manager instancesRespondToSelector:@selector(saveConfiguration:withCompletionQueue:handler:)]
            && [NSClassFromString(@"NEConfiguration") instancesRespondToSelector:@selector(initWithName:grade:)]
            && [NSClassFromString(@"NEVPN") instancesRespondToSelector:@selector(isOnDemandEnabled)]
            && [NSClassFromString(@"NEVPN") instancesRespondToSelector:@selector(isDisconnectOnDemandEnabled)];
        void *library = dlopen("/usr/lib/system/libsystem_networkextension.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (library) {
            _create = (CreateSession)dlsym(library, "ne_session_create");
            _start = (SessionAction)dlsym(library, "ne_session_start");
            _stop = (SessionAction)dlsym(library, "ne_session_stop");
            _cancel = (SessionAction)dlsym(library, "ne_session_cancel");
            _release = (SessionAction)dlsym(library, "ne_session_release");
            _getStatus = (SessionStatus)dlsym(library, "ne_session_get_status");
            _setEvents = (SessionEvents)dlsym(library, "ne_session_set_event_handler");
        }
        _available &= _create && _start && _stop && _cancel && _release && _getStatus && _setEvents;
        _status = 1;
    }
    return self;
}

- (BOOL)available { return _available; }

- (BOOL)owns:(NEConfiguration *)configuration identifier:(NSString *)identifier {
    return identifier.length && [configuration.identifier.UUIDString isEqualToString:identifier]
        && [configuration.application isEqualToString:NSBundle.mainBundle.bundleIdentifier]
        && [configuration.name isEqualToString:@"Meridian"]
        && [configuration.VPN.protocol isKindOfClass:[NEVPNProtocolIKEv2 class]];
}

- (void)loadOwned:(void (^)(NEConfiguration *, NSError *))completion {
    NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:@"vpnIdentifier"];
    if (!identifier) { completion(nil, nil); return; }
    if (!_available) { completion(nil, failure(@"This macOS version does not support Meridian's native VPN controls.")); return; }
    // A fresh manager avoids accepting the stale list observed in the feasibility test.
    NEConfigurationManager *reader = [NSClassFromString(@"NEConfigurationManager") new];
    [reader loadConfigurationsWithCompletionQueue:dispatch_get_main_queue() handler:^(NSArray *configurations, NSError *error) {
        (void)reader;
        if (error) { completion(nil, error); return; }
        for (NEConfiguration *configuration in configurations) {
            if ([configuration.identifier.UUIDString isEqualToString:identifier]) {
                completion([self owns:configuration identifier:identifier] ? configuration : nil,
                    [self owns:configuration identifier:identifier] ? nil : failure(@"The saved VPN belongs to another application. Meridian will not change it."));
                return;
            }
        }
        completion(nil, nil);
    }];
}

- (void)detach {
    _epoch++;
    if (_session) {
        _setEvents(_session, dispatch_get_main_queue(), ^(int event, void *data) {});
        _cancel(_session);
        _release(_session);
        _session = NULL;
    }
}

- (BOOL)attach:(NEConfiguration *)configuration {
    [self detach];
    uuid_t bytes;
    [configuration.identifier getUUIDBytes:bytes];
    _session = _create(bytes, 1);
    if (!_session) return NO;
    NSUInteger epoch = _epoch;
    __weak NativeVPN *weakSelf = self;
    _setEvents(_session, dispatch_get_main_queue(), ^(int event, void *data) {
        NativeVPN *self = weakSelf;
        if (self && self->_epoch == epoch) [self refresh];
    });
    return YES;
}

- (void)refresh {
    if (!_session) return;
    NSUInteger epoch = _epoch;
    __weak NativeVPN *weakSelf = self;
    _getStatus(_session, dispatch_get_main_queue(), ^(int status) {
        NativeVPN *self = weakSelf;
        if (!self || self->_epoch != epoch) return;
        self->_status = status;
        if ((status == 0 || status == 1) && self->_stopped) {
            void (^done)(NSError *) = self->_stopped;
            self->_stopped = nil;
            done(nil);
            return;
        }
        if (self->_suppressStatus) return;
        if (self->_starting) {
            if (status == 2 || status == 4) self->_sawProgress = YES;
            if (status == 3 || ((status == 0 || status == 1) && self->_sawProgress)) {
                self->_starting = NO;
                void (^done)(NSError *) = self->_connected;
                self->_connected = nil;
                if (done) done(status == 3 ? nil : failure(@"Nord rejected the connection. Check your service credentials and Nord certificate."));
            } else if (status == 0 || status == 1) return;
        }
        if (self.statusChanged) self.statusChanged(status);
    });
}

- (void)observe {
    if (!_available) return;
    NSUInteger operation = _operation;
    [self loadOwned:^(NEConfiguration *configuration, NSError *error) {
        if (operation == self->_operation && !self->_session && !error && configuration && [self attach:configuration]) [self refresh];
    }];
}

- (void)stopSession:(void (^)(NSError *))completion {
    if (!_session) { completion(nil); return; }
    _stopped = [completion copy];
    NSUInteger epoch = _epoch;
    _stop(_session);
    [self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self->_epoch != epoch || !self->_stopped) return;
        void (^done)(NSError *) = self->_stopped;
        self->_stopped = nil;
        done(failure(@"The previous Meridian connection did not stop. Retry after it disconnects."));
    });
}

- (void)disconnectWithCompletion:(void (^)(NSError *))completion {
    NSUInteger operation = ++_operation;
    _starting = NO;
    _connected = nil;
    _suppressStatus = YES;
    if (_stopped) { void (^previous)(NSError *) = _stopped; _stopped = nil; previous(failure(@"Connection request cancelled.")); }
    [self loadOwned:^(NEConfiguration *configuration, NSError *error) {
        if (operation != self->_operation) return;
        if (error) { self->_suppressStatus = NO; completion(error); return; }
        if (!self->_session && configuration && ![self attach:configuration]) {
            self->_suppressStatus = NO; completion(failure(@"macOS could not open the Meridian session.")); return;
        }
        [self stopSession:^(NSError *stopError) {
            if (operation != self->_operation) return;
            self->_suppressStatus = NO;
            completion(stopError);
            [self refresh];
        }];
    }];
}

- (BOOL)authorize:(NSError **)error {
    OSStatus result = errAuthorizationSuccess;
    if (!_authorization) result = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &_authorization);
    AuthorizationItem item = { "system.preferences.network", 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    if (result == errAuthorizationSuccess) result = AuthorizationCopyRights(_authorization, &rights, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize, NULL);
    if (result != errAuthorizationSuccess) {
        *error = failure(@"macOS did not authorize the VPN configuration. Click Connect to try again.");
        return NO;
    }
    return YES;
}

- (void)verifyHost:(NSString *)host reference:(NSData *)reference operation:(NSUInteger)operation attempts:(NSInteger)attempts completion:(void (^)(NSError *))completion {
    if (operation != _operation) return;
    [self loadOwned:^(NEConfiguration *configuration, NSError *error) {
        if (operation != self->_operation) return;
        NEVPNProtocolIKEv2 *protocol = (NEVPNProtocolIKEv2 *)configuration.VPN.protocol;
        BOOL matches = configuration && configuration.VPN.isEnabled && !configuration.VPN.isOnDemandEnabled
            && !configuration.VPN.isDisconnectOnDemandEnabled && !protocol.includeAllNetworks && !protocol.enforceRoutes
            && [protocol.serverAddress isEqualToString:host] && [protocol.remoteIdentifier isEqualToString:host]
            && [protocol.passwordReference isEqual:reference];
        if (!error && !matches && attempts > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                [self verifyHost:host reference:reference operation:operation attempts:attempts - 1 completion:completion];
            });
            return;
        }
        self->_writer = nil;
        if (error || !matches || ![self attach:configuration]) {
            self->_suppressStatus = NO;
            completion(error ?: failure(@"macOS has not confirmed the new VPN settings. No connection was started. Retry."));
            return;
        }
        self->_suppressStatus = NO;
        self->_starting = YES;
        self->_sawProgress = NO;
        self->_connected = [completion copy];
        if (self.statusChanged) self.statusChanged(2);
        self->_start(self->_session);
        [self refresh];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (operation != self->_operation || !self->_starting) return;
            self->_starting = NO;
            void (^done)(NSError *) = self->_connected;
            self->_connected = nil;
            self->_stop(self->_session);
            if (done) done(failure(@"Nord did not connect within 45 seconds. Check service credentials and the certificate, then Retry."));
        });
    }];
}

- (void)connectToHost:(NSString *)host username:(NSString *)username passwordReference:(NSData *)reference completion:(void (^)(NSError *))completion {
    if (!_available) { completion(failure(@"Native VPN controls are unavailable on this macOS version.")); return; }
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.nordvpn\\.com$" options:0 error:NULL];
    if ([pattern numberOfMatchesInString:host options:0 range:NSMakeRange(0, host.length)] != 1 || !username.length || !reference.length) {
        completion(failure(@"The Nord server or service credentials are invalid.")); return;
    }
    NSUInteger operation = ++_operation;
    _suppressStatus = YES;
    [self loadOwned:^(NEConfiguration *configuration, NSError *error) {
        if (operation != self->_operation) return;
        if (error) { self->_suppressStatus = NO; completion(error); return; }
        if (!self->_session && configuration && ![self attach:configuration]) {
            self->_suppressStatus = NO; completion(failure(@"macOS could not open the Meridian session.")); return;
        }
        [self stopSession:^(NSError *stopError) {
            if (operation != self->_operation) return;
            if (stopError) { self->_suppressStatus = NO; completion(stopError); return; }
            NSError *authError = nil;
            if (![self authorize:&authError]) { self->_suppressStatus = NO; completion(authError); return; }
            NEConfiguration *owned = configuration;
            if (!owned) {
                owned = [[NSClassFromString(@"NEConfiguration") alloc] initWithName:@"Meridian" grade:2];
                owned.application = NSBundle.mainBundle.bundleIdentifier;
                owned.applicationName = @"Meridian";
                // Persist identity before saving, so an interrupted first save cannot orphan ownership.
                [NSUserDefaults.standardUserDefaults setObject:owned.identifier.UUIDString forKey:@"vpnIdentifier"];
            }
            NEVPNProtocolIKEv2 *protocol = [NEVPNProtocolIKEv2 new];
            protocol.serverAddress = host;
            protocol.remoteIdentifier = host;
            protocol.username = username;
            protocol.passwordReference = reference;
            protocol.authenticationMethod = NEVPNIKEAuthenticationMethodNone;
            protocol.useExtendedAuthentication = YES;
            protocol.disconnectOnSleep = NO;
            protocol.includeAllNetworks = NO;
            protocol.enforceRoutes = NO;
            protocol.excludeLocalNetworks = YES;
            NEVPN *vpn = [NSClassFromString(@"NEVPN") new];
            vpn.protocol = protocol;
            vpn.enabled = YES;
            vpn.onDemandEnabled = NO;
            vpn.disconnectOnDemandEnabled = NO;
            owned.VPN = vpn;
            self->_writer = [NSClassFromString(@"NEConfigurationManager") new];
            [self->_writer setAuthorization:self->_authorization];
            [self->_writer saveConfiguration:owned withCompletionQueue:dispatch_get_main_queue() handler:^(NSError *saveError) {
                if (operation != self->_operation) return;
                if (saveError) { self->_suppressStatus = NO; self->_writer = nil; completion(saveError); return; }
                [self verifyHost:host reference:reference operation:operation attempts:12 completion:completion];
            }];
        }];
    }];
}

- (void)dealloc {
    [self detach];
    if (_authorization) AuthorizationFree(_authorization, kAuthorizationFlagDefaults);
}
@end
