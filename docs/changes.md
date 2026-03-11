# CPAClient 变更说明

## 本次更新

### 1) WebDAV 默认地址
- 默认地址改为：`https://dav.jianguoyun.com/dav`
- 仍保留保存时自动追加 `/CpaClient` 的规则。

### 2) 包名修改
- Linux `APPLICATION_ID`：`com.zozo1010.cpa`
- macOS `PRODUCT_BUNDLE_IDENTIFIER`：`com.zozo1010.cpa`
- macOS RunnerTests bundle id：`com.zozo1010.cpa.RunnerTests`
- Windows CompanyName/Copyright 同步为 `com.zozo1010`

### 3) 应用图标
- 重新生成了桌面端图标资源：
  - `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png`
  - `windows/runner/resources/app_icon.ico`

### 4) 设置页调整
- 移除底部“初始化完成”文案显示。
- 新增主题模式设置，支持：
  - 日间（Light）
  - 夜间（Dark）
  - 随系统（System）
- 主题模式会持久化到本地配置（`themeMode` 字段）。

### 5) 本地打包增强
- 新增统一的 Python3 本地打包脚本：
  - `tool/package_local.py`（跨平台）
- macOS 本地打包支持可选签名能力：
  - `--macos-sign-identity`（支持证书签名与 ad-hoc 签名）
  - `--macos-entitlements`（可选 entitlements 文件）

### 6) WebDAV usage 多端同步与手动全量备份解耦
- 自动 usage 同步改为独立链路，仅处理 `usage.json`，不再与手动全量备份还原耦合。
- 远端目录拆分：
  - 手动全量：`backups/<versionId>/backup.7z`
  - usage 自动同步：`sync/<versionId>/usage.7z`
- usage 自动同步每分钟检查一次本地/远端变化，按确定性规则执行 upload/download/noop。
- 冲突规则：本地与远端同时变化时，按“较新时间戳胜出；相等时 upload”。

### 7) usage 同步稳定性与限流保护
- 新增 usage 同步元数据文件（sandbox config 目录）：记录本地 hash、mtime、远端版本和最近上传时间。
- 自动上传节奏调整为：本地 1 分钟检查缓存，远端上传最短间隔 3 分钟。
- 启动应用或核心重启后 20 秒内，禁止同步、备份、还原操作。
- WebDAV 限流退避策略升级：命中 `BlockedTemporarily` 后按 10 → 20 → 30 分钟退避，成功后自动恢复默认频率。

### 8) WebDAV usage 版本保留策略
- `sync` 目录最多保留最近 100 份 usage 版本，超出自动清理旧版本。
- 清理失败不会影响当前备份成功结果。

### 9) 字体策略与中国区镜像
- 恢复 Google Fonts 运行时方案，并支持中国区镜像源。
- 启用 `auto` 时根据系统 locale 自动判断是否使用中国镜像。
- Windows 端保留 `Microsoft YaHei/微软雅黑` 回退链，镜像或下载异常时仍可稳定显示。
- 启动日志输出最终字体源选择（runtime/mode/locale/css/asset）。

### 10) 设置页异常兜底
- 针对备份/还原等操作增加统一异常捕获，网络异常时以 Snackbar 提示，避免页面崩溃。

### 11) 质量验证
- `flutter analyze`：通过
- `flutter test test/core/services/webdav_service_test.dart`：通过
- `flutter test test/features/settings/usage_sync_decision_test.dart`：通过
