// 上游单据明细引入对话框（编辑页"从上游引入"用）。
//
// 两步：
//  1) 拉上游单据列表（page:1, size:20），用户选一张。
//  2) detail → items，渲染复选清单：货品名 / 上游数量 / 本次数量（默认 = 上游数量，
//     若上游为订货且当前为收货，则默认 = 上游 qty - receivedQty）。
//  确认返回所选 [LinkedItem] 列表（带 upstreamItemId），编辑页据此外推明细行并
//  回填 requestItemId/orderItemId/receiptItemId。
//
// 上游类型由 cfg 决定：linkToReceiptItem→收货（退货优先收货），linkToOrderItem→订货，
// linkToRequestItem→申请。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';

/// 上游引入回填项：货品 + 本次数量 + 单价 + 上游明细 id（用于回写 *ItemId）+
/// 可选颜色/单位。
class LinkedItem {
  const LinkedItem({
    required this.goodsId,
    required this.qty,
    this.price,
    this.upstreamItemId,
    this.colorId,
    this.unitId,
  });

  final String goodsId;
  final double qty;
  final double? price;
  final String? upstreamItemId;
  final String? colorId;
  final String? unitId;
}

/// 从 cfg 推断上游单据类型。退货同时可链收货/订货时优先收货。
PurchaseDocType _upstreamType(PurchaseDocConfig cfg) {
  if (cfg.linkToReceiptItem) return PurchaseDocType.receipt;
  if (cfg.linkToOrderItem) return PurchaseDocType.order;
  return PurchaseDocType.request;
}

/// 弹出"从上游引入"对话框；返回所选明细（null 表示用户取消，空列表理论上不会发生）。
Future<List<LinkedItem>?> showDocLinkPicker(
  BuildContext context,
  WidgetRef ref,
  PurchaseDocConfig cfg,
) {
  return showDialog<List<LinkedItem>>(
    context: context,
    builder: (_) => _DocLinkPickerDialog(cfg: cfg, upstreamType: _upstreamType(cfg)),
  );
}

class _DocLinkPickerDialog extends ConsumerStatefulWidget {
  const _DocLinkPickerDialog({required this.cfg, required this.upstreamType});

  final PurchaseDocConfig cfg;
  final PurchaseDocType upstreamType;

  @override
  ConsumerState<_DocLinkPickerDialog> createState() =>
      _DocLinkPickerDialogState();
}

class _DocLinkPickerDialogState extends ConsumerState<_DocLinkPickerDialog> {
  // Step 1：上游单据列表
  PagedResult<PurchaseDocListItem>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;

  // Step 2：所选上游单据明细
  String? _pickedDocId;
  PurchaseDocDetail? _detail;
  bool _loadingDetail = false;
  String? _detailError;

  // Step 2 复选与数量编辑
  final Set<int> _selected = {}; // index in _detail.items
  final Map<int, TextEditingController> _qtyCtrls = {};

  PurchaseDocType get _upstream => widget.upstreamType;
  PurchaseDocConfig get _cfg => widget.cfg;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDocs());
  }

  @override
  void dispose() {
    for (final c in _qtyCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDocs() async {
    setState(() {
      _loadingDocs = true;
      _docsError = null;
    });
    try {
      final r = await ref
          .read(purchaseRepositoryProvider(_upstream))
          .list();
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
        _docsError = '加载上游单据失败'; // TODO(l10n): 补 arb
        _loadingDocs = false;
      });
    }
  }

  Future<void> _pickDoc(PurchaseDocListItem d) async {
    setState(() {
      _pickedDocId = d.id;
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final detail = await ref
          .read(purchaseRepositoryProvider(_upstream))
          .detail(d.id);
      final goodsIds = detail.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      // 初始化数量控制器（默认值 = 上游数量，订货→收货 = 待收 = qty - receivedQty）
      for (var i = 0; i < detail.items.length; i++) {
        final it = detail.items[i];
        final remaining = (_upstream == PurchaseDocType.order &&
                _cfg.type == PurchaseDocType.receipt)
            ? math.max(0.0, (it.qty ?? 0) - (it.receivedQty ?? 0))
            : (it.qty ?? 0);
        _qtyCtrls[i] = TextEditingController(text: remaining.toString());
      }
      setState(() {
        _detail = detail;
        _loadingDetail = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _detailError = e.message;
        _loadingDetail = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _detailError = '加载单据明细失败'; // TODO(l10n): 补 arb
        _loadingDetail = false;
      });
    }
  }

  void _backToDocs() {
    setState(() {
      _pickedDocId = null;
      _detail = null;
      _detailError = null;
      _selected.clear();
      for (final c in _qtyCtrls.values) {
        c.dispose();
      }
      _qtyCtrls.clear();
    });
  }

  void _confirm() {
    final items = _detail?.items ?? const <PurchaseDocItem>[];
    final out = <LinkedItem>[];
    for (final i in _selected) {
      if (i >= items.length) continue;
      final it = items[i];
      final qty = double.tryParse(_qtyCtrls[i]?.text ?? '') ?? 0;
      if (qty <= 0) continue;
      out.add(LinkedItem(
        goodsId: it.goodsId ?? '',
        qty: qty,
        price: it.price,
        upstreamItemId: it.id,
        colorId: it.colorId,
        unitId: it.unitId,
      ));
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: 620,
        height: 600,
        child: Column(
          children: [
            _buildHeader(theme),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: _pickedDocId == null ? _buildStep1(theme) : _buildStep2(theme),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            _buildFooter(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final title = _pickedDocId == null ? '从上游引入 · 选择单据' : '从上游引入 · 选择明细';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          if (_pickedDocId != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              onPressed: _backToDocs,
              tooltip: '返回', // TODO(l10n): 补 arb
            ),
          Expanded(
            child: Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildStep1(ThemeData theme) {
    if (_loadingDocs) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_docsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text(_docsError!,
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center),
        ),
      );
    }
    final items = _docPage?.items ?? const <PurchaseDocListItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text('暂无上游单据',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final names = ref.watch(masterNameServiceProvider);
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final it = items[i];
        return ListTile(
          onTap: () => _pickDoc(it),
          title: Row(children: [
            Text(it.billNo ?? '—',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            if (it.status != null)
              Text(purchaseStatusLabel(it.status),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          ]),
          subtitle: Text(
            [
              (it.billDate ?? '').substring(0, 10),
              if (_cfg.hasSupplier) names.supplier(it.supplierId),
              if (it.totalLocal != null)
                '¥${it.totalLocal!.toStringAsFixed(2)}',
            ].join('  ·  '),
            style: const TextStyle(fontSize: 12),
          ),
          trailing:
              const Icon(Icons.chevron_right_rounded, color: Colors.grey),
        );
      },
    );
  }

  Widget _buildStep2(ThemeData theme) {
    if (_loadingDetail) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_detailError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_detailError!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center),
              const SizedBox(height: UtenSpacing.s8),
              TextButton(onPressed: _backToDocs, child: const Text('返回')),
            ],
          ),
        ),
      );
    }
    final items = _detail?.items ?? const <PurchaseDocItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text('该单据无明细',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final names = ref.watch(masterNameServiceProvider);
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final it = items[i];
        final checked = _selected.contains(i);
        final remaining = (_upstream == PurchaseDocType.order &&
                _cfg.type == PurchaseDocType.receipt)
            ? math.max(0.0, (it.qty ?? 0) - (it.receivedQty ?? 0))
            : (it.qty ?? 0);
        return CheckboxListTile(
          value: checked,
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(i);
            } else {
              _selected.remove(i);
            }
          }),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(names.goods(it.goodsId),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Text('上游数量：${_fmt(it.qty)}',
                  style: const TextStyle(fontSize: 12)),
              if (remaining != (it.qty ?? 0)) ...[
                const SizedBox(width: 12),
                Text('待收：${_fmt(remaining)}',
                    style: const TextStyle(fontSize: 12)),
              ],
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _qtyCtrls[i],
                  enabled: checked,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '本次数量',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          const SizedBox(width: UtenSpacing.s8),
          FilledButton(
            onPressed: _pickedDocId == null || _selected.isEmpty
                ? null
                : _confirm,
            child: Text('引入 ${_selected.isEmpty ? "" : "(${_selected.length})"}'),
          ),
        ],
      ),
    );
  }

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(2);
}
