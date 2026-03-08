# CPAClient

[English](README.md)

CPAClient 是一个 Flutter 桌面客户端，用于本地管理并运行 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)。
它以“设置页”为中心，提供核心程序下载/更新、WebUI 快捷访问，以及 `config.yaml` 的 WebDAV 同步能力。

## 功能特性

- **一键准备核心环境**
  - 自动初始化 sandbox 目录和 `config.yaml`
  - 按当前系统/架构下载对应的 CLIProxyAPI Release 资产
  - 自动启动核心进程
- **核心管理（设置页）**
  - 从 GitHub Release 获取最近版本并切换
  - 更新/重启核心
  - 直接打开 WebUI（`http://127.0.0.1:<port>/management.html#/login`）
  - 快速打开 `config.yaml`、配置目录、sandbox 目录
- **安全访问设置**
  - 保存 GitHub Token（用于 Release API 与避免限流）
  - 保存 WebUI 密码（同步到 `remote-management.secret-key`）
- **WebDAV 同步**
  - 保存 WebDAV 地址与账号密码
  - 测试连接
  - 备份/还原 `config.yaml`
  - 可视化状态（未测试/进行中/成功/失败）
- **桌面集成**
  - 托盘菜单：WebUI / 设置 / 退出
  - 开机启动开关
  - 主题切换（浅色/深色/跟随系统）

## 技术栈

- Flutter（Material 3）
- 桌面插件：`tray_manager`、`window_manager`、`launch_at_startup`、`url_launcher`
- 网络与文件：`http`、`dio`、`archive`、`yaml`、`path_provider`

## 支持平台

运行支持跟随 Flutter Desktop 与核心二进制资产格式。
当前 release 工作流覆盖：

- Linux：`amd64`、`arm64`
- macOS：`amd64`、`arm64`
- Windows：`amd64`、`arm64`

## 项目结构

```text
lib/
  app/                      # 应用入口（主题 + MaterialApp）
  core/
    constants/              # 默认常量
    models/                 # 设置模型 / GitHub release 模型
    services/               # 启动、下载、进程、配置、路径、日志等服务
  features/
    settings/               # 设置页与控制器（主界面）
    tray/                   # 系统托盘能力
configs/
  config.yaml               # 内置默认配置模板
.github/workflows/
  release.yml               # 多平台桌面发布流水线
```

## 快速开始（开发）

### 1）环境要求

- Flutter SDK（CI 当前使用稳定版 `3.35.5`）
- Dart SDK（兼容 `sdk: ^3.6.2`）
- 各平台桌面构建工具链：
  - **Windows**：Visual Studio C++ Desktop workload
  - **macOS**：Xcode Command Line Tools
  - **Linux**：`clang`、`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev`，以及 appindicator 开发包

### 2）安装依赖

```bash
flutter pub get
```

### 3）运行桌面程序

```bash
flutter run -d windows
# 或
flutter run -d macos
# 或
flutter run -d linux
```

## 首次启动流程

1. 应用自动创建 sandbox 数据目录。
2. 若核心二进制不存在，会提示配置 GitHub Token，并下载核心发布包。
3. 使用本地 `config.yaml` 启动核心进程。
4. 可在设置页或托盘直接打开 WebUI。

## 数据与配置存储

CPAClient 通过 `path_provider` 将运行数据写入应用支持目录，主要包括：

- `sandbox/bin/`（核心程序）
- `sandbox/config/config.yaml`
- `sandbox/app_settings.json`
- `sandbox/app.log`

可在设置页通过快捷按钮直接打开这些路径。

## 构建与发布

Tag 发布流程定义在 `.github/workflows/release.yml`：

- 触发条件：push 标签匹配 `v*`
- 矩阵构建 Linux/macOS/Windows 的 amd64/arm64 产物
- 打包格式：Linux/macOS 为 `.tar.gz`，Windows 为 `.zip`
- 自动上传到对应 GitHub Release

## 安全说明

- 请妥善保管 GitHub Token 与 WebDAV 凭据。
- `config.yaml` 可能包含敏感配置，不要泄露或提交本地运行副本。
- 非必要情况下建议仅本机访问管理接口（localhost）。

## 常见问题

- **拉取 release 出现 403**：请在设置页配置 GitHub Token。
- **核心更新失败**：查看 UI 提示中的日志路径定位问题。
- **WebDAV 备份/还原失败**：先检查地址与凭据，并先执行测试连接。

## 相关项目

- CLIProxyAPI：https://github.com/router-for-me/CLIProxyAPI
- CPAClient：https://github.com/AriaLyy/CPAClient
