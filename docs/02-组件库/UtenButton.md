# UtenButton 与统一控件尺度

源码：[UtenButton](../../lib/components/buttons/uten_button.dart)、[控件尺度](../../lib/core/theme/uten_tokens.dart)、[原生主题适配](../../lib/core/theme/uten_control_theme.dart)。

默认桌面普通按钮40、主要操作48、紧凑顶栏36；触屏在窗口逻辑坐标中至少48×48。应用缩小档通过同一尺度保底；应用放大由根部整体变换处理，按钮不再次乘应用倍率。系统文字放大时内容和图标随实际文字策略增长，最小高度允许内容撑高。

文字小/标准14、主要16，圆角 `UtenRadius.control`（10）。同组同用途保持高度一致，宽度随内容；窄宽长标签可换行，禁止用缩字维持固定高。primary/secondary/ghost/tonal/danger/success复用同一交互内核与语义颜色。

`UtenActionButton`仅负责ClickGuard的异步防重入、忙态与解锁，视觉委托UtenButton；`UtenImportButton`也委托同一内核，不再保留独立padding/fixedSize/色板。导出、草稿、顶栏按钮保持原权限、身份和业务回调。

原生Material按钮在根部经UtenControlTheme接收同一个宽高目标和密度，不能只给触控高度保底却漏掉短标签宽度。表格内联动作桌面按单行文字显示、触屏扩为48目标；它不是普通办公工具栏按钮。

回归：[点击与键盘](../../test/components/uten_button_test.dart)、[异步防重入](../../test/components/click_guard_test.dart)、[倍率与命中](../../test/components/uten_display_geometry_test.dart)。
