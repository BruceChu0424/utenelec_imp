# UtenClientPicker · 客户选择器

> 源码：[`uten_client_picker.dart`](../../lib/features/basic_data/widgets/uten_client_picker.dart) · 统一层级搜索契约：[UtenHierarchySearch](UtenHierarchySearch.md) · 最后核对：2026-08-16。

## 一、用途与入口

`showUtenClientPicker(context, ref)` 用于销售、钱流等单据表头选择客户，返回 `ClientListItem?`；取消返回 `null`。`UtenClientPickerField` 是表单字段包装，只提交客户 ID。

选择器取代旧的平铺客户字典：用户可以按分类浏览，也可以直接输入分类名称/编号或客户名称/编号等字段定位。客户列表与主档服务同源，继续受 `client:view` 及服务端客户 owner 可见范围约束；前端不复制权限过滤。

**二次操作契约（2026-08-16，全站滑窗统一）**：点客户行仅高亮勾选（行尾绿色对勾 + 底部确认栏显示「已选择：客户名（编号）」），必须再点底部「确定」才把选中客户返回给调用方并关闭面板；「取消」（或右上角关闭/点遮罩）= 放弃选择。底部确认栏是共享的 [UtenPickerConfirmBar](UtenPickerConfirmBar.md)。

## 二、响应式布局

- compact：`showUtenAdaptivePanel` 底部抽屉。
- medium/expanded：右侧滑入 720dp 面板。
- 面板内部始终为“左客户分类树 + 右客户分页列表”；左栏宽 compact 176dp、其余 240dp。
- 搜索框始终在左树顶部，不因抽屉/侧滑形态退化成右侧独立搜索。
- 底部固定 `UtenPickerConfirmBar` 确认栏（取消 / 确定；未选中时「确定」禁用）。

## 三、统一搜索

- 一个关键词同时匹配分类名称/编号，以及客户名称、编号、全称、联系人、手机等服务端 keyword 字段。
- 浏览与搜索都向主档接口传 `excludeLegacyFinanceStub=true`，由数据库在分页前排除 legacy 财务占位；搜索再按服务端分页完整汇总授权范围内的有效客户并按客户 ID 去重，因此不会出现占位吃掉整页、漏掉后续真实客户或显示错误页数。
- 内容命中默认定位首个有效分类，右侧展示跨分类结果；翻页复用已完成的客户与分类定位缓存，不用当前页覆盖整棵命中树。
- 点击包含命中客户的分类分支时，右侧改为“该分类子树 + 同一关键词”；只命中分类时，右侧展示该分类全部客户。
- 请求使用 300ms 防抖与 request version；加载、搜索失败、完整定位失败、无结果均有可见状态。清空框才完全退出搜索态。
- V272 候选之后，数据层的正常客户、官网询盘转客户与 legacy 财务占位都绑定真实、受保护的“未分类”系统根（本选择器仍按上文排除财务占位）；可见的未分类客户命中时应展开并选中该根，不再把“未分类”当成无节点结果。`categoryId` 为空或不在当前树只作为滚动升级/脏数据防御：不形成无效选中，右侧仍可展示服务端授权范围内的全局客户结果。

## 四、数据与权限

- 分类树：客户分类 repository。
- 浏览：`GET /api/master/clients?categoryId=&excludeLegacyFinanceStub=true&page=&size=`，`categoryId` 为子树范围。
- 搜索：`GET /api/master/clients?keyword=&excludeLegacyFinanceStub=true&page=&size=100`，逐页收集有效客户和定位信息，再在选择器内按 100 条分页。
- 权限：分类树与客户列表各自接受后端权限校验；客户列表仍执行 owner 可见范围，选择器不能放宽为全库。
- 旧财务占位客户（编号前缀 `LEGACY-FIN-CL-`）在列表和定位中都排除。
- **禁用客户（`status=禁用`）不进选择器**（2026-08-16）：单据不能再选禁用客户开新单。过滤在前端分类浏览与全局搜索两条路径同时生效（`_clientSelectable`）；已删除（软删）客户后端已过滤不下发。客户管理页不受影响，仍显示禁用客户供维护。

## 五、回归测试

[`uten_client_picker_test.dart`](../../test/features/basic_data/widgets/uten_client_picker_test.dart) 覆盖：宽屏单一搜索、分类名称搜索、跨分页分类完整展开、legacy 占位跨页过滤与页数重算、compact 形态无布局异常；2026-08-16 起两处选中用例按二次操作契约改为「点行高亮 → 点确定返回」。共享的分页取消、树外 ID 和分支保留规则由 `category_tree_search_test.dart` 覆盖。
