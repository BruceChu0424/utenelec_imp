# 本机更新与恢复

由唯一进度登记表生成。

## W7-UPD-001

- [ ] **legacy更新元数据检查** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 家族/当前进程arch/build/mode/显式PUBLISHED和SHA/size严格，不接Flutter包。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-UPD-002

- [ ] **有界包下载和取消保旧** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 复用CORE-017，不在RAM整包、错误不破坏旧final，令牌不跟随外链。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-UPD-003

- [ ] **指令目录/父进程/ready握手** — 本机验证/待本项最终验收

影响：`delivery`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 私有GUID job，schema/PID/starttime/exe锚定，完整预检后ready才正常退出。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：真helper Execute已在隔离KnownFolder中按两arch实际核parent原生handle/PID/start/image/ready/正常exit，22矩阵含错身份和超时；不冒称现场Win7。。

## W7-UPD-004

- [ ] **ZIP/manifest/PE完整预检** — 本机验证/待本项最终验收

影响：`delivery`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 固定6文件、显式update/family/arch、SHA/size/version、路径/ADS/大小写/zipbomb、拒降级。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`。

接续/限制：单一package-contract及BC锁，三方六文件/显式update/EOCD分配前边界/PECLR/Company/版本校验统一；同producer两架构native9+Java贯通，整体Updater203。无生产Execute/Win7验收。。

## W7-UPD-005

- [ ] **更新单写锁与并发外改** — 本机验证/待本项最终验收

影响：`delivery`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 排他句柄/锁，失败不覆盖并发更改，不允许两个helper同时写同一安装。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：两不同job同appRoot的真helper互斥/旧target lease/源lease拒绝均实测，203组件及22真实进程矩阵。。

## W7-UPD-006

- [ ] **备份/日志/回滚可恢复** — 本机验证/待本项最终验收

影响：`delivery`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 逐批准文件备份、故障恢复/未知状态证据；不宣称断电事务，不盲目重启半更新。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：真实失败回滚、backup原字节+recovery manifest/hash、journal/result已验证保留；不保证跨文件掉电事务，强退自动恢复入口仍待。。

## W7-UPD-007

- [ ] **取消/窗口关闭不误应用** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 任何UI取消/账号变化/超时写cancel协议，helper不能等父稍后关闭就继续偷偷安装。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/03-安装更新与双架构验证交接.md`；`clients/windows_legacy/progress/evidence/native-checkpoint-20261028.json`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：取消/无授权/错误SHA授权/父17退出/超时等真Execute矩阵均在两arch按预期拒绝应用，当前主runner203通过；Win7目标机另验。。

## W7-UPD-008

- [ ] **整体bootstrap/测试接入** — 本机验证/待本项最终验收

影响：`delivery`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. RootTests真正引用Updater并执行；build脚本部署helper；与同一个producer ZIP集成核验。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/04-当前接手记录.md`；`clients/windows_legacy/progress/evidence/native-checkpoint-20261028.json`；`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`。

接续/限制：主runner含Updater203和真实Core/下载/Units/UI双arch通过，实际构建helper并PE匹配，同producer临时包预检/ApplyForChecks/Java成功。真实Setup安装/父进程握手/Execute仍待。。

## W7-UPD-009

- [ ] **重启后版本/profile核对** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 成功重启锚定main，版本和六文件一致、凭据/草稿保全，失败显示真实恢复路径。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/biz037-flow001-upd009-20261030.json`。

接续/限制：启动result消费已实现：UpdateOutcomeReader按GUID任务目录读最新未消费result.json(16KiB界限/scheme/family/arch校验，不可读按事实呈现)，apply-authorized无result判中断并按recovery-manifest升级警示；登录前UpdateOutcomeWindow展示一次并写result-consumed.json，绝不删恢复资料；成功锚定当前构建号。update outcomes 13双架构绿；真机掉电/断点恢复仍待。。

## W7-UPD-010

- [ ] **Win7 x86/x64真实更新矩阵** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-CORE-017, W7-INS-004。

源入口：`clients/windows_legacy/Uten.Legacy.Updater/UpdateExecutor.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Updates/ClientUpdateCoordinator.cs`。

完成条件：

1. 正常、取消、坏包、权限不足、磁盘/断电/进程占用、外改和回滚分别目标机验收。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
