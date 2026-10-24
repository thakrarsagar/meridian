#import "../native/NativeVPN.m"

// These adapters drive the production Connect method without system writes or session calls.
@interface RevisionManager : NSObject
@property NEConfiguration *fixture;
@property BOOL loaded;
@property NSInteger saves;
@end
@implementation RevisionManager
- (void)setAuthorization:(AuthorizationRef)authorization {}
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)queue handler:(void (^)(NSArray *, NSError *))handler {
    self.loaded = YES;
    handler(@[self.fixture], nil);
}
- (void)saveConfiguration:(NEConfiguration *)configuration withCompletionQueue:(dispatch_queue_t)queue handler:(void (^)(NSError *))handler {
    self.saves++;
    handler(self.loaded ? nil : [NSError errorWithDomain:@"NEConfigurationErrorDomain" code:5
        userInfo:@{NSLocalizedDescriptionKey:@"configuration is stale"}]);
}
@end

@interface FixtureVPN : NativeVPN
@property NEConfiguration *fixture;
@property NSMutableArray<RevisionManager *> *managers;
@property BOOL authorized;
@property BOOL verified;
@property BOOL rejectAfterAuthorization;
@end
@implementation FixtureVPN
- (NEConfigurationManager *)newConfigurationManager {
    RevisionManager *manager = [RevisionManager new];
    manager.fixture = self.fixture;
    [self.managers addObject:manager];
    return (NEConfigurationManager *)manager;
}
- (BOOL)owns:(NEConfiguration *)configuration identifier:(NSString *)identifier {
    return [configuration.identifier.UUIDString isEqual:identifier] && !(self.authorized && self.rejectAfterAuthorization);
}
- (BOOL)attach:(NEConfiguration *)configuration { return YES; }
- (void)stopSession:(void (^)(NSError *))completion { completion(nil); }
- (BOOL)authorize:(NSError **)error { self.authorized = YES; return YES; }
- (void)verifyHost:(NSString *)host reference:(NSData *)reference operation:(NSUInteger)operation attempts:(NSInteger)attempts completion:(void (^)(NSError *))completion {
    self.verified = YES;
    completion(nil);
}
@end

static void require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static OSStatus credentialStatus;
static NSInteger credentialReads;
static void (^credentialReadAction)(void);
// Resolve this SDK call inside the test binary; dummy reads never reach Keychain.
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *values = (__bridge NSDictionary *)query;
    require([values[(__bridge id)kSecValuePersistentRef] isEqual:[@"test-reference" dataUsingEncoding:NSUTF8StringEncoding]],
        "Start must resolve only the supplied persistent reference");
    require([values[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]
        && [values[(__bridge id)kSecReturnData] boolValue], "Start must request the saved generic password");
    credentialReads++;
    if (credentialReadAction) credentialReadAction();
    if (credentialStatus != errSecSuccess) return credentialStatus;
    *result = CFBridgingRetain([@"test-password" dataUsingEncoding:NSUTF8StringEncoding]);
    return errSecSuccess;
}

@interface StartVPN : FixtureVPN
@property xpc_object_t options;
@end
@implementation StartVPN
- (void)sendStartOptions:(xpc_object_t)options { self.options = options; }
- (void)verifyHost:(NSString *)host reference:(NSData *)reference operation:(NSUInteger)operation attempts:(NSInteger)attempts completion:(void (^)(NSError *))completion {
    NSError *error = nil;
    BOOL started = [self startSessionWithProtocol:(NEVPNProtocolIKEv2 *)self.fixture.VPN.protocol operation:operation error:&error];
    completion(started ? nil : error);
}
@end

static void start(OSStatus status, BOOL cancel) {
    StartVPN *vpn = [StartVPN new];
    vpn.fixture = [[NEConfiguration alloc] initWithName:@"Meridian" grade:2];
    vpn.managers = [NSMutableArray new];
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"vpnIdentifier":vpn.fixture.identifier.UUIDString} forName:NSArgumentDomain];
    credentialStatus = status;
    credentialReads = 0;
    credentialReadAction = cancel ? ^{
        [vpn disconnectWithCompletion:^(NSError *error) { require(error == nil, "Fixture cancellation failed"); }];
    } : nil;
    __block NSError *error = nil;
    __block BOOL done = NO;
    [vpn connectToHost:@"test.nordvpn.com" username:@"test-user" passwordReference:[@"test-reference" dataUsingEncoding:NSUTF8StringEncoding]
        completion:^(NSError *failure) { error = failure; done = YES; }];
    credentialReadAction = nil;
    require(done && credentialReads == 1, "Connect must resolve the password only at Start");
    if (status == errSecSuccess && !cancel) {
        require(error == nil && vpn.options != NULL, "Start did not receive credential options");
        require(strcmp(xpc_dictionary_get_string(vpn.options, NEVPNConnectionStartOptionUsername.UTF8String) ?: "", "test-user") == 0
            && strcmp(xpc_dictionary_get_string(vpn.options, NEVPNConnectionStartOptionPassword.UTF8String) ?: "", "test-password") == 0,
            "Start must supply Apple's username and password override keys");
    } else {
        require(error != nil && vpn.options == NULL, "Denied or cancelled credential access must fail before Start");
    }
}

static void run(BOOL rejectAfterAuthorization) {
    FixtureVPN *vpn = [FixtureVPN new];
    vpn.fixture = [[NEConfiguration alloc] initWithName:@"Meridian" grade:2];
    vpn.managers = [NSMutableArray new];
    vpn.rejectAfterAuthorization = rejectAfterAuthorization;
    // A process-only lookup override; the tests never persist a preference or create a profile.
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"vpnIdentifier":vpn.fixture.identifier.UUIDString} forName:NSArgumentDomain];
    __block NSError *failure = nil; __block BOOL done = NO;
    [vpn connectToHost:@"test.nordvpn.com" username:@"test-user" passwordReference:[@"test-reference" dataUsingEncoding:NSUTF8StringEncoding]
        completion:^(NSError *error) { failure = error; done = YES; }];
    require(done, "Connect did not finish with the synchronous platform adapters");
    if (rejectAfterAuthorization) {
        require(failure != nil && !vpn.verified, "Ownership must be revalidated after authorization");
        for (RevisionManager *manager in vpn.managers) require(manager.saves == 0, "An ownership conflict reached Save");
    } else {
        require(failure == nil && vpn.verified, "Existing profile save failed because the writer had no loaded revision");
        RevisionManager *writer = vpn.managers.lastObject;
        require(writer.loaded && writer.saves == 1, "Save must use the manager that loaded the profile revision");
    }
}

int main(void) {
    @autoreleasepool {
        run(NO);
        run(YES);
        start(errSecSuccess, NO);
        start(errSecInteractionNotAllowed, NO);
        start(errSecSuccess, YES);
        puts("PASS: existing-profile revision loading, ownership revalidation, password handoff, and denied/cancelled credential access through native Connect. No system configuration, authorization, session, Keychain, network, or persistent-preference operations.");
    }
    return 0;
}
