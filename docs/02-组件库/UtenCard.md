# UtenCard 与表格外框

源码：[UtenCard](../../lib/components/cards/uten_card.dart)、[UtenHubCard](../../lib/components/cards/uten_hub_card.dart)、[UtenTableSurface](../../lib/components/data_display/uten_table_surface.dart)。

普通卡片统一圆角16、内边距16；复杂内容可按24内距分组。卡片不设置统一固定高度：指标、入口、详情、表单内容不同，最低尺寸与内容决定高度，窄屏减少列数。字段与数字不通过FittedBox变回小字。

深浅主题原生Card同样圆角16并裁剪表面；UtenCard保持原solid/glass/outlined、性能档降级、边框和onTap/onLongPress语义。标准表面克制使用低层阴影，业务状态通过语义色和文字表达。

Hub图标、黄红徽章空间不足时分行，完整计数与黄→红顺序保持；0隐藏和99+规则仍由徽章组件处理。正文标题允许换行。

表格作为独立数据工作区使用12外框圆角；连接的工具栏/表头/表体在同一外框内，内部单元格保持直线边界。UtenTableSurface负责裁剪，不增加布局padding；UtenTableHeaderSurface单独裁剪表头上方两角，使有无工具栏的普通表格、滑窗选择表和编辑表保持一致。每个可见数据列都保留右边界，包括隐藏列后的实际末列；行尾操作列及其冻结副本也保留右边界。实现不改变列宽、冻结列、选中、拖拽或滚动坐标。原生纸面/PDF表格仍按原文档尺寸生成。

主题共同字号源：[uten_typography.dart](../../lib/core/theme/uten_typography.dart)。普通正文16、密集表格14、次要说明13；放大由根部界面倍率完成。
