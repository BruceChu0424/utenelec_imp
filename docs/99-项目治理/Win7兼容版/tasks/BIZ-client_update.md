# 全部业务页面迁移 / client_update

由唯一进度登记表生成。

## W7-BIZ-215

- [ ] **客户端下载与更新 / client release publish** — 进行中

影响：`frontend+shared-contract`；负责人：Codex；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/client_update/client_release_publish_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、complete、confirm、copy、download、edit、post、reconcile、remove、restore、save（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/software-download-publish-20261028.json`；`clients/windows_legacy/progress/evidence/publish-workbench-20261030.json`；`clients/windows_legacy/progress/evidence/publish-workbench-ui-reopened-20261101.json`；`clients/windows_legacy/progress/evidence/client-publish-page-ui-20261101.json`。

接续/限制：原生发布工作台已完整迁移（非只读壳）：Core 队列状态机/流式上传 sink/wire PUT 放行/DPAPI 草稿 CAS/step-up 协调器+Desktop 页面/目标编辑器/草稿租约/step-up 密码弹窗/下载页入口。三条铁律与失败三分支 75+9 断言钉住；x86/x64 Debug runner 全绿且既有计数保持。未验：真实服务器发布链、Win7 真机 UAT、正式双包（见证据 notCovered）。；2026-11-01 复核失效并重开：当前main与9477的View Git内容SHA256均为d66815a19367c8633da87415b334ba585dbecbb8ccbafce0e32d7c23288299ed。真实View构造/Arrange三栈及无next包装的STA最小证明确认：原145编辑器字段重复托管、105/114页面重复托管、235把Double CardValue绑定CornerRadius，当前UI不可用。旧75协议断言和原证据保留，但未覆盖真实View构造/布局，不能继续标本机验证。next分支修复尚未合入main；Win7真机、真实server发布链及正式双包仍未验。本次仅回退状态，未导入next代码。；2026-11-01 客户端发布页整体UI重设计：Flutter/Web采用配置侧栏+文件队列/发布记录，窄屏纵排，顶部保留草稿入口；WPF现有发布页同步布局、紧凑字段及适用字段标签显隐。原发布/恢复/未知提交合同不变。80项Flutter回归、相关静态检查、Web Debug构建，以及x86/x64警告即失败编译与原生UI fixture通过。证据 clients/windows_legacy/progress/evidence/client-publish-page-ui-20261101.json；设计记录docs/99-项目治理/2026-11-01-客户端发布页面整体设计.md。独立分支uimp/client-publish-page-redesign-20261101；未合main、未部署、未正式打包、未上传。Win7真机与真实发布链仍未验，本项继续in_progress；历史源清单待整体同步。。

## W7-BIZ-039

- [ ] **客户端下载与更新 / client update** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/client_update/client_update_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、post、remove、stop、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/windows-update-page-20261102.json`。

接续/限制：尚未迁移；先做动作/合同审计。2026-11-02 Flutter Windows 更新页改为宽屏双栏，并补齐缓存损坏后重下、安装重试错误清除、并发交接互斥和详情页空闲倒计时。WPF 本页仍未迁移，后续须接入运行时隔离、保存工作与未知提交保护、下载/安装反馈及相同重试语义；保持 todo，不开放占位入口，不推定 Win7 已验收。见 E-WINDOWS-UPDATE-PAGE-20261102。。

## W7-BIZ-040

- [ ] **客户端下载与更新 / software downloads** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/client_update/software_downloads_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、download、post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。
