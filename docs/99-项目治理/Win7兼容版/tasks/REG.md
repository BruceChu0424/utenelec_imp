# 回归与质量门

由唯一进度登记表生成。

## W7-REG-001

- [ ] **原有Flutter客户端更新回归** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. 当前Win10路径、默认请求/双包/权限/切服/下载保全；新字段不改变旧行为。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-002

- [ ] **发布后端既有+新隔离回归** — 进行中

影响：`backend`；负责人：Codex；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. 当前源码完整clientupdates检查/服务/保留/流程测试，不用旧classes冒充。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-003

- [ ] **混合备份跨环境回归** — 进行中

影响：`backend`；负责人：Codex；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. Windows与POSIX覆盖区别、Java互锁缺口单独列出，不能把skip写pass。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-004

- [ ] **现有业务后端未改变证明** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. 业务计算/事务/权限不因client分发改动变化；必要契约增量同步各客户端样例。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-005

- [ ] **全页面视觉/交互与语言对照** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. 全部适用页和对话框/状态/品牌，不只登录截图；差异有结论。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-006

- [ ] **跨模块链回归及数据账核对** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. 按FLOW任务真实测试数据闭环，数量/金额/归属/回执可追溯。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-007

- [ ] **静态检查/构建/漂移全门** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. C#/Dart/Java/Python当前输入构建+分析，token/coverage/依赖/receipt均不过期。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-REG-008

- [ ] **错误/取消/重启/并发系统矩阵** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-GOV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj`；`test/features/client_update`。

完成条件：

1. 每种动作处理方式有样例与证据，未知写不盲重试，身份退役不串数据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
