# CPAClient

[English](README.md)

CPAClient 是一个 Flutter 桌面客户端，用于在本地管理并运行 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)。
应用以“设置页”为核心，覆盖核心程序的下载与更新、WebUI 快捷访问、以及 `config.yaml` 的 WebDAV 备份/还原流程。

## 目录

- [核心能力](#核心能力)
- [界面与交互](#界面与交互)
- [技术栈](#技术栈)
- [支持平台](#支持平台)
- [项目结构](#项目结构)
- [快速开始开发](#快速开始开发)
- [首次启动流程](#首次启动流程)
- [数据与配置存储](#数据与配置存储)
- [构建与发布](#构建与发布)
- [测试与代码检查](#测试与代码检查)
- [配置项说明](#配置项说明)
- [安全说明](#安全说明)
- [常见问题](#常见问题)
- [相关项目](#相关项目)

## 核心能力

- **一键准备核心环境**
  - 自动初始化 sandbox 目录与 `config.yaml`
  - 按当前系统/架构下载对应的 CLIProxyAPI Release 资产
  - 自动启动核心进程
- **核心版本管理**
  - 从 GitHub Release 获取最近版本并切换
  - 支持更新、重启、停止核心进程
- **WebUI 快捷访问**
  - 直接打开 `http://127.0.0.1:<port>/management.html#/login`
  - 快速打开 `config.yaml`、配置目录、sandbox 目录
- **WebDAV 同步**
  - 保存 WebDAV 地址与账号凭据
  - 测试连接
  - 备份 / 还原 `config.yaml`
  - 支持自动备份（按分钟间隔）
  - 可视化状态（未测试 / 进行中 / 成功 / 失败）
- **桌面集成**
  - 托盘菜单（WebUI / 设置 / 退出）
  - 开机启动开关
  - 主题切换（浅色 / 深色 / 跟随系统）

## 界面与交互

- 应用主界面为设置页，按功能分区组织：
  - Core（核心管理）
  - Security（令牌与密码）
  - Preferences（主题、开机启动等）
  - WebDAV（连接测试、备份与恢复）
  - About（版本信息等）
- 桌面窗口当前为固定尺寸（860 × 640），适合稳定的桌面运维场景。

## 技术栈

- Flutter（Material 3）
- 桌面能力：`tray_manager`、`window_manager`、`launch_at_startup`、`url_launcher`
- 网络与文件：`http`、`dio`、`archive`、`yaml`、`path_provider`
- 加解密相关：`cryptography`

## 支持平台

运行支持跟随 Flutter Desktop 与核心二进制资产格式。当前发布流程覆盖：

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
test/
  core/services/            # 服务层测试
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
  - **Linux**：`clang`、`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev` 及 appindicator 开发包

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
2. 如果核心二进制不存在，应用将按配置版本尝试下载。
3. 使用本地 `config.yaml` 启动核心进程。
4. 可从设置页或托盘直接打开 WebUI。

> 若 GitHub API 请求受限（例如 403），可在设置页填写 GitHub Token 以提高请求额度。

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
- 打包格式：Linux/macOS 为 `.tar.gz`，Windows 直接输出 `.exe`
- 自动上传到对应 GitHub Release

## 本地打包

可使用 Python 脚本在当前宿主系统打包：

```bash
python3 tool/package_local.py
```

可选参数：

- 构建版本：`--build-name`、`--build-number`
- 仅打包不构建：`--skip-build`
- 输出目录：`--output-dir`

macOS 本地签名：

- 指定签名证书：`--macos-sign-identity "Developer ID Application: ..."`
- 使用 ad-hoc 签名：`--macos-sign-identity "-"`
- 可选权限文件：`--macos-entitlements path/to/entitlements.plist`

默认输出到 `release/`，命名与 CI 保持一致：

- Linux：`linux_<arch>.tar.gz`
- macOS：`darwin_<arch>.tar.gz`
- Windows：`windows_<arch>.exe`

说明：本地打包为“本机打本机”（Windows 打 Windows，macOS 打 macOS，Linux 打 Linux）。

## 测试与代码检查

```bash
# 单元测试
flutter test

# 静态检查
flutter analyze
```

## 配置项说明

应用设置（`app_settings.json`）主要包括：

- `coreVersion`：核心版本
- `themeMode`：主题模式（`light` / `dark` / `system`）
- `keepGithubToken`：是否保留 GitHub Token
- `webdavAutoBackupEnabled`：是否启用自动备份
- `webdavAutoBackupIntervalMinutes`：自动备份间隔（分钟）
- `secrets`：敏感字段容器（如 GitHub Token、WebDAV 凭据、WebUI 密钥）

## 安全说明

- 请妥善保管 GitHub Token 与 WebDAV 凭据。
- `config.yaml` 可能包含敏感配置，不要泄露或提交本地运行副本。
- 非必要情况下建议仅本机访问管理接口（localhost）。
- 建议使用最小权限原则配置 Token 与 WebDAV 账号。

## 常见问题

- **拉取 release 出现 403**：请在设置页配置 GitHub Token。
- **核心更新失败**：查看 UI 提示中的日志路径（`sandbox/app.log`）。
- **WebDAV 备份/还原失败**：先检查地址与凭据，并先执行测试连接。
- **启动后无法打开 WebUI**：确认核心进程已运行，并检查 `config.yaml` 中端口配置。

## 相关项目

- CLIProxyAPI：https://github.com/router-for-me/CLIProxyAPI
- CPAClient：https://github.com/AriaLyy/CPAClient
