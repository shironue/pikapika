# AGENTS.md

面向本仓库内工作的编码代理。请先阅读本文件，再修改代码。

## 交流与提交

- 默认使用简体中文回复用户。
- Git 提交信息使用简体中文，格式可沿用 Conventional Commits，例如：`fix(reader): 修复翻页状态同步`。
- 不要自动提交；除非用户明确要求提交或批准提交。

## 项目概览

- `pikapika` 是一个跨平台漫画客户端，主要由 Flutter/Dart UI 和 Go 移动/桌面桥接组成。
- Flutter 入口：
  - `lib/main.dart`：通用应用入口。
  - `lib/main_desktop.dart`：go-flutter/hover 桌面入口，转发到 `lib/main.dart`。
- 目标平台包括 Android、iOS、Windows、macOS、Linux。
- `.fvmrc` 指定 Flutter `3.13.9`。README 和 CI 仍兼容部分 Flutter `2.10.3` 构建路径，修改依赖或 API 时要注意旧版本兼容分支。
- `pubspec.yaml` 的 Dart SDK 约束是 `>=2.12.0 <3.0.0`，不要引入 Dart 3 专属语法或依赖约束。

## 目录职责

- `lib/basic/`：核心基础层。
  - `Method.dart`：Dart 到原生/Go 的 `MethodChannel("method")` 封装，主要通过 `flatInvoke` 调用 Go 侧方法。
  - `Channels.dart`：`EventChannel("flatEvent")` 多订阅分发。
  - `Entities.dart`：API/业务实体模型，通常以 `fromJson` 构造。
  - `Common.dart`：通用 UI 对话框、toast、工具函数和深链处理。
  - `Navigator.dart`：导航观察器和 `navPushOrReplace`。
  - `config/`：一文件一配置项，通常包含 `initXxx`、`currentXxx`、选择对话框和 `xxxSetting()` widget。
- `lib/screens/`：页面级 Flutter widget。文件名多为 `XxxScreen.dart`，当前 lint 允许非 snake_case 文件名。
- `lib/screens/components/`：页面间复用的 UI 组件。
- `lib/assets/`：图片、SVG 和翻译资源。`lib/assets/translations/` 包含 `en-US`、`zh-CN`、`zh-TW`、`ja-JP`、`ko-KR`。
- `android/`、`ios/`、`macos/`、`linux/`、`windows/`：平台工程和平台通道实现。
- `go/mobile/lib/`：Go mobile 绑定产物位置，`Mobile.aar` 等生成物被 `.gitignore` 忽略；不要手工编辑生成产物。
- `ci/`：发布检查、上传等 Go 工具，使用独立 `ci/go.mod`。
- `scripts/`：作者构建脚本，包含 `gomobile bind`、APK/IPA/桌面打包脚本，以及 `rebuild_mobile_aar_from_apk.ps1` 这类临时恢复脚本。
- `test/`：当前只有 Flutter 模板测试，不能视为有效业务覆盖。

## 常用命令

优先使用仓库指定 Flutter 版本：

```bash
fvm flutter pub get
fvm flutter analyze
fvm flutter test
```

如果没有 FVM，可使用系统 Flutter：

```bash
flutter pub get
flutter analyze
flutter test
```

发布/平台构建通常还需要 Go、gomobile、hover、Android/iOS/macOS/Linux/Windows 原生工具链。不要把完整发布链当作普通验证命令；一般改动先运行 `flutter analyze`，有测试改动时运行相关 `flutter test`。

如果缺少 Go core 源码或原始 `Mobile.aar`，但手头有已编译 Android APK，可以按 `scripts/rebuild_mobile_aar_from_apk.README.md` 使用恢复脚本从 APK 提取 `libgojni.so` 并重建 Android 需要的 `go/mobile/lib/Mobile.aar`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\rebuild_mobile_aar_from_apk.ps1 `
  -ApkPath "D:\tmp\pikapika-android-arm64.apk"
```

需要脚本生成 AAR 后直接验证 Android arm64 debug 构建时，追加 `-VerifyBuild`。这只是临时恢复流程，不会还原 Go 源码；输入 APK 只包含哪个 ABI，生成的 AAR 也只适用于对应 ABI。

## 代码风格

- 遵守 `analysis_options.yaml`，当前继承 `package:flutter_lints/flutter.yaml`，并显式放宽：
  - `avoid_print: false`
  - `unnecessary_this: false`
  - `file_names: false`
  - `constant_identifier_names: false`
  - `no_logic_in_create_state: false`
- 现有代码大量使用 `late` 字段、手写 `fromJson`、模块级状态和函数式配置项；改动时优先延续现有模式。
- UI 文案必须走 `tr("...")`，不要在新 UI 中硬编码用户可见文案，除非周边代码已明确是平台原生固定文案。
- 新增翻译 key 时同步更新所有 `lib/assets/translations/*.json`，至少保证 fallback 行为可接受。
- 页面导航优先使用 `navPushOrReplace(context, ...)` 或周边页面已有的导航方式，避免绕过当前深度控制逻辑。
- 平台相关判断优先复用 `dart:io Platform` 和 `lib/basic/config/Platform.dart` 中既有能力。

## 原生桥接约定

- Dart 侧所有 Go/API 能力优先通过 `method` 单例封装，不要在页面里直接散落 `MethodChannel` 调用。
- `Method._flatInvoke` 会把非字符串参数 JSON 编码后传给原生侧 `flatInvoke`；新增 Go 方法时要保持方法名和参数结构稳定。
- `flatEvent` 是给 Go/原生事件用的平铺事件通道。Dart 侧通过 `registerEvent`/`unregisterEvent` 订阅指定事件名。
- Android 原生入口在 `android/app/src/main/kotlin/opensource/pic2acg/MainActivity.kt`，已定义 `method`、`network`、`volume_button` 通道。
- iOS 原生入口在 `ios/Runner/AppDelegate.swift`，已定义 `method`、`network`、`flatEvent` 通道。
- 修改平台通道时必须同时检查 Dart 封装和对应平台实现，至少覆盖 Android/iOS；桌面行为也要确认是否由 Go/hover 侧提供。

## 配置项模式

`lib/basic/config/` 中的配置项通常遵循以下模式：

- 常量 `_propertyName` 和 `_defaultValue`。
- 模块级 `_current...` 状态。
- `initXxx()` 从 `method.loadProperty` 加载。
- `currentXxx()` 或类似函数供业务读取。
- `chooseXxx()`/`setXxx()` 保存到 `method.saveProperty`。
- `xxxSetting()` 返回 `ListTile`、`SwitchListTile` 或 `StatefulBuilder` 供设置页复用。

新增配置时优先复制相近配置文件的结构，并确认初始化函数已接入应用启动流程或设置页。

## 国际化与资源

- 移动端使用 `easy_localization`，桌面端由 `lib/i18.dart` 加载 `zh-CN.json` 到内存。
- `lib/basic/define.dart` 定义支持语言和翻译路径。
- `pubspec.yaml` 已声明资源目录：
  - `lib/assets/`
  - `lib/assets/translations/`
- 新增资源后确认 `pubspec.yaml` 覆盖路径即可；不要把运行期生成的 `lib/assets/version.txt` 提交到仓库。

## 构建产物与不要误动的文件

- 不要提交 `build/`、`.dart_tool/`、`.fvm/`、`.flutter-plugins*`、`go.work`、`tmp/`。
- 不要手工修改或提交 `go/mobile/lib/*.aar`、`*.jar`、`*.framework/`、`*.xcframework/`；这些由 `gomobile bind`、构建脚本或 `scripts/rebuild_mobile_aar_from_apk.ps1` 生成。
- 平台生成文件如 `generated_plugin_registrant.*`、`generated_plugins.cmake` 通常由 Flutter 工具维护；只有依赖变更需要刷新时才让工具更新。
- Android 发布签名脚本依赖 CI 环境变量；本地不要写入密钥、密码或证书。

## 验证建议

- Dart/UI 改动：运行 `fvm flutter analyze` 或 `flutter analyze`。
- 修改测试或可测试逻辑：运行 `fvm flutter test` 或 `flutter test`。注意当前 `test/widget_test.dart` 是模板测试，可能需要先修正后才有业务意义。
- Android/iOS 平台通道改动：至少执行对应平台的编译或局部构建；移动绑定相关改动需要重新执行对应 `scripts/bind-*.sh` 或构建脚本。
- 使用 `scripts/rebuild_mobile_aar_from_apk.ps1` 恢复 `Mobile.aar` 后，按 `scripts/rebuild_mobile_aar_from_apk.README.md` 检查 APK 是否包含 `classes.dex`、`lib/<abi>/libgojni.so` 和 gomobile 绑定类；必要时用 `-KeepWorkDir` 保留临时目录排查，并运行 `flutter build apk --debug --target-platform android-arm64` 或脚本的 `-VerifyBuild`。
- CI 工具改动：进入 `ci/` 后运行 `go test ./...` 或至少 `go test`/`go run` 对应命令。
- 构建脚本改动：优先做 shell 静态阅读和最小目标验证，避免无意触发完整发布流程。

## 外部文档

当用户询问库、框架、SDK、API、CLI 或云服务用法时，按用户级指令优先使用 `ctx7` CLI 获取最新文档；不要仅凭记忆回答版本敏感问题。
