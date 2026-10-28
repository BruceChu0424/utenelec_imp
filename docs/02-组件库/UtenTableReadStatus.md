# UtenTableReadStatus

表格读取异常的公共显示入口为 `lib/components/data_display/uten_table_read_status.dart`。界面修改默认使用 `frontend-design`，沿用 Uten 主题、按钮、弹窗和触控目标，不为某个业务页面复制错误提示。

## 显示与交互合同

- 表内只放单行摘要、详情和可选重试，最大宽度 280；小于 200 的可用宽度改用带语义及短提示的图标。原始错误的长度、换行数不影响工具条高度。
- 悬停只显示简短操作说明。鼠标点击、触摸或键盘激活详情后，在可滚动的 `UtenAlertDialog` 中查看、选择和复制完整原因，同时显示影响范围和处理办法。
- 加载时禁用重试；详情内重试先关闭说明，再调用所属读取入口。组件不执行请求，不推断某个业务命令是否可重放。
- `ownerIdentity` 表达所属账号、服务器、表格及查询。所属对象、错误或加载状态变化时，旧详情立即失效并只关闭自身弹窗；同一对象的普通重建保留详情，并调用最新回调。不得保留跳转前的分页或分组重试动作。
- 组件使用中性表面与次级文字，沿用主题的交互色和焦点反馈；不把可恢复的读取失败铺成大块红色内容。输入校验、审批阻断和保存冲突继续遵守各自语义。
- `title`、`loadingTitle`、`impact`、`reason` 和 `guidance` 由拥有数据的调用方提供；通用动作默认支持中英韩。`retry == null` 时不显示伪重试操作。

## 接入位置

| 公共宿主 | 入口 / 保留差异 |
|---|---|
| `PlatformTableStatus` | 扩展列元数据、权限、记录与网络错误的本地化；转到 `PlatformTableController.retryRead`，保留完整快照、草稿和读取代次保护 |
| `MasterDataTableView` 首次读取失败 | 没有本次列表结果；只重试列表读取 |
| `MasterDataTableView` 后台刷新失败 | 保留上次成功结果，明确提示尚未更新；刷新进度仍使用原进度行 |
| `MasterDataTableView` 连续翻页失败 | 保留已加载页，重试失败方向的分页读取 |
| `MasterDataTableView` 分组读取失败 | 保留分组展开状态和已取得记录，查看完整原因并重试该组 |

`MasterDataTableView`、`UtenEditableGrid` 的扩展列提示均经同一个 `PlatformTableStatus`；详情、选择器、修订表和全屏复用各自公共宿主。原始附件、打印纸面、业务校验和保存冲突不并入表格读取重试。

验证入口：`test/shared/platform_tables/platform_table_status_test.dart`、`platform_table_recovery_test.dart`、`test/components/uten_table_read_status_lifecycle_test.dart`，以及列表刷新、连续分页和表格输入交互回归。自动恢复策略与本轮证据见 [表格读取异常恢复记录](../99-项目治理/表格读取异常恢复-20261028.md)。
