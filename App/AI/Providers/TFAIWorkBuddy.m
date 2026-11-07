#import "TFAIWorkBuddy.h"

// WorkBuddy 网关与标准 OpenAI 兼容站点的差异，逐条在这里对齐：
// 1. 首条消息必须是 system，否则 400 "first message is not system prompt"；
// 2. DeepSeek / Kimi 等模型会因为工具名、schema 里的写法拒绝整轮请求（11129 / 11133）；
// 3. 工具结果后面直接跟用户消息会 triggers 11153，需要补一条空的 assistant；
// 4. 系统提示词命中其它 Agent 的特征行时被拒为 11101 / 11128，改投给用户消息再发一次。

#define WB_IDE_VERSION @"5.0.0"

BOOL TFAIWorkBuddyProvider(NSString *identifier){return [@[@"workbuddy",@"workbuddy-ai"] containsObject:identifier?:@""];}

NSString *TFAIWorkBuddyDefaultModel(NSString *identifier){return [identifier isEqual:@"workbuddy-ai"]?@"default-model":@"auto";}

static NSString *WBBodyText(id value){
 if([value isKindOfClass:NSString.class])return value;
 if(![value isKindOfClass:NSArray.class])return @"";
 NSMutableArray *parts=[NSMutableArray new];
 for(id item in (NSArray *)value)if([item isKindOfClass:NSDictionary.class]&&[item[@"text"] isKindOfClass:NSString.class])[parts addObject:item[@"text"]];
 return [parts componentsJoinedByString:@"\n"];
}

static NSString *WBRandomHex(void){
 uint8_t bytes[16];arc4random_buf(bytes,sizeof bytes);NSMutableString *hex=[NSMutableString stringWithCapacity:32];
 for(NSUInteger i=0;i<sizeof bytes;i++)[hex appendFormat:@"%02x",bytes[i]];return hex;
}

static NSString *WBDigest(NSString *text){
 const char *bytes=text.UTF8String;unsigned long long h=1469598103934665603ULL;
 for(NSUInteger i=0;bytes&&bytes[i];i++){h^=(unsigned char)bytes[i];h*=1099511628211ULL;}
 return [NSString stringWithFormat:@"%016llx",h];
}

// WorkBuddy 的 id 是 32 位十六进制：把几段摘要接起来再截取，短段也不会越界。
static NSString *WBDigest32(NSString *text){
 NSString *hex=[NSString stringWithFormat:@"%@%@",WBDigest(text),WBDigest([@"salt" stringByAppendingString:text])];
 if(hex.length>=32)return [hex substringWithRange:NSMakeRange(0,32)];
 return [hex stringByPaddingToLength:32 withString:@"0" startingAtIndex:0];
}

static NSString *WBMessageRole(NSDictionary *message){id role=message[@"role"];return [role isKindOfClass:NSString.class]?role:@"";}

static NSString *WBDefaultSystem(void){return @"You are a helpful assistant.";}

static NSDictionary *WBClientHeaders(NSString *identifier){
 NSMutableDictionary *headers=[@{@"X-Product":@"SaaS",@"X-IDE-Type":@"WorkBuddy",@"X-Requested-With":@"XMLHttpRequest",@"X-Agent-Intent":@"craft",@"X-Agent-Purpose":@"conversation",@"X-IDE-Name":@"WorkBuddy",@"X-IDE-Version":WB_IDE_VERSION,@"User-Agent":[NSString stringWithFormat:@"WorkBuddy/%@",WB_IDE_VERSION]} mutableCopy];
 if([identifier isEqual:@"workbuddy-ai"])headers[@"X-Agent-Type"]=@"main";
 return headers;
}

NSDictionary<NSString *, NSString *> *TFAIWorkBuddyChatHeaders(NSDictionary *connection){
 NSString *identifier=[connection[@"protocol"] isKindOfClass:NSString.class]?connection[@"protocol"]:@"workbuddy";
 NSMutableDictionary *headers=[WBClientHeaders(identifier) mutableCopy];
 NSString *request=WBRandomHex();
 headers[@"X-Conversation-Message-ID"]=request;
 headers[@"X-Request-ID"]=request;
 // 同一轮对话（工具结果回传、重试）共用一个 request id，下一次用户发言换成新的。
 NSString *session=[connection[@"id"] isKindOfClass:NSString.class]?connection[@"id"]:@"";
 NSString *turn=[connection[@"turnID"] isKindOfClass:NSString.class]?connection[@"turnID"]:@"";
 if(session.length){
  headers[@"X-Conversation-ID"]=WBDigest32([NSString stringWithFormat:@"conversation|%@",session]);
  NSString *key=turn.length?turn:(connection[@"model"]?:@"");
  headers[@"X-Conversation-Request-ID"]=WBDigest32([NSString stringWithFormat:@"turn|%@|%@",session,key]);
 }
 return headers;
}

NSDictionary<NSString *, NSString *> *TFAIWorkBuddyConfigHeaders(NSDictionary *connection){
 NSString *identifier=[connection[@"protocol"] isKindOfClass:NSString.class]?connection[@"protocol"]:@"workbuddy";
 NSMutableDictionary *headers=[WBClientHeaders(identifier) mutableCopy];
 // 裸的 WorkBuddy/<版本> 拿到的是 IDE 的配置，没有 cli agent。
 headers[@"User-Agent"]=[NSString stringWithFormat:@"CLI/%@ WorkBuddy/%@",WB_IDE_VERSION,WB_IDE_VERSION];
 headers[@"Accept"]=@"application/json";
 return headers;
}

NSURL *_Nullable TFAIWorkBuddyConfigURL(NSDictionary *connection,NSError **error){
 NSString *raw=[connection[@"baseURL"] isKindOfClass:NSString.class]?connection[@"baseURL"]:@"";
 NSURLComponents *u=[NSURLComponents componentsWithString:[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
 if(!u.host.length||![u.scheme.lowercaseString isEqual:@"https"]){if(error)*error=[NSError errorWithDomain:@"TweakForge.AI" code:41 userInfo:@{NSLocalizedDescriptionKey:@"WorkBuddy 需要 HTTPS 服务地址"}];return nil;}
 // 规整 host，避免裸域（workbuddy.ai）301 跳到 www 被当成跨域重定向拦截（error 25）
 NSString *host=u.host.lowercaseString;
 if([host isEqual:@"workbuddy.ai"])u.host=@"www.workbuddy.ai";
 else if([host isEqual:@"www.copilot.tencent.com"])u.host=@"copilot.tencent.com";
 NSString *path=u.path?:@"";
 while([path hasSuffix:@"/"])path=[path substringToIndex:path.length-1];
 for(NSString *suffix in @[@"/v2/chat/completions",@"/chat/completions",@"/v2",@"/v3/config",@"/models"])if([path hasSuffix:suffix]){path=[path substringToIndex:path.length-suffix.length];break;}
 u.path=[path stringByAppendingString:@"/v3/config"];u.query=nil;u.fragment=nil;return u.URL;
}

id TFAIWorkBuddyConfigObject(NSData *data){return data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}

NSArray<NSString *> *_Nullable TFAIWorkBuddyModelsFromConfig(id payload,NSString *_Nullable *reason){
 if(![payload isKindOfClass:NSDictionary.class]){if(reason)*reason=@"模型目录不是 JSON 对象";return nil;}
 NSDictionary *config=payload;id code=config[@"code"];
 if([code isKindOfClass:NSNumber.class]&&[code integerValue]!=0){if(reason)*reason=[NSString stringWithFormat:@"模型目录返回 %@：%@",code,[config[@"msg"] isKindOfClass:NSString.class]?config[@"msg"]:@""];return nil;}
 id data=[config[@"data"] isKindOfClass:NSDictionary.class]?config[@"data"]:config;
 if([data isKindOfClass:NSDictionary.class]&&[data[@"error"] isKindOfClass:NSDictionary.class])data=data[@"error"];
 NSMutableArray *ids=[NSMutableArray new];
 for(id agent in ([data[@"agents"] isKindOfClass:NSArray.class]?data[@"agents"]:@[])){
  if(![agent isKindOfClass:NSDictionary.class]||![agent[@"name"] isEqual:@"cli"])continue;
  for(id row in ([agent[@"models"] isKindOfClass:NSArray.class]?agent[@"models"]:@[])){
   NSString *ident=[row isKindOfClass:NSString.class]?row:([row isKindOfClass:NSDictionary.class]&&[row[@"id"] isKindOfClass:NSString.class])?row[@"id"]:nil;
   if(ident.length&&![ids containsObject:ident])[ids addObject:ident];
  }
 }
 if(!ids.count){if(reason)*reason=[NSString stringWithFormat:@"配置里没有 CLI agent 的模型列表（%@）",[data[@"msg"] isKindOfClass:NSString.class]?data[@"msg"]:@"可能未登录或令牌无效"];return nil;}
 return ids;
}

// 在扁平 JSON 文本里取 code / msg：网关的错误体是 {"code":11128,"msg":"..."}，也可能嵌一层 data 或 error。
static id WBFlatValue(NSString *text,NSArray<NSString *> *keys){
 for(NSString *key in keys){
  NSString *needle=[NSString stringWithFormat:@"\"%@\"",key];NSRange search=NSMakeRange(0,text.length);
  while(search.length){
   NSRange found=[text rangeOfString:needle options:0 range:search];
   if(found.location==NSNotFound)break;
   NSUInteger i=NSMaxRange(found);
   while(i<text.length&&([text characterAtIndex:i]==' '||[text characterAtIndex:i]=='\t'||[text characterAtIndex:i]=='\n'))i++;
   if(i<text.length&&[text characterAtIndex:i]==':'){
    i++;while(i<text.length&&([text characterAtIndex:i]==' '||[text characterAtIndex:i]=='\t'))i++;
    if(i<text.length&&[text characterAtIndex:i]=='"'){
     NSUInteger end=i+1;NSMutableString *out=[NSMutableString new];BOOL closed=NO;
     while(end<text.length){unichar ch=[text characterAtIndex:end];if(ch=='\\'&&end+1<text.length){[out appendFormat:@"%C",[text characterAtIndex:end+1]];end+=2;continue;}if(ch=='"'){closed=YES;end++;break;}[out appendFormat:@"%C",ch];end++;}
     if(closed)return out;
    }else{
     NSUInteger end=i;while(end<text.length){unichar ch=[text characterAtIndex:end];if(!((ch>='0'&&ch<='9')||ch=='-'))break;end++;}
     if(end>i)return @([[text substringWithRange:NSMakeRange(i,end-i)] integerValue]);
    }
   }
   search=NSMakeRange(NSMaxRange(found),text.length-NSMaxRange(found));
  }
 }
 return nil;
}

static NSInteger WBErrorCode(NSString *body){id code=WBFlatValue(body,@[@"code"]);return [code isKindOfClass:NSNumber.class]?[code integerValue]:0;}

static NSString *WBErrorMessage(NSString *body){
 id msg=WBFlatValue(body,@[@"displayMsg",@"displayMessage",@"msg",@"message"]);
 return [msg isKindOfClass:NSString.class]?msg:nil;
}

NSString *_Nullable TFAIWorkBuddyExplainError(NSInteger status,NSString *body){
 NSString *said=WBErrorMessage(body?:@"");NSInteger code=WBErrorCode(body?:@"");
 NSString *advice=nil;
 if(code==11101||code==11128)advice=@"网关认为这段对话像其它 Agent 的提示词；换新会话，或改用其它服务商";
 else if(code==11129||code==11133)advice=@"当前模型的工具定义被拒；可在连接里关闭项目工具后重试";
 else if(code==11153)advice=@"工具结果后面还需要一条用户消息；换新会话后重试";
 else if(code==11140||status==403)advice=@"账户被 WorkBuddy 限制，需在 WorkBuddy 内申诉解除";
 else if(code==14018||[body containsString:@"14018"])advice=@"账户积分包已用尽，需在 WorkBuddy 购买或续期";
 else if(status==401)advice=@"令牌无效或已过期，请重新填写 Bearer 令牌";
 else if(status==403)advice=@"账户被 WorkBuddy 限制或没有该模型权限，需在 WorkBuddy 内申诉解除";
 else if(status==429)advice=@"请求过于频繁或被限流，请稍后重试";
 if(!said.length&&!advice)return [NSString stringWithFormat:@"WorkBuddy 返回 HTTP %ld",(long)status];
 if(!advice)return said;
 if(!said.length||[said isEqual:advice])return advice;
 return [NSString stringWithFormat:@"%@（%@）",said,advice];
}

// MARK: - 工具 schema

static NSArray *WBKnownTypes(void){return @[@"string",@"number",@"integer",@"boolean",@"object",@"array",@"null"];}

static NSArray *WBOneSchemaKeys(void){return @[@"items",@"additionalItems",@"unevaluatedItems",@"contains",@"not",@"if",@"then",@"else",@"propertyNames",@"additionalProperties",@"unevaluatedProperties"];}
static NSArray *WBSchemaListKeys(void){return @[@"anyOf",@"oneOf",@"allOf",@"prefixItems"];}
static NSArray *WBSchemaMapKeys(void){return @[@"properties",@"patternProperties",@"$defs",@"definitions",@"dependentSchemas"];}

static BOOL WBIsBoolean(id value){if(![value isKindOfClass:NSNumber.class])return NO;const char *type=[(NSNumber *)value objCType];return strcmp(type,"c")==0||strcmp(type,"B")==0;}

static id WBFitEnum(NSMutableDictionary *object){
 id raw=object[@"enum"];
 if(![raw isKindOfClass:NSArray.class]||!((NSArray *)raw).count){if(raw)[object removeObjectForKey:@"enum"];return object;}
 NSArray *values=raw;
 NSArray *types=[object[@"type"] isKindOfClass:NSArray.class]?object[@"type"]:([object[@"type"] isKindOfClass:NSString.class]?@[object[@"type"]]:@[]);
 NSUInteger typed=0;for(id type in types)if(![type isEqual:@"null"])typed++;
 if(typed)return object; // 已带具体类型：枚举值也按该类型，原样发送。
 NSMutableArray *order=[NSMutableArray new];NSMutableDictionary *groups=[NSMutableDictionary new];
 for(id value in values){NSString *type=[value isKindOfClass:NSString.class]?@"string":[value isKindOfClass:NSNull.class]?@"null":WBIsBoolean(value)?@"boolean":[value isKindOfClass:NSNumber.class]?@"integer":@"object";if(!groups[type]){groups[type]=[NSMutableArray new];[order addObject:type];}[groups[type] addObject:value];}
 if([order containsObject:@"integer"]&&[order containsObject:@"number"]){[groups[@"number"] addObjectsFromArray:groups[@"integer"]];[(NSMutableArray *)groups[@"number"] sortUsingComparator:^NSComparisonResult(id a,id b){return [[a description] compare:[b description]];}];[order removeObject:@"integer"];}
 BOOL hasNull=[order containsObject:@"null"];[order removeObject:@"null"];
 [object removeObjectForKey:@"enum"];
 if(order.count<=1){NSString *type=order.firstObject?:@"null";object[@"type"]=hasNull?@[type,@"null"]:type;return object;}
 NSMutableArray *split=[NSMutableArray new];for(NSString *type in order)[split addObject:@{@"type":type,@"enum":groups[type]}];
 if(hasNull)[split addObject:@{@"type":@"null"}];
 [object removeObjectForKey:@"type"];object[@"anyOf"]=split;return object;
}

static id WBFitSchema(id schema,NSUInteger depth);
static id WBSubSchema(id value,NSString *key,NSUInteger depth){
 if(WBIsBoolean(value)&&![@[@"additionalProperties",@"unevaluatedProperties"] containsObject:key])return [(NSNumber *)value boolValue]?@{}:@{@"not":@{}};
 return WBFitSchema(value,depth+1);
}

static id WBFitSchema(id schema,NSUInteger depth){
 if(depth>64)return schema;
 if([schema isKindOfClass:NSArray.class]){NSMutableArray *out=[NSMutableArray new];for(id item in (NSArray *)schema)[out addObject:WBFitSchema(item,depth+1)];return out;}
 if(![schema isKindOfClass:NSDictionary.class])return schema;
 NSMutableDictionary *object=[schema mutableCopy];
 id type=object[@"type"];
 if(type){
  NSArray *listed=[type isKindOfClass:NSArray.class]?type:@[type];NSMutableArray *known=[NSMutableArray new];
  for(id raw in listed){if(![raw isKindOfClass:NSString.class])continue;NSString *name=((NSString *)raw).lowercaseString;if([WBKnownTypes() containsObject:name]&&![known containsObject:name])[known addObject:name];}
  if(!known.count)[object removeObjectForKey:@"type"];else object[@"type"]=known.count==1?known.firstObject:[known copy];
 }
 id required=object[@"required"];
 if([required isKindOfClass:NSArray.class]){NSMutableArray *names=[NSMutableArray new];for(id raw in (NSArray *)required)if([raw isKindOfClass:NSString.class])[names addObject:raw];object[@"required"]=[names copy];}
 else if(required)[object removeObjectForKey:@"required"];
 if(object[@"enum"])WBFitEnum(object);
 for(NSString *key in WBOneSchemaKeys())if(object[key])object[key]=WBSubSchema(object[key],key,depth);
 for(NSString *key in WBSchemaListKeys()){id list=object[key];if(![list isKindOfClass:NSArray.class])continue;NSMutableArray *out=[NSMutableArray new];for(id item in (NSArray *)list)[out addObject:WBSubSchema(item,key,depth)];object[key]=[out copy];}
 for(NSString *key in WBSchemaMapKeys()){id map=object[key];if(![map isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *out=[NSMutableDictionary new];for(id name in (NSDictionary *)map)out[name]=WBSubSchema(((NSDictionary *)map)[name],key,depth);object[key]=[out copy];}
 return [object copy];
}

static id WBFitParameters(id parameters){
 if(![parameters isKindOfClass:NSDictionary.class])return @{@"type":@"object",@"properties":@{}};
 id fitted=WBFitSchema(parameters,0);
 if([fitted isKindOfClass:NSDictionary.class]&&[fitted[@"anyOf"] isKindOfClass:NSArray.class]&&[fitted[@"anyOf"] count]==1&&[fitted[@"anyOf"][0] isKindOfClass:NSDictionary.class])fitted=fitted[@"anyOf"][0];
 NSMutableDictionary *root=[fitted isKindOfClass:NSDictionary.class]?[fitted mutableCopy]:[NSMutableDictionary new];
 if(![root[@"type"] isEqual:@"object"]){root[@"type"]=@"object";if(![root[@"properties"] isKindOfClass:NSDictionary.class])root[@"properties"]=@{};}
 return [root copy];
}

static BOOL WBIsSafeNameByte(unsigned char byte){return (byte>='0'&&byte<='9')||(byte>='A'&&byte<='Z')||(byte>='a'&&byte<='z')||byte=='_'||byte=='-';}

static NSString *WBSafeName(NSString *name,NSMutableSet<NSString *> *taken){
 NSMutableString *base=[NSMutableString new];
 // 逐字符处理 UTF-8，非 ASCII 字符一律换成 _。
 const char *bytes=name.UTF8String;
 for(NSUInteger i=0;bytes&&bytes[i];i++){unsigned char byte=(unsigned char)bytes[i];[base appendFormat:@"%c",WBIsSafeNameByte(byte)?byte:'_'];}
 if(!base.length)[base appendString:@"tool"];
 NSString *candidate=base.copy;NSUInteger suffix=2;
 while([taken containsObject:candidate])candidate=[NSString stringWithFormat:@"%@_%lu",base,(unsigned long)suffix++];
 [taken addObject:candidate];return candidate;
}

// MARK: - 请求体

static void WBWithoutTools(NSMutableDictionary *root){
 NSArray *fields=@[@"tool_choice",@"tools",@"functions",@"parallel_tool_calls"];
 for(NSString *field in fields)[root removeObjectForKey:field];
}

static void WBMendToolChoice(NSMutableDictionary *root,NSString *renamed){
 id choice=root[@"tool_choice"];
 if(!choice)return;
 if([choice isKindOfClass:NSString.class]){if([((NSString *)choice).lowercaseString isEqual:@"none"])WBWithoutTools(root);return;}
 if([choice isKindOfClass:NSDictionary.class]&&[choice[@"type"] isEqual:@"function"]&&renamed.length){root[@"tool_choice"]=renamed;return;}
 if(![choice isKindOfClass:NSDictionary.class]){[root removeObjectForKey:@"tool_choice"];return;}
 NSString *type=[choice[@"type"] isKindOfClass:NSString.class]?((NSString *)choice[@"type"]).lowercaseString:@"";
 if([type isEqual:@"none"])WBWithoutTools(root);
 else if([type isEqual:@"auto"])root[@"tool_choice"]=@"auto";
 else if([type isEqual:@"required"])root[@"tool_choice"]=@"required";
 else if([type isEqual:@"function"]){id name=choice[@"function"][@"name"];root[@"tool_choice"]=([name isKindOfClass:NSString.class]&&[name length])?name:@"auto";}
 else[root removeObjectForKey:@"tool_choice"];
}

void TFAIWorkBuddyPlan(NSDictionary *body,NSDictionary *connection,NSArray<NSDictionary *> *tools,NSDictionary **firstAttempt,NSDictionary<NSString *, NSString *> **renames){
 NSMutableDictionary *root=[body isKindOfClass:NSDictionary.class]?[body mutableCopy]:[NSMutableDictionary new];
 // 1. 首条必须是 system。
 id raw=root[@"messages"];NSMutableArray *messages=[NSMutableArray new];
 if([raw isKindOfClass:NSArray.class])for(id item in (NSArray *)raw)if([item isKindOfClass:NSDictionary.class])[messages addObject:item];
 if(messages.count&&![WBMessageRole(messages.firstObject) isEqual:@"system"])[messages insertObject:@{@"role":@"system",@"content":WBDefaultSystem()} atIndex:0];
 if(messages.count)root[@"messages"]=messages;
 // 2. 工具名与参数。
 NSMutableDictionary *sent=[NSMutableDictionary new],*original=[NSMutableDictionary new];NSMutableSet *taken=[NSMutableSet new];
 for(NSDictionary *tool in tools)if([tool[@"name"] isKindOfClass:NSString.class]&&[tool[@"name"] length])[taken addObject:tool[@"name"]];
 NSMutableArray *fitted=[NSMutableArray new];
 for(NSDictionary *tool in tools){
  if(![tool isKindOfClass:NSDictionary.class])continue;
  NSMutableDictionary *copy=[tool mutableCopy];copy[@"parameters"]=WBFitParameters(tool[@"parameters"]);
  NSString *name=[tool[@"name"] isKindOfClass:NSString.class]?tool[@"name"]:@"";
  BOOL safe=name.length>0;for(NSUInteger i=0;safe&&i<name.length;i++){unichar ch=[name characterAtIndex:i];if(ch>0x7f||!WBIsSafeNameByte((unsigned char)ch))safe=NO;}
  if(!safe){NSString *replacement=WBSafeName(name,taken);sent[name]=replacement;original[replacement]=name;copy[@"name"]=replacement;}
  [fitted addObject:[copy copy]];
 }
 if(fitted.count)root[@"tools"]=[fitted copy];
 if(sent.count&&[root[@"messages"] isKindOfClass:NSArray.class]){
  NSMutableArray *mended=[root[@"messages"] mutableCopy];
  for(NSUInteger i=0;i<mended.count;i++){
   NSDictionary *message=mended[i];if(![message[@"tool_calls"] isKindOfClass:NSArray.class])continue;
   NSMutableArray *calls=[NSMutableArray new];
   for(NSDictionary *call in message[@"tool_calls"]){if(![call isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *copy=[call mutableCopy];NSString *replacement=sent[[call[@"name"] isKindOfClass:NSString.class]?call[@"name"]:@""];if(replacement)copy[@"name"]=replacement;[calls addObject:copy];}
   NSMutableDictionary *copy=[message mutableCopy];copy[@"tool_calls"]=[calls copy];mended[i]=copy;
  }
  root[@"messages"]=[mended copy];
 }
 NSString *choiceName=[tools.firstObject[@"name"] isKindOfClass:NSString.class]?tools.firstObject[@"name"]:nil;
 WBMendToolChoice(root,choiceName?sent[choiceName]:nil);
 // 3. 思考档位：网关只认 none/minimal/low/medium/high/xhigh/max，off 不发送。
 NSString *effort=[connection[@"reasoningEffort"] isKindOfClass:NSString.class]?connection[@"reasoningEffort"]:@"";
 if(effort.length&&![effort isEqual:@"auto"])root[@"reasoning_effort"]=[@[@"none",@"minimal",@"low",@"medium",@"high",@"xhigh",@"max"] containsObject:effort]?effort:@"high";
 if([connection[@"omitStreamUsage"] boolValue])[root removeObjectForKey:@"stream_options"];
 if(firstAttempt)*firstAttempt=[root copy];
 if(renames)*renames=[original copy];
}

NSString *TFAIWorkBuddyRestoreName(NSString *name,NSDictionary<NSString *, NSString *> *renames){NSString *own=renames[name];return own?:name?:@"";}

BOOL TFAIWorkBuddyRefused(NSInteger status,NSString *body,NSDictionary *last,NSDictionary **retry){
 if(![last isKindOfClass:NSDictionary.class])return NO;
 NSInteger code=WBErrorCode(body?:@"");
 if(status!=400)return NO;
 NSMutableDictionary *root=[last mutableCopy];
 id raw=root[@"messages"];
 // 4. 工具结果后跟用户消息：中间补一条空的 assistant。
 if(code==11153||[body containsString:@"11153"]){
  if(![raw isKindOfClass:NSArray.class])return NO;
  NSMutableArray *messages=[raw mutableCopy];NSInteger index=(NSInteger)messages.count-1;
  while(index>=0&&[WBMessageRole(messages[(NSUInteger)index]) isEqual:@"user"])index--;
  if(index<0||index==(NSInteger)messages.count-1||![WBMessageRole(messages[(NSUInteger)index]) isEqual:@"tool"])return NO;
  [messages insertObject:@{@"role":@"assistant",@"content":@""} atIndex:(NSUInteger)index+1];
  root[@"messages"]=[messages copy];if(retry)*retry=[root copy];return YES;
 }
 // 4'. 系统提示词被拒：整段改作第一段用户发言，首条 system 只留默认一句。
 if(code==11101||code==11128){
  if(![raw isKindOfClass:NSArray.class])return NO;
  NSMutableArray *messages=[raw mutableCopy];NSMutableArray *lead=[NSMutableArray new];NSUInteger index=0;
  while(index<messages.count&&[WBMessageRole(messages[(NSUInteger)index]) isEqual:@"system"]){[lead addObject:WBBodyText(messages[index][@"content"])];index++;}
  NSString *said=[[lead componentsJoinedByString:@"\n\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if(!said.length||[said isEqual:WBDefaultSystem()])return NO;
  NSString *instructions=[NSString stringWithFormat:@"<instructions>\n%@\n</instructions>",said];
  NSMutableArray *out=[NSMutableArray new];[out addObject:@{@"role":@"system",@"content":WBDefaultSystem()}];BOOL placed=NO;
  for(NSUInteger i=index;i<messages.count;i++){
   NSMutableDictionary *copy=[messages[i] mutableCopy];
   if([WBMessageRole(copy) isEqual:@"system"]){copy[@"role"]=@"user";}
   else if(!placed&&[WBMessageRole(copy) isEqual:@"user"]){
    placed=YES;id content=copy[@"content"];
    if([content isKindOfClass:NSArray.class]){NSMutableArray *parts=[NSMutableArray arrayWithObject:@{@"type":@"text",@"text":instructions}];[parts addObjectsFromArray:(NSArray *)content];copy[@"content"]=[parts copy];}
    else copy[@"content"]=[NSString stringWithFormat:@"%@\n\n%@",instructions,[content isKindOfClass:NSString.class]?content:@""];
   }else if(!placed&&i==messages.count-1){placed=YES;}
   [out addObject:[copy copy]];
  }
  if(!placed)[out addObject:@{@"role":@"user",@"content":instructions}];
  root[@"messages"]=[out copy];if(retry)*retry=[root copy];return YES;
 }
 return NO;
}
