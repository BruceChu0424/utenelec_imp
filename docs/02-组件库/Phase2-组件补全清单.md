# Phase 2+ 组件补全清单（设计系统补全）

> 本档汇总 Phase 2-4 页面设计过程中**新触发**的组件需求，是设计系统补全（Task 4）的施工图。
> 现有组件总览见 [组件总览](组件总览.md)，使用规范见 [09-组件库使用规范](../00-项目准则/09-组件库使用规范.md)。

---

## 一、品牌色阶正式校准

> ⚠️ 当前 `lib/core/theme/uten_colors.dart` 的 50–900 色阶是**占位值**（见 [08-主题与配色 §2.2](../00-项目准则/08-主题与配色.md)），需用 Material Theme Builder 正式导出。

### 校准步骤
1. 打开 [Material Theme Builder](https://m3.material.io/theme-builder)
2. 输入主色 `#0F3D2E`（UtenGreen）+ 强调 `#14B8A6`（UtenTeal）
3. 导出 **light + dark** 两套 ColorScheme（Dart 代码）
4. 用导出值替换 `uten_colors.dart` 的 `green50–900` / `teal50–900`
5. 同步更新 `light_theme.dart` / `dark_theme.dart` 的 ColorScheme
6. 多设备（含低端 LCD）验证色彩还原，对比度复测 WCAG AA

### 验收
- [ ] green/teal 色阶来自 Theme Builder，非手填
- [ ] 浅色/深色模式对比度全部达标（见 08 文档 §7）
- [ ] 主题预览页切换前后无违和

---

## 二、待新建组件清单（19 个）

> 按"页面用到前必须先实现"的原则排期。每个组件实现前先写文档（`02-组件库/UtenXxx.md`，按模板）。

### 输入类

| 组件 | 用途 | 关键 API | 用在 | Phase |
|---|---|---|---|---|
| `UtenDropdown` | 下拉选择（单选/多选/可搜索） | `items / value / onChanged / multiple / searchable` | 员工编辑、通知发布、检测上传、产量录入 | 2 |
| `UtenDatePicker` | 日期/日期范围选择 | `value / firstDate / lastDate / mode(date/range)` | 员工编辑、入职、合同、检测、报表筛选 | 2 |
| `UtenSwitch` | 开关 | `value / onChanged` | 通知置顶、用工性质、空调定时 | 2 |
| `UtenSlider` | 滑块（空调温度） | `value / min / max / divisions / onChanged` | 空调控制 | 4 |
| `UtenIconButton` | 图标按钮（带 tooltip） | `icon / onPressed / tooltip` | 各页操作菜单 | 2 |

### 反馈类

| 组件 | 用途 | 关键 API | 用在 | Phase |
|---|---|---|---|---|
| `UtenConfirmDialog` | 确认对话框 | `title / content / confirmLabel / danger / onConfirm` | 删除/发布/审批/批量操作 | 2 |
| `UtenLoading` | 加载指示器（菊花/点） | `type / size` | 各页 loading | 2 |

### 数据展示类

| 组件 | 用途 | 关键 API | 用在 | Phase |
|---|---|---|---|---|
| `UtenDataTable` | 响应式表格（桌面表格/窄屏卡片） | `columns / rows / sortable / selectable / onSort / paging` | 员工列表、审批、工资条、报表、产量、库存 | 2 |
| `UtenTimeline` | 时间线（审批轨迹/任职记录/指令历史） | `items(node/status/actor/comment/at) / pendingIndex` | 审批详情、员工详情、空调控制 | 2 |
| `UtenTag` | 标签/Chip | `label / color / size` | 类别、工种 | 2 |
| `UtenAvatar` | 头像（图片/文字 fallback） | `image / name / size` | 员工卡、发布人、审批人 | 2 |
| `UtenTreeView` | 树形（部门树） | `nodes / onSelect / draggable / onReorder` | 部门管理 | 2 |
| `UtenChartPlaceholder` | 图表占位（Phase 5 换真库） | `type / data` | 报表、产量统计 | 4→5 |

### 布局类

| 组件 | 用途 | 用在 | Phase |
|---|---|---|---|
| `UtenMasterDetail` | 列表-详情分栏 | 员工档案、审批、审核 | 2 |
| `UtenTwoPaneLayout` | 通用双栏（左树右表） | 部门管理 | 2 |
| `UtenContentWidth` | 最大宽度居中 | 详情/表单页 | 2 |
| `UtenWizard` | 多步骤向导 | 入职、离职、工资条生成 | 2 |
| `UtenForm` | 分组表单容器 | 员工编辑、通知发布、检测上传 | 2 |

### 导航类

| 组件 | 用途 | 用在 | Phase |
|---|---|---|---|
| `UtenViewContextSelector` | 视角选择器（全局机制） | 所有跟随页 AppBar | 2 |

> 所有组件必须遵守 [09-组件库使用规范](../00-项目准则/09-组件库使用规范.md)：取色走 colorScheme、字号走 textTheme、文案走 i18n、处理响应式三档 + 性能档三档。

---

## 三、组件文档补全（现有已实现组件缺文档）

> 当前 `02-组件库/` 仅 3 份详细文档（总览 + UtenBottomActionBar + UtenSectionHeader）。以下已实现组件需补文档（按模板）：

`UtenButton` / `UtenCard` / `UtenStatCard` / `UtenListItem` / `UtenInput` / `UtenSearchBar` / `UtenSegmentedFilter` / `UtenInfoRow` / `UtenStatusBadge` / `UtenAnimatedNumber` / `UtenEmpty` / `UtenSkeleton` / `UtenToast` / `UtenAppBar` / `UtenResponsiveGrid` / `UtenFontScaler` / `UtenLocaleSwitcher` / `UtenThemeSwitcher` / `UtenPerformanceSwitcher`

---

## 四、实现优先级（按页面依赖）

1. **Phase 2 先行批**（员工/部门页要用）：`UtenForm`、`UtenDropdown`、`UtenDatePicker`、`UtenSwitch`、`UtenDataTable`、`UtenMasterDetail`、`UtenTreeView`、`UtenWizard`、`UtenConfirmDialog`、`UtenIconButton`、`UtenAvatar`、`UtenTag`、`UtenTimeline`、`UtenViewContextSelector`
2. **Phase 3 批**：`UtenChartPlaceholder`（报表先用占位）
3. **Phase 4 批**：`UtenSlider`（空调）、`UtenTwoPaneLayout`
4. **Phase 5 批**：正式图表库（替换 `UtenChartPlaceholder`，见 [技术选型 §9](../01-规划/技术选型.md)）

---

## 五、推进纪律

- 每个组件：**先文档 → 评审 → 实现 → barrel 导出 → 总览登记 → 示例 → 测试**（见 [09 规范 §6](../00-项目准则/09-组件库使用规范.md)）
- 色阶校准与组件实现**解耦**，可并行
- 新组件一律 `Uten` 前缀，文件 `uten_<name>.dart`

---

**最后更新**：2026-07-22 · **状态**：补全清单定稿，待按优先级实现
