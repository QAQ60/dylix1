#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// WorkBuddy（腾讯 CodeBuddy 开发工作台）的两个站点：copilot.tencent.com 与 workbuddy.ai。
// 它走 OpenAI 的 chat-completions 线，但网关对请求头、消息形状、工具 schema 和错误体都有自己的要求。
// 这里只在服务商 id 为 workbuddy / workbuddy-ai 时生效；其他服务商一律走原有实现。
// 行为对齐 kwwk（https://github.com/EYHN/kwwk）的 Sources/KWWKAI/WorkBuddy。
// 鉴权：网关只认 WorkBuddy 账户的 Bearer 令牌。kwwk 的登录流程使用 WorkBuddy 客户端自己的
// 客户端标识与回跳地址，本实现没有复制这些值，因此连接里要填的是网关签发的 Bearer 令牌；
// 普通 API Key 会被网关拒绝。
FOUNDATION_EXPORT BOOL TFAIWorkBuddyProvider(NSString * _Nullable identifier);
FOUNDATION_EXPORT NSString *TFAIWorkBuddyDefaultModel(NSString *identifier);
// 模型目录：GET <去掉 /v2 的 baseURL>/v3/config，取 "cli" agent 的模型。
// 失败返回 nil 并给出原因，连接仍可手工填写模型 id。
FOUNDATION_EXPORT id _Nullable TFAIWorkBuddyConfigObject(NSData *data);
FOUNDATION_EXPORT NSArray<NSString *> *_Nullable TFAIWorkBuddyModelsFromConfig(id payload, NSString *_Nullable *reason);
// 对话请求的额外头：客户端标识、每次请求新生成的 id，以及按连接复用的对话 id。
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *TFAIWorkBuddyChatHeaders(NSDictionary *connection);
// 模型列表请求的头（User-Agent 换成 CLI 形式，否则拿到别的产品配置）。
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *TFAIWorkBuddyConfigHeaders(NSDictionary *connection);
// 模型列表请求的地址。
FOUNDATION_EXPORT NSURL * _Nullable TFAIWorkBuddyConfigURL(NSDictionary *connection, NSError **error);
// 编排一次请求：补上 system、整形工具并改名、修 tool_choice 与思考档位。
// firstAttempt 给出将要发出的正文（失败重发时由 TFAIWorkBuddyRefused 在这份正文上继续修）；
// renames 是「发送名 → App 自己的名字」，用来把模型返回的调用名还原。
FOUNDATION_EXPORT void TFAIWorkBuddyPlan(NSDictionary *body, NSDictionary *connection, NSArray<NSDictionary *> *tools,
                                        NSDictionary **firstAttempt, NSDictionary<NSString *, NSString *> **renames);
// 网关返回 400 时喂入正文与上一次实际发出的请求体；返回 YES 表示 retry 里是改好可以重发的请求体。
// 同一种修补只做一次：调用方重发后仍失败就如实报错。
FOUNDATION_EXPORT BOOL TFAIWorkBuddyRefused(NSInteger status, NSString *body, NSDictionary *last, NSDictionary **retry);
// 把工具调用名还原成 App 自己的名字。
FOUNDATION_EXPORT NSString *TFAIWorkBuddyRestoreName(NSString *name, NSDictionary<NSString *, NSString *> *renames);
// 把网关的错误体翻译成一句中文（{code,msg}，可能嵌在 data/error 里），失败返回 nil。
FOUNDATION_EXPORT NSString * _Nullable TFAIWorkBuddyExplainError(NSInteger status, NSString *body);
NS_ASSUME_NONNULL_END
