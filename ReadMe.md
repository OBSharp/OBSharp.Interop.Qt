# OBSharp.Interop.Qt

面向 .NET 的 Qt 6 绑定库，让 C# 项目可以直接使用 Qt 6 的窗口、控件、绘图、网络、多媒体等能力。

托管 API 由工具从 Qt 的公共头文件统一生成，原生侧提供与 Qt 对接的封装层，因此不需要手写 P/Invoke 声明，也不需要维护大量重复的封装代码。

## 特性

- 覆盖 Qt 6 常用模块：Core、Gui、Widgets、Network、Multimedia、Svg、OpenGL 等
- 托管类型与 Qt 的类、枚举、信号槽语义保持一致，便于对照 Qt 文档使用
- 原生库随 NuGet 包按平台分发，目标项目引用即可
- 兼容 .NET 的裁剪与 Native AOT
- 绑定由生成器统一产出，跟 Qt 头文件的变化保持一致

## 平台支持

| 平台    | 架构                     |
| :------ | :----------------------- |
| Windows | x64、ARM64               |
| Linux   | x64、ARM64               |
| macOS   | x64（Intel）、ARM64      |

## 环境要求

- .NET SDK（版本以 `global.json` 为准）
- CMake 3.20 及以上
- C++20 编译器（MSVC / GCC / Clang）
- Qt 6 开发环境：Windows 与 macOS 由构建过程自动准备，Linux 使用发行版提供的 Qt 6

## 构建

```pwsh
dotnet tool restore
cmake --preset <平台预设>
cmake --build --preset <平台预设>-release
dotnet build --artifacts-path artifacts
```

可用的平台预设见 `CMakePresets.json`，当前为 `win-x64`、`win-arm64`、`linux-x64`、`linux-arm64`、`osx-x64`、`osx-arm64`。

## 状态

项目处于早期开发阶段，绑定的覆盖范围与 API 细节会随 Qt 版本和生成器的演进调整。

## 许可

以 MIT 许可证发布，详见 [LICENSE](LICENSE)。
