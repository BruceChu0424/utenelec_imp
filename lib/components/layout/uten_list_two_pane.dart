// UtenListTwoPane - 列表页「筛选在上 / 表格在下」布局
// 文档：docs/00-项目准则/03-自适应布局组件.md、docs/02-组件库/组件总览.md
//
// 设计原则（2026-09-10 改版）：
// - **所有断点统一上下堆叠**：筛选区在上（整宽），表格区 Expanded 占满剩余高度。
//   此前 expanded（>=840）走左右分栏（UtenSplitView + UtenFilterPane 侧栏），
//   用户口径「列表页不要左右分栏，改上下」——筛选做成窄侧栏后表格横向被压，
//   而表格列多才是列表页的主体；分类树主档页（货品/客户/供应商/模具分类、部门、
//   权限）仍保留左右分栏，那是「树 + 详情」不是「筛选 + 表格」，见 UtenSplitView。
// - 筛选内容整宽渲染：调用方传的 Column（搜索框 + 状态 Chip Wrap）在整宽下
//   自然摊成一两行，不再是窄栏里的长条。
// - [filterPaneTitle] / [filterPaneFooter] 渲染成筛选区顶部的一行
//   （标题在左、操作按钮在右），不再只在宽屏出现——此前 compact 直接丢掉页脚操作，
//   页面得自己在页头再摆一个「新建」。
//
// 用法：
//   UtenListTwoPane(
//     filterPane: Column(children: [搜索框, 状态 Chip Wrap]),
//     filterPaneTitle: '筛选',
//     filterPaneFooter: UtenButton(child: Text('新建')),
//     tablePane: MasterDataTableView(...),
//   )
//
// 注意：本组件依赖父容器给出「有界高度」——通常由调用方包一层 [Expanded] 提供
// （列表页外壳：Column([页面头, Expanded(UtenListTwoPane(...))])）。

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// 列表页布局：筛选区在上（整宽）、表格区在下占满剩余高度。
class UtenListTwoPane extends StatelessWidget {
  const UtenListTwoPane({
    super.key,
    required this.filterPane,
    required this.tablePane,
    this.filterPaneTitle,
    this.filterPaneFooter,
  });

  /// 筛选区内容（搜索、状态 Chip、其它过滤），整宽渲染在表格上方。
  final Widget filterPane;

  /// 表格区内容（通常为 `MasterDataTableView`），占满剩余高度。
  final Widget tablePane;

  /// 筛选区顶部小标题。传 null 且无 [filterPaneFooter] 时不渲染标题行。
  final String? filterPaneTitle;

  /// 筛选区顶部右侧操作（如「新建」按钮）。传 null 不渲染。
  final Widget? filterPaneFooter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = filterPaneTitle != null || filterPaneFooter != null;
    final header = hasHeader
        ? Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Row(
              children: [
                if (filterPaneTitle != null)
                  Expanded(
                    child: Text(
                      filterPaneTitle!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                ?filterPaneFooter,
              ],
            ),
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 筛选区高度封顶 45%（至少 120）并内部可滚：调用方的筛选内容原本是为窄侧栏
        // 设计的纵向 Column，整宽放到顶部后在矮视口（横屏 / 超大字号）会顶爆 Column。
        // 封顶 + 内滚保证永不溢出，且表格恒得 55% 以上高度。
        // 可分配高度先扣掉两区之间的间距，再按 45% 封顶——**不设下限**：
        // 矮视口（横屏 202→122 等）下写死的最小高会把表格挤到负空间造成溢出
        //（2026-09-10 实测 h=122 时 120 的下限直接溢出 6px）。
        final available = (constraints.maxHeight - UtenSpacing.s8).clamp(
          0.0,
          double.infinity,
        );
        // 表格自带固定件（工具条 + 表头 + 分页）约需 160。
        const minTableHeight = 160.0;
        const minFilterHeight = 120.0;
        final filterBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [?header, filterPane],
        );
        if (constraints.maxHeight.isFinite &&
            available < minTableHeight + minFilterHeight) {
          // 极矮视口（横屏 + 超大字号，可用高度只剩一百多）：两区都塞不下，
          // 整体改为可滚——筛选完整可见可点（压到 0 高会让筛选彻底点不到），
          // 表格给最小可用高度并在其内部滚动。
          return SingleChildScrollView(
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                filterBlock,
                const SizedBox(height: UtenSpacing.s8),
                SizedBox(height: minTableHeight, child: tablePane),
              ],
            ),
          );
        }
        final maxFilterHeight = constraints.maxHeight.isFinite
            ? (available * 0.45).clamp(
                0.0,
                (available - minTableHeight).clamp(0.0, double.infinity),
              )
            : double.infinity;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxFilterHeight),
              child: SingleChildScrollView(
                // 不接 PrimaryScrollController：表格（MasterDataTableView primary:true）
                // 才是本页主滚动区，两者都挂会报「attached to more than one ScrollPosition」。
                primary: false,
                child: filterBlock,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Expanded(child: tablePane),
          ],
        );
      },
    );
  }
}
