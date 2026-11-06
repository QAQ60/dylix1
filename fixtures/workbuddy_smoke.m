// WorkBuddy 适配的离线冒烟测试：不联网，只验证请求编排与错误翻译。
// 构建：clang -c 该文件与 App/AI/Providers/TFAIWorkBuddy.m，再 ldid -S 后运行。
// 用法：workbuddy_smoke [-v config.json] [-e body.txt]
#import <Foundation/Foundation.h>
#import "../App/AI/Providers/TFAIWorkBuddy.h"

static int failures = 0;
static void check(BOOL ok, NSString *what) {
    if (!ok) { failures++; fprintf(stderr, "FAIL  %s\n", what.UTF8String); }
    else printf("ok    %s\n", what.UTF8String);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSUserDefaults *args = [NSUserDefaults standardUserDefaults];
        NSString *configPath = [args stringForKey:@"v"];
        NSString *bodyPath = [args stringForKey:@"e"];
        if (configPath) {
            NSData *data = [NSData dataWithContentsOfFile:configPath];
            NSString *reason = nil;
            NSArray *models = TFAIWorkBuddyModelsFromConfig(TFAIWorkBuddyConfigObject(data), &reason);
            printf("config models: %s (reason: %s)\n", [models componentsJoinedByString:@","].UTF8String, reason.UTF8String ?: "-");
        }
        if (bodyPath) {
            NSString *text = [NSString stringWithContentsOfFile:bodyPath encoding:NSUTF8StringEncoding error:nil];
            printf("explain: %s\n", (TFAIWorkBuddyExplainError(400, text) ?: @"(nil)").UTF8String);
        }
        if (configPath || bodyPath) return 0;

        NSDictionary *connection = @{@"id": @"c1", @"protocol": @"workbuddy", @"model": @"auto", @"baseURL": @"https://copilot.tencent.com/v2", @"reasoningEffort": @"high"};
        NSArray *tools = @[@{@"name": @"read file", @"parameters": @{@"type": @"object", @"properties": @{@"path": @{@"type": @"String"}, @"mode": @{@"enum": @[@"a", @"b"]}}, @"required": @[@"path", @"mode"]}}];
        NSDictionary *body = @{@"model": @"auto", @"stream": @YES, @"stream_options": @{@"include_usage": @YES},
                               @"messages": @[@{@"role": @"user", @"content": @"hi"}],
                               @"tools": @[@{@"type": @"function", @"function": tools.firstObject}],
                               @"tool_choice": @{@"type": @"function", @"function": @{@"name": @"read file"}}};
        NSDictionary *attempt = nil, *names = nil;
        TFAIWorkBuddyPlan(body, connection, tools, &attempt, &names);
        NSArray *messages = attempt[@"messages"];
        check([messages.firstObject[@"role"] isEqual:@"system"], @"首条消息补成 system");
        check(messages.count == 2, @"原有消息保留");
        NSString *sentName = attempt[@"tools"][0][@"name"];
        check([sentName isEqual:@"read_file"], @"工具名改成安全字符");
        check([names[sentName] isEqual:@"read file"], @"记录发送名到原名");
        check([attempt[@"tools"][0][@"parameters"][@"properties"][@"path"][@"type"] isEqual:@"string"], @"schema 类型小写");
        check([attempt[@"tools"][0][@"parameters"][@"properties"][@"mode"][@"type"] isEqual:@"string"], @"无类型枚举补上类型");
        check([attempt[@"tool_choice"] isEqual:sentName], @"tool_choice 改成发送的工具名");
        check([attempt[@"reasoning_effort"] isEqual:@"high"], @"思考档位走 reasoning_effort");
        check(attempt[@"stream_options"] == nil || [attempt[@"stream_options"] isEqualToDictionary:@{@"include_usage": @YES}], @"原样带过来由传输层删除");

        NSDictionary *retry = nil;
        NSDictionary *withTools = @{@"model": @"auto", @"messages": @[@{@"role": @"system", @"content": @"s"}, @{@"role": @"assistant", @"content": @"", @"tool_calls": @[@{@"id": @"t", @"name": @"read_file", @"arguments": @{}}]}, @{@"role": @"tool", @"tool_call_id": @"t", @"content": @"r"}, @{@"role": @"user", @"content": @"go"}]};
        check(TFAIWorkBuddyRefused(400, @"{\"code\":11153,\"msg\":\"x\"}", withTools, &retry), @"11153 触发重发");
        check([retry[@"messages"] count] == 5 && [retry[@"messages"][3][@"role"] isEqual:@"assistant"], @"工具结果后插入空 assistant");

        NSDictionary *withSystem = @{@"model": @"auto", @"messages": @[@{@"role": @"system", @"content": @"You are Claude Code, Anthropic's official CLI for Claude"}, @{@"role": @"user", @"content": @"hi"}]};
        retry = nil;
        check(TFAIWorkBuddyRefused(400, @"{\"code\":11128,\"msg\":\"Illegal API invocation from an unapproved channel\"}", withSystem, &retry), @"11128 触发重发");
        NSArray *retryMessages = (NSArray *)retry[@"messages"];
        check([retryMessages.firstObject[@"content"] isEqual:@"You are a helpful assistant."], @"系统提示词降为默认一句");
        check([retryMessages[1][@"content"] containsString:@"<instructions>"], @"原系统提示词进入用户消息");
        check(!TFAIWorkBuddyRefused(400, @"{\"code\":14018,\"msg\":\"Credits exhausted\"}", withSystem, &retry), @"额度不足不重发");

        check([TFAIWorkBuddyExplainError(403, @"{\"code\":11140,\"msg\":\"request illegal\"}") containsString:@"限制"], @"11140 提示账户被限制");
        check([TFAIWorkBuddyExplainError(429, @"{\"data\":{\"code\":14018,\"msg\":\"Credits exhausted\"}}") containsString:@"积分"], @"嵌套错误体读得出 code");

        NSDictionary *headers = TFAIWorkBuddyChatHeaders(connection);
        NSString *conversationID = headers[@"X-Conversation-ID"];
        check([headers[@"X-IDE-Type"] isEqual:@"WorkBuddy"] && conversationID.length > 0, @"对话头齐全");
        check([[TFAIWorkBuddyConfigURL(connection, nil) absoluteString] isEqual:@"https://copilot.tencent.com/v3/config"], @"模型目录地址");
        check([TFAIWorkBuddyDefaultModel(@"workbuddy") isEqual:@"auto"], @"默认模型");

        printf(failures ? "%d 项失败\n" : "全部通过\n", failures);
        return failures ? 1 : 0;
    }
}
