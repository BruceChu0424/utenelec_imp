// 上游单据明细引入对话框（销售编辑页"从上游引入"用）。
//
// 两步：
//  1) 拉上游单据列表（page:1, size:20），用户选一张。
//  2) detail → items，渲染复选清单：货品名 / 上游数量 / 本次数量（默认 = 上游数量；
//     出货引入订货时默认 = qty - shippedQty，跳过已发完的行）。
//  确认返回所选 [SalesLinkedItem] 列表（带 orderItemId / outItemId），编辑页据此外推明细行。
//
// 上游类型由 cfg 决定：
//  - linkToOutItem（退货链出货）：拉 shipments（已审优先）
//  - linkToOrderItem（出货/退货链订货）：拉 orders（已审优先）
//
// 注：当前 v1 实现单源选择（退货同时双挂需引入两次，UI 略繁但满足业务）；
// 后续如需"选一次自动双挂"可扩展 _pickSources 返回多个上游。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

/// 上游引入回填项：货品 + 本次数量 + 单价 + 上游明细 id（用于回写 orderItemId/outItemId）+
/// 可选颜色/单位。
class SalesLinkedItem {
  const SalesLinkedItem({
    required this.goodsId,
    required this.qty,
    this.price,
    this.orderItemId,
    this.outItemId,
    this.colorId,
    this.unitId,
  });

  final String goodsId;
  final double qty;
  final double? price;
  final String? orderItemId;
  final String? outItemId;
  final String? colorId;
  final String? unitId;
}

/// 决定引入源（订货 / 出货）。退货同时双挂时优先出货（outItemId 真骨干），
/// 订货 orderItemId 由编辑页"再引入一次订货"补全（v1 简化）。
SalesDocType _upstreamType(SalesDocConfig cfg) {
  if (cfg.linkToOutItem) return SalesDocType.shipment;
  if (cfg.linkToOrderItem) return SalesDocType.order;
  return SalesDocType.order;
}

/// 弹出"从上游引入"对话框；返回所选明细（null 表示用户取消，空列表理论上不会发生）。
Future<List<SalesLinkedItem>?> showSalesDocLinkPicker(
  BuildContext context,
  WidgetRef ref,
  SalesDocConfig cfg,
) {
  return showDialog<List<SalesLinkedItem>>(
    context: context,
    builder: (_) =>
        _SalesDocLinkPickerDialog(cfg: cfg, upstreamType: _upstreamType(cfg)),
  );
}

class _SalesDocLinkPickerDialog extends ConsumerStatefulWidget {
  const _SalesDocLinkPickerDialog({required this.cfg, required this.upstreamType});

  final SalesDocConfig cfg;
  final SalesDocType upstreamType;

  @override
  ConsumerState<_SalesDocLinkPickerDialog> createState() =>
      _SalesDocLinkPickerDialogState();
}

class _SalesDocLinkPickerDialogState
    extends ConsumerState<_SalesDocLinkPickerDialog> {
  // Step 1：上游单据列表
  PagedResult<SalesDocListItem>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;

  // Step 2：选中上游单据后的明细清单
  SalesDocDetail? _upDetail;
  final Map<int, double> _picked = {}; // lineIndex → 本次数量
  bool _loadingItems = false;

  SalesDocType get _upType => widget.upstreamType;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded();
      _loadDocs(1);
    });
  }

  Future<void> _loadDocs(int page) async {
    setState(() {
      _loadingDocs = true;
      _docsError = null;
    });
    try {
      final r = await ref.read(salesRepositoryProvider(_upType)).list(
            page: page,
            size: 20,
            filter: const SalesDocFilter(status: kSalesStatusApproved),
          );
      if (!mounted) return;
      setState(() {
        _docPage = r;
        _loadingDocs = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _docsError = e.message;
        _loadingDocs = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _docsError = '加载上游单据失败';
        _loadingDocs = false;
      });
    }
  }

  Future<void> _pickDoc(SalesDocListItem d) async {
    setState(() {
      _loadingItems = true;
      _upDetail = null;
      _picked.clear();
    });
    try {
      final detail =
          await ref.read(salesRepositoryProvider(_upType)).detail(d.id);
      final goodsIds = detail.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() {
        _upDetail = detail;
        _loadingItems = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingItems = false);
    }
  }

  /// 默认本次数量：出货引入订货 → max(0, qty - shippedQty)；其它 → qty。
  double _defaultQty(SalesDocItem it) {
    if (_upType == SalesDocType.order && widget.cfg.type == SalesDocType.shipment) {
      final remain = (it.qty ?? 0) - (it.shippedQty ?? 0);
      return remain < 0 ? 0 : remain;
    }
    return it.qty ?? 0;
  }

  void _toggle(int i, bool? checked) {
    final items = _upDetail?.items ?? const <SalesDocItem>[];
    if (i >= items.length) return;
    setState(() {
      if (checked == true) {
        _picked[i] = _defaultQty(items[i]);
      } else {
        _picked.remove(i);
      }
    });
  }

  void _submit() {
    final items = _upDetail?.items ?? const <SalesDocItem>[];
    final out = <SalesLinkedItem>[];
    _picked.forEach((i, qty) {
      if (i >= items.length || qty <= 0) return;
      final it = items[i];
      if (it.goodsId == null) return;
      out.add(SalesLinkedItem(
        goodsId: it.goodsId!,
        qty: qty,
        price: it.price,
        orderItemId:
            widget.cfg.linkToOrderItem && _upType == SalesDocType.order
                ? it.id
                : null,
        outItemId:
            widget.cfg.linkToOutItem && _upType == SalesDocType.shipment
                ? it.id
                : null,
        colorId: it.colorId,
        unitId: it.unitId,
      ));
    });
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    return Dialog(
      child: SizedBox(
        width: math.min(640, MediaQuery.of(context).size.width - 40),
        height: math.min(560, MediaQuery.of(context).size.height - 80),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Text(
                      _upDetail == null
                          ? '从${_upTypeLabel()}引入'
                          : '选择明细（${names.client(_upDetail!.clientId)}）',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (_upDetail != null)
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _upDetail = null;
                        _picked.clear();
                      }),
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: const Text('重选单据'),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _upDetail == null
                  ? _buildDocList(theme, names)
                  : _buildItemList(theme, names),
            ),
            if (_upDetail != null)
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('已选 ${_picked.length} 行',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(width: UtenSpacing.s12),
                      FilledButton.icon(
                        onPressed:
                            _picked.isEmpty ? null : _submit,
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('引入'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _upTypeLabel() {
    switch (_upType) {
      case SalesDocType.order:
        return '订货';
      case SalesDocType.shipment:
        return '出货';
      default:
        return '上游';
    }
  }

  Widget _buildDocList(ThemeData theme, SalesMasterNameService names) {
    if (_loadingDocs && _docPage == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_docsError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_docsError!),
            const SizedBox(height: UtenSpacing.s8),
            OutlinedButton(onPressed: () => _loadDocs(1), child: const Text('重试')),
          ],
        ),
      );
    }
    final items = _docPage?.items ?? const <SalesDocListItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text('暂无可引入的${_upTypeLabel()}单',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final d = items[i];
        return ListTile(
          title: Text(d.billNo ?? '—'),
          subtitle: Text(
            '${(d.billDate ?? '').substring(0, 10)}  ·  ${names.client(d.clientId)}',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: Text('¥${d.totalLocal?.toStringAsFixed(0) ?? '—'}'),
          onTap: () => _pickDoc(d),
        );
      },
    );
  }

  Widget _buildItemList(ThemeData theme, SalesMasterNameService names) {
    if (_loadingItems) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final items = _upDetail?.items ?? const <SalesDocItem>[];
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final it = items[i];
        final checked = _picked.containsKey(i);
        final remaining =
            (it.qty ?? 0) - (it.shippedQty ?? 0);
        final exhausted = _upType == SalesDocType.order &&
            widget.cfg.type == SalesDocType.shipment &&
            remaining <= 0;
        return CheckboxListTile(
          value: checked,
          onChanged: exhausted ? null : (v) => _toggle(i, v),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(names.goods(it.goodsId)),
          subtitle: Text(
            [
              names.color(it.colorId),
              names.unit(it.unitId),
              if (_upType == SalesDocType.order)
                '订 ${it.qty?.toStringAsFixed(1)}'
              else
                '出 ${it.qty?.toStringAsFixed(1)}',
              if (_upType == SalesDocType.order &&
                  widget.cfg.type == SalesDocType.shipment)
                '· 待 ${remaining.toStringAsFixed(1)}'
              else if (_upType == SalesDocType.order)
                '· 已发 ${(it.shippedQty ?? 0).toStringAsFixed(1)}'
              else if (_upType == SalesDocType.shipment)
                '· 已退 ${(it.returnedQty ?? 0).toStringAsFixed(1)}',
            ].join('  ·  '),
            style: const TextStyle(fontSize: 11),
          ),
          isThreeLine: false,
          secondary: checked
              ? SizedBox(
                  width: 84,
                  child: TextFormField(
                    initialValue: _picked[i]?.toString() ?? '',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '本次',
                    ),
                    onChanged: (v) {
                      final n = double.tryParse(v);
                      if (n != null) _picked[i] = n;
                    },
                  ),
                )
              : (exhausted
                  ? Text('已发完',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11))
                  : null),
        );
      },
    );
  }
}
