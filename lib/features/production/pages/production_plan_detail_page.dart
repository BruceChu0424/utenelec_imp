// 生产计划单详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 production_plan:edit。
// is_closed（CheckFulfill4 派生：所有明细 qty-iqty≤0）/ is_stopped / is_canceled 经徽章副标体现。
// 关联销售订单：明细 salesOrderNo（文本占位，销售模块上线后挂真 FK）。
// 名称解析：货品/颜色/单位经 MasterNameService（跨 feature 复用 purchase 的 provider）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_plan.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_status_badge.dart';
import '../widgets/progress_ring.dart';
import '../widgets/subplan_split_sheet.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import 'production_plan_list_page.dart' show ProductionPerm;

class ProductionPlanDetailPage extends ConsumerStatefulWidget {
  const ProductionPlanDetailPage({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ProductionPlanDetailPage> createState() =>
      _ProductionPlanDetailPageState();
}

class _ProductionPlanDetailPageState
    extends ConsumerState<ProductionPlanDetailPage> {
  ProductionPlanDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  List<MrpRow>? _mrpRows;
  List<MrpSubplanRef>? _subplans;
  bool _mrpLoading = false;
  bool _mrpBusy = false;
  /// D3：采购申请开单策略（net 净需求扣库存+在途 / gross 毛需求）。
  String _mrpStrategy = 'net';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(ProductionPerm.planEdit);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref.read(productionPlanRepositoryProvider).detail(widget.id);
      final goodsIds =
          d.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      await ref
          .read(masterNameServiceProvider)
          .loadEmployeeNames([d.sellerId, d.workerId]);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
      _loadSubplans();
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

  Future<void> _approve() => _doAction(
      '审核后将驱动下游（BOM 锁定/排产/采购回写归未来模块），确认审核？',
      (repo) => repo.approve(widget.id),
      '已审核');

  Future<void> _reverse() => _doAction('红冲将反向冲销，单据保留不可删，确认？',
      (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(ProductionPlanRepository) fn,
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
      await fn(ref.read(productionPlanRepositoryProvider));
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

  /// 子任务（子计划）随详情打开直接加载展示；MRP 物料需求仍按需手动展开。
  Future<void> _loadSubplans() async {
    try {
      final subs = await ref
          .read(productionPlanRepositoryProvider)
          .mrpSubplans(widget.id);
      if (!mounted) return;
      setState(() => _subplans = subs);
    } catch (_) {
      // 子任务区加载失败不打扰主详情（保持空白即可）
    }
  }

  // ───────────────────────── MRP-lite 面板 ─────────────────────────
  Future<void> _loadMrp() async {
    setState(() => _mrpLoading = true);
    try {
      final repo = ref.read(productionPlanRepositoryProvider);
      final results = await Future.wait([
        repo.mrpPreview(widget.id),
        // 子计划溯源独立容错：失败不影响物料需求主数据
        repo.mrpSubplans(widget.id).catchError((_) => <MrpSubplanRef>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _mrpRows = results[0] as List<MrpRow>;
        _subplans = results[1] as List<MrpSubplanRef>;
        _mrpLoading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _mrpLoading = false);
        context.appError(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _mrpLoading = false);
        context.appError('物料需求加载失败');
      }
    }
  }

  Future<void> _generateMrp() async {
    if (_mrpBusy) return;
    final grossMode = _mrpStrategy == 'gross';
    final buyCount = (_mrpRows ?? []).where(
        (r) => !r.selfMade && ((grossMode ? r.gross : r.net) ?? 0) > 0).length;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('生成采购申请'),
        content: Text(grossMode
            ? '将按毛需求（不扣库存/在途）外购物料生成一张采购申请草稿（$buyCount 行），确认生成？'
            : '将按净需求外购物料生成一张采购申请草稿（$buyCount 行），'
                '采购员在采购申请中审核后走正常采购流程。确认生成？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('生成')),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _mrpBusy = true);
    try {
      final r = await ref
          .read(productionPlanRepositoryProvider)
          .mrpGenerate(widget.id, strategy: _mrpStrategy);
      if (!mounted) return;
      context.appSuccess('已生成采购申请 ${r.requestBillNo}（${r.lineCount} 行）');
      await _loadMrp();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _mrpBusy = false);
    }
  }

  /// 按车间拆分子计划（可定制）：选行/改量/选车间 → 每车间一张草稿。
  Future<void> _splitSubplans() async {
    if (_mrpBusy) return;
    final rows = (_mrpRows ?? [])
        .where((r) => r.selfMade && (r.net ?? 0) > 0)
        .toList();
    if (rows.isEmpty) return;
    final items = await showSubplanSplitSheet(context, ref,
        selfMadeRows: rows,
        defaultDepartmentId: _detail?.departmentId,
        defaultWorkshopName: _detail?.workshopName);
    if (items == null || items.isEmpty || !mounted) return;
    setState(() => _mrpBusy = true);
    try {
      final created = await ref
          .read(productionPlanRepositoryProvider)
          .mrpGenerateSubplans(widget.id, items);
      if (!mounted) return;
      setState(() => _mrpBusy = false);
      // 结果对话框：每个车间一张，可逐个打开（继续向下展开/审核）
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('已生成 ${created.length} 张子计划'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final s in created)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.account_tree_outlined, size: 18),
                    title: Text('${s.billNo ?? '—'}'
                        '${s.workshopName != null ? '（${s.workshopName}）' : ''}'),
                    subtitle: Text('${s.lineCount} 行 · 草稿'),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                    onTap: () {
                      Navigator.pop(ctx);
                      context.push(RoutePath.productionPlanDetail(s.planId));
                    },
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成')),
          ],
        ),
      );
      if (!mounted) return;
      await _loadMrp(); // 刷新物料需求 + 子计划溯源区
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('拆分生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _mrpBusy = false);
    }
  }

  /// 自制件一键生成子计划（多层 BOM 逐级展开）：净需求开下层生产计划草稿。
  Future<void> _generateSubplan() async {
    if (_mrpBusy) return;
    final makeCount =
        (_mrpRows ?? []).where((r) => r.selfMade && (r.net ?? 0) > 0).length;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('生成自制件子计划'),
        content: Text(
            '将对 $makeCount 行自制件（本身有 BOM 的组件）按净需求生成一张下层生产计划草稿，'
            '交货日取本计划最早开工日。确认后可在子计划上继续向下展开。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('生成')),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _mrpBusy = true);
    try {
      final r =
          await ref.read(productionPlanRepositoryProvider).mrpGenerateSubplan(widget.id);
      if (!mounted) return;
      setState(() => _mrpBusy = false);
      // 成功后面向下一步：可直接打开子计划继续展开/审核
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('子计划已生成'),
          content: Text('已生成子计划 ${r.requestBillNo}（${r.lineCount} 行，草稿）。'
              '打开子计划可继续展开下层零件或审核排产。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('留在此页')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('打开子计划')),
          ],
        ),
      );
      if (!mounted) return;
      await _loadMrp();
      if (open == true && mounted) {
        context.push(RoutePath.productionPlanDetail(r.requestId));
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _mrpBusy = false);
    }
  }

  Future<void> _generateDraw() => _generateStockDoc(        kind: '领料单',
        desc: '按 BOM 毛需求生成领料单草稿（含自制件），选择发料仓库：',
        whLabel: '发料仓库',
        run: (wh) => ref.read(productionPlanRepositoryProvider).mrpGenerateDraw(widget.id, wh),
      );

  Future<void> _generateFinishedIn() => _generateStockDoc(
        kind: '成品入库单',
        desc: '按计划明细（排产量−已入库量）生成成品入库单草稿，选择入库仓库：',
        whLabel: '入库仓库',
        run: (wh) => ref.read(productionPlanRepositoryProvider).mrpGenerateFinishedIn(widget.id, wh),
      );

  Future<void> _generateStockDoc({
    required String kind,
    required String desc,
    required String whLabel,
    required Future<MrpGenerateResult> Function(String wh) run,
  }) async {
    if (_mrpBusy) return;
    final names = ref.read(masterNameServiceProvider);
    final whs = names.warehouseEntries.entries.toList();
    if (whs.isEmpty) {
      context.appError('仓库字典未加载');
      return;
    }
    String? whId = whs.first.key;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('生成$kind'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(desc),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: whId,
                decoration: InputDecoration(labelText: whLabel, border: const OutlineInputBorder()),
                items: [for (final e in whs) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setD(() => whId = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('生成')),
          ],
        ),
      ),
    );
    if (c != true || whId == null) return;
    setState(() => _mrpBusy = true);
    try {
      final r = await run(whId!);
      if (!mounted) return;
      context.appSuccess('已生成$kind ${r.requestBillNo}（${r.lineCount} 行）');
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _mrpBusy = false);
    }
  }

  /// 子计划进度卡：与看板同款圆环进度行（点行跳子计划详情，可继续向下展开）。
  Widget _subplansCard(ThemeData theme) {
    final subs = _subplans;
    if (subs == null || subs.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('子任务 · 子计划（${subs.length} 张）',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: UtenSpacing.s4),
            for (final sp in subs) _subplanProgressRow(theme, sp),
          ],
        ),
      ),
    );
  }

  Widget _subplanProgressRow(ThemeData theme, MrpSubplanRef sp) {
    final pct = sp.percent.clamp(0.0, 1.0);
    final reversed = sp.status == -1;
    final done = !reversed && (sp.closed || pct >= 1.0);
    final statusText = reversed
        ? '红冲'
        : sp.status == 0
            ? '草稿'
            : done
                ? '已完成 ✓'
                : '进行中';
    final statusColor = reversed
        ? theme.colorScheme.onSurfaceVariant
        : sp.status == 0
            ? Colors.orange
            : done
                ? Colors.green
                : Colors.orange;
    String fmt(double? v) => v == null
        ? '—'
        : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => context.push(RoutePath.productionPlanDetail(sp.planId)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
        child: Row(
          children: [
            ProgressRing(value: pct, size: 40, fontSize: 10, done: done),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sp.billNo ?? '—',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                      decoration:
                          reversed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (sp.deliveryDate != null)
                    Text('交货 ${sp.deliveryDate!.substring(0, 10)}',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Text('${fmt(sp.inboundQty)} / ${fmt(sp.totalQty)}',
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: UtenSpacing.s8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(statusText,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: statusColor)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mrpCard(ThemeData theme, MasterNameService names) {
    final rows = _mrpRows;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('物料需求（MRP）',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (_mrpLoading)
                    const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else ...[
                    // D3（李主管）：策略选择——净需求（扣库存+在途）/ 毛需求（不扣）
                    ChoiceChip(
                      label: const Text('净需求'),
                      selected: _mrpStrategy == 'net',
                      onSelected: (_) => setState(() => _mrpStrategy = 'net'),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    ChoiceChip(
                      label: const Text('毛需求'),
                      selected: _mrpStrategy == 'gross',
                      onSelected: (_) => setState(() => _mrpStrategy = 'gross'),
                    ),
                    TextButton.icon(
                      onPressed: _loadMrp,
                      icon: const Icon(Icons.account_tree_outlined, size: 16),
                      label: Text(rows == null ? '展开物料需求' : '刷新'),
                    ),
                  ],
                ],
              ),
            ),
            // 操作按钮单独一行 Wrap：窗口窄时自动换行，避免 Row 溢出导致按钮被裁掉点不到
            if (_canEdit)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s4, 0, UtenSpacing.s4, UtenSpacing.s4),
                child: Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    if (rows != null && rows.isNotEmpty) ...[
                      FilledButton.icon(
                        onPressed: _mrpBusy ? null : _generateMrp,
                        icon: const Icon(Icons.playlist_add, size: 16),
                        label: Text(_mrpBusy ? '生成中…' : '生成采购申请'),
                      ),
                      // 多层 BOM：自制件（本身有 BOM 的组件）一键生成下层生产计划
                      if (rows.any((r) => r.selfMade && (r.net ?? 0) > 0)) ...[
                        FilledButton.tonalIcon(
                          onPressed: _mrpBusy ? null : _generateSubplan,
                          icon: const Icon(Icons.account_tree_outlined, size: 16),
                          label: const Text('一键子计划'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _mrpBusy ? null : _splitSubplans,
                          icon: const Icon(Icons.splitscreen_rounded, size: 16),
                          label: const Text('按车间拆分'),
                        ),
                      ],
                      OutlinedButton.icon(
                        onPressed: _mrpBusy ? null : _generateDraw,
                        icon: const Icon(Icons.outbound, size: 16),
                        label: const Text('生成领料单'),
                      ),
                    ],
                    OutlinedButton.icon(
                      onPressed: _mrpBusy ? null : _generateFinishedIn,
                      icon: const Icon(Icons.inventory_2_outlined, size: 16),
                      label: const Text('生成成品入库'),
                    ),
                  ],
                ),
              ),
            if (rows != null) const Divider(height: 1),
            if (rows != null && rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(UtenSpacing.s12),
                child: Text('明细货品均未维护 BOM，无物料需求'),
              )
            else if (rows != null)
              for (final r in rows) _mrpRow(theme, names, r),
          ],
        ),
      ),
    );
  }

  Widget _mrpRow(ThemeData theme, MasterNameService names, MrpRow r) {    final net = r.net ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.goodsName ?? names.goods(r.goodsId), style: const TextStyle(fontSize: 13)),
                Text(
                  [r.goodsCode, r.spec, names.color(r.colorId)].where((s) => s != null && s != '—').join(' · '),
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _mrpNum('毛 ${r.gross?.toStringAsFixed(2) ?? '—'}', theme),
          _mrpNum('存 ${r.onhand?.toStringAsFixed(2) ?? '—'}', theme),
          _mrpNum('途 ${r.openPo?.toStringAsFixed(2) ?? '—'}', theme),
          SizedBox(
            width: 76,
            child: Text(
              r.selfMade ? '自制' : net.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: r.selfMade
                    ? theme.colorScheme.onSurfaceVariant
                    : (net > 0 ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mrpNum(String text, ThemeData theme) {
    return SizedBox(
      width: 76,
      child: Text(text,
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除计划单'),
        content: const Text('确定删除该草稿计划单吗？已审单据请走红冲。'),
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
      await ref.read(productionPlanRepositoryProvider).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go('/production/plans');
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
      appBar: UtenAppBar(
        title: '生产计划单详情',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/production/plans'),
            child: const Text('查看历史'),
          ),
        ],
      ),
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
                            const SizedBox(height: UtenSpacing.s12),
                            _mrpCard(theme, names),
                            if (_subplans != null && _subplans!.isNotEmpty)
                              const SizedBox(height: UtenSpacing.s12),
                            _subplansCard(theme),
                          ],
                        ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy
          ? null
          : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('单据日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if ((d.fStyle ?? '').isNotEmpty) _KV('生产类型', d.fStyle),
      if (d.deliveryDate != null) _KV('交货日', d.deliveryDate),
      if (d.departmentId != null || (d.workshopName ?? '').isNotEmpty)
        _KV(
            '车间',
            d.departmentId != null
                ? names.department(d.departmentId)
                : d.workshopName),
      if (d.workerId != null || (d.workerName ?? '').isNotEmpty)
        _KV(
            '生产工',
            d.workerId != null ? names.employee(d.workerId) : d.workerName),
      if (d.sellerId != null || (d.sellerName ?? '').isNotEmpty)
        _KV(
            '跟单员',
            d.sellerId != null ? names.employee(d.sellerId) : d.sellerName),
      if ((d.sourceDocNo ?? '').isNotEmpty) _KV('来源单号', d.sourceDocNo),
      if ((d.remark ?? '').isNotEmpty) _KV('备注', d.remark),
      _KV('状态', null,
          badge: ProductionStatusBadge(
            status: d.status,
            closed: d.closed,
            stopped: d.stopped,
            canceled: d.canceled,
          )),
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

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；口径保留（编号/颜色/单位并入货品列，关联销售订单一并显示）。
  Widget _itemsCard(ThemeData theme, MasterNameService names) {
    final items = _detail!.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('明细 (${items.length})',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: UtenSpacing.s8),
        MasterDataTableView<ProductionPlanItem>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'goods',
              label: '货品 / 编号',
              width: 260,
              value: (it) {
                final sub = [
                  it.productNo,
                  names.color(it.colorId),
                  names.unit(it.unitId),
                ].where((s) => s != '—').join(' · ');
                final so = it.salesOrderNo;
                return '${names.goods(it.goodsId)}'
                    '${sub.isEmpty ? '' : '（$sub）'}'
                    '${(so != null && so.isNotEmpty) ? ' · 销售订单：$so' : ''}';
              },
            ),
            MasterColumnDef(
              key: 'qty',
              label: '排产量',
              width: 90,
              type: 'number',
              value: (it) => it.qty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'oqty',
              label: '订货量',
              width: 90,
              type: 'number',
              value: (it) => it.oqty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'iqty',
              label: '完工量',
              width: 90,
              type: 'number',
              value: (it) => it.iqty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'outboundDate',
              label: '交货日',
              width: 110,
              type: 'date',
              value: (it) => productionDateOnly(it.outboundDate),
            ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: (_) {},
          emptyMessage: '暂无明细',
        ),
      ],
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
              context.push('/production/plans/${widget.id}/edit'),
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
        onPressed: () => context.go('/production/plans'),
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
