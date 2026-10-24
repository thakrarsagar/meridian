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
        puts("PASS: existing-profile revision loading and ownership revalidation through native Connect. No system configuration, authorization, session, Keychain, network, or persistent-preference operations.");
    }
    return 0;
}
