// 货品详情弹窗（基础资料-货品资料）：页签式（基本信息 / 组装信息 / 成本预算）。
//
// 替代货品行点击原来的 showMasterDetailSheet（模具/客户/供应商仍用通用面板）：
// - 基本信息：原详情字段网格 + 编辑/删除按钮；
// - 组装信息：货品 BOM 树（goods_bom_tab.dart），可增删改（组件编号唯一）；
// - 成本预算：18 项成本字段可编辑表单（goods_cost_tab.dart）；
// - 头部「预览」：A4 产品配件清单（goods_bom_preview.dart），支持打印 + 下载 Excel。
//
// 容器自适应（参照 showMasterDetailSheet）：compact 底部抽屉 / medium+ 居中面板（更宽，放 BOM 树）。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/goods_node.dart';
import 'goods_bom_preview.dart';
import 'goods_bom_tab.dart';
import 'goods_cost_tab.dart';
import 'master_detail_sheet.dart';

/// 弹出货品详情（页签式）。
///
/// [onEdit]/[onDelete] 语义与 showMasterDetailSheet 一致（先 pop 本面板再回调）。
/// [onDataChanged] 在组装/成本数据变动后触发（调用方刷新货品列表行）。
Future<void> showGoodsDetailDialog({
  required BuildContext context,
  required GoodsDetail detail,
  required List<MasterDetailRow> basicRows,
  bool canEdit = false,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
  VoidCallback? onDataChanged,
}) {
  final body = _GoodsDetailBody(
    detail: detail,
    basicRows: basicRows,
    canEdit: canEdit,
    onEdit: onEdit,
    onDelete: onDelete,
    onDataChanged: onDataChanged,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: body,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 920,
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
        ),
        child: body,
      ),
    ),
  );
}

class _GoodsDetailBody extends StatefulWidget {
  const _GoodsDetailBody({
    required this.detail,
    required this.basicRows,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
    required this.onDataChanged,
  });

  final GoodsDetail detail;
  final List<MasterDetailRow> basicRows;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onDataChanged;

  @override
  State<_GoodsDetailBody> createState() => _GoodsDetailBodyState();
}

class _GoodsDetailBodyState extends State<_GoodsDetailBody> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.detail.name?.isNotEmpty == true
        ? widget.detail.name!
        : (widget.detail.code ?? '货品详情'); // TODO(l10n): 补 arb
    return SafeArea(
      child: DefaultTabController(
        length: 3,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(theme, title),
            const Divider(height: 1),
            TabBar(
              labelColor: theme.colorScheme.primary,
              unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
              indicatorColor: theme.colorScheme.primary,
              tabs: const [
                Tab(text: '基本信息'), // TODO(l10n): 补 arb
                Tab(text: '组装信息'), // TODO(l10n): 补 arb
                Tab(text: '成本预算'), // TODO(l10n): 补 arb
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: TabBarView(
                children: [
                  _BasicInfoTab(
                    rows: widget.basicRows,
                    canEdit: widget.canEdit,
                    onEdit: widget.onEdit,
                    onDelete: widget.onDelete,
                  ),
                  GoodsBomTab(
                    goodsId: widget.detail.id,
                    canEdit: widget.canEdit,
                    onDataChanged: widget.onDataChanged,
                  ),
                  GoodsCostTab(
                    detail: widget.detail,
                    canEdit: widget.canEdit,
                    onSaved: widget.onDataChanged,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 预览：A4 产品配件清单（打印 + 下载 Excel）
          UtenButton(
            type: UtenButtonType.tonal,
            size: UtenButtonSize.small,
            icon: Icons.preview_outlined,
            onPressed: () => showGoodsBomPreview(
              context: context,
              goodsId: widget.detail.id,
              productName: widget.detail.name,
              productModel: widget.detail.model,
              productCode: widget.detail.code,
            ),
            child: const Text('预览'), // TODO(l10n): 补 arb
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// 基本信息页签：原详情字段网格（与 master_detail_sheet 同款卡片格）+ 编辑/删除。
class _BasicInfoTab extends StatelessWidget {
  const _BasicInfoTab({
    required this.rows,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final List<MasterDetailRow> rows;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final twoColumn = !context.breakpoint.isCompact;
    final colCount = twoColumn ? 2 : 1;
    final gridRows = <Widget>[];
    for (var i = 0; i < rows.length; i += colCount) {
      final first = rows[i];
      final second = i + 1 < rows.length ? rows[i + 1] : null;
      gridRows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _cell(theme, first)),
              if (colCount > 1) ...[
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: second != null
                      ? _cell(theme, second)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: gridRows,
            ),
          ),
        ),
        if (canEdit && (onEdit != null || onDelete != null)) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onEdit != null) ...[
                  UtenButton(
                    type: UtenButtonType.secondary,
                    icon: Icons.edit_outlined,
                    onPressed: () {
                      Navigator.of(context).pop();
                      onEdit!();
                    },
                    child: const Text('编辑'), // TODO(l10n): 补 arb
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                ],
                if (onDelete != null)
                  UtenButton(
                    type: UtenButtonType.danger,
                    icon: Icons.delete_outline,
                    onPressed: () {
                      Navigator.of(context).pop();
                      onDelete!();
                    },
                    child: const Text('删除'), // TODO(l10n): 补 arb
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _cell(ThemeData theme, MasterDetailRow r) {
    final hasValue = r.value != null && r.value!.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            r.label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            hasValue ? r.value! : '—',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
