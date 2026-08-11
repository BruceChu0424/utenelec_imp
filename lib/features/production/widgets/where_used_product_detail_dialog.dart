import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/repositories/goods_repository.dart';

import 'where_used_source_breakdown.dart';

/// 物料反查结果弹窗中可继续前往的关联页面。
enum WhereUsedProductLink { goodsProfile, bom, stockMovements }

class WhereUsedProductDetailResult {
  const WhereUsedProductDetailResult({
    required this.link,
    required this.productId,
    this.detail,
  });

  final WhereUsedProductLink link;
  final String productId;
  final GoodsDetail? detail;
}

/// 展示一条“物料反查产成品”结果的历史汇总和当前货品主档。
///
/// compact 使用底部抽屉，medium+ 使用居中弹窗。关联动作通过返回值交给
/// 调用页处理，确保先关闭当前弹层，再打开货品详情或路由页面。
Future<WhereUsedProductDetailResult?> showWhereUsedProductDetailDialog({
  required BuildContext context,
  required Map<String, dynamic> row,
  required GoodsListItem material,
  required String historyRangeLabel,
  required bool canViewGoods,
  required bool canViewStock,
}) {
  final body = _WhereUsedProductDetailBody(
    row: row,
    material: material,
    historyRangeLabel: historyRangeLabel,
    canViewGoods: canViewGoods,
    canViewStock: canViewStock,
  );

  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<WhereUsedProductDetailResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.xxl),
        ),
      ),
      builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: body),
    );
  }

  return showDialog<WhereUsedProductDetailResult>(
    context: context,
    builder: (dialogContext) {
      final height = (MediaQuery.sizeOf(dialogContext).height - 48)
          .clamp(240.0, 760.0)
          .toDouble();
      return Dialog(
        shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
        child: SizedBox(width: 800, height: height, child: body),
      );
    },
  );
}

class _WhereUsedProductDetailBody extends ConsumerStatefulWidget {
  const _WhereUsedProductDetailBody({
    required this.row,
    required this.material,
    required this.historyRangeLabel,
    required this.canViewGoods,
    required this.canViewStock,
  });

  final Map<String, dynamic> row;
  final GoodsListItem material;
  final String historyRangeLabel;
  final bool canViewGoods;
  final bool canViewStock;

  @override
  ConsumerState<_WhereUsedProductDetailBody> createState() =>
      _WhereUsedProductDetailBodyState();
}

class _WhereUsedProductDetailBodyState
    extends ConsumerState<_WhereUsedProductDetailBody> {
  GoodsDetail? _detail;
  bool _loading = false;
  bool _loadFailed = false;
  bool _accessDenied = false;

  String get _productId =>
      _rawText(widget.row['__productId'] ?? widget.row['__srcId']);

  @override
  void initState() {
    super.initState();
    if (widget.canViewGoods) {
      _loading = true;
      _loadDetail();
    } else {
      _accessDenied = true;
    }
  }

  Future<void> _loadDetail({bool retry = false}) async {
    if (retry) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    if (_productId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return;
    }
    try {
      final detail = await ref.read(goodsRepositoryProvider).detail(_productId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _loadFailed = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        final forbidden = error is ApiException && error.code == 'FORBIDDEN';
        _loading = false;
        _loadFailed = !forbidden;
        _accessDenied = forbidden;
        if (forbidden) _detail = null;
      });
    }
  }

  void _follow(WhereUsedProductLink link) {
    final detail = _detail;
    if (link != WhereUsedProductLink.stockMovements && detail == null) return;
    if (_productId.isEmpty) return;
    Navigator.of(context).pop(
      WhereUsedProductDetailResult(
        link: link,
        productId: _productId,
        detail: detail,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final productName = _display(widget.row['goodsName']);
    final productCode = _display(widget.row['goodsCode']);

    return SafeArea(
      key: const Key('where-used-product-detail-dialog'),
      child: Column(
        children: [
          _DialogHeader(
            productName: productName,
            productCode: productCode,
            onClose: () => Navigator.of(context).pop(),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HistoryNotice(theme: theme),
                  const SizedBox(height: UtenSpacing.s20),
                  _SectionTitle(
                    icon: Icons.query_stats_rounded,
                    title: '本次反查',
                    subtitle:
                        '${widget.historyRangeLabel} · ${_materialLabel(widget.material)}',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  WhereUsedSourceBreakdown(row: widget.row),
                  const SizedBox(height: UtenSpacing.s24),
                  const _SectionTitle(
                    icon: Icons.inventory_2_outlined,
                    title: '当前产成品资料',
                    subtitle: '来自货品主档；与上方各来源关系和数量分开显示',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  if (_loading)
                    const _DetailLoading()
                  else if (_accessDenied)
                    const _DetailUnavailable(message: '你没有查看当前货品主档和 BOM 的权限。')
                  else if (_loadFailed)
                    _DetailLoadError(onRetry: () => _loadDetail(retry: true))
                  else
                    _GoodsInfoGrid(detail: _detail!),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          _DialogActions(
            goodsLinksEnabled: _detail != null,
            stockLinkEnabled: widget.canViewStock && _productId.isNotEmpty,
            showGoodsLinks: widget.canViewGoods,
            showStockLink: widget.canViewStock,
            onClose: () => Navigator.of(context).pop(),
            onGoodsProfile: () => _follow(WhereUsedProductLink.goodsProfile),
            onBom: () => _follow(WhereUsedProductLink.bom),
            onStockMovements: () =>
                _follow(WhereUsedProductLink.stockMovements),
          ),
        ],
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.productName,
    required this.productCode,
    required this.onClose,
  });

  final String productName;
  final String productCode;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s16,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      productName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s8,
                        vertical: UtenSpacing.s4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: UtenRadius.pillAll,
                      ),
                      child: Text(
                        '多来源关系详情',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                SelectableText(
                  '产成品编号：$productCode',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _HistoryNotice extends StatelessWidget {
  const _HistoryNotice({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '数据口径说明',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.history_rounded,
              size: 20,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '当前 BOM、新生产需求、旧生产快照和委外历史分别展示；不同来源的数量不能相加。名称、编号、规格和分类按查询时主档展示。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GoodsInfoGrid extends StatelessWidget {
  const _GoodsInfoGrid({required this.detail});

  final GoodsDetail detail;

  @override
  Widget build(BuildContext context) {
    final values = [
      _InfoValue('分类', _display(detail.categoryName)),
      _InfoValue('状态', _display(detail.status)),
      _InfoValue('来源', _display(detail.sourceType)),
      _InfoValue('型号', _display(detail.model)),
      _InfoValue('规格', _display(detail.spec)),
      _InfoValue('材质', _display(detail.material)),
      _InfoValue('主颜色', _display(detail.colorName)),
      _InfoValue('单位', _display(detail.unitName)),
      _InfoValue('包装', _display(detail.pack)),
      _InfoValue('件数', _display(detail.pieces)),
    ];
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = constraints.maxWidth >= 560 ? 2 : 1;
        final width =
            (constraints.maxWidth - UtenSpacing.s8 * (columnCount - 1)) /
            columnCount;
        return Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final value in values)
              SizedBox(
                width: width,
                child: Container(
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
                    children: [
                      Text(
                        value.label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        value.value,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DetailLoading extends StatelessWidget {
  const _DetailLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '正在加载当前产成品资料',
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: UtenSpacing.s8),
            Text('正在加载当前产成品资料…'),
          ],
        ),
      ),
    );
  }
}

class _DetailLoadError extends StatelessWidget {
  const _DetailLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
        ),
        child: Column(
          children: [
            Text(
              '当前货品主档加载失败，历史反查结果仍可查看。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            TextButton.icon(
              key: const Key('where-used-detail-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试加载'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailUnavailable extends StatelessWidget {
  const _DetailUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.lgAll,
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.goodsLinksEnabled,
    required this.stockLinkEnabled,
    required this.showGoodsLinks,
    required this.showStockLink,
    required this.onClose,
    required this.onGoodsProfile,
    required this.onBom,
    required this.onStockMovements,
  });

  final bool goodsLinksEnabled;
  final bool stockLinkEnabled;
  final bool showGoodsLinks;
  final bool showStockLink;
  final VoidCallback onClose;
  final VoidCallback onGoodsProfile;
  final VoidCallback onBom;
  final VoidCallback onStockMovements;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          alignment: WrapAlignment.end,
          runAlignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: onClose,
              child: const Text('关闭'),
            ),
            if (showStockLink)
              Semantics(
                button: true,
                label: '打开该产成品的出入库流水',
                child: UtenButton(
                  key: const Key('where-used-open-stock-movements'),
                  type: UtenButtonType.ghost,
                  icon: Icons.swap_vert_rounded,
                  onPressed: stockLinkEnabled ? onStockMovements : null,
                  child: const Text('出入库流水'),
                ),
              ),
            if (showGoodsLinks)
              Semantics(
                button: true,
                label: '打开该产成品的货品详情',
                child: UtenButton(
                  key: const Key('where-used-open-goods-profile'),
                  type: UtenButtonType.ghost,
                  icon: Icons.open_in_new_rounded,
                  onPressed: goodsLinksEnabled ? onGoodsProfile : null,
                  child: const Text('货品详情'),
                ),
              ),
            if (showGoodsLinks)
              Semantics(
                button: true,
                label: '打开该产成品当前的组装信息',
                child: UtenButton(
                  key: const Key('where-used-open-bom'),
                  icon: Icons.account_tree_outlined,
                  onPressed: goodsLinksEnabled ? onBom : null,
                  child: const Text('查看组装信息'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoValue {
  const _InfoValue(this.label, this.value);

  final String label;
  final String value;
}

String _materialLabel(GoodsListItem material) {
  final name = _display(material.name);
  final code = _display(material.code);
  if (name == '—' || code == '—') return name == '—' ? code : name;
  return '$name（$code）';
}

String _rawText(Object? value) => value?.toString().trim() ?? '';

String _display(Object? value) {
  if (value == null) return '—';
  if (value is num) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  final text = value.toString().trim();
  return text.isEmpty ? '—' : text;
}
