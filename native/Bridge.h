#import <Foundation/Foundation.h>

void * _Nonnull nord_core_new(void);
char * _Nullable nord_core_call(void * _Nonnull core, const char * _Nonnull input);
void nord_core_free(void * _Nonnull core);
void nord_string_free(char * _Nonnull string);

NS_ASSUME_NONNULL_BEGIN
@interface NativeVPN : NSObject
@property(copy, nullable) void (^statusChanged)(NSInteger status);
@property(readonly) BOOL available;
- (void)observe;
- (void)connectToHost:(NSString *)host username:(NSString *)username
   passwordReference:(NSData *)reference completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(connect(host:username:passwordReference:completion:));
- (void)disconnectWithCompletion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(disconnect(completion:));
@end
NS_ASSUME_NONNULL_END
