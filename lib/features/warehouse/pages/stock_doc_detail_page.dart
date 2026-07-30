// 仓库单据详情页：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
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

  /// DRAW 出库/反出库对话框：按行输入本次数量（默认填满剩余/已出），提交后刷新。
  Future<void> _issueDialog({required bool reverse}) async {
    if (_busy || _d == null) return;
    final names = ref.read(masterNameServiceProvider);
    final lines = _d!.items
        .where((it) => reverse ? (it.issuedQty ?? 0) > 0 : it.remainingQty > 0)
        .toList();
    final ctrls = {
      for (final it in lines)
        it.id!: TextEditingController(
            text: (reverse ? (it.issuedQty ?? 0) : it.remainingQty).toStringAsFixed(2)),
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(reverse ? '反出库（退回数量）' : '出库（本次数量）'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final it in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          '${names.goods(it.goodsId)}\n${reverse ? '已出库 ${(it.issuedQty ?? 0).toStringAsFixed(2)}' : '剩余 ${it.remainingQty.toStringAsFixed(2)}'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: ctrls[it.id!],
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(reverse ? '反出库' : '出库')),
        ],
      ),
    );
    if (confirmed != true) {
      for (final c in ctrls.values) {
        c.dispose();
      }
      return;
    }

    // 组装请求行（>0 才提交；后端会再校验上限）
    final body = <Map<String, dynamic>>[];
    for (final it in lines) {
      final q = double.tryParse(ctrls[it.id]!.text.trim()) ?? 0;
      if (q > 0) body.add({'itemId': it.id, 'qty': q});
    }
    for (final c in ctrls.values) {
      c.dispose();
    }
    if (body.isEmpty) {
      if (mounted) context.appError('没有有效的数量');
      return;
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      if (reverse) {
        await repo.reverseIssue(widget.id, body);
      } else {
        await repo.issue(widget.id, body);
      }
      if (!mounted) return;
      context.appSuccess(reverse ? '已反出库' : '已出库');
      await _load();
    } catch (_) {
      if (mounted) context.appError(reverse ? '反出库失败' : '出库失败');
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
      appBar: UtenAppBar(
        title: '${widget.docType.label}详情',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () =>
                context.push(RoutePath.stockDocList(widget.docType.code)),
            child: const Text('查看历史'),
          ),
        ],
      ),
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
                                _kv('制单员', _d!.makerName, theme),
                                _kv('制单时间', utenFmtIsoTime(_d!.createdAt), theme),
                                _kv('仓库', names.warehouse(_d!.warehouseId), theme),
                                if (widget.docType == StockDocType.transfer)
                                  _kv('调入仓', names.warehouse(_d!.toWarehouseId), theme),
                                if (widget.docType == StockDocType.draw) ...[
                                  _kv('领料车间', names.department(_d!.departmentId), theme),
                                  _kv('出库进度', drawIssueStatusLabel(_d!.issueStatus), theme),
                                ],
                                if (_d!.remark?.isNotEmpty == true) _kv('备注', _d!.remark, theme),
                                _kv('状态', stockStatusLabel(_d!.status), theme),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        // 明细区：统一表格样式（嵌入模式，与全站报表/主档同款），不再是卡片 ListTile。
                        Text('明细 (${_d!.items.length})',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: UtenSpacing.s8),
                        MasterDataTableView<StockDocItem>(
                          embedded: true,
                          columns: [
                            MasterColumnDef(
                              key: 'goods',
                              label: '货品',
                              width: 220,
                              value: (it) =>
                                  '${names.goods(it.goodsId)}（${names.color(it.colorId)} · ${names.unit(it.unitId)}）',
                            ),
                            if (widget.docType == StockDocType.check) ...[
                              MasterColumnDef(
                                key: 'bookQty',
                                label: '账面数量',
                                width: 90,
                                type: 'number',
                                value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                              ),
                              MasterColumnDef(
                                key: 'countQty',
                                label: '实盘数量',
                                width: 90,
                                type: 'number',
                                value: (it) => it.countQty?.toStringAsFixed(1),
                              ),
                              MasterColumnDef(
                                key: 'surplusQty',
                                label: '盈亏',
                                width: 90,
                                type: 'number',
                                value: (it) => it.surplusQty?.toStringAsFixed(1),
                              ),
                            ] else if (widget.docType == StockDocType.draw) ...[
                              MasterColumnDef(
                                key: 'qty',
                                label: '数量',
                                width: 90,
                                type: 'number',
                                value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                              ),
                              MasterColumnDef(
                                key: 'issuedQty',
                                label: '已出库',
                                width: 90,
                                type: 'number',
                                value: (it) => (it.issuedQty ?? 0).toStringAsFixed(2),
                              ),
                              MasterColumnDef(
                                key: 'remainingQty',
                                label: '剩余',
                                width: 90,
                                type: 'number',
                                value: (it) => it.remainingQty.toStringAsFixed(2),
                              ),
                            ] else
                              MasterColumnDef(
                                key: 'qty',
                                label: '数量',
                                width: 90,
                                type: 'number',
                                value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                              ),
                          ],
                          items: _d!.items,
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                          onRowTap: (_) {},
                          emptyMessage: '暂无明细',
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
      // DRAW 已审：分轮出库 / 反出库 / 红冲（有出库记录时红冲被服务端拦截，须先全部反出库）
      if (widget.docType == StockDocType.draw) {
        final anyRemaining = _d!.items.any((it) => it.remainingQty > 0);
        final anyIssued = _d!.items.any((it) => (it.issuedQty ?? 0) > 0);
        if (anyRemaining) {
          children
            ..add(UtenButton(
                icon: Icons.logout_rounded,
                onPressed: () => _issueDialog(reverse: false),
                child: const Text('出库')))
            ..add(const SizedBox(width: 8));
        }
        if (anyIssued) {
          children
            ..add(UtenButton(
                type: UtenButtonType.secondary,
                icon: Icons.undo_rounded,
                onPressed: () => _issueDialog(reverse: true),
                child: const Text('反出库')))
            ..add(const SizedBox(width: 8));
        }
      }
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
