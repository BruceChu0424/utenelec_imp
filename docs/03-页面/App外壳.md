# App 外壳（导航容器）

> 路由：`/` (ShellRoute) · 实现源：`lib/features/shell/pages/main_shell_page.dart` + `lib/features/shell/widgets/floating_capsule_nav_bar.dart`
> 最近重构：2026-07-23（UI v4 · 取消侧边栏，全断点统一悬浮胶囊导航）

## 一、定位

登录后所有员工端页面的容器。负责：四大主 Tab 的承载与切换、全局导航入口、未读通知角标。

- UI v4 变化：**取消** v3 的三档外壳（compact 底栏 / medium 折叠 Rail / expanded 左侧分组侧栏），改为**全断点统一**的底部悬浮胶囊导航；原侧边栏的角色分组功能入口全部迁入 [工作台首页](工作台首页.md) 的功能模块区。

## 二、结构

```
┌──────────────────────────────────────────────┐
│                                              │
│   内容区（全屏宽、全高）                        │
│   · 主 Tab 路由 → 内部 PageView（4 页保活）     │
│   · 业务子路由 → ShellRoute child              │
│   （业务页底部自动预留胶囊高度，防遮挡底栏按钮）    │
│                                              │
│        ╭─────────────────────────╮           │
│        │ 工作台  通知•  我的  设置  │ ← 悬浮胶囊  │
│        ╰─────────────────────────╯   overlay  │
└──────────────────────────────────────────────┘
```

### 悬浮胶囊导航（FloatingCapsuleNavBar）

- 交互参考 JustPlay 同款：高 56 / 圆角 28，半透明玻璃底色（浅 `white 0.85` / 深 `#1C2523 0.78`）+ 主色淡投影 + 1px 描边。
- **整体滑块跟手高亮**：滑块横向位置 = 连续位置 × 单格宽，手指拖多少走多少；文字颜色/字重按与当前位置的距离实时插值。
- **宽度自适应**：按最长 label 用 `TextPainter` 计算单格宽（64–96 clamp），**携带 `MediaQuery.textScaler`**——全局字号档（小/中/大/超大）调大时胶囊同步变长；外壳宽度 = 内容区 + padding(12) + 描边(2)，防溢出；极端小屏 + 超大字号时 label 由 `FittedBox` 等比缩小兜底。
- 通知项未读红点（`unreadNoticeCountProvider`，>0 显示）。
- overlay 悬浮（`Stack` + `Positioned`），**不占布局空间**；`resizeToAvoidBottomInset: false`，键盘弹起不顶胶囊。

### 四页 PageView（跟手滑动）

- 四个主 Tab（工作台 / 通知 `/notice` / 我的 / 设置）由外壳内部 `PageView` 承载，支持左右跟手滑动；`PageController.page` 连续位置喂给胶囊滑块。
- 四页 `AutomaticKeepAlive` 保活：滑过的页常驻，滚动位置/页面状态不丢。
- **路由双向同步**：滑动停稳 → `context.go(tab 路由)` 更新 URL；深链/点胶囊/权限重定向进入 tab 路由 → `animateToPage` 切到对应页。
- 主 Tab 页自带底部留白 ~96px，滚动到底内容可越过胶囊。

### 业务子页面

- 其余路由（工资条/报销/人事…）照常渲染 ShellRoute child，胶囊停留在归属 Tab（前缀匹配，如 `/notice/123` → 通知）。
- 业务页底部预留「胶囊高 + 系统手势条」高度：部分页面自带 `bottomNavigationBar`（提交/审批按钮），预留后永不被胶囊遮挡。

## 三、涉及的 Uten 组件 / 机制

- `FloatingCapsuleNavBar`（外壳私有组件）
- `UtenAnim`（切页动画时长/曲线 token）
- `unreadNoticeCountProvider`（通知未读数）
- go_router `ShellRoute` + `permission_by_path` 路由守卫

## 四、功能链路图

```mermaid
flowchart LR
    Swipe[左右滑动] -->|停稳 onPageChanged| Go[context.go 同步 URL]
    Tap[点胶囊项] --> Go2[context.go] --> Anim[animateToPage]
    Deep[深链 /notice] --> Anim
    Guard[路由守卫拒绝] -->|redirect| Dash[/dashboard]
```

## 五、权限要求

- 四个主 Tab 全员可见；业务子页面的显隐与准入由工作台模块区 + 路由守卫按权限点控制（见 [全局机制.md §一](../05-架构/全局机制.md)）。

## 六、边界情况

- 滑动中途被系统手势/来电打断：`PageView` 原生吸附回最近页，位置不会悬挂。
- 屏幕旋转/窗口拉宽：胶囊宽度按当前屏宽与 textScaler 重算，不溢出。
- 桌面端（鼠标无法拖拽 PageView）：点胶囊切换，动画与移动端一致。
