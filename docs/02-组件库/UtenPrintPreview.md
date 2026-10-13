# UtenPrintPreview

源码：`lib/components/print/uten_print_preview.dart`。

屏幕预览采用 `UtenDialogFrame`，按当前画布、安全区和键盘约束宽高。标题与打印、下载、关闭动作采用换行布局；低高窗口整个预览可竖向滚动，关闭动作仍可到达。

预览纸面保留 1000 逻辑宽和原 20 行分组，每页重复表头、页码；单独横向滚动查看完整纸面，不缩小表内文字。二维纸面预览不作为分类栏或普通表单横滚的理由。

本次只调整屏幕 UI。PDF 仍使用 A4 横版、28 点边距、原打印字号、完整中文字体及原表格列宽和分页；loader、表头投影、权限、动态字段计算、导出密码与文件交付行为保持。

从顶栏“更多操作”进入时，`showUtenPrintPreview` 先通过 `UtenAppBarActionScope.actionContextOf` 恢复原页上下文，再按原页路由读取表头投影。异步Consumer在loader与预览期间保持挂载；关闭预览后只移除所属动作面板，不能把面板路由当成数据表所属路由而漏掉隐藏列/列序投影。

回归：`test/components/platform_scale_surfaces_test.dart`、`test/components/print/uten_print_projection_test.dart`、`test/components/uten_app_bar_action_lifecycle_test.dart` 与导出身份/权限测试。
