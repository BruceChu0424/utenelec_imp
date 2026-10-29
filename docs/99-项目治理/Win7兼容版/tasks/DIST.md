# 后端与各端Windows分发

由唯一进度登记表生成。

## W7-DIST-001

- [ ] **runtimeFamily模型向后兼容** — 源码已实现/待整合验证

影响：`backend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 旧缺/null默认flutter，新legacy仅合法platform/arch；旧构造/旧API不破。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-DIST-002

- [ ] **版本推荐和查询隔离** — 源码已实现/待整合验证

影响：`backend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. defaultFlutter不变；legacy显式query，严格family/arch/build，下载拒错family。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-DIST-003

- [ ] **上传包模式与结构检查** — 源码已实现/待整合验证

影响：`backend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. WPF独立setup/archive、PE/CLR/六文件/版本/ReleaseCompany；不执行上传程序集。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-DIST-004

- [ ] **幂等/构建号/发布完整组** — 源码已实现/待整合验证

影响：`backend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 按platform+family+arch隔离草稿意图、单调和双包配对，不跨版本误匹配。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-DIST-005

- [ ] **清理/撤回/保旧边界** — 源码已实现/待整合验证

影响：`backend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 仅新完整组成功后清本组旧二进制；失败保旧，不能清Win10/其他架构/业务数据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-DIST-006

- [ ] **Flutter Windows下载/发布适配** — 源码已实现/待整合验证

影响：`frontend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 版本+架构圆角控件、真实已发布包、无包无按钮，普通自动更新字段/行为保持。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-DIST-007

- [ ] **WPF Windows下载/更新适配** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 和Flutter共用新契约，真实保存/核验及helper而非链接回Web；状态和权限正确。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-DIST-008

- [ ] **权限/错误/多运行时端到端** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 真实接口层、权限/角色、错误/取消、下载两链路、publisher再认证、无跨源/跨family。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-DIST-009

- [ ] **现网部署及兼容回滚门** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-GOV-006。

源入口：`server/src/main/java/com/uten/imp/features/clientupdates/ClientReleaseService.java`；`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 新service+backup helper成组；旧JAR不能对混合catalog发布/清理；当前不得擅自部署。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
