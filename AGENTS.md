# dylix-workbuddy：本工作区的构建说明

这是 [Dylix](https://github.com/yangokok886/dylix) 的源码工作区（Apelin 外部构建）。Dylix 是 iPhone / iPad 上的插件开发 App，**不是 tweak**。

## 本机（iOS 设备）上能做和不能做的

- 这里**无法产出可安装的 IPA**：`scripts/build.py` 需要 macOS 上完整的 Xcode / `xcrun`、CMake、Rust 工具链，以及 `App/` 之外的资源；`shell_run` 里没有 `xcrun`、`cmake`、`make`、`cargo`，`Vendor/` 里的预编译框架也没有拉取（需 `scripts/fetch_toolchain.py`）。
- 因此本工作区**不声明 `external.script`**，`apelin_project_build` 没有可跑的构建；发布 IPA 仍要在 Mac 上执行 `python3 scripts/fetch_toolchain.py` 后 `python3 scripts/build.py --sdk-root LocalSDKs/iPhoneOS26.0.sdk`。
- 能在本机做的是**离线验证**：用设备上的 clang + `SDKROOT` 对改动文件做语法检查，并把与 UI 无关的纯逻辑编成命令行程序跑回归（见下）。

## 改代码后的检查方法（本机）

改动文件与 iOS SDK 一起做语法检查：

```sh
cd "$APELIN_PROJECT_ROOT"
for f in App/AI/Providers/TFAIWorkBuddy.m App/AI/Transport/TFAITransport.m; do
  clang -fobjc-arc -fmodules -O0 -Wall -Wno-nullability-completeness -c -o /dev/null "$f" || exit 1
done
```

纯逻辑回归（`fixtures/workbuddy_smoke.m`，不联网）：自己链接的程序**必须先用工具有效的 entitlements 签名**，否则 shell_run 直接 exit 137。

```sh
d="$(mktemp -d)"; cd "$APELIN_PROJECT_ROOT"
clang -fobjc-arc -w -o "$d/smoke" App/AI/Providers/TFAIWorkBuddy.m fixtures/workbuddy_smoke.m -framework Foundation
cat > "$d/Tool.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
</dict></plist>
EOF
cd "$d" && ldid -STool.entitlements smoke && ./smoke
```

`smoke` 也接受 `-v config.json`（解析真实的 `/v3/config` 响应）和 `-e body.txt`（翻译真实错误体）。

注意：本机 Foundation 上 `-[NSString substringToIndex:]` 的行为不可靠（会抛越界），拿不准时用 `substringWithRange:` 并先判长度，`fixtures/workbuddy_smoke.m` 里踩过这个坑。

## AI 服务商：WorkBuddy 适配（2026-11）

- 目录：`Resources/AIProviders/Providers.json` 新增 `workbuddy`（`https://copilot.tencent.com/v2`）与 `workbuddy-ai`（`https://workbuddy.ai/v2`），二者 `wireProtocol` 都是 `chat`。
- 适配代码：`App/AI/Providers/TFAIWorkBuddy.{h,m}`，只对这两个 id 生效：
  - 请求头带客户端标识（`X-Product`、`X-IDE-Type`、`X-Conversation-ID` 等），User-Agent 固定为客户端形式；
  - 请求体补 `system`、整形工具名与 JSON Schema、`tool_choice` 改成字符串、思考档位走 `reasoning_effort`；
  - 模型目录走 `GET <base 去掉 /v2>/v3/config` 的 `cli` agent；
  - 400 时按 `11153`（工具结果后跟用户消息）与 `11101/11128`（系统提示词被拒）各修补重发一次；
  - 401/403/429 与 `14018`、`11140` 等错误码翻成可操作的中文。
- 参考实现：[EYHN/kwwk](https://github.com/EYHN/kwwk) `Sources/KWWKAI/WorkBuddy`。
- **鉴权限制**：网关只认 WorkBuddy 账户的 Bearer 令牌。kwwk 的 OAuth 用 WorkBuddy 客户端自己的客户端标识与回跳，Dylix 没有该客户端身份（App 的 `CFBundleURLTypes` 也没有对应 scheme），所以 Dylix 里是「API 密钥」形式填 Bearer 令牌；否则网关答 401（APISIX，HTML 正文）。要支持 OAuth 登录，需要拿到公开的客户端参数并在 App 里注册回跳 scheme。
- 未在真机 Dylix 里跑过：本机无法构建 App，所以 UI 流程与真实账户调用都待用户在 Mac 构建后验证。
