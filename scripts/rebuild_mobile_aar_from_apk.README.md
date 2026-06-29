# rebuild_mobile_aar_from_apk.ps1

从已经编译好的 Android APK 中提取 `libgojni.so`，并重建项目需要的 `go/mobile/lib/Mobile.aar`。

这个脚本用于缺少 `pikapika-go-core` 源码或原始 `Mobile.aar` 时的临时恢复流程。它不会还原 Go 源码，只会从 APK 中提取已编译的 native 库，并生成一组最小 gomobile Java stub，让 Flutter Android 工程可以重新编译。

## 前置条件

- Windows PowerShell。
- JDK 可用，`javac` 和 `jar` 需要在 `PATH` 中。
- Android SDK 可用，并且安装了至少一个 `platforms/android-*/android.jar`。
- APK 中必须包含：
  - `classes.dex`
  - `lib/<abi>/libgojni.so`
  - dex 里存在 `mobile.Mobile`、`mobile.EventNotifyHandler`、`go.Seq` 等 gomobile 绑定类。

脚本会按以下顺序寻找 Android SDK：

1. 命令参数 `-AndroidSdk`
2. `android/local.properties` 里的 `sdk.dir`
3. 环境变量 `ANDROID_HOME`
4. 环境变量 `ANDROID_SDK_ROOT`

## 常用命令

在项目根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\rebuild_mobile_aar_from_apk.ps1 `
  -ApkPath "D:\tmp\pikapika-v1.8.20-android-arm64-flutter_3.13.9.apk"
```

默认输出：

```text
D:\workspace\github\shironue\pikapika\go\mobile\lib\Mobile.aar
```

生成 AAR 后，可以构建 arm64 APK：

```powershell
flutter build apk --debug --target-platform android-arm64
```

如果要让脚本生成 AAR 后直接验证 debug 构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\rebuild_mobile_aar_from_apk.ps1 `
  -ApkPath "D:\tmp\pikapika-v1.8.20-android-arm64-flutter_3.13.9.apk" `
  -VerifyBuild
```

## 参数

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `-ApkPath` | 是 | 输入 APK 路径。 |
| `-OutputAar` | 否 | 输出 AAR 路径。默认是项目内 `go/mobile/lib/Mobile.aar`。 |
| `-WorkDir` | 否 | 临时工作目录。默认使用系统临时目录下的随机目录。 |
| `-AndroidSdk` | 否 | 显式指定 Android SDK 路径。 |
| `-KeepWorkDir` | 否 | 保留临时工作目录，方便排查生成出的 Java stub、`classes.jar`、`dexdump.txt`。 |
| `-VerifyBuild` | 否 | 生成 AAR 后执行 `flutter build apk --debug --target-platform android-arm64`。 |

示例：指定输出位置并保留临时目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\rebuild_mobile_aar_from_apk.ps1 `
  -ApkPath "D:\tmp\source.apk" `
  -OutputAar "D:\tmp\Mobile.aar" `
  -KeepWorkDir
```

## 生成内容

脚本会生成一个标准 AAR：

```text
Mobile.aar
├─ AndroidManifest.xml
├─ classes.jar
└─ jni/
   └─ <abi>/
      └─ libgojni.so
```

`classes.jar` 中包含最小 Java stub：

- `go.Seq`
- `go.Universe`
- `go.error`
- `mobile.EventNotifyHandler`
- `mobile.Mobile`

这些类名和 native 方法名需要保留，因为 `libgojni.so` 会按 gomobile 的 JNI 命名约定查找它们。

## Release 构建注意事项

Release 构建会经过 R8/ProGuard。为了避免 gomobile JNI 绑定类被混淆或裁剪，项目需要保留规则：

```proguard
-keep class go.** { *; }
-keep class mobile.** { *; }
-keepnames class go.**
-keepnames class mobile.**

-keepclasseswithmembernames class * {
    native <methods>;
}
```

否则可能出现 release APK 启动闪退，常见原因是 `mobile.Mobile$proxyEventNotifyHandler`、`go.Universe$proxyerror` 等类名被 R8 改写。

## 限制

- 这不是源码恢复。脚本无法还原 Go core 源码，只能复用 APK 中已经编译好的 `libgojni.so`。
- 输出 AAR 只包含输入 APK 里已有的 ABI。比如输入 APK 只有 `arm64-v8a`，生成的 AAR 也只能用于 arm64 构建。
- 如果后续版本的 gomobile Java API 发生变化，脚本内的 stub 签名可能需要同步调整。
- 如果 APK 没有 `libgojni.so` 或 dex 中没有预期的 `mobile.Mobile` 绑定类，脚本会直接失败。

## 排错

查看 APK 是否包含 native 库：

```powershell
jar tf "D:\tmp\source.apk" | Select-String "libgojni.so"
```

保留临时目录以检查生成过程：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\rebuild_mobile_aar_from_apk.ps1 `
  -ApkPath "D:\tmp\source.apk" `
  -KeepWorkDir
```

如果 release APK 闪退，先确认 dex 中类名没有被混淆：

```text
mobile.Mobile
mobile.Mobile$proxyEventNotifyHandler
go.Seq
go.Universe$proxyerror
```

如果电脑能连接手机，可以用 `adb logcat` 抓启动崩溃栈再定位。
