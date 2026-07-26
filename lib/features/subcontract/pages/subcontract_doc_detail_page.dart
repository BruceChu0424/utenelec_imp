// 委外单据详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 edit 权限。
// 名称解析：委外商(supplier)/仓库/币种/颜色/单位复用采购 MasterNameService；货品按明细 id 批量 lookup。
// 审核仅调 approve：后端联动（发料出库 / 进仓入库+立应付 / 损耗出库+回写 等）由后端承担。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';
import '../widgets/subcontract_status_badge.dart';
import '../../../features/purchase/providers/master_name_provider.dart'
    as mn;

class SubcontractDocDetailPage extends ConsumerStatefulWidget {
  const SubcontractDocDetailPage(
      {super.key, required this.docType, required this.id});
  final SubcontractDocType docType;
  final String id;

  @override
  ConsumerState<SubcontractDocDetailPage> createState() =>
      _SubcontractDocDetailPageState();
}

class _SubcontractDocDetailPageState
    extends ConsumerState<SubcontractDocDetailPage> {
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(widget.docType);
  SubcontractDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(mn.masterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(subcontractRepositoryProvider(widget.docType))
          .detail(widget.id);
      final goodsIds =
          d.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() async =>
      _doAction('${_cfg.approveEffect}\n\n确认审核？',
          (repo) => repo.approve(widget.id), '已审核');
  Future<void> _reverse() async => _doAction('红冲将反向冲销，确认？',
      (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(SubcontractRepository) fn,
    String ok,
  ) async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(confirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(subcontractRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除单据'),
        content: const Text('确定删除该草稿单据吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(subcontractRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go(SubcontractRoute.list(_cfg.pathSegment));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(title: '${_cfg.label}详情'),
      body: SafeArea(
        child: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
                  ? Center(child: Text(_error!))
                  : _detail == null
                      ? const SizedBox.shrink()
                      : ListView(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          children: [
                            _headerCard(theme),
                            const SizedBox(height: UtenSpacing.s12),
                            _itemsCard(theme),
                          ],
                        ),
        ),
      ),
      bottomNavigationBar:
          _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme) {
    final d = _detail!;
    final names = ref.watch(mn.masterNameServiceProvider);
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      if (_cfg.hasSupplier) _KV('委外商', names.supplier(d.supplierId)),
      _KV('仓库', names.warehouse(d.warehouseId)),
      if (_cfg.hasCurrency) _KV('币种', names.currency(d.currencyId)),
      if (d.exchangeRate != null) _KV('汇率', d.exchangeRate?.toString()),
      if (_cfg.hasTaxRate && d.taxRate != null)
        _KV('税率', d.taxRate?.toString()),
      // 人员字段展示 id（员工名解析未接入；与采购详情页同款已知限制，待统一 EmployeeNameService）。
      if (_cfg.hasPurchaser) _KV('采购员', d.purchaserId ?? '—'),
      if (_cfg.hasSender) _KV('交货人', d.senderId ?? '—'),
      if (_cfg.hasWorker) _KV('经办人', d.workerId ?? '—'),
      if (_cfg.hasDeliverDate) _KV('交货日', d.deliverDate),
      if (_cfg.hasLastDate) _KV('最后交货日', d.lastDate),
      if (_cfg.hasBStyle) _KV('bStyle', d.bStyle?.toString()),
      if (_cfg.hasTotalWeight && d.totalWeight != null)
        _KV('总重', d.totalWeight?.toStringAsFixed(2)),
      if (_cfg.hasAmount) _KV('合计(本币)', d.totalLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV('状态', null,
          badge: SubcontractStatusBadge(
              status: d.status, closed: d.closed, apPosted: d.apPosted)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in rows) _kvRow(theme, r),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(r.label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: r.badge ?? Text(r.value ?? '—')),
        ],
      ),
    );
  }

  Widget _itemsCard(ThemeData theme) {
    final d = _detail!;
    final items = d.items;
    final names = ref.watch(mn.masterNameServiceProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s4),
              child: Text('明细 (${items.length})',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            _itemHeader(theme),
            for (final it in items) _itemRow(theme, names, it),
          ],
        ),
      ),
    );
  }

  Widget _itemHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          _icell('货品', 3, theme, bold: true),
          _icell('数量', 1, theme, bold: true),
          if (_cfg.itemHasPrice) _icell('单价', 1, theme, bold: true),
          if (_cfg.itemHasPrice) _icell('金额', 1, theme, bold: true),
          if (_cfg.itemHasWeight) _icell('重量', 1, theme, bold: true),
          if (_cfg.showReceived) _icell('已收', 1, theme, bold: true),
          if (_cfg.showReturned) _icell('已退', 1, theme, bold: true),
          if (_cfg.showWasted) _icell('已损耗', 1, theme, bold: true),
          if (_cfg.itemHasWasteFields)
            _icell('损耗率/原因', 2, theme, bold: true),
        ],
      ),
    );
  }

  Widget _itemRow(
      ThemeData theme, mn.MasterNameService names, SubcontractDocItem it) {
    final amt = (it.qty ?? 0) * (it.price ?? 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(names.goods(it.goodsId),
                    style: const TextStyle(fontSize: 13)),
                Text(
                  [names.color(it.colorId), names.unit(it.unitId)].join(' · '),
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _icell(it.qty?.toStringAsFixed(2), 1, theme),
          if (_cfg.itemHasPrice) ...[
            _icell(it.price?.toStringAsFixed(2), 1, theme),
            _icell(amt.toStringAsFixed(2), 1, theme),
          ],
          if (_cfg.itemHasWeight)
            _icell(it.weight?.toStringAsFixed(2), 1, theme),
          if (_cfg.showReceived)
            _icell(it.receivedQty?.toStringAsFixed(2), 1, theme),
          if (_cfg.showReturned)
            _icell(it.returnedQty?.toStringAsFixed(2), 1, theme),
          if (_cfg.showWasted)
            _icell(it.wastedQty?.toStringAsFixed(2), 1, theme),
          if (_cfg.itemHasWasteFields)
            Expanded(
              flex: 2,
              child: Text(
                [
                  if (it.wasteRate != null) '${it.wasteRate}%',
                  if (it.cause?.isNotEmpty == true) it.cause,
                ].join(' · '),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _icell(String? text, int flex, ThemeData theme, {bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text ?? '—',
        textAlign: TextAlign.right,
        style: TextStyle(
            fontSize: 12,
            fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            color: bold ? theme.colorScheme.onSurfaceVariant : null),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final children = <Widget>[];
    if (s == kSubcontractStatusDraft && _canEdit) {
      children
        ..add(UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.delete_outline,
          onPressed: _delete,
          child: const Text('删除'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          type: UtenButtonType.secondary,
          icon: Icons.edit_outlined,
          onPressed: () => context.push(
              SubcontractRoute.edit(_cfg.pathSegment, widget.id)),
          child: const Text('编辑'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          icon: Icons.check_circle_outline,
          onPressed: _approve,
          child: const Text('审核'),
        ));
    } else if (s == kSubcontractStatusApproved && _canEdit) {
      children.add(UtenButton(
        type: UtenButtonType.danger,
        icon: Icons.undo_outlined,
        onPressed: _reverse,
        child: const Text('红冲'),
      ));
    } else {
      children.add(UtenButton(
        type: UtenButtonType.secondary,
        onPressed: () => context.go(SubcontractRoute.list(_cfg.pathSegment)),
        child: const Text('返回列表'),
      ));
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border:
              Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
            mainAxisAlignment: MainAxisAlignment.center, children: children),
      ),
    );
  }
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
