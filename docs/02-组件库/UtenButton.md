# UtenButton 与统一控件尺度

源码：[UtenButton](../../lib/components/buttons/uten_button.dart)、[控件尺度](../../lib/core/theme/uten_tokens.dart)、[原生主题适配](../../lib/core/theme/uten_control_theme.dart)。

默认桌面普通按钮40、主要操作48、紧凑顶栏36；触屏在窗口逻辑坐标中至少48×48。应用缩小档通过同一尺度保底；应用放大由根部整体变换处理，按钮不再次乘应用倍率。系统文字放大时内容和图标随实际文字策略增长，最小高度允许内容撑高。

文字小/标准14、主要16，圆角 `UtenRadius.control`（10）。同组同用途保持高度一致，宽度随内容；窄宽长标签可换行，禁止用缩字维持固定高。primary/secondary/ghost/tonal/danger/success复用同一交互内核与语义颜色。

界面与交互改动默认使用 `frontend-design`，沿用 Uten tokens。内容按实际宽度、图标实测尺寸和标签最小自然宽度选择横排或纵排：能容纳时文字在图标右侧的剩余空间换行，不额外增加一整行图标；确实容不下时才纵排。装饰图标和忙态进度受实际宽度限制，文字字号、完整文案和按钮语义保持。布局支持 intrinsic/dry layout，对话框的固有尺寸测量与正常布局使用同一套约束。悬浮动作卡由 `UtenFloatingActionGroup` 统一滚动，卡片内部不再重复建立同向滚动区。

`UtenActionButton`仅负责ClickGuard的异步防重入、忙态与解锁，视觉委托UtenButton；`UtenImportButton`也委托同一内核，不再保留独立padding/fixedSize/色板。导出、草稿、顶栏按钮保持原权限、身份和业务回调。

原生Material按钮在根部经UtenControlTheme接收同一个宽高目标和密度，不能只给触控高度保底却漏掉短标签宽度。表格内联动作桌面按单行文字显示、触屏扩为48目标；它不是普通办公工具栏按钮。

回归：[点击与键盘](../../test/components/uten_button_test.dart)、[异步防重入](../../test/components/click_guard_test.dart)、[倍率与命中](../../test/components/uten_display_geometry_test.dart)。
