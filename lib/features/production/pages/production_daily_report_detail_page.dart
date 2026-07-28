// 生产日报详情页（全页路由 · production_daily_report:view）：主表头卡 + 只读明细子表 +
// 状态门控操作（审核/红冲/编辑/删除）。结构与生产计划单详情页同构。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 production_daily_report:edit。
// 本期空结构（0 行），UI 完整保未来启用零成本。
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
import '../../purchase/providers/master_name_provider.dart';
import '../models/production_daily_report.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_status_badge.dart';
import 'production_plan_list_page.dart' show ProductionPerm;

class ProductionDailyReportDetailPage extends ConsumerStatefulWidget {
  const ProductionDailyReportDetailPage({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ProductionDailyReportDetailPage> createState() =>
      _ProductionDailyReportDetailPageState();
}

class _ProductionDailyReportDetailPageState
    extends ConsumerState<ProductionDailyReportDetailPage> {
  ProductionDailyReportDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit => ref
      .read(currentPermissionsProvider)
      .contains(ProductionPerm.dailyReportEdit);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(widget.id);
      final goodsIds =
          d.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
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

  Future<void> _approve() => _doAction('审核后日报生效，确认？',
      (repo) => repo.approve(widget.id), '已审核');
  Future<void> _reverse() => _doAction('红冲将反向冲销，确认？',
      (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(ProductionDailyReportRepository) fn,
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
      await fn(ref.read(productionDailyReportRepositoryProvider));
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
        title: const Text('删除日报'),
        content: const Text('确定删除该草稿日报吗？'),
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
      await ref.read(productionDailyReportRepositoryProvider).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go('/production/daily-reports');
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
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: const UtenAppBar(title: '生产日报详情', showBackButton: true),
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
                            _headerCard(theme, names),
                            const SizedBox(height: UtenSpacing.s12),
                            _itemsCard(theme, names),
                          ],
                        ),
        ),
      ),
      bottomNavigationBar:
          _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      if (d.warehouseId != null)
        _KV('仓库', names.warehouse(d.warehouseId)),
      if ((d.workshopName ?? '').isNotEmpty) _KV('车间', d.workshopName),
      if ((d.sourceDocNo ?? '').isNotEmpty) _KV('来源单号', d.sourceDocNo),
      if ((d.remark ?? '').isNotEmpty) _KV('备注', d.remark),
      _KV('状态', null, badge: ProductionStatusBadge(status: d.status, closed: d.closed)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final r in rows) _kvRow(theme, r)],
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

  Widget _itemsCard(ThemeData theme, MasterNameService names) {
    final items = _detail!.items;
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
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(UtenSpacing.s12),
                child: Text('暂无明细'),
              )
            else
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
          _icell('完工量', 1, theme, bold: true),
          _icell('单价', 1, theme, bold: true),
          _icell('金额', 1, theme, bold: true),
          _icell('计划号', 1, theme, bold: true),
        ],
      ),
    );
  }

  Widget _itemRow(
      ThemeData theme, MasterNameService names, ProductionDailyReportItem it) {
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
                  [names.color(it.colorId), names.unit(it.unitId)]
                      .where((s) => s != '—')
                      .join(' · '),
                  style: TextStyle(
                      fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _icell(it.qty?.toStringAsFixed(2), 1, theme),
          _icell(it.price?.toStringAsFixed(2), 1, theme),
          _icell(amt.toStringAsFixed(2), 1, theme),
          _icell(it.planNo, 1, theme),
        ],
      ),
    );
  }

  Widget _icell(String? text, int flex, ThemeData theme, {bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text == null || text.isEmpty ? '—' : text,
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: 12,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
          color: bold ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final children = <Widget>[];
    if (s == kProductionStatusDraft && _canEdit) {
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
          onPressed: () =>
              context.push('/production/daily-reports/${widget.id}/edit'),
          child: const Text('编辑'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          icon: Icons.check_circle_outline,
          onPressed: _approve,
          child: const Text('审核'),
        ));
    } else if (s == kProductionStatusApproved && _canEdit) {
      children.add(UtenButton(
        type: UtenButtonType.danger,
        icon: Icons.undo_outlined,
        onPressed: _reverse,
        child: const Text('红冲'),
      ));
    } else {
      children.add(UtenButton(
        type: UtenButtonType.secondary,
        onPressed: () => context.go('/production/daily-reports'),
        child: const Text('返回列表'),
      ));
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: children),
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
