# 无 Xcode 构建 icopool 发行版（CommandLineTools 环境）

本方法面向**没有完整 Xcode、只有 CommandLineTools** 的机器/agent。
产物是 ad-hoc 签名的 `icopool.app`，可直接本地部署/分发（不做 Developer ID 签名与公证）。

> 对比 `scripts/release_macos.sh`：那个脚本需要完整 Xcode（`xcodebuild archive`）、
> Developer ID 证书与公证后端，只适用于正式对外分发；本方法无这些依赖。

## 快速开始

```bash
# 一条命令：构建 + 组装 dist/icopool.app
./scripts/build_release_noxcode.sh

# 构建 + 组装 + 部署本地 + 打 zip
./scripts/build_release_noxcode.sh --deploy --zip
```

其他参数见脚本头注释（`--skip-build` / `--app <path>`）。

## 前置条件

- `CommandLineTools`：`xcode-select -p` 输出 `/Library/Developer/CommandLineTools` 即可（不需要 Xcode.app）
- 工具：`swift`、`codesign`、`ditto`、`plutil`、`/usr/libexec/PlistBuddy`
- 项目根目录可用 `git`（版本号从 `project.yml` 读取，与 Xcode 构建保持一致）

## 完整流程（手动步骤，脚本内部即此逻辑）

### 1. 版本号

从 `project.yml` 读取（勿硬编码）：

```bash
MARKETING_VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | awk '{print $2}')
CURRENT_PROJECT_VERSION=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}')
```

### 2. 选择 SDK（关键！）

**必须避开 macOS 27 SDK。** 27 SDK 里 `@State` 改成了 Swift 宏
（`SwiftUIMacros.StateMacro`），而宏插件只随完整 Xcode 发布——CommandLineTools
没有，直接编译报：

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
      for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

（表现是**所有** `@State` 相关代码报错：`cannot find '$xxx' in scope`、
`cannot use mutating member on immutable value` 等，全是级联噪音。）

**解法：用 26.x SDK 构建**：

```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build -c release --sdk "$SDK"
```

26.5 SDK 下 `@State` 仍是属性包装器，可正常编译。产物在
`.build/release/Copool`、`.build/release/CopoolRouterHost`、
`.build/release/Copool_Copool.bundle`。

### 3. 组装 app bundle（dist/icopool.app）

```
Contents/
├── Info.plist              ← 模板 Sources/Copool/Info-macOS.plist，替换占位符
├── MacOS/
│   ├── icopool             ← .build/release/Copool
│   └── CopoolRouterHost    ← .build/release/CopoolRouterHost
└── Resources/
    ├── Copool.icns         ← 图标（从旧 bundle 保留；源是 icon composer 格式，无法用 iconutil 转换）
    ├── Copool_Copool.bundle ← ★ 整个资源 bundle 必须拷入（见坑 2）
    └── <bundle 展开资源>     ← lproj / proxyd-* / provider-registry-seed.json 等
```

Info.plist 占位符替换（用 sed 或 PlistBuddy）：

| 占位符 | 值 |
|---|---|
| `$(DEVELOPMENT_LANGUAGE)` | `en` |
| `$(EXECUTABLE_NAME)` | `icopool` |
| `$(PRODUCT_BUNDLE_IDENTIFIER)` | `com.alick.copool` |
| `$(PRODUCT_BUNDLE_PACKAGE_TYPE)` | `APPL` |
| `$(MARKETING_VERSION)` | 从 project.yml |
| `$(CURRENT_PROJECT_VERSION)` | 从 project.yml |

已有 bundle 时用 PlistBuddy 只改两个版本键即可。

### 4. ad-hoc 签名

```bash
codesign --remove-signature dist/icopool.app 2>/dev/null || true
codesign --force --deep --sign - dist/icopool.app
codesign --verify --deep --strict dist/icopool.app   # 必须输出无错误
```

### 5. 部署到本地 /Applications

```bash
pkill -f "icopool.app/Contents/MacOS/icopool" || true
rm -rf /Applications/icopool.app && cp -R dist/icopool.app /Applications/
codesign --force --deep --sign - /Applications/icopool.app
open /Applications/icopool.app
```

### 6. 验证

```bash
pgrep -fl "icopool.app/Contents/MacOS/icopool"          # 进程存活
KEY=$(cat ~/.codex-tools-proxyd/api-proxy.key)
curl -s -m 8 -H "Authorization: Bearer $KEY" http://127.0.0.1:8787/v1/models   # 返回模型列表
ls -t ~/Library/Logs/DiagnosticReports/icopool-*.ips | head -1   # 不应有本次启动的新崩溃
```

## 三个关键坑（都踩过）

1. **27 SDK 的 `@State` 宏**（见上）。判断方法：报错里出现
   `SwiftUIMacros` / `$xxx in scope` → 换 26.5 SDK。
2. **`Bundle.module` 运行时查找**。新工具链生成的资源访问器不再嵌入开发机
   绝对路径（旧产物里有 `/Users/.../.build/arm64-apple-macosx/release/Copool_Copool.bundle`
   这样的字符串，新产物没有），而是按顺序查找：
   `Bundle.main.resourceURL` → framework 位置 → `Bundle.main.bundleURL`，
   即期望 `<app>/Contents/Resources/Copool_Copool.bundle`。
   **不拷入 bundle 会导致启动即崩溃**（`L10n` 初始化 `_assertionFailure`）。
   注意：增量构建时 accessor 可能又嵌入绝对路径，让开发机"碰巧能跑"，
   但**发行版必须带 bundle**，否则换机器就崩。
3. **`Data.split` 歧义**（26.5 SDK 下）：`data.split(separator: 0x0A).map(Data.init)`
   会报 `ambiguous use of 'split'`。已修复为
   `data.split(separator: UInt8(0x0A)).map { Data($0) }`
   （提交 `76bc336`，拉最新代码即可；如遇同样报错按此改）。

## 常见问题

- **`swift build` 报 SwiftUIMacros**：忘了 `--sdk`，或机器上没有 26.x SDK。
  检查 `ls /Library/Developer/CommandLineTools/SDKs/`。
- **启动即崩、DiagnosticReports 出现 `NSBundle.module` 断言**：Resources 里缺
  `Copool_Copool.bundle`，重新组装（脚本第 4.3 步会自动处理）。
- **启动卡住**：ad-hoc 签名每次重建签名变化，macOS 可能弹 keychain 授权框
  （本项目的 KeychainSecretStore 已做 3 秒超时硬化，一般会自动降级）。
- **lproj 大小写**（`zh-Hans` vs `zh-hans`）：不同 SDK/构建布局有差异，
  macOS 默认文件系统大小写不敏感，两者等效，不必纠结。
- **版本号对不上**：始终以 `project.yml` 的 `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` 为准，Info.plist 是它的投影。

## 产物

- `dist/icopool.app` —— 组装好的 app
- `dist/icopool-<ver>-macOS-signed.zip` + `.sha256` —— 分发 zip（`--zip`）
- 旧版备份可先 `cp -R /Applications/icopool.app /tmp/icopool-backup.app`
