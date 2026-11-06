#import <Foundation/Foundation.h>
#import "../AIContracts.h"
@class UIViewController;
@interface TFAIOAuth : NSObject
+ (instancetype)shared;
- (BOOL)hasCredential:(NSString *)identifier;
- (void)login:(NSDictionary *)connection presenter:(UIViewController *)presenter completion:(TFAIResult)completion;
- (void)credential:(NSDictionary *)connection completion:(void(^)(NSString *token,NSError *error))completion;
- (void)logout:(NSDictionary *)connection completion:(TFAIResult)completion;
// WorkBuddy 账号头（X-User-Id / X-Domain / X-Enterprise-Id），非 workbuddy 返回空。
- (NSDictionary<NSString *,NSString *> *)accountHeaders:(NSDictionary *)connection;
@end
