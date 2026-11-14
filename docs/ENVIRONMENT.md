# 开发环境记录(本机 D:\DPAPP,2026-11-14 安装并验证)

> 用途:M0 起的所有构建/验证命令都依赖这些路径与变量。换机器时按本文件重装一遍。

## 已装组件

| 组件 | 版本 | 位置 |
|---|---|---|
| Node.js / npm | v24.22.0 / 11.19.1 | `C:\Program Files\nodejs`(系统 PATH) |
| git | 2.56.0 | `C:\Program Files\Git\cmd`(系统 PATH) |
| Flutter / Dart | 3.50.0 stable / 3.14.0 | `D:\dev\flutter` |
| JDK(Temurin) | 17.0.21+9 | `D:\dev\jdk-17` |
| Android SDK | platform-tools 37.0.1、platforms/android-36、build-tools 36.0.0、ndk 28.2.13676358、cmdline-tools latest | `D:\dev\android-sdk` |
| Chrome(Web 调试目标) | 156 | `C:\Program Files\Google\Chrome` |

Flutter 3.50 模板默认 `compileSdk=36 / targetSdk=36 / minSdk=24`,与已装 platforms/android-36 一致。

## 环境变量(User 级,已持久化,新终端生效)

```
JAVA_HOME          = D:\dev\jdk-17
ANDROID_HOME       = D:\dev\android-sdk
ANDROID_SDK_ROOT   = D:\dev\android-sdk
PATH              += D:\dev\flutter\bin
                     D:\dev\android-sdk\platform-tools
                     D:\dev\android-sdk\cmdline-tools\latest\bin
                     D:\dev\android-sdk\emulator
                     D:\dev\jdk-17\bin
```

## 踩过的坑(重装时避免)

1. **不要用 winget 装 JDK**:当前会话非管理员,全机 MSI 会卡在看不见的 UAC 上。改用 Temurin zip 解压 + 设 `JAVA_HOME` 即可,无需提权。
2. **NDK 必须手动预装**:
   ```powershell
   sdkmanager --sdk_root=D:\dev\android-sdk --install "ndk/28.2.13676358"
   ```
   直接 `flutter build apk` 会失败:AGP 用旧语法 `ndk;版本` 自动安装,而新版 cmdline-tools 已把包名改成 `ndk/版本` 并废弃 sdkmanager,导致 "Package 28.2.13676358 not found"。
3. **sdkmanager 已标记废弃**,新 CLI 是 `android`(同目录),包名用斜杠(`platforms/android-36`、`build-tools/36.0.0`、`ndk/28.2.13676358`);旧分号语法仍兼容但不全。
4. **已启动的 DSH / 终端不继承新 PATH**:命令行里用绝对路径 `D:\dev\flutter\bin\flutter.bat`,或在命令前显式设置 `$env:PATH`。
5. **别删 Gradle 缓存** `C:\Users\liduo\.gradle`:首次构建花了 ~6.5 分钟下载,后续构建 ~2.5 分钟。

## 验证结论

- `flutter doctor`:Android toolchain √、Chrome √、Proxy √、Network resources √(仅 Visual Studio 缺,它只用于 Windows 桌面应用,本项目不需要)
- 临时工程 `flutter build apk --debug` 成功产出 `app-debug.apk`(150.7 MB),Gradle/AGP/NDK 全链路打通
- 真机调试:`adb devices` 需连上手机并开启 USB 调试;当前未连设备
