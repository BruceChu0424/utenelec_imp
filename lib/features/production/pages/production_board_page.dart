// 生产调度与进度（合一页面，三 Tab）。
//
//  Tab1 待排产：已审订单行缺口列表（交货升序 ≤3天标红）→ 勾选/全选 → 合并排产（原调度页能力）。
//  Tab2 进行中：已审未结案计划卡片（父计划圆形总进度，点开展子计划小圆环），搜索 + 车间筛选 + 显示设置。
//  Tab3 已完成：已结案计划卡片（绿色完成标志）。
//
// 进度 = 完工入库量 ÷ 排产量（成品入库审核后即时反映）。
// 路由：/production/schedule → Tab0；/production/progress → Tab1（旧两页合并，Hub 两卡片进不同 Tab）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../providers/production_pending_provider.dart';
import '../repositories/production_repository.dart';
import '../widgets/progress_ring.dart';

class ProductionBoardPage extends ConsumerStatefulWidget {
  const ProductionBoardPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<ProductionBoardPage> createState() =>
      _ProductionBoardPageState();
}

class _ProductionBoardPageState extends ConsumerState<ProductionBoardPage> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: UtenAppBar(
          title: '生产调度与进度',
          leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.production),
          ),
          bottom: const TabBar(
            tabs: [
              Tab(text: '待排产'),
              Tab(text: '进行中'),
              Tab(text: '已完成'),
            ],
          ),
        ),
        body: const SafeArea(
          child: TabBarView(
            children: [
              _PendingPanel(),
              _PlanPanel(closed: false),
              _PlanPanel(closed: true),
            ],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════ Tab1 待排产（原调度页） ═════════════════════════

class _PendingPanel extends ConsumerStatefulWidget {
  const _PendingPanel();

  @override
  ConsumerState<_PendingPanel> createState() => _PendingPanelState();
}

class _PendingPanelState extends ConsumerState<_PendingPanel> {
  List<SchedulePendingRow>? _rows;
  bool _loading = false;
  String? _error;
  bool _submitting = false;

  /// 勾选状态：orderItemId → 本次排产量（勾选时默认=缺口，可改）。
  final Map<String, double> _selected = {};

  DateTime? _beginDate;
  DateTime? _endDate;
  final _workshopCtrl = TextEditingController();
  final _workerCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _workshopCtrl.dispose();
    _workerCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows =
          await ref.read(productionPlanRepositoryProvider).schedulePending();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        final ids = rows.map((r) => r.orderItemId).toSet();
        _selected.removeWhere((k, _) => !ids.contains(k));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = productionErrorMessage(e, fallback: '加载待排产列表失败');
        _loading = false;
      });
    }
  }

  List<SchedulePendingRow> get _filtered {
    final kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return _rows ?? const [];
    return [
      for (final r in _rows ?? const <SchedulePendingRow>[])
        if ((r.orderBillNo ?? '').toLowerCase().contains(kw) ||
            (r.clientName ?? '').toLowerCase().contains(kw) ||
            (r.goodsName ?? '').toLowerCase().contains(kw) ||
            (r.goodsCode ?? '').toLowerCase().contains(kw))
          r,
    ];
  }

  int get _mergedLineCount {
    final keys = <String>{};
    for (final r in _rows ?? const <SchedulePendingRow>[]) {
      if (_selected.containsKey(r.orderItemId)) {
        keys.add('${r.goodsId}|${r.colorName ?? ''}');
      }
    }
    return keys.length;
  }

  Future<void> _pickDate(bool begin) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_beginDate ?? now) : (_endDate ?? now),
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) setState(() => begin ? _beginDate = d : _endDate = d);
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 建议计划单：一键采纳全部待排产行（按缺口量合并排产，生成草稿计划）。
  Future<void> _suggestAllAndSubmit() async {
    final rows = _rows;
    if (rows == null || rows.isEmpty || _submitting) return;
    setState(() {
      _selected
        ..clear()
        ..addEntries(rows.map((r) => MapEntry(r.orderItemId, r.needQty ?? 0)));
    });
    await _submit();
  }

  Future<void> _suggestFinish() async {
    if (_rows == null) return;
    final byGoods = <String, double>{};
    for (final r in _rows!) {
      final v = _selected[r.orderItemId];
      if (v != null && r.goodsId != null) {
        byGoods[r.goodsId!] = (byGoods[r.goodsId!] ?? 0) + v;
      }
    }
    if (byGoods.isEmpty) return;
    final res = await context.guardAction(
      () => ref.read(productionPlanRepositoryProvider).suggestFinish({
        'items': [
          for (final e in byGoods.entries) {'goodsId': e.key, 'qty': e.value},
        ],
        if (_beginDate != null) 'startDate': _fmtDate(_beginDate!),
      }),
      errorFallback: '推算失败，请稍后重试',
    );
    if (!mounted || res == null) return;
    final s = res['suggestedDate']?.toString();
    if (s == null) {
      context.appWarning(res['note']?.toString() ?? '无历史工时，无法推算');
      return;
    }
    setState(() => _endDate = DateTime.tryParse(s));
    context.appInfo(
      '建议完工 $s（${res['planDays']} 天，含 BOM 缓冲 ${res['bomBufferDays']} 天）',
    );
  }

  Future<void> _submit() async {
    if (_selected.isEmpty || _submitting) return;
    for (final r in _rows!) {
      final v = _selected[r.orderItemId];
      if (v != null && (v <= 0 || v > (r.needQty ?? 0) + 1e-6)) {
        context.appWarning(
          '订单 ${r.orderBillNo} 排产量需在 0 ~ 缺口 '
          '${(r.needQty ?? 0).toStringAsFixed(2)} 之间',
        );
        return;
      }
    }
    setState(() => _submitting = true);
    final planId = await context.guardAction(
      () => ref.read(productionPlanRepositoryProvider).createMergePlan({
        'items': [
          for (final e in _selected.entries)
            {'orderItemId': e.key, 'qty': e.value},
        ],
        if (_beginDate != null) 'planBeginDate': _fmtDate(_beginDate!),
        if (_endDate != null) 'planEndDate': _fmtDate(_endDate!),
        if (_workshopCtrl.text.trim().isNotEmpty)
          'workshopName': _workshopCtrl.text.trim(),
        if (_workerCtrl.text.trim().isNotEmpty)
          'workerName': _workerCtrl.text.trim(),
      }),
      success: '已生成生产计划（草稿），请确认后审核',
      errorFallback: '合并排产失败，请稍后重试',
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (planId != null) {
      ref.read(productionPendingCountProvider.notifier).refresh();
      context.push(RoutePath.productionPlanDetail(planId));
    }
  }

  void _toggle(SchedulePendingRow r, bool on) {
    setState(() {
      if (on) {
        _selected[r.orderItemId] = r.needQty ?? 0;
      } else {
        _selected.remove(r.orderItemId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: Column(
        children: [
          // 工具行：搜索 + 建议计划 + 刷新
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon:
                          const Icon(Icons.search_rounded, size: 20),
                      hintText: '搜索订单号 / 客户 / 货品',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (v) => setState(() => _keyword = v),
                  ),
                ),
                if (_canEdit) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  TextButton.icon(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text('建议计划（全部 ${_rows?.length ?? 0} 行）'),
                    onPressed:
                        (_rows?.isEmpty ?? true) || _submitting
                            ? null
                            : _suggestAllAndSubmit,
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: '刷新',
                  onPressed: _load,
                ),
              ],
            ),
          ),
          Expanded(child: _list(theme)),
          if (_canEdit) _footer(theme),
        ],
      ),
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading && _rows == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _rows == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
              type: UtenButtonType.tonal,
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return Center(
        child: Text(_keyword.isEmpty ? '暂无待排产的订单行' : '没有匹配「$_keyword」的行'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s4),
      itemBuilder: (_, i) => _pendingRow(theme, rows[i]),
    );
  }

  Widget _pendingRow(ThemeData theme, SchedulePendingRow r) {
    final checked = _selected.containsKey(r.orderItemId);
    final deliver =
        r.deliverDate == null ? '—' : r.deliverDate!.substring(0, 10);
    final color = r.urgent ? theme.colorScheme.error : null;
    return Material(
      color: r.urgent
          ? theme.colorScheme.error.withValues(alpha: 0.06)
          : theme.colorScheme.surface,
      borderRadius: UtenRadius.mdAll,
      child: InkWell(
        borderRadius: UtenRadius.mdAll,
        onTap: _canEdit ? () => _toggle(r, !checked) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s8,
            vertical: UtenSpacing.s8,
          ),
          child: Row(
            children: [
              if (_canEdit)
                Checkbox(
                  value: checked,
                  onChanged: (v) => _toggle(r, v ?? false),
                ),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${r.goodsName ?? r.goodsCode ?? '—'}'
                      '${r.spec != null && r.spec!.isNotEmpty ? ' · ${r.spec}' : ''}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${r.orderBillNo ?? ''} · ${r.clientName ?? '—'}'
                      '${r.colorName != null ? ' · ${r.colorName}' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _num(theme, '订货', r.qty),
              _num(theme, '缺口', r.needQty, highlight: true),
              if (checked)
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    initialValue: _selected[r.orderItemId]!.toStringAsFixed(2),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '本次排产',
                    ),
                    onChanged: (v) {
                      final parsed = double.tryParse(v);
                      if (parsed != null) {
                        _selected[r.orderItemId] = parsed;
                      }
                    },
                  ),
                )
              else
                const SizedBox(width: 96),
              const SizedBox(width: UtenSpacing.s8),
              SizedBox(
                width: 92,
                child: Text(
                  deliver,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: r.urgent ? FontWeight.w700 : FontWeight.normal,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _num(
    ThemeData theme,
    String label,
    double? v, {
    bool highlight = false,
  }) {
    return SizedBox(
      width: 76,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            v?.toStringAsFixed(2) ?? '—',
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.normal,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _dateBtn('开工', _beginDate, () => _pickDate(true)),
                _dateBtn('完工', _endDate, () => _pickDate(false)),
                IconButton(
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  tooltip: '建议完工日期',
                  onPressed: _selected.isEmpty ? null : _suggestFinish,
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _workshopCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '车间',
                    ),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _workerCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '负责人',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            icon: Icons.merge_type_rounded,
            onPressed: _selected.isEmpty || _submitting ? null : _submit,
            child: Text(
              _submitting
                  ? '提交中…'
                  : '合并排产（${_selected.length} 行 → $_mergedLineCount 行）',
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateBtn(String label, DateTime? d, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.date_range_rounded, size: 16),
      label: Text(
        d == null
            ? label
            : '$label ${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
      ),
    );
  }
}

// ═════════════════════ Tab2/3 进行中 / 已完成（进度卡片） ═════════════════════

class _PlanPanel extends ConsumerStatefulWidget {
  const _PlanPanel({required this.closed});

  final bool closed;

  @override
  ConsumerState<_PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends ConsumerState<_PlanPanel> {
  List<PlanProgressRow>? _rows;
  bool _loading = false;
  String? _error;

  final _searchCtrl = TextEditingController();
  String _keyword = '';
  String? _workshop; // null=全部车间
  final Set<String> _expanded = {};

  /// 显示设置（Excel 列显隐思路）：卡片上哪些信息块可见。
  bool _showWorkshop = true;
  bool _showWindow = true;
  bool _showDates = true;
  bool _showQty = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref
          .read(productionPlanRepositoryProvider)
          .planProgress(closed: widget.closed);
      if (!mounted) return;
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = productionErrorMessage(e, fallback: '加载生产进度失败');
        _loading = false;
      });
    }
  }

  List<String> get _workshops => {
        for (final r in _rows ?? const <PlanProgressRow>[])
          if (r.workshopName != null && r.workshopName!.isNotEmpty)
            r.workshopName!,
      }.toList()
        ..sort();

  List<PlanProgressRow> get _filtered {
    final kw = _keyword.trim().toLowerCase();
    return [
      for (final r in _rows ?? const <PlanProgressRow>[])
        if ((_workshop == null || r.workshopName == _workshop) &&
            (kw.isEmpty ||
                (r.billNo ?? '').toLowerCase().contains(kw) ||
                (r.workshopName ?? '').toLowerCase().contains(kw)))
          r,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: Column(
        children: [
          _filterHeader(theme),
          Expanded(child: _list(theme)),
        ],
      ),
    );
  }

  /// Excel 式筛选表头：搜索 + 车间筛选 + 显示设置（选显示什么）。
  Widget _filterHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: '搜索计划单号 / 车间',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (v) => setState(() => _keyword = v),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              initialValue: _workshop ?? '',
              decoration: const InputDecoration(
                isDense: true,
                labelText: '车间',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('全部车间')),
                for (final w in _workshops)
                  DropdownMenuItem(value: w, child: Text(w)),
              ],
              onChanged: (v) => setState(
                  () => _workshop = (v == null || v.isEmpty) ? null : v),
            ),
          ),
          PopupMenuButton<void>(
            icon: const Icon(Icons.view_column_outlined),
            tooltip: '显示设置',
            itemBuilder: (_) => [
              _checkItem('车间标签', _showWorkshop,
                  (v) => setState(() => _showWorkshop = v)),
              _checkItem('工期窗口', _showWindow,
                  (v) => setState(() => _showWindow = v)),
              _checkItem('单据/交货日期', _showDates,
                  (v) => setState(() => _showDates = v)),
              _checkItem('数量明细', _showQty,
                  (v) => setState(() => _showQty = v)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  PopupMenuItem<void> _checkItem(
      String label, bool value, ValueChanged<bool> onChanged) {
    return PopupMenuItem(
      child: StatefulBuilder(
        builder: (_, setM) => CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: const TextStyle(fontSize: 13)),
          value: value,
          onChanged: (v) {
            setM(() {});
            onChanged(v ?? false);
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading && _rows == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _rows == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _load,
                child: const Text('重试')),
          ],
        ),
      );
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return Center(
        child: Text(widget.closed
            ? '暂无已完成计划'
            : (_keyword.isEmpty && _workshop == null
                ? '暂无在产计划（已审未结案的计划会出现在这里）'
                : '没有匹配的计划')),
      );
    }
    // 总览条
    final totalQty = rows.fold<double>(0, (s, r) => s + (r.totalQty ?? 0));
    final totalIn = rows.fold<double>(0, (s, r) => s + (r.inboundQty ?? 0));
    final overall = totalQty > 0 ? totalIn / totalQty : 0.0;
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                ProgressRing(value: overall, size: 44),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Text(
                    '${widget.closed ? '已完成' : '在产'} ${rows.length} 张计划 · '
                    '排产 ${_fmt(totalQty)} · 已完工 ${_fmt(totalIn)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        for (final r in rows) _planCard(theme, r),
      ],
    );
  }

  Widget _planCard(ThemeData theme, PlanProgressRow r) {
    final pct = r.percent.clamp(0.0, 1.0);
    final done = widget.closed || pct >= 1.0;
    final expanded = _expanded.contains(r.planId);
    final deliver = r.deliveryDate == null
        ? '交货未定'
        : '交货 ${r.deliveryDate!.substring(0, 10)}';
    final window = (r.planBeginDate == null && r.planEndDate == null)
        ? null
        : '${r.planBeginDate?.substring(0, 10) ?? '？'} ~ ${r.planEndDate?.substring(0, 10) ?? '？'}';
    return Card(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      color: r.urgent && !done
          ? theme.colorScheme.error.withValues(alpha: 0.04)
          : null,
      child: InkWell(
        borderRadius: UtenRadius.lgAll,
        onTap: () => context.push(RoutePath.productionPlanDetail(r.planId)),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProgressRing(value: pct, done: done),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                r.billNo ?? '—',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            _statusChip(theme, r, done),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: UtenSpacing.s12,
                          runSpacing: 2,
                          children: [
                            if (_showWorkshop &&
                                r.workshopName != null &&
                                r.workshopName!.isNotEmpty)
                              _meta(theme, Icons.factory_outlined,
                                  r.workshopName!),
                            if (_showDates)
                              _meta(
                                theme,
                                Icons.event_outlined,
                                deliver,
                                color: r.urgent && !done
                                    ? theme.colorScheme.error
                                    : null,
                              ),
                            if (_showDates && r.billDate != null)
                              _meta(theme, Icons.edit_calendar_outlined,
                                  '开单 ${r.billDate!.substring(0, 10)}'),
                            if (_showWindow && window != null)
                              _meta(theme, Icons.date_range_rounded,
                                  '工期 $window'),
                            _meta(theme, Icons.list_alt_outlined,
                                '${r.lineCount} 行'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_showQty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('已完工 ${_fmt(r.inboundQty)}',
                            style: theme.textTheme.bodySmall),
                        Text('排产 ${_fmt(r.totalQty)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                ],
              ),
              if (r.subplans.isNotEmpty) ...[
                const Divider(height: UtenSpacing.s16),
                InkWell(
                  borderRadius: UtenRadius.mdAll,
                  onTap: () => setState(() => expanded
                      ? _expanded.remove(r.planId)
                      : _expanded.add(r.planId)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
                    child: Row(
                      children: [
                        Icon(
                          expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '子计划 ${r.subplans.length} 张（点开展示进度）',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
                if (expanded)
                  for (final s in r.subplans) _subplanRow(theme, s),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _subplanRow(ThemeData theme, SubPlanProgress s) {
    final pct = s.percent.clamp(0.0, 1.0);
    final done = s.closed || pct >= 1.0;
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => context.push(RoutePath.productionPlanDetail(s.planId)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            vertical: UtenSpacing.s4, horizontal: UtenSpacing.s8),
        child: Row(
          children: [
            ProgressRing(value: pct, size: 34, fontSize: 9, done: done),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.billNo ?? '—',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                      decoration: s.status == -1
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  if (s.workshopName != null && s.workshopName!.isNotEmpty)
                    Text(s.workshopName!,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Text(
              '${_fmt(s.inboundQty)} / ${_fmt(s.totalQty)}',
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: UtenSpacing.s8),
            _miniStatus(theme, s, done),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(ThemeData theme, PlanProgressRow r, bool done) {
    final (label, color) = done
        ? ('已完成 ✓', Colors.green)
        : r.urgent
            ? ('紧急', theme.colorScheme.error)
            : ('进行中', Colors.orange);
    return _chip(label, color);
  }

  Widget _miniStatus(ThemeData theme, SubPlanProgress s, bool done) {
    final (label, color) = s.status == -1
        ? ('红冲', theme.colorScheme.onSurfaceVariant)
        : s.status == 0
            ? ('草稿', Colors.orange)
            : done
                ? ('已完成 ✓', Colors.green)
                : ('进行中', Colors.orange);
    return _chip(label, color, fontSize: 10);
  }

  Widget _chip(String label, Color color, {double fontSize = 11}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: fontSize, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _meta(ThemeData theme, IconData icon, String text, {Color? color}) {
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: c),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 11, color: c)),
      ],
    );
  }

  String _fmt(double? v) => v == null
      ? '—'
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
}
