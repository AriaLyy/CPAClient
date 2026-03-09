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

### 6) 质量验证
- `flutter analyze`：通过
- `flutter test`：通过
