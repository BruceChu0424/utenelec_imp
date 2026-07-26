// 委外上游单据明细引入对话框（编辑页"从上游引入"用）。
//
// 与采购 doc_link_picker 同构，但委外 8 单据链路更复杂（4 个上游方向）：
//   订货       → 申请（applicationItemId）
//   进仓       → 订货（orderItemId）
//   退货       → 进仓（receiptItemId）优先 / 订货（orderItemId）
//   发料       → 订货（orderItemId）
//   材料退     → 发料（materialIssueItemId）优先 / 订货（orderItemId）
//   损耗       → 发料（materialIssueItemId）
//
// 两步：① 拉上游单据列表（仅已审 status=1，更实用；可放宽）→ 选一张；
//      ② detail→items 复选清单：货品名 / 上游数量 / 本次数量（默认=上游数量）。
// 确认返回 [LinkedItem] 列表，编辑页据此外推明细行并回填对应 *ItemId。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';
import '../providers/subcontract_providers.dart';
import '../../../features/purchase/providers/master_name_provider.dart' as mn;

/// 上游引入回填项：货品 + 本次数量 + 单价(可空) + 上游明细 id + 颜色/单位。
/// [upstreamItemId] 由编辑页按 cfg 映射为对应 *ItemId 字段。
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

/// 由 cfg 推断上游单据类型。退货/材料退双链时优先进仓/发料（更接近源头）。
SubcontractDocType upstreamTypeOf(SubcontractDocConfig cfg) {
  if (cfg.linkToReceiptItem) return SubcontractDocType.receipt;
  if (cfg.linkToMaterialIssueItem) return SubcontractDocType.materialIssue;
  if (cfg.linkToOrderItem) return SubcontractDocType.order;
  return SubcontractDocType.application;
}

/// 弹出"从上游引入"对话框。null=取消，空列表理论上不会发生。
Future<List<LinkedItem>?> showSubcontractLinkPicker(
  BuildContext context,
  WidgetRef ref,
  SubcontractDocConfig cfg,
) {
  return showDialog<List<LinkedItem>>(
    context: context,
    builder: (_) => _LinkPickerDialog(cfg: cfg, upstream: upstreamTypeOf(cfg)),
  );
}

class _LinkPickerDialog extends ConsumerStatefulWidget {
  const _LinkPickerDialog({required this.cfg, required this.upstream});
  final SubcontractDocConfig cfg;
  final SubcontractDocType upstream;

  @override
  ConsumerState<_LinkPickerDialog> createState() => _LinkPickerDialogState();
}

class _LinkPickerDialogState extends ConsumerState<_LinkPickerDialog> {
  SubcontractDocConfig get _cfg => widget.cfg;
  SubcontractDocType get _upstream => widget.upstream;

  PagedResult<SubcontractDocListItem>? _docPage;
  bool _loadingDocs = false;
  String? _docsError;

  String? _pickedDocId;
  SubcontractDocDetail? _detail;
  bool _loadingDetail = false;
  String? _detailError;

  final Set<int> _selected = {};
  final Map<int, TextEditingController> _qtyCtrls = {};

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
      // 拉已审单据（草稿单据的明细不该被引入）。
      final r = await ref.read(subcontractRepositoryProvider(_upstream)).list(
            filter: const SubcontractDocFilter(status: kSubcontractStatusApproved),
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

  Future<void> _pickDoc(SubcontractDocListItem d) async {
    setState(() {
      _pickedDocId = d.id;
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final detail = await ref
          .read(subcontractRepositoryProvider(_upstream))
          .detail(d.id);
      final goodsIds = detail.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      for (var i = 0; i < detail.items.length; i++) {
        final it = detail.items[i];
        _qtyCtrls[i] = TextEditingController(text: (it.qty ?? 0).toString());
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
        _detailError = '加载单据明细失败';
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
    final items = _detail?.items ?? const <SubcontractDocItem>[];
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

  String get _upstreamLabel {
    switch (_upstream) {
      case SubcontractDocType.application:
        return '委外申请单';
      case SubcontractDocType.order:
        return '委外订货单';
      case SubcontractDocType.receipt:
        return '委外进仓单';
      case SubcontractDocType.materialIssue:
        return '委外发料单';
      default:
        return '上游单据';
    }
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
    final title = _pickedDocId == null
        ? '从$_upstreamLabel引入 · 选择单据'
        : '从$_upstreamLabel引入 · 选择明细';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          if (_pickedDocId != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              onPressed: _backToDocs,
              tooltip: '返回',
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
    final items = _docPage?.items ?? const <SubcontractDocListItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text('暂无已审的$_upstreamLabel',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final names = ref.watch(mn.masterNameServiceProvider);
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
              Text(subcontractStatusLabel(it.status),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          ]),
          subtitle: Text(
            [
              (it.billDate ?? '').substring(0, 10),
              if (_cfg.hasSupplier) names.supplier(it.supplierId),
              if (it.totalLocal != null) '¥${it.totalLocal!.toStringAsFixed(2)}',
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
    final items = _detail?.items ?? const <SubcontractDocItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text('该单据无明细',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final names = ref.watch(mn.masterNameServiceProvider);
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final it = items[i];
        final checked = _selected.contains(i);
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
            child: const Text('取消'),
          ),
          const SizedBox(width: UtenSpacing.s8),
          FilledButton(
            onPressed: _pickedDocId == null || _selected.isEmpty
                ? null
                : _confirm,
            child: Text(_selected.isEmpty
                ? '引入'
                : '引入 (${_selected.length})'),
          ),
        ],
      ),
    );
  }

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(2);
}
