# UtenHierarchySearch · 层级树与内容统一关联搜索

> 适用范围：页面或选择器同时包含“左侧分类/部门树 + 右侧具体内容”时，一个搜索入口必须同时查层级节点和具体内容，并把内容命中反向定位到树路径。
>
> 源码所有者：[`category_tree_search.dart`](../../lib/features/basic_data/widgets/category_tree_search.dart)、[`uten_category_tree_view.dart`](../../lib/features/basic_data/widgets/uten_category_tree_view.dart)、[`uten_department_tree_view.dart`](../../lib/features/department/widgets/uten_department_tree_view.dart)。最后核对：2026-08-14。

---

## 一、统一交互契约

1. **一个搜索框**：放在左树顶部；同时匹配层级名称/编号和右侧具体内容的业务搜索字段。不得再让用户猜“左框只搜分类、右框才搜内容”。
2. **完整定位集合**：内容命中必须收集全部结果页的 `categoryId` / `departmentId`，或调用只返回去重分类 ID 的轻量定位端点；不能只用当前 50/100 条推断分类。
3. **授权树内失败关闭**：服务端定位与右侧列表使用同一权限、scope 和状态口径；客户端仍丢弃空 ID、已删除节点和当前树之外的 ID。
4. **展开与选中**：合并“层级自身命中 + 内容所属节点”，补齐全部祖先路径并自动展开；默认选中首个有效的内容命中节点，若没有内容命中则选中最浅的层级命中。
5. **右侧语义**：
   - 命中具体内容：右侧使用同一关键词，并按当前选中分类/部门子树展示匹配内容。
   - 只命中层级名称/编号：右侧展示该层级的全部内容，不能把层级词误当成内容关键词。
   - 客户、模具、供应商在 V272 候选之后把未分类主档绑定到真实、受保护的系统根；命中时必须像普通分类一样补祖先、展开并选中该根。
   - 只有尚未建立真实节点的数据域，或滚动升级/脏数据仍返回空 ID、树外 ID 且右侧支持全局查询时，树才可以没有可展开节点，右侧保留同一授权范围内的全局关键词结果；不得伪造无效选中。
6. **搜索态导航**：点击包含内容命中的另一条相关分支时保留关键词；点击无关分支进入普通浏览。清空搜索框后恢复完整树并退出搜索态。
7. **异步状态完整**：300ms 防抖；输入一变化即让旧请求失效；加载、失败、无结果都在树附近显式反馈，错误使用可访问 live region，禁止静默吞错或让旧响应覆盖新关键词。
8. **响应式不降级**：expanded 在固定左栏内显示统一搜索；compact/medium 的树进入抽屉或自适应面板时，仍必须提供同一搜索入口、相同字段与相同状态语义。

---

## 二、共享实现

| 能力 | 实现 |
|---|---|
| 层级名称/编号匹配 | `categoryHits`，统一 `trim + lower`，命中节点包含祖先；层级自身命中时保留其子树 |
| 内容分类解析 | `resolveHierarchySearch`，过滤树外/空 ID、补祖先、选择首个有效内容分类 |
| 完整分页定位 | `collectPagedHierarchyCategoryIds`，复用首屏、逐页收集、每页前后检查请求代次 |
| 搜索态点树分支 | `hierarchyBranchContainsAny`，判断该分支是否包含内容命中并决定是否保留关键词 |
| 分类树受控状态 | `visibleFilterIds + externalSearchQuery + externalSearchLoading + externalSearchError` |
| 部门树受控状态 | 与分类树同名参数；内部纯节点搜索也匹配部门名称/编号且忽略大小写 |

树组件只负责渲染受控状态，不调用业务 API。页面/选择器负责选择正确的数据源、权限与业务字段；不得把货品、客户或员工仓库直接塞入共享树组件。

---

## 三、已接入场景与搜索口径

| 场景 | 层级字段 | 内容字段与定位方式 | 右侧结果 |
|---|---|---|---|
| 货品资料 `/basicinfo/goods` | 分类名称/编号 | 货品名称、编号、型号、规格、系列、客户型号、材质、备注；`GET /api/master/goods/search-category-ids` | 当前分类子树 + 同一关键词；搜索态包含禁用品、排除历史 stub |
| 模具资料 `/basicinfo/mould` | 分类名称/编号 | 模具名称、编号、存放位置、备注；分页完整收集 `categoryId` | 当前分类子树 + 同一关键词；V272 未分类模具定位真实系统根 |
| 客户资料 `/basicinfo/client` | 分类名称/编号 | 客户名称、编号、全称、联系人、手机；分页完整收集 `categoryId` | 当前分类子树 + 同一关键词；V272 未分类客户定位真实系统根，仍受客户 owner 可见范围约束 |
| 供应商资料 `/basicinfo/supplier` | 分类名称/编号 | 供应商编号、名称、描述、联系人、法人、地区、手机；分页完整收集 `categoryId` | 当前分类子树 + 同一关键词；V272 未分类供应商定位真实系统根 |
| 即时库存 `/stock/instant-inventory` | 货品分类名称/编号 | 货品名称、编号、型号、客户型号；`GET /api/stock/instant-inventory/search-category-ids` | 当前分类子树或未分类全局结果 + 同一关键词；定位与右表都只排除软删除货品 |
| 部门管理 `/department` | 部门名称/编号 | 员工姓名、工号（员工接口还支持车牌）；分页完整收集 `departmentId` | 当前部门子树 + 同一员工关键词 |
| 我的部门 `/profile/me/department` | 授权分支内部门名称/编号 | 安全花名册姓名、工号；只读取分支根花名册一次并本地定位 | 当前部门子树 + 同一员工关键词；绝不调用全员员工接口 |
| 应收应付总览 `/finance/report/overview` | 客户/供应商分类名称、编号 | 往来单位名称、编号；分页读取 `GET /api/finance/reports/ar-ap/party-locations` | `categoryType/categoryId + keyword` 组合查询；V272 正常未分类往来单位定位真实系统根，空/树外 ID 仅作公司级防御回退 |
| `UtenGoodsPicker` | 当前 scope 内分类名称/编号 | scope 内货品字段；受限分页 + 轻量分类 ID 定位 | 跨可见分类的当前结果页；点击相关分支后按该子树 + 同词过滤 |
| `UtenClientPicker` | 客户分类名称/编号 | 客户字段；分页完整收集 `categoryId` | 跨分类当前结果页，或相关分类子树 + 同词过滤 |
| `DepartmentEmployeePicker` | 部门名称/编号 | 员工姓名/工号；分页完整定位 | 跨部门分页结果，或相关部门子树 + 同词过滤 |

货品定位端点每次最多接受 32 个 `categoryRootIds`；页面根数超过上限时按 32 个一组取并集。无效根必须零命中，不能退化成全库。`UtenGoodsPicker` 还会校验右侧每条结果的 `categoryId` 属于当前可见树，避免旧服务端忽略 scope 时越界展示。

---

## 四、权限与数据范围

- 货品定位要求 `goods:view`；`GoodsService` 的 owner 隔离仅在 `UTEN_GOODS_OWNER_SCOPE_ENABLED=true` 时启用，默认关闭。货品资料页仅排除 stub，选择器同时排除禁用和 stub；货品/库存分类树还分别需要页面组合中的 `material_category:view`。
- 模具、客户、供应商资料沿用各自主档查看权限；客户结果继续受 owner 可见范围约束。
- 即时库存定位与右表都要求 `stock:view`，并共享“仅排除 `is_deleted`”口径。
- 部门管理的树/员工列表分别使用 `department:view`、`employee:view`；没有 `employee:view` 时统一框只搜部门节点，不发员工请求。员工选择器专用最小树 `GET /api/org/departments/employee-picker-tree` 只要求 `employee:view`，仅返回定位字段，不扩大部门管理权限。
- “我的部门”只使用 `/api/my-department/tree` 与 `/api/my-department/roster`，服务端限制在本人所在大部门分支，并只返回安全花名册字段。
- 应收应付分类定位要求 `finance_report:view`，服务层与公司级总览一致继续要求 `finance:view:all`；不能借用受客户 owner 范围裁剪的主档搜索。

---

## 五、明确不适用的页面

- 收付款类别：纯类别目录 + 类别属性检查器，没有“分类下具体主档列表”。
- 分类/部门编辑弹窗、`UtenDepartmentPicker`：只选择层级节点，名称/编号节点搜索即可。
- 权限管理：左侧是账号结果列表、右侧是单账号详情，不存在分类反向定位；未保存权限还要求独立离开保护。

不能因为页面也有左右栏，就机械套用本契约。判定标准是“左侧为层级树，右侧为归属于该层级的具体内容”。

---

## 六、回归验收

- 用层级名称、层级编号、内容名称、内容编号分别搜索；英文编号大小写混输。
- 构造同词命中多个深层分类且超过一页内容，确认全部祖先路径可见，翻右侧页不丢已定位分类。
- 搜索后点击第一、第二个相关分支，再点击无关分支与清空框，核对右侧关键词语义。
- 人为延迟旧请求，确认新关键词结果不被覆盖；模拟定位接口失败，确认错误可见且右侧不偷偷切全量。
- 分别验证 expanded 与 compact/medium；树空、无结果、未分类内容、树外 ID、禁用/stub 与权限不足。

当前自动化入口包括：`category_tree_search_test.dart`、`uten_category_tree_view_test.dart`、`uten_department_tree_view_test.dart`、`uten_goods_picker_test.dart`、`uten_client_picker_test.dart`、`department_employee_picker_test.dart`、`my_department_page_search_test.dart`、`finance_ar_ap_overview_search_test.dart`，以及服务端 Goods/Stock/Finance/Department/MyDepartment/Supplier 聚焦合同测试。

本文记录的是当前工作树源码候选，不代表已提交、已部署到目标服务器或已完成真实岗位 UAT。
