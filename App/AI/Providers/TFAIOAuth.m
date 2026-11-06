#import "TFAIOAuth.h"
#import "TFAIRegistry.h"
#import "TFAIProtocol.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
static NSError *AuthError(NSString *message){return TFAIError(401,message);}
static NSString *B64(NSData *d){return [[[[d base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];}
static BOOL OfficialBase(NSURL *url,NSURL *official){return [url.scheme.lowercaseString isEqual:@"https"]&&[url.host.lowercaseString isEqual:official.host.lowercaseString]&&(!url.port||url.port.integerValue==443)&&!url.user&&!url.password&&!url.query&&!url.fragment&&[url.path.stringByStandardizingPath isEqual:official.path.stringByStandardizingPath];}
static NSString *Random(void){uint8_t bytes[32];if(SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess)return nil;return B64([NSData dataWithBytes:bytes length:sizeof(bytes)]);}
static NSMutableDictionary *TokenQuery(NSString *identifier){return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"com.xuegao.dylix.ai.oauth.v1",(__bridge id)kSecAttrAccount:identifier?:@""} mutableCopy];}
static NSDictionary *ReadToken(NSString *identifier){NSMutableDictionary *q=TokenQuery(identifier);q[(__bridge id)kSecReturnData]=@YES;CFTypeRef result=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)q,&result)!=errSecSuccess)return nil;NSData *d=CFBridgingRelease(result);id j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];return [j isKindOfClass:NSDictionary.class]?j:nil;}
static BOOL SaveToken(NSString *identifier,NSDictionary *record){NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];if(!data)return NO;NSMutableDictionary *q=TokenQuery(identifier);OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)q,(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});if(status==errSecItemNotFound){q[(__bridge id)kSecValueData]=data;q[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;status=SecItemAdd((__bridge CFDictionaryRef)q,NULL);}return status==errSecSuccess;}
static NSData *Form(NSDictionary *fields){NSMutableArray *pairs=[NSMutableArray new];NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];for(NSString *key in fields)[pairs addObject:[NSString stringWithFormat:@"%@=%@",[key stringByAddingPercentEncodingWithAllowedCharacters:allowed],[[fields[key] description] stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];}
@interface TFAIOAuth () <ASWebAuthenticationPresentationContextProviding,NSURLSessionTaskDelegate>
@property ASWebAuthenticationSession *web;
@property(nonatomic,weak) UIViewController *presenter;
@property NSMutableDictionary<NSString *,NSMutableArray *> *waiters;
@property NSMutableDictionary<NSString *,NSNumber *> *epochs;
@property NSUInteger loginSerial;
@property NSInteger wbPollFailures;
@end
@implementation TFAIOAuth
+ (instancetype)shared{static id s;static dispatch_once_t once;dispatch_once(&once,^{s=[self new];});return s;}
- (instancetype)init{if((self=[super init])){_waiters=[NSMutableDictionary new];_epochs=[NSMutableDictionary new];}return self;}
- (BOOL)hasCredential:(NSString *)identifier{return [ReadToken(identifier)[@"accessToken"] length]>0;}
// WorkBuddy 账号头：请求必须带 X-User-Id 与 X-Domain，否则网关按个人账户处理。
- (NSDictionary<NSString *,NSString *> *)accountHeaders:(NSDictionary *)connection{
 NSDictionary *oauth=TFAIProvider(connection[@"protocol"])[@"oauth"];
 if(![oauth[@"kind"] isEqual:@"workbuddy"])return @{};
 NSDictionary *record=ReadToken(connection[@"id"]);
 NSMutableDictionary *out=[NSMutableDictionary new];
 NSString *uid=record[@"uid"],*domain=record[@"domain"],*enterprise=record[@"enterpriseId"];
 if([uid isKindOfClass:NSString.class]&&uid.length)out[@"X-User-Id"]=uid;
 if([domain isKindOfClass:NSString.class]&&domain.length)out[@"X-Domain"]=domain;
 if([enterprise isKindOfClass:NSString.class]&&enterprise.length){out[@"X-Enterprise-Id"]=enterprise;out[@"X-Tenant-Id"]=enterprise;}
 return out;
}
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session{return self.presenter.view.window;}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler{completionHandler(nil);}
// 通用 JSON 请求（WorkBuddy 登录/轮询/刷新用），回调给解析后的字典与 HTTP 状态码。
- (void)jsonRequest:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSDictionary *)body completion:(void(^)(NSDictionary *result,NSInteger status,NSError *error))completion{
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];r.HTTPMethod=method;r.timeoutInterval=45;
 if(body){r.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];[r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];}
 [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
 [r setValue:@"WorkBuddy/5.5.6" forHTTPHeaderField:@"User-Agent"];
 for(NSString *k in headers)[r setValue:headers[k] forHTTPHeaderField:k];
 NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;NSURLSession *s=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
 [[s dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *response,NSError *error){NSInteger status=[(NSHTTPURLResponse *)response statusCode];NSDictionary *value=d.length<4*1024*1024?[NSJSONSerialization JSONObjectWithData:d?:NSData.data options:0 error:nil]:nil;dispatch_async(dispatch_get_main_queue(),^{completion([value isKindOfClass:NSDictionary.class]?value:@{},status,error);[s finishTasksAndInvalidate];});}] resume];
}
// WorkBuddy 业务信封：code != 0 即失败；成功返回 data 或整包。
static NSDictionary *WBUnwrap(NSDictionary *envelope){NSNumber *code=envelope[@"code"];if([code isKindOfClass:NSNumber.class]&&code.integerValue!=0)return nil;id data=envelope[@"data"];if([data isKindOfClass:NSDictionary.class])return data;if([data isKindOfClass:NSArray.class])return @{@"list":data};return envelope;}
// 从 WorkBuddy 的 token 响应里解析 access/refresh 与过期时间（毫秒或秒）。
static NSDictionary *WBMergeToken(NSDictionary *token,NSDictionary *base){
 NSString *access=token[@"accessToken"];if(![access isKindOfClass:NSString.class]||!access.length)return nil;
 NSMutableDictionary *out=[base mutableCopy]?:[NSMutableDictionary new];out[@"accessToken"]=access;
 NSString *refresh=token[@"refreshToken"];[refresh isKindOfClass:NSString.class]&&refresh.length?(out[@"refreshToken"]=refresh):0;
 double nowMs=NSDate.date.timeIntervalSince1970*1000;
 NSNumber *exp=token[@"expiresAt"];if([exp isKindOfClass:NSNumber.class]&&exp.doubleValue>0)out[@"expiresAt"]=@(exp.doubleValue);
 else{NSNumber *sec=token[@"expiresIn"];if([sec isKindOfClass:NSNumber.class]&&sec.doubleValue>0)out[@"expiresAt"]=@(nowMs+sec.doubleValue*1000);else out[@"expiresAt"]=@(nowMs+60*60*1000);}
 NSString *domain=token[@"domain"];if([domain isKindOfClass:NSString.class]&&domain.length)out[@"domain"]=domain;
 return out;
}
- (void)request:(NSString *)url fields:(NSDictionary *)fields json:(BOOL)json completion:(void(^)(NSDictionary *,NSError *))completion{
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];r.HTTPMethod=@"POST";r.timeoutInterval=45;r.HTTPBody=json?[NSJSONSerialization dataWithJSONObject:fields options:0 error:nil]:Form(fields);[r setValue:json?@"application/json":@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
 NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;NSURLSession *s=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
 [[s dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *response,NSError *error){NSInteger status=[(NSHTTPURLResponse *)response statusCode];NSDictionary *value=d.length<1024*1024?[NSJSONSerialization JSONObjectWithData:d?:NSData.data options:0 error:nil]:nil;dispatch_async(dispatch_get_main_queue(),^{BOOL ok=!error&&status>=200&&status<300;completion([value isKindOfClass:NSDictionary.class]?value:@{},ok?nil:AuthError(@"官方授权请求失败，请重新登录；令牌与响应详情未写入诊断。"));[s finishTasksAndInvalidate];});}] resume];
}
- (void)login:(NSDictionary *)c presenter:(UIViewController *)presenter completion:(TFAIResult)completion{
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self login:c presenter:presenter completion:completion];});return;}
 NSDictionary *oauth=TFAIProvider(c[@"protocol"])[@"oauth"];if(!oauth){completion(nil,AuthError(@"此服务商本期使用官方 API 密钥。"));return;}
 if([oauth[@"kind"] isEqual:@"workbuddy"]){[self loginWorkBuddy:c presenter:presenter completion:completion];return;}
 NSURL *base=[NSURL URLWithString:c[@"baseURL"]],*official=[NSURL URLWithString:TFAIProvider(c[@"protocol"])[@"baseURL"]];if(!OfficialBase(base,official)){completion(nil,AuthError(@"OAuth 仅用于该服务商官方 HTTPS 地址。"));return;}
 if(self.web){completion(nil,AuthError(@"已有登录流程正在进行。"));return;}
 NSString *identifier=c[@"id"],*verifier=Random(),*state=Random(),*kind=oauth[@"kind"],*client=c[@"oauthClientID"]?:@"";BOOL google=[kind isEqual:@"google"];
 if(!verifier||!state){completion(nil,AuthError(@"系统随机数生成失败，请重试。"));return;}
 NSString *scheme=@"dylix",*redirect=nil;if(google){if(![client hasSuffix:@".apps.googleusercontent.com"]||[client rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"].invertedSet].location!=NSNotFound){completion(nil,AuthError(@"请填写为本App Bundle ID配置的Google iOS OAuth客户端ID。"));return;}scheme=[@"com.googleusercontent.apps." stringByAppendingString:[client substringToIndex:client.length-@".apps.googleusercontent.com".length]];redirect=[scheme stringByAppendingString:@":/oauthredirect"];}else redirect=[NSString stringWithFormat:@"dylix://oauth/openrouter?state=%@",state];
 uint8_t digest[CC_SHA256_DIGEST_LENGTH];NSData *v=[verifier dataUsingEncoding:NSUTF8StringEncoding];CC_SHA256(v.bytes,(CC_LONG)v.length,digest);NSString *challenge=B64([NSData dataWithBytes:digest length:sizeof(digest)]);
 NSURLComponents *parts=[NSURLComponents componentsWithString:oauth[@"authorizationURL"]];NSMutableArray *query=[NSMutableArray arrayWithArray:@[[NSURLQueryItem queryItemWithName:@"code_challenge" value:challenge],[NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"]]];
 if(google)[query addObjectsFromArray:@[[NSURLQueryItem queryItemWithName:@"client_id" value:client],[NSURLQueryItem queryItemWithName:@"redirect_uri" value:redirect],[NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],[NSURLQueryItem queryItemWithName:@"scope" value:oauth[@"scope"]],[NSURLQueryItem queryItemWithName:@"state" value:state],[NSURLQueryItem queryItemWithName:@"access_type" value:@"offline"],[NSURLQueryItem queryItemWithName:@"prompt" value:@"consent"]]];else[query addObject:[NSURLQueryItem queryItemWithName:@"callback_url" value:redirect]];parts.queryItems=query;
 self.epochs[identifier]=@([self.epochs[identifier] unsignedIntegerValue]+1);self.presenter=presenter;NSUInteger loginSerial=++self.loginSerial;NSUInteger epoch=[self.epochs[identifier] unsignedIntegerValue];__weak typeof(self) weak=self;
 self.web=[[ASWebAuthenticationSession alloc]initWithURL:parts.URL callbackURLScheme:scheme completionHandler:^(NSURL *callback,NSError *error){dispatch_async(dispatch_get_main_queue(),^{TFAIOAuth *s=weak;if(!s)return;if(loginSerial!=s.loginSerial){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}s.web=nil;NSURLComponents *result=[NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];NSMutableDictionary *values=[NSMutableDictionary new];BOOL duplicate=NO;for(NSURLQueryItem *q in result.queryItems){if(values[q.name])duplicate=YES;values[q.name]=q.value?:@"";}NSURL *expected=[NSURL URLWithString:redirect];BOOL path=[callback.scheme isEqual:expected.scheme]&&[(callback.host?:@"") isEqual:expected.host?:@""]&&[(callback.path?:@"") isEqual:expected.path?:@""];
 if(error||callback.fragment.length||!path||duplicate||![values[@"state"] isEqual:state]||![values[@"code"] length]||epoch!=[s.epochs[identifier] unsignedIntegerValue]){completion(nil,AuthError(@"登录已取消或授权回调校验失败，原连接保持不变。"));return;}
 NSDictionary *fields=google?@{@"grant_type":@"authorization_code",@"client_id":client,@"code":values[@"code"],@"code_verifier":verifier,@"redirect_uri":redirect}:@{@"code":values[@"code"],@"code_verifier":verifier,@"code_challenge_method":@"S256"};
 [s request:oauth[@"tokenURL"] fields:fields json:!google completion:^(NSDictionary *result,NSError *failure){if(epoch!=[s.epochs[identifier] unsignedIntegerValue]){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}NSString *access=result[google?@"access_token":@"key"];if(failure||![access isKindOfClass:NSString.class]||!access.length){completion(nil,failure?:AuthError(@"官方授权未返回凭据，请重新登录。"));return;}NSDictionary *record=@{@"accessToken":access,@"refreshToken":[result[@"refresh_token"] isKindOfClass:NSString.class]?result[@"refresh_token"]:@"",@"expiresAt":google?@(NSDate.date.timeIntervalSince1970+MAX(0,[result[@"expires_in"] doubleValue])):@0,@"kind":kind,@"clientID":client};if(!SaveToken(identifier,record)){completion(nil,AuthError(@"钥匙串保存失败，连接未切换。"));return;}completion(@{@"authenticated":@YES},nil);}];});}];self.web.presentationContextProvider=self;self.web.prefersEphemeralWebBrowserSession=YES;if(![self.web start]){self.web=nil;completion(nil,AuthError(@"系统登录页面启动失败，请重试。"));}
}
// WorkBuddy 账号登录：POST /auth/state 拿 state 与登录页，打开系统授权页后每 1 秒轮询
// /auth/token 直到拿到令牌，再轮询 /login/account 取 uid。无回调 scheme、无 client_id，
// 是 WorkBuddy 官方的插件登录接口（同 kwwk 的 Sources/KWWKAuth/Providers/WorkBuddyOAuth.swift）。
- (void)loginWorkBuddy:(NSDictionary *)c presenter:(UIViewController *)presenter completion:(TFAIResult)completion{
 if(self.web){completion(nil,AuthError(@"已有登录流程正在进行。"));return;}
 NSDictionary *oauth=TFAIProvider(c[@"protocol"])[@"oauth"];
 NSString *identifier=c[@"id"],*platform=[oauth[@"platform"] isKindOfClass:NSString.class]?oauth[@"platform"]:@"workbuddy";
 self.epochs[identifier]=@([self.epochs[identifier] unsignedIntegerValue]+1);self.presenter=presenter;NSUInteger epoch=[self.epochs[identifier] unsignedIntegerValue];NSUInteger loginSerial=++self.loginSerial;__weak typeof(self) weak=self;
 NSString *authURL=[oauth[@"authURL"] isKindOfClass:NSString.class]?oauth[@"authURL"]:@"";
 authURL=[NSString stringWithFormat:@"%@?platform=%@",authURL,[platform stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
 // 1. 请求 sign-in state 与登录页
 [self jsonRequest:authURL method:@"POST" headers:@{@"X-No-Authorization":@"true",@"X-No-User-Id":@"true",@"X-No-Enterprise-Id":@"true",@"X-No-Department-Info":@"true"} body:@{} completion:^(NSDictionary *result,NSInteger status,NSError *error){
  TFAIOAuth *s=weak;if(!s||loginSerial!=s.loginSerial){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}
  NSDictionary *started=WBUnwrap(result);
  NSString *state=[started[@"state"] isKindOfClass:NSString.class]?started[@"state"]:@"";
  NSURL *pageURL=[NSURL URLWithString:[started[@"authUrl"] isKindOfClass:NSString.class]?started[@"authUrl"]:@""];
  if(error||!state.length||!pageURL||![pageURL.scheme isEqual:@"https"]){completion(nil,AuthError(@"WorkBuddy 未返回登录页，请重试。"));return;}
  // 给登录页补 version 与 loginSessionId
  NSURLComponents *parts=[NSURLComponents componentsWithURL:pageURL resolvingAgainstBaseURL:NO];
  NSMutableArray *items=[parts.queryItems mutableCopy]?:[NSMutableArray new];
  uint8_t rb[16];SecRandomCopyBytes(kSecRandomDefault,sizeof(rb),rb);NSMutableString *sid=[NSMutableString stringWithCapacity:32];for(int i=0;i<16;i++)[sid appendFormat:@"%02x",rb[i]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"version" value:@"2.0.0"]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"loginSessionId" value:sid]];
  parts.queryItems=items;pageURL=parts.URL;
  // 2. 打开登录页（用固定 scheme 仅为满足 ASWebAuthenticationSession 的构造要求）
  NSString *scheme=@"dylixwbauth";
  s.web=[[ASWebAuthenticationSession alloc]initWithURL:pageURL callbackURLScheme:scheme completionHandler:^(NSURL *callback,NSError *err){dispatch_async(dispatch_get_main_queue(),^{TFAIOAuth *w=weak;if(w&&w.web){w.web=nil;}/* 不以此判定完成；轮询决定 */});}];
  s.web.presentationContextProvider=s;s.web.prefersEphemeralWebBrowserSession=YES;
  if(![s.web start]){s.web=nil;completion(nil,AuthError(@"系统登录页面启动失败，请重试。"));return;}
  // 3. 轮询 token，成功后轮询 account
  [s wbPollToken:oauth state:state identifier:identifier epoch:epoch loginSerial:loginSerial deadline:NSDate.date.timeIntervalSince1970+300 completion:completion];
 }];
}
// 轮询 WorkBuddy /auth/token?state=…（pending 码 11217 表示还没登录，继续等）。
- (void)wbPollToken:(NSDictionary *)oauth state:(NSString *)state identifier:(NSString *)identifier epoch:(NSUInteger)epoch loginSerial:(NSUInteger)loginSerial deadline:(NSTimeInterval)deadline completion:(TFAIResult)completion{
 if(epoch!=[self.epochs[identifier] unsignedIntegerValue]||loginSerial!=self.loginSerial){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}
 if(NSDate.date.timeIntervalSince1970>deadline){[self.web cancel];self.web=nil;completion(nil,AuthError(@"登录超时，请重试。"));return;}
 NSString *tokenURL=[oauth[@"tokenURL"] isKindOfClass:NSString.class]?oauth[@"tokenURL"]:@"";
 NSString *url=[NSString stringWithFormat:@"%@?state=%@",tokenURL,[state stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
 __weak typeof(self) weak=self;
 [self jsonRequest:url method:@"GET" headers:@{} body:nil completion:^(NSDictionary *result,NSInteger status,NSError *error){
  TFAIOAuth *s=weak;if(!s)return;
  if(epoch!=[s.epochs[identifier] unsignedIntegerValue]||loginSerial!=s.loginSerial){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}
  NSNumber *code=result[@"code"];
  if(code&&[code isKindOfClass:NSNumber.class]&&code.integerValue==11217){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[s wbPollToken:oauth state:state identifier:identifier epoch:epoch loginSerial:loginSerial deadline:deadline completion:completion];});return;}
  NSDictionary *data=WBUnwrap(result);NSDictionary *merged=WBMergeToken(data,nil);
  if(error||!merged){// 空答复或 408/429 视为还没好，继续等（限 3 次网络错误后放弃）
   NSInteger http=status;
   if(error&&http==0){s.wbPollFailures++;if(s.wbPollFailures>=3){s.wbPollFailures=0;[s.web cancel];s.web=nil;completion(nil,AuthError(@"WorkBuddy 登录轮询网络失败，请重试。"));return;}}
   else s.wbPollFailures=0;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[s wbPollToken:oauth state:state identifier:identifier epoch:epoch loginSerial:loginSerial deadline:deadline completion:completion];});
   return;
  }
  s.wbPollFailures=0;
  [s wbFetchAccount:oauth state:state token:[merged copy] identifier:identifier epoch:epoch loginSerial:loginSerial completion:completion];
 }];
}
// 拿到 token 后轮询 /login/account?state=…（pending 码 12151）取 uid / domain。
- (void)wbFetchAccount:(NSDictionary *)oauth state:(NSString *)state token:(NSDictionary *)token identifier:(NSString *)identifier epoch:(NSUInteger)epoch loginSerial:(NSUInteger)loginSerial completion:(TFAIResult)completion{
 if(epoch!=[self.epochs[identifier] unsignedIntegerValue]||loginSerial!=self.loginSerial){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}
 NSString *accountURL=[oauth[@"accountURL"] isKindOfClass:NSString.class]?oauth[@"accountURL"]:@"";
 NSString *url=[NSString stringWithFormat:@"%@?state=%@",accountURL,[state stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
 NSString *access=[token[@"accessToken"] isKindOfClass:NSString.class]?token[@"accessToken"]:@"";
 NSString *domain=[token[@"domain"] isKindOfClass:NSString.class]?token[@"domain"]:@"";
 __weak typeof(self) weak=self;
 [self jsonRequest:url method:@"GET" headers:@{@"Authorization":[@"Bearer " stringByAppendingString:access],@"X-Domain":domain.length?domain:@""} body:nil completion:^(NSDictionary *result,NSInteger status,NSError *error){
  TFAIOAuth *s=weak;if(!s)return;
  if(epoch!=[s.epochs[identifier] unsignedIntegerValue]||loginSerial!=s.loginSerial){completion(nil,AuthError(@"登录状态已变更，请重试。"));return;}
  NSNumber *code=result[@"code"];
  if(code&&[code isKindOfClass:NSNumber.class]&&code.integerValue==12151){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[s wbFetchAccount:oauth state:state token:token identifier:identifier epoch:epoch loginSerial:loginSerial completion:completion];});return;}
  NSDictionary *account=WBUnwrap(result);
  NSString *uid=[account[@"uid"] isKindOfClass:NSString.class]?account[@"uid"]:@"";
  if(error||!uid.length){completion(nil,AuthError(@"WorkBuddy 登录成功但未取到账号信息，请重试。"));return;}
  NSMutableDictionary *record=[token mutableCopy];record[@"uid"]=uid;record[@"kind"]=@"workbuddy";
  NSString *nick=[account[@"nickname"] isKindOfClass:NSString.class]?account[@"nickname"]:@"";
  NSString *phone=[account[@"phoneNumber"] isKindOfClass:NSString.class]?account[@"phoneNumber"]:@"";
  record[@"accountName"]=nick.length?nick:(phone.length?phone:uid);
  NSString *enterprise=[account[@"enterpriseId"] isKindOfClass:NSString.class]?account[@"enterpriseId"]:@"";
  if(enterprise.length)record[@"enterpriseId"]=enterprise;
  [s.web cancel];s.web=nil;
  if(!SaveToken(identifier,record)){completion(nil,AuthError(@"钥匙串保存失败，连接未切换。"));return;}
  completion(@{@"authenticated":@YES,@"account":record[@"accountName"]},nil);
 }];
}
- (void)credential:(NSDictionary *)c completion:(void(^)(NSString *,NSError *))completion{
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self credential:c completion:completion];});return;}
 NSString *identifier=c[@"id"]?:@"";NSDictionary *oauth=TFAIProvider(c[@"protocol"])[@"oauth"],*record=ReadToken(identifier);
 if([oauth[@"kind"] isEqual:@"workbuddy"]){[self credentialWorkBuddy:c oauth:oauth record:record completion:completion];return;}
 NSURL *url=[NSURL URLWithString:c[@"baseURL"]],*official=[NSURL URLWithString:TFAIProvider(c[@"protocol"])[@"baseURL"]];if(!oauth||!OfficialBase(url,official)){completion(nil,AuthError(@"OAuth 连接地址已变化，请恢复官方地址并重新登录。"));return;}
 if(![record[@"accessToken"] length]){completion(nil,AuthError(@"请先登录此连接。"));return;}
 if(![record[@"kind"] isEqual:oauth[@"kind"]]||([oauth[@"kind"] isEqual:@"google"]&&![record[@"clientID"] isEqual:c[@"oauthClientID"]])){completion(nil,AuthError(@"服务商或OAuth客户端已变化，请退出旧授权后重新登录。"));return;}
 if(![record[@"expiresAt"] doubleValue]||[record[@"expiresAt"] doubleValue]>NSDate.date.timeIntervalSince1970+60){completion(record[@"accessToken"],nil);return;}
 if(self.waiters[identifier]){[self.waiters[identifier] addObject:[completion copy]];return;}self.waiters[identifier]=[NSMutableArray arrayWithObject:[completion copy]];NSUInteger epoch=[self.epochs[identifier] unsignedIntegerValue];
 NSMutableArray *flight=self.waiters[identifier];void (^finish)(NSString *,NSError *)=^(NSString *token,NSError *failure){if(self.waiters[identifier]!=flight)return;NSArray *waiting=[flight copy];[self.waiters removeObjectForKey:identifier];for(void(^cb)(NSString *,NSError *) in waiting)cb(token,failure);};
 if(![record[@"refreshToken"] length]){finish(nil,AuthError(@"授权已过期，请重新登录。"));return;}
 [self request:oauth[@"tokenURL"] fields:@{@"grant_type":@"refresh_token",@"refresh_token":record[@"refreshToken"],@"client_id":record[@"clientID"]} json:NO completion:^(NSDictionary *result,NSError *error){if(epoch!=[self.epochs[identifier] unsignedIntegerValue]){finish(nil,AuthError(@"已退出登录。"));return;}if(error||![result[@"access_token"] isKindOfClass:NSString.class]||![result[@"access_token"] length]){finish(nil,AuthError(@"授权刷新失败，请重新登录；原凭据保留供重试。"));return;}NSMutableDictionary *next=[record mutableCopy];next[@"accessToken"]=result[@"access_token"];if([result[@"refresh_token"] isKindOfClass:NSString.class])next[@"refreshToken"]=result[@"refresh_token"];next[@"expiresAt"]=@(NSDate.date.timeIntervalSince1970+MAX(0,[result[@"expires_in"] doubleValue]));if(!SaveToken(identifier,next)){finish(nil,AuthError(@"刷新凭据保存失败，请重新登录。"));return;}finish(next[@"accessToken"],nil);}];
}
// WorkBuddy token 获取：有效直接返回；过期用 POST /auth/token/refresh（X-Refresh-Token 头）刷新。
- (void)credentialWorkBuddy:(NSDictionary *)c oauth:(NSDictionary *)oauth record:(NSDictionary *)record completion:(void(^)(NSString *,NSError *))completion{
 NSString *identifier=c[@"id"]?:@"";
 if(![record[@"accessToken"] length]){completion(nil,AuthError(@"请先登录此连接。"));return;}
 // expiresAt 存的是毫秒；未到前 1 分钟直接返回
 double exp=[record[@"expiresAt"] doubleValue];
 if(exp>0&&exp/1000.0>NSDate.date.timeIntervalSince1970+60){completion(record[@"accessToken"],nil);return;}
 if(![record[@"refreshToken"] length]){completion(nil,AuthError(@"授权已过期，请重新登录。"));return;}
 NSString *refreshURL=[oauth[@"refreshURL"] isKindOfClass:NSString.class]?oauth[@"refreshURL"]:@"";
 NSString *refresh=[record[@"refreshToken"] isKindOfClass:NSString.class]?record[@"refreshToken"]:@"";
 NSString *domain=[record[@"domain"] isKindOfClass:NSString.class]?record[@"domain"]:@"";
 __weak typeof(self) weak=self;
 [self jsonRequest:refreshURL method:@"POST" headers:@{@"X-Refresh-Token":refresh,@"X-Auth-Refresh-Source":@"plugin",@"X-Domain":domain.length?domain:@""} body:@{} completion:^(NSDictionary *result,NSInteger status,NSError *error){
  TFAIOAuth *s=weak;if(!s)return;
  NSDictionary *data=WBUnwrap(result);NSDictionary *merged=WBMergeToken(data,record);
  if(error||!merged){completion(nil,AuthError(@"WorkBuddy 授权刷新失败，请重新登录；原凭据保留供重试。"));return;}
  NSMutableDictionary *next=[merged mutableCopy];next[@"kind"]=@"workbuddy";next[@"uid"]=record[@"uid"];next[@"accountName"]=record[@"accountName"];next[@"enterpriseId"]=record[@"enterpriseId"];
  if(!SaveToken(identifier,next)){completion(nil,AuthError(@"刷新凭据保存失败，请重新登录。"));return;}
  completion(next[@"accessToken"],nil);
 }];
}
- (void)logout:(NSDictionary *)c completion:(TFAIResult)completion{
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self logout:c completion:completion];});return;}
 NSString *identifier=c[@"id"]?:@"";self.epochs[identifier]=@([self.epochs[identifier] unsignedIntegerValue]+1);NSArray *waiting=[self.waiters[identifier] copy];[self.waiters removeObjectForKey:identifier];for(void(^cb)(NSString *,NSError *) in waiting)cb(nil,AuthError(@"已退出登录。"));self.loginSerial++;[self.web cancel];self.web=nil;NSDictionary *record=ReadToken(identifier),*oauth=TFAIProvider(c[@"protocol"])[@"oauth"];OSStatus deleted=SecItemDelete((__bridge CFDictionaryRef)TokenQuery(identifier));if(deleted!=errSecSuccess&&deleted!=errSecItemNotFound){completion(nil,AuthError(@"钥匙串清除失败，请重试退出。"));return;}
 if([record[@"kind"] isEqual:@"workbuddy"]){completion(@{@"cleared":@YES,@"revoked":@NO,@"message":@"本机凭据已清除。WorkBuddy 插件登录没有远程吊销接口；如需撤销，请在 WorkBuddy 中退出该设备。"},nil);return;}
 if([record[@"kind"] isEqual:@"google"])oauth=TFAIProvider(@"gemini")[@"oauth"];else if([record[@"kind"] isEqual:@"openrouter"])oauth=TFAIProvider(@"openrouter")[@"oauth"];NSString *revoke=oauth[@"revokeURL"],*token=[record[@"refreshToken"] length]?record[@"refreshToken"]:record[@"accessToken"];if(!token.length){completion(@{@"cleared":@YES,@"revoked":@YES},nil);return;}if(!revoke.length){completion(@{@"cleared":@YES,@"revoked":@NO,@"message":@"本机凭据已清除。此官方PKCE流程返回API key，请在OpenRouter密钥管理页撤销该key；本流程没有公开的refresh/revoke接口。"},nil);return;}
 [self request:revoke fields:@{@"token":token} json:NO completion:^(NSDictionary *result,NSError *error){completion(@{@"cleared":@YES,@"revoked":@(!error),@"message":error?@"本机已清除；网络吊销未完成，请在Google账户中撤销授权。":@"已清除并吊销官方授权。"},nil);}];
}
@end
