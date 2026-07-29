// 生产调度工作台（业务链 · 排产段，V90 docs/07-业务链路/02）。
//
// 待排产订单行列表（交货升序，≤3 天红色 urgent）→ 勾选（可改本次排产量）→
// 底部面板填 开工/完工日期 + 车间 + 负责人 → 合并排产：同货品+颜色合并成计划行，
// 生成草稿生产计划后跳详情页，调度确认审核即进入业务链（回写 planned_qty + 缺料标记）。
// 无 production_plan:edit 时只读（列表可见，创建面板隐藏）。
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

class ProductionSchedulePage extends ConsumerStatefulWidget {
  const ProductionSchedulePage({super.key});

  @override
  ConsumerState<ProductionSchedulePage> createState() =>
      _ProductionSchedulePageState();
}

class _ProductionSchedulePageState
    extends ConsumerState<ProductionSchedulePage> {
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _workshopCtrl.dispose();
    _workerCtrl.dispose();
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
      final rows = await ref
          .read(productionPlanRepositoryProvider)
          .schedulePending();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        // 剔除已不存在的勾选（排产后缺口消失的行）
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
      context.appApiError(e, fallback: '加载待排产列表失败');
    }
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

  /// D2 建议完工日期：勾选行按货品聚合量 → 后端推算 → 回填完工日期。
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

  /// 建议计划单：系统自动采纳全部待排产行（每行按缺口量），直接合并排产生成草稿计划。
  /// 用户确认后审核即入业务链；不想全排的可逐行勾选走底部「合并排产」，或手工新建计划单。
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

  Future<void> _submit() async {
    if (_selected.isEmpty || _submitting) return;
    // 超缺口前置校验（后端同样硬校验，前端先给友好提示）
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
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final planId = await context.guardAction(
      () => ref.read(productionPlanRepositoryProvider).createMergePlan({
        'items': [
          for (final e in _selected.entries)
            {'orderItemId': e.key, 'qty': e.value},
        ],
        if (_beginDate != null) 'planBeginDate': fmt(_beginDate!),
        if (_endDate != null) 'planEndDate': fmt(_endDate!),
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
      // 徽标计数同步刷新（待排产行已进草稿计划）
      ref.read(productionPendingCountProvider.notifier).refresh();
      context.go(RoutePath.productionPlanDetail(planId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产调度',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          // 建议计划单：一键采纳全部待排产行（按缺口量合并排产，生成草稿计划）；
          // 想自己挑选就勾选下方行走「合并排产」，或去新建计划单手工开单。
          if (_canEdit)
            TextButton.icon(
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text('建议计划（全部 ${_rows?.length ?? 0} 行）'),
              onPressed: (_rows?.isEmpty ?? true) || _submitting
                  ? null
                  : _suggestAllAndSubmit,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Column(
            children: [
              Expanded(child: _body(theme)),
              if (_canEdit) _footer(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading && _rows == null) {
      return const Center(child: CircularProgressIndicator());
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
    final rows = _rows ?? const <SchedulePendingRow>[];
    if (rows.isEmpty) {
      return const Center(child: Text('暂无待排产的订单行'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s4),
      itemBuilder: (_, i) => _row(theme, rows[i]),
    );
  }

  Widget _row(ThemeData theme, SchedulePendingRow r) {
    final checked = _selected.containsKey(r.orderItemId);
    final deliver = r.deliverDate == null
        ? '—'
        : r.deliverDate!.substring(0, 10);
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

  void _toggle(SchedulePendingRow r, bool on) {
    setState(() {
      if (on) {
        _selected[r.orderItemId] = r.needQty ?? 0;
      } else {
        _selected.remove(r.orderItemId);
      }
    });
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
                _dateBtn(theme, '开工', _beginDate, () => _pickDate(true)),
                _dateBtn(theme, '完工', _endDate, () => _pickDate(false)),
                // D2（韩焕超）：按历史工时+BOM 层级给建议完工日，一键回填
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

  Widget _dateBtn(
    ThemeData theme,
    String label,
    DateTime? d,
    VoidCallback onTap,
  ) {
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
