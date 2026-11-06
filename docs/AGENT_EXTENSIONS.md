# 服务商与通用 Agent · Build 163

## 服务商与模型

设置 → AI 开发助手 → ＋。保留原8家，新增 Kimi（Moonshot）、xAI（Grok）和正式的自定义 OpenAI 兼容入口。自定义入口需自行填写服务地址；App不预置中转地址或密钥。

后续新增 WorkBuddy（腾讯 CodeBuddy 开发工作台，`workbuddy` / `workbuddy-ai`）：`App/AI/Providers/TFAIWorkBuddy.{h,m}` 只对这两个 id 生效，负责请求头、`system` 首条约束、工具名与 schema 整形、`tool_choice` 写法、思考档位，以及 `11101/11128/11153` 的一次性修补重发；模型目录是 `GET <base 去掉 /v2>/v3/config` 的 `cli` agent。网关只认 WorkBuddy 账户的 Bearer 令牌，连接里以 API 密钥形式填写；OAuth 登录需要 WorkBuddy 客户端的公开客户端参数与回跳 scheme，本期未接入。

服务目录位于 `Resources/AIProviders/Providers.json`，按模型族的思考档位位于 `Thinking.json`。目录中的五项能力初值全部为unknown，模型发现本身不证明调用能力。获取官方模型列表后仍可手工添加模型ID；现有分页、Gemini generateContent筛选和四项实际探测保留。更换模型、地址、协议、鉴权方式或客户端ID后重新验证能力。

在会话模型菜单切换服务商/模型，先做文本连接探测；通过后更新下一轮连接。失败保留原连接并显示错误，进行中的一轮保持原连接快照。项目覆盖与全局默认仍各自保存；切换不会新建项目、清除历史或重置人设/技能/记忆。标题显示服务商、模型及实测支持/失败状态，其他能力保持unknown。

## 官方 OAuth

支持 Google Gemini 的标准OAuth，以及OpenRouter文档规定的PKCE授权换key。其他服务使用API key；本期没有订阅、Cookie、逆向鉴权或非官方登录适配。

Google：为自己的App Bundle ID注册Google iOS OAuth客户端，把公开客户端ID填入连接。按官方文档启用API并配置同意屏幕/配额项目。由ASWebAuthenticationSession展示官方授权页，使用PKCE S256、随机state和回调校验。访问/刷新令牌仅存钥匙串；临近过期时并发请求共用一次刷新。客户端/服务商/官方地址发生变化时要求重新登录，令牌不转送到新服务。退出先清除本机凭据，再调用官方revoke。吊销遇到网络错误时如实提示到Google账户撤销。

OpenRouter：官方PKCE流程返回API key，没有refresh-token对；本机同样只存钥匙串。退出清除本机key，远端撤销须在官网密钥管理完成，本流程没有假造自动吊销接口。该项不等同于Google的refresh/revoke验收。

OAuth诊断不保存响应正文、底层网络错误或令牌；令牌不写UserDefaults、连接JSON或日志。真实账户登录、授权回跳和远端吊销仍需要账户侧验收。

## 技能

会话菜单 → 通用 Agent，或AI设置 → 通用 Agent。四份随App分发的文本技能：Theos/Logos、Hook模板、deb打包、Mach-O分析。首次使用可安装至当前项目`.dylix/skills/<id>/SKILL.md`；已有同名目录原样保留，项目版本优先。

SKILL.md以简单frontmatter声明`name`、`description`，其后是正文。清单元数据进入独立上下文，正文仅在模型调用`agent_skill_read`时读取。脚本不执行；文本不授予写项目、Git或构建权限。越界和外部符号链接被拒绝。没有添加新的人设正文，旧人设数据及目录保持原样。

## HTTP MCP

导入格式：

```json
{"mcpServers":{"文档服务":{"url":"https://example.org/mcp","headers":{"Authorization":"Bearer YOUR_TOKEN"}}}}
```

仅支持2025-06-18 Streamable HTTP（POST JSON或SSE响应）。公网HTTPS；HTTP仅限局域网。鉴权头进入独立钥匙串，元数据仅记录服务器地址、名称和逐项允许列表。URL内的账号、密钥查询参数、Cookie、stdio command/args/env不导入。

导入 → 发现工具 → 审核并逐项启用只读查询 → 在目标会话开启服务器。全局设置页没有会话开关权限；从会话进入可配置对应会话。重启后会话启用状态关闭，重新发现后再启用；服务配置和逐项允许列表保留。重新导入会清除缓存、工具允许列表和会话启用状态，要求重新审核。

只接受明确readOnlyHint=true、destructiveHint=false的工具，额外拒绝写入/执行/构建/Git等名称与写SQL参数。工具默认不开放。服务端声明不是可信证明，用户须审核服务器与工具；远端只读承诺最终由该服务器执行。MCP没有本机文件/构建/Git桥接权限；这些操作继续走原Dylix工具和审批。结果标记为远端参考数据，不作为操作授权。

## 只读 JS 浏览

启用原有联网工具后，runtime额外提供`web_browse`；也可在通用Agent页面手工读取公开网页。临时WKWebView渲染JavaScript并提取正文、标题、URL和最多100条链接。账号数据不持久化，不自动登录、填表、下载或打开外部应用。导航仅GET；脚本层阻止常见写请求和表单，并禁用动态表单控件。

此功能提供只读Agent交互，不把任意网页JavaScript变成网络沙盒。页面资源仍由WebKit加载，不应打开依赖账户授权的操作页面；远端内容始终是非可信参考资料。

## 项目记忆与长会话

项目根目录MEMORY.md可在通用Agent页面编辑，用于记录已确认架构、SDK和已知坑。不覆盖现有文件；保存用内容指纹检测其他编辑器的修改，并复用Git写租约。模型可按现有项目读取权限按需读取，记忆正文不自动塞入system。

超过80条消息或192KB的长上下文，按角色截取早期记录至`.dylix/summaries/<会话UUID>.md`，后续请求保留最近8次用户发言及完整工具轮次。此处是确定性的本地截取记录，不是模型生成的语义摘要；不调用额外模型，也不自动上传摘要文件。保存失败则继续保留全部上下文。完整UI/落盘聊天历史独立保留，不因请求压缩而截断。

## 构建队列与检查点

原生、AI和Remote进入原Studio构建入口后加入全局队列；原有审批、Git租约、项目快照、编译器和打包器继续使用。同项目重复请求合并，其他项目排队；已有非队列本机构建运行时等待空闲。

取消排队立即生效；运行中在快照/Logos/编译/打包步骤边界取消，不强杀当前LLVM调用。取消不会显示构建成功。失败、取消或进程中断后在任务页查看日志/结果，点击“从检查点重新构建”，确认后重新核对当前项目再入队，不重用旧审批。

检查点以项目普通文件内容（含隐藏头文件）、配置、App构建号和SDK资源指纹及编译参数作为键，只复用SHA-256校验通过的成功目标文件。源码、配置或SDK变化时重新编译；链接与打包始终重跑。缓存限制约256MB并保守清理；原始日志和可导出checkpoint.json保留。调试路径可能指向原快照，符号诊断须结合对应来源记录核对。

进度复用现有音频/系统后台、LiveActivity和通知能力。iOS15没有LiveActivity，16.2及以上按现有桥接能力展示。任务完成通知进入构建队列。后台和锁屏运行仍服从iOS调度与音频开关；不承诺永久运行，进程重启后未完成任务标记中断，重新确认后续跑。

## 代码与存储索引

- 服务声明：Resources/AIProviders；协议目录入口：App/AI/Providers/TFAIRegistry。
- OAuth：App/AI/Providers/TFAIOAuth；传输：TFAITransport；连接：TFAIConnections。
- Agent：App/AI/Agent；runtime接入：App/AI/Core/AIRuntime.m；原工具schema和审批文件保持原哈希。
- 本机配置：Application Support/DylixAgent/mcp.json、build-queue.json；MCP鉴权头及OAuth令牌分别存钥匙串。
- 原项目、技能、记忆、人设目录均无清空或重置迁移。

## 参考依据

仅参考OpenMinis的目录分层与结构，Objective-C独立实现，未复制Swift代码或引入依赖。参考commit：`1a71df0f381cefde80bf912b723de6f9831bc177`。

- https://github.com/OpenMinis/OpenMinis
- https://platform.moonshot.ai/docs/api/models
- https://docs.x.ai/developers/rest-api-reference/inference/models
- https://openrouter.ai/docs/guides/overview/auth/oauth
- https://ai.google.dev/gemini-api/docs/oauth
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
