// 仓库单据详情页：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

class StockDocDetailPage extends ConsumerStatefulWidget {
  const StockDocDetailPage({super.key, required this.docType, required this.id});
  final StockDocType docType;
  final String id;

  @override
  ConsumerState<StockDocDetailPage> createState() => _StockDocDetailPageState();
}

class _StockDocDetailPageState extends ConsumerState<StockDocDetailPage> {
  StockDocDetail? _d;
  bool _loading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit => ref.read(currentPermissionsProvider).contains(Perm.stockDocEdit);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref.read(stockDocRepositoryProvider(widget.docType)).detail(widget.id);
      final goodsIds = d.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() => _d = d);
    } catch (_) {
      if (mounted) context.appError('加载详情失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(String confirm, Future<void> Function() fn, String ok) async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(confirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn();
      if (!mounted) return;
      context.appSuccess(ok);
      await _load();
    } catch (_) {
      if (mounted) context.appError('操作失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: const Text('确定删除该草稿单据吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
      await ref.read(stockDocRepositoryProvider(widget.docType)).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go(RoutePath.stockDocList(widget.docType.code));
    } catch (_) {
      if (mounted) context.appError('删除失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(title: '${widget.docType.label}详情', showBackButton: true),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _d == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: UtenFormGrid(
                              children: [
                                _kv('单据号', _d!.billNo, theme),
                                _kv('日期', _d!.billDate, theme),
                                _kv('仓库', names.warehouse(_d!.warehouseId), theme),
                                if (widget.docType == StockDocType.transfer)
                                  _kv('调入仓', names.warehouse(_d!.toWarehouseId), theme),
                                if (_d!.remark?.isNotEmpty == true) _kv('备注', _d!.remark, theme),
                                _kv('状态', stockStatusLabel(_d!.status), theme),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Text('明细 (${_d!.items.length})',
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(fontWeight: FontWeight.w600)),
                                ),
                                for (final it in _d!.items)
                                  ListTile(
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                                    title: Text(names.goods(it.goodsId)),
                                    subtitle: Text(
                                      [
                                        names.color(it.colorId),
                                        names.unit(it.unitId),
                                        if (widget.docType == StockDocType.check)
                                          '实盘 ${it.countQty?.toStringAsFixed(1)} · 盈亏 ${it.surplusQty?.toStringAsFixed(1)}'
                                        else
                                          '数量 ${(it.qty ?? 0).toStringAsFixed(2)}',
                                      ].join(' · '),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
      bottomNavigationBar: _d == null || _busy ? null : _actions(theme),
    );
  }

  Widget _kv(String label, String? value, ThemeData theme) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 84,
              child: Text(label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(value ?? '—')),
        ],
      );

  Widget _actions(ThemeData theme) {
    final s = _d!.status;
    final children = <Widget>[];
    if (s == 0 && _canEdit) {
      children
        ..add(UtenButton(type: UtenButtonType.danger, icon: Icons.delete_outline, onPressed: _delete, child: const Text('删除')))
        ..add(const SizedBox(width: 8))
        ..add(UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(RoutePath.stockDocEdit(widget.docType.code, widget.id)),
            child: const Text('编辑')))
        ..add(const SizedBox(width: 8))
        ..add(UtenButton(
            icon: Icons.check_circle_outline,
            onPressed: () => _act('审核将联动库存，确认？',
                () => ref.read(stockDocRepositoryProvider(widget.docType)).approve(widget.id), '已审核'),
            child: const Text('审核')));
    } else if (s == 1 && _canEdit) {
      children.add(UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.undo_outlined,
          onPressed: () => _act('红冲将反向冲销库存，确认？',
              () => ref.read(stockDocRepositoryProvider(widget.docType)).reverse(widget.id), '已红冲'),
          child: const Text('红冲')));
    } else {
      children.add(UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => context.go(RoutePath.stockDocList(widget.docType.code)),
          child: const Text('返回列表')));
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: children),
      ),
    );
  }
}
