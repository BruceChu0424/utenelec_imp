// 生产调度与进度（合一页面，三 Tab）。
//
//  Tab1 待排产：已审订单行缺口列表（交货升序 ≤3天标红）→ 勾选/全选 → 合并排产（原调度页能力）。
//  Tab2 进行中：已审未结案计划卡片（父计划圆形总进度，点开展子计划小圆环），搜索 + 车间筛选 + 显示设置。
//  Tab3 已完成：已结案计划卡片（绿色完成标志）。
//
// 进度 = 完工入库量 ÷ 排产量（成品入库审核后即时反映）。
// 路由：/production/schedule → Tab0；/production/progress → Tab1（旧两页合并，Hub 两卡片进不同 Tab）。
import 'dart:async';

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
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../providers/production_board_sort_provider.dart';
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

class _ProductionBoardPageState extends ConsumerState<ProductionBoardPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late int _activeTab;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, 2);
    _tabController = TabController(
      length: 3,
      initialIndex: _activeTab,
      vsync: this,
    )..addListener(_handleTabChange);
  }

  void _handleTabChange() {
    final next = _tabController.index;
    if (next != _activeTab && mounted) {
      setState(() => _activeTab = next);
    }
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产调度与进度',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '待排产'),
            Tab(text: '进行中'),
            Tab(text: '已完成'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _PendingPanel(active: _activeTab == 0),
            _PlanPanel(closed: false, active: _activeTab == 1),
            _PlanPanel(closed: true, active: _activeTab == 2),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════ Tab1 待排产（原调度页） ═════════════════════════

class _PendingPanel extends ConsumerStatefulWidget {
  const _PendingPanel({required this.active});

  final bool active;

  @override
  ConsumerState<_PendingPanel> createState() => _PendingPanelState();
}

class _PendingPanelState extends ConsumerState<_PendingPanel> {
  PagedResult<SchedulePendingRow>? _page;
  bool _loading = false;
  String? _error;
  bool _submitting = false;

  int _pageNo = 1;
  int _pageSize = 20;

  /// 勾选状态：orderItemId → 本次排产量（跨页保留，勾选时默认=缺口，可改）。
  final Map<String, double> _selected = {};

  DateTime? _beginDate;
  DateTime? _endDate;
  DateTime? _deliverFrom; // 交货日期范围筛选（从）
  DateTime? _deliverTo; // 交货日期范围筛选（至）
  final _workerCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _keyword = '';
  Timer? _debounce;
  bool _hasLoaded = false;

  List<SchedulePendingRow> get _rows => _page?.items ?? const [];

  @override
  void initState() {
    super.initState();
    _loadWhenActive();
  }

  @override
  void didUpdateWidget(covariant _PendingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _loadWhenActive();
  }

  void _loadWhenActive() {
    if (!widget.active || _hasLoaded) return;
    _hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _workerCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit);

  bool get _canForward =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanForwardRd) ||
      ref.read(isSuperAdminProvider);

  /// 进行中的转发（按 orderItemId 去重，避免连点重复 POST）。
  final Set<String> _forwarding = {};

  /// BOM 缺失 → 转发工程研发部（建研发任务 + 通知研发）；成功后刷新徽标与本页。
  Future<void> _forwardToRd(SchedulePendingRow r) async {
    if (r.rdForwarded || _forwarding.contains(r.orderItemId)) return;
    setState(() => _forwarding.add(r.orderItemId));
    try {
      final ok = await context.guardAction(
        () => ref
            .read(productionPlanRepositoryProvider)
            .forwardToRd(r.orderItemId),
        success: '已转发工程研发部，待其维护 BOM',
        errorFallback: '转发失败，请稍后重试',
      );
      if (!mounted || ok == null) return;
      ref.read(productionPendingCountProvider.notifier).refresh();
      ref.read(rdTaskCountProvider.notifier).refresh();
      await _load();
    } finally {
      if (mounted) setState(() => _forwarding.remove(r.orderItemId));
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 筛选/每页条数变化：回到第一页重新加载。
  void _reload() {
    _pageNo = 1;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(productionPlanRepositoryProvider)
          .schedulePending(
            page: _pageNo,
            size: _pageSize,
            keyword: _keyword,
            dateFrom: _deliverFrom == null ? null : _fmtDate(_deliverFrom!),
            dateTo: _deliverTo == null ? null : _fmtDate(_deliverTo!),
          );
      if (!mounted) return;
      // 服务端已把越界页码回退到最后一页；与本地页码对齐
      if (page.page != _pageNo) _pageNo = page.page;
      setState(() {
        _page = page;
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

  Future<void> _pickDate(bool begin) async {
    final now = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_beginDate ?? now) : (_endDate ?? now),
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) setState(() => begin ? _beginDate = d : _endDate = d);
  }

  /// 交货日期范围筛选（从/至；互相纠偏）。
  Future<void> _pickDeliverDate(bool begin) async {
    final now = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_deliverFrom ?? now) : (_deliverTo ?? now),
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null) return;
    if (begin) {
      _deliverFrom = d;
      if (_deliverTo != null && _deliverTo!.isBefore(d)) _deliverTo = null;
    } else {
      _deliverTo = d;
      if (_deliverFrom != null && _deliverFrom!.isAfter(d)) _deliverFrom = null;
    }
    _reload();
  }

  /// 建议计划单：一键采纳本页全部待排产行（按缺口量合并排产，生成草稿计划）。
  Future<void> _suggestAllAndSubmit() async {
    final rows = _rows;
    if (rows.isEmpty || _submitting) return;
    final missingBom = rows.where((row) => !row.bomReady).length;
    if (missingBom > 0) {
      context.appWarning(
        '当前页有 $missingBom 条产品缺少 BOM，建议计划未生成；'
        '请先维护组装物料资料，或手动选择其它可排产品。',
      );
      return;
    }
    setState(() {
      for (final r in rows) {
        _selected[r.orderItemId] = r.needQty ?? 0;
      }
    });
    await _submit();
  }

  Future<void> _suggestFinish() async {
    final byGoods = <String, double>{};
    for (final r in _rows) {
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
    // 本页勾选的行先做前端校验；其它页勾选量=勾选时的缺口，由服务端硬校验兜底
    for (final r in _rows) {
      final v = _selected[r.orderItemId];
      if (v != null && !r.bomReady) {
        context.appWarning(
          '产品 ${r.goodsCode ?? r.goodsName ?? '未编码货品'} 缺少有效 BOM，'
          '请先维护组装物料资料。',
        );
        return;
      }
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

        if (_workerCtrl.text.trim().isNotEmpty)
          'workerName': _workerCtrl.text.trim(),
      }),
      success: '已生成计划草稿，请先物料评审与预排，再审核下达',
      errorFallback: '合并排产失败，请稍后重试',
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (planId != null) {
      _selected.clear();
      ref.read(productionPendingCountProvider.notifier).refresh();
      context.push(RoutePath.productionPlanDetail(planId));
    }
  }

  void _toggle(SchedulePendingRow r, bool on) {
    if (on && !r.bomReady) {
      context.appWarning(
        '产品 ${r.goodsCode ?? r.goodsName ?? '未编码货品'} 缺少有效 BOM，'
        '请先维护组装物料资料。',
      );
      return;
    }
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
          // 工具行：搜索 + 交货日期范围 + 建议计划 + 刷新
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: '搜索订单号 / 客户 / 货品',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (v) {
                      // 服务端筛选：400ms 防抖，避免逐字打请求
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 400), () {
                        _keyword = v;
                        _reload();
                      });
                    },
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickDeliverDate(true),
                  icon: const Icon(Icons.date_range_rounded, size: 16),
                  label: Text(
                    _deliverFrom == null ? '交货从' : _fmtDate(_deliverFrom!),
                  ),
                  style: _deliverFrom != null
                      ? OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                        )
                      : null,
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickDeliverDate(false),
                  icon: const Icon(Icons.event_rounded, size: 16),
                  label: Text(
                    _deliverTo == null ? '交货至' : _fmtDate(_deliverTo!),
                  ),
                  style: _deliverTo != null
                      ? OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                        )
                      : null,
                ),
                if (_deliverFrom != null || _deliverTo != null)
                  IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    tooltip: '清除时间筛选',
                    onPressed: () {
                      _deliverFrom = null;
                      _deliverTo = null;
                      _reload();
                    },
                  ),
                if (_canEdit)
                  TextButton.icon(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text('建议计划（本页 ${_rows.length} 行）'),
                    onPressed: _rows.isEmpty || _submitting
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
          ),
          Expanded(child: _list(theme)),
          _pager(theme),
          if (_canEdit) _footer(theme),
        ],
      ),
    );
  }

  /// 分页条：总数 + 每页条数 + 翻页（勾选跨页保留）。
  Widget _pager(ThemeData theme) {
    final p = _page;
    final total = p?.total ?? 0;
    final pages = p?.totalPages ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Row(
        children: [
          Text(
            '共 $total 行',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(width: UtenSpacing.s8),
            Text(
              '已选 ${_selected.length} 行',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const Spacer(),
          DropdownButton<int>(
            value: _pageSize,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 20, child: Text('20 条/页')),
              DropdownMenuItem(value: 50, child: Text('50 条/页')),
              DropdownMenuItem(value: 100, child: Text('100 条/页')),
            ],
            onChanged: (v) {
              if (v == null || v == _pageSize) return;
              _pageSize = v;
              _reload();
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: '上一页',
            onPressed: _pageNo > 1 && !_loading
                ? () {
                    _pageNo--;
                    _load();
                  }
                : null,
          ),
          Text(
            pages == 0 ? '0 / 0' : '$_pageNo / $pages',
            style: theme.textTheme.bodySmall,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: '下一页',
            onPressed: _pageNo < pages && !_loading
                ? () {
                    _pageNo++;
                    _load();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading && _page == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _page == null) {
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
    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          _keyword.isEmpty && _deliverFrom == null && _deliverTo == null
              ? '暂无待排产的订单行'
              : '没有匹配的待排产行',
        ),
      );
    }
    return Stack(
      children: [
        ListView.separated(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s4),
          itemBuilder: (_, i) => _pendingRow(theme, rows[i]),
        ),
        if (_loading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _pendingRow(ThemeData theme, SchedulePendingRow r) {
    final checked = _selected.containsKey(r.orderItemId);
    final deliver = r.deliverDate == null
        ? '—'
        : r.deliverDate!.substring(0, 10);
    final color = r.urgent ? theme.colorScheme.error : null;
    return Material(
      color: !r.bomReady
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
          : r.urgent
          ? theme.colorScheme.error.withValues(alpha: 0.06)
          : theme.colorScheme.surface,
      borderRadius: UtenRadius.mdAll,
      child: InkWell(
        borderRadius: UtenRadius.mdAll,
        onTap: _canEdit && r.bomReady ? () => _toggle(r, !checked) : null,
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
                  onChanged: r.bomReady ? (v) => _toggle(r, v ?? false) : null,
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
                    if (!r.bomReady) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              r.rdForwarded
                                  ? 'BOM 缺失 · 已转发工程研发部，等待维护'
                                  : 'BOM 缺失 · 请先维护组装物料资料',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                          if (!r.rdForwarded && _canForward)
                            TextButton.icon(
                              onPressed: _forwarding.contains(r.orderItemId)
                                  ? null
                                  : () => _forwardToRd(r),
                              icon: const Icon(Icons.send_outlined, size: 14),
                              label: Text(
                                _forwarding.contains(r.orderItemId)
                                    ? '转发中…'
                                    : '转发研发',
                                style: const TextStyle(fontSize: 11),
                              ),
                              style: TextButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: const Size(0, 28),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                        ],
                      ),
                    ],
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
            icon: Icons.playlist_add_check_rounded,
            onPressed: _selected.isEmpty || _submitting ? null : _submit,
            child: Text(
              _submitting ? '生成中…' : '生成生产计划（${_selected.length} 个订单行）',
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

/// 进行中/已完成列表排序方式（置顶的计划始终排最前）。
/// billDate=开单远→近（先开单的在前，默认）；billDateDesc=开单近→远（最新开的在前）。
enum _PlanSort { billDate, billDateDesc, deliveryDate, progress }

class _PlanPanel extends ConsumerStatefulWidget {
  const _PlanPanel({required this.closed, required this.active});

  final bool closed;
  final bool active;

  @override
  ConsumerState<_PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends ConsumerState<_PlanPanel> {
  PagedResult<PlanProgressRow>? _page;
  Map<String, dynamic>? _summary;
  List<String> _workshops = const [];
  bool _loading = false;
  String? _error;

  int _pageNo = 1;
  int _pageSize = 20;

  final _searchCtrl = TextEditingController();
  String _keyword = '';
  String? _workshop; // null=全部车间
  DateTime? _from; // 开单日期范围（从）
  DateTime? _to; // 开单日期范围（至）
  Timer? _debounce;
  final Set<String> _expanded = {};
  bool _hasLoaded = false;

  /// 显示设置（Excel 列显隐思路）：卡片上哪些信息块可见。
  bool _showWorkshop = true;
  bool _showWindow = true;
  bool _showDates = true;
  bool _showQty = true;

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit);

  List<PlanProgressRow> get _rows => _page?.items ?? const [];

  /// 排序方式（按账号持久化偏好：默认开单远→近；置顶始终最前）。仅 build 路径可用（watch）。
  _PlanSort get _sort =>
      _PlanSort.values.asNameMap()[ref.watch(productionBoardSortProvider)] ??
      _PlanSort.billDate;

  void _setSort(_PlanSort v) {
    ref.read(productionBoardSortProvider.notifier).update(v.name);
    _reload();
  }

  @override
  void initState() {
    super.initState();
    _loadWhenActive();
  }

  @override
  void didUpdateWidget(covariant _PlanPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _loadWhenActive();
  }

  void _loadWhenActive() {
    if (!widget.active || _hasLoaded) return;
    _hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 筛选/排序/每页条数变化：回到第一页重新加载。
  void _reload() {
    _pageNo = 1;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(productionPlanRepositoryProvider);
    final sort = ref.read(productionBoardSortProvider);
    final kw = _keyword;
    final ws = _workshop ?? '';
    final from = _from == null ? null : _fmtDate(_from!);
    final to = _to == null ? null : _fmtDate(_to!);
    try {
      final results = await Future.wait([
        repo.planProgress(
          closed: widget.closed,
          sort: sort,
          page: _pageNo,
          size: _pageSize,
          keyword: kw,
          workshop: ws,
          dateFrom: from,
          dateTo: to,
        ),
        repo.planProgressSummary(
          closed: widget.closed,
          keyword: kw,
          workshop: ws,
          dateFrom: from,
          dateTo: to,
        ),
        repo.planProgressWorkshops(closed: widget.closed),
      ]);
      if (!mounted) return;
      final page = results[0] as PagedResult<PlanProgressRow>;
      // 服务端已把越界页码回退到最后一页；与本地页码不一致时对齐（如过滤后总数变少）
      if (page.page != _pageNo) {
        _pageNo = page.page;
      }
      setState(() {
        _page = page;
        _summary = results[1] as Map<String, dynamic>;
        _workshops = results[2] as List<String>;
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

  /// 置顶 / 重要标注：成功后重新加载（置顶影响服务端排序与分页位置）。
  Future<void> _toggleFlag(
    PlanProgressRow r, {
    bool? pinned,
    bool? important,
  }) async {
    final ok = await context.guardRun(
      () => ref
          .read(productionPlanRepositoryProvider)
          .updatePlanFlags(r.planId, pinned: pinned, important: important),
      success: pinned != null
          ? (pinned ? '已置顶' : '已取消置顶')
          : (important! ? '已标注重要' : '已取消重要标注'),
      errorFallback: '标记失败，请稍后重试',
    );
    if (ok && mounted) _load();
  }

  Future<void> _pickDate(bool begin) async {
    final now = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_from ?? now) : (_to ?? now),
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null) return;
    if (begin) {
      _from = d;
      if (_to != null && _to!.isBefore(d)) _to = null;
    } else {
      _to = d;
      if (_from != null && _from!.isAfter(d)) _from = null;
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 大屏幕：左右布局（左筛选面板 / 右卡片列表）；窄屏：顶部筛选 + 下列表
          final wide = constraints.maxWidth >= 1080;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 264,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s8,
                    ),
                    child: _controls(theme, vertical: true),
                  ),
                ),
                const VerticalDivider(width: 1),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: _listPane(theme)),
              ],
            );
          }
          return Column(
            children: [
              _controls(theme, vertical: false),
              Expanded(child: _listPane(theme)),
            ],
          );
        },
      ),
    );
  }

  /// 筛选面板：搜索 / 车间 / 排序 / 开单日期范围 / 显示设置 / 刷新。
  /// vertical=true 宽屏左栏竖排；false 窄屏顶部 Wrap 横排。
  Widget _controls(ThemeData theme, {required bool vertical}) {
    if (vertical) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '筛选与排序',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          _searchField(),
          const SizedBox(height: UtenSpacing.s8),
          _workshopDropdown(),
          const SizedBox(height: UtenSpacing.s8),
          _sortDropdown(),
          const SizedBox(height: UtenSpacing.s8),
          Align(alignment: Alignment.centerLeft, child: _dateRange()),
          const SizedBox(height: UtenSpacing.s4),
          Row(children: [_settingsMenu(), const Spacer(), _refreshBtn()]),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(width: 240, child: _searchField()),
          SizedBox(width: 160, child: _workshopDropdown()),
          SizedBox(width: 132, child: _sortDropdown()),
          _dateRange(),
          _settingsMenu(),
          _refreshBtn(),
        ],
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        hintText: '搜索计划单号 / 车间',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onChanged: (v) {
        // 服务端筛选：400ms 防抖，避免逐字打请求
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 400), () {
          _keyword = v;
          _reload();
        });
      },
    );
  }

  Widget _workshopDropdown() {
    // 防御：已选车间已不在最新选项里（计划结案后车间消失）时回退「全部」，避免断言
    final value = (_workshop != null && _workshops.contains(_workshop))
        ? _workshop!
        : '';
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(
        isDense: true,
        labelText: '车间',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('全部车间')),
        for (final w in _workshops) DropdownMenuItem(value: w, child: Text(w)),
      ],
      onChanged: (v) {
        _workshop = (v == null || v.isEmpty) ? null : v;
        _reload();
      },
    );
  }

  Widget _sortDropdown() {
    return DropdownButtonFormField<_PlanSort>(
      initialValue: _sort,
      decoration: const InputDecoration(
        isDense: true,
        labelText: '排序',
        border: OutlineInputBorder(),
      ),
      items: const [
        DropdownMenuItem(value: _PlanSort.billDate, child: Text('开单远→近')),
        DropdownMenuItem(value: _PlanSort.billDateDesc, child: Text('开单近→远')),
        DropdownMenuItem(value: _PlanSort.deliveryDate, child: Text('交货日期')),
        DropdownMenuItem(value: _PlanSort.progress, child: Text('完工进度')),
      ],
      onChanged: (v) => _setSort(v ?? _PlanSort.billDate),
    );
  }

  /// 时间范围筛选（开单日期 从/至 + 清除）。
  Widget _dateRange() {
    return Wrap(
      spacing: 4,
      children: [
        OutlinedButton.icon(
          onPressed: () => _pickDate(true),
          icon: const Icon(Icons.date_range_rounded, size: 16),
          label: Text(_from == null ? '开单从' : _fmtDate(_from!)),
          style: _from != null
              ? OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
        OutlinedButton.icon(
          onPressed: () => _pickDate(false),
          icon: const Icon(Icons.event_rounded, size: 16),
          label: Text(_to == null ? '开单至' : _fmtDate(_to!)),
          style: _to != null
              ? OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
        if (_from != null || _to != null)
          IconButton(
            icon: const Icon(Icons.clear_rounded, size: 18),
            tooltip: '清除时间筛选',
            onPressed: () {
              _from = null;
              _to = null;
              _reload();
            },
          ),
      ],
    );
  }

  Widget _settingsMenu() {
    return PopupMenuButton<void>(
      icon: const Icon(Icons.view_column_outlined),
      tooltip: '显示设置',
      itemBuilder: (_) => [
        _checkItem(
          '车间标签',
          _showWorkshop,
          (v) => setState(() => _showWorkshop = v),
        ),
        _checkItem('工期窗口', _showWindow, (v) => setState(() => _showWindow = v)),
        _checkItem(
          '单据/交货日期',
          _showDates,
          (v) => setState(() => _showDates = v),
        ),
        _checkItem('数量明细', _showQty, (v) => setState(() => _showQty = v)),
      ],
    );
  }

  Widget _refreshBtn() {
    return IconButton(
      icon: const Icon(Icons.refresh_rounded),
      tooltip: '刷新',
      onPressed: _load,
    );
  }

  PopupMenuItem<void> _checkItem(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
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

  /// 右栏：总览条 + 卡片列表 + 底部分页条。
  Widget _listPane(ThemeData theme) {
    return Column(
      children: [
        _summaryCard(theme),
        Expanded(child: _list(theme)),
        _pager(theme),
      ],
    );
  }

  /// 总览条（跨全部页的汇总，来自 /progress/summary）。
  Widget _summaryCard(ThemeData theme) {
    final count = (_summary?['count'] as num?)?.toInt() ?? _page?.total ?? 0;
    final sumQty = (_summary?['sumQty'] as num?)?.toDouble() ?? 0;
    final sumIn = (_summary?['sumInbound'] as num?)?.toDouble() ?? 0;
    final overall = sumQty > 0 ? (sumIn / sumQty).clamp(0.0, 1.0) : 0.0;
    return Card(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            ProgressRing(value: overall, size: 44),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                '${widget.closed ? '已完成' : '在产'} $count 张计划 · '
                '排产 ${_fmt(sumQty)} · 已完工 ${_fmt(sumIn)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部分页条：总数 + 每页条数 + 翻页。
  Widget _pager(ThemeData theme) {
    final p = _page;
    final total = p?.total ?? 0;
    final pages = p?.totalPages ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Row(
        children: [
          Text(
            '共 $total 张',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          DropdownButton<int>(
            value: _pageSize,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 20, child: Text('20 条/页')),
              DropdownMenuItem(value: 50, child: Text('50 条/页')),
              DropdownMenuItem(value: 100, child: Text('100 条/页')),
            ],
            onChanged: (v) {
              if (v == null || v == _pageSize) return;
              _pageSize = v;
              _reload();
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: '上一页',
            onPressed: _pageNo > 1 && !_loading
                ? () {
                    _pageNo--;
                    _load();
                  }
                : null,
          ),
          Text(
            pages == 0 ? '0 / 0' : '$_pageNo / $pages',
            style: theme.textTheme.bodySmall,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: '下一页',
            onPressed: _pageNo < pages && !_loading
                ? () {
                    _pageNo++;
                    _load();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading && _page == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _page == null) {
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
    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          widget.closed
              ? '暂无已完成计划'
              : (_keyword.isEmpty &&
                        _workshop == null &&
                        _from == null &&
                        _to == null
                    ? '暂无在产计划（已审未结案的计划会出现在这里）'
                    : '没有匹配的计划'),
        ),
      );
    }
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
          children: [for (final r in rows) _planCard(theme, r)],
        ),
        if (_loading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _planCard(ThemeData theme, PlanProgressRow r) {
    final pct = r.percent.clamp(0.0, 1.0);
    final done = widget.closed || pct >= 1.0;
    final overdue = r.overdue && !done; // 已过交货日：整卡红色标注
    final urgent = r.urgent && !done && !overdue; // 交货 ≤3 天未逾期：浅色提醒
    final expanded = _expanded.contains(r.planId);
    final deliver = r.deliveryDate == null
        ? '交货未定'
        : '交货 ${r.deliveryDate!.substring(0, 10)}';
    final window = (r.planBeginDate == null && r.planEndDate == null)
        ? null
        : '${r.planBeginDate?.substring(0, 10) ?? '？'} ~ ${r.planEndDate?.substring(0, 10) ?? '？'}';
    return Card(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      color: overdue
          ? theme.colorScheme.error.withValues(alpha: 0.10)
          : urgent
          ? theme.colorScheme.error.withValues(alpha: 0.04)
          : null,
      shape: overdue
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.error, width: 1.2),
              borderRadius: UtenRadius.lgAll,
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          children: [
            InkWell(
              borderRadius: UtenRadius.mdAll,
              onTap: () => _openPlanDetail(r.planId),
              child: Row(
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
                            if (r.pinned)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.push_pin_rounded,
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            if (r.important)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.star_rounded,
                                  size: 16,
                                  color: Colors.amber,
                                ),
                              ),
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
                            _statusChip(theme, r, done, overdue: overdue),
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
                              _meta(
                                theme,
                                Icons.factory_outlined,
                                r.workshopName!,
                              ),
                            if (_showDates)
                              _meta(
                                theme,
                                Icons.event_outlined,
                                deliver,
                                color: r.urgent && !done
                                    ? theme.colorScheme.error
                                    : null,
                                bold: overdue,
                              ),
                            if (_showDates && r.billDate != null)
                              _meta(
                                theme,
                                Icons.edit_calendar_outlined,
                                '开单 ${r.billDate!.substring(0, 10)}',
                              ),
                            if (_showWindow && window != null)
                              _meta(
                                theme,
                                Icons.date_range_rounded,
                                '工期 $window',
                              ),
                            _meta(
                              theme,
                              Icons.list_alt_outlined,
                              '${r.lineCount} 行',
                            ),
                            if ((r.todayQty ?? 0) > 0)
                              _meta(
                                theme,
                                Icons.today_rounded,
                                '今日完工 +${_fmt(r.todayQty)}',
                                color: Colors.green.shade700,
                                bold: true,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_showQty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '已完工 ${_fmt(r.inboundQty)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          '排产 ${_fmt(r.totalQty)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  if (_canEdit)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert_rounded, size: 18),
                      tooltip: '标记',
                      onSelected: (v) {
                        if (v == 'pin') {
                          _toggleFlag(r, pinned: !r.pinned);
                        } else if (v == 'important') {
                          _toggleFlag(r, important: !r.important);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'pin',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.push_pin_outlined,
                              size: 18,
                            ),
                            title: Text(r.pinned ? '取消置顶' : '置顶'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'important',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.star_outline_rounded,
                              size: 18,
                            ),
                            title: Text(r.important ? '取消重要标注' : '标注重要'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (r.subplans.isNotEmpty) ...[
              const Divider(height: UtenSpacing.s16),
              InkWell(
                borderRadius: UtenRadius.mdAll,
                onTap: () => setState(
                  () => expanded
                      ? _expanded.remove(r.planId)
                      : _expanded.add(r.planId),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
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
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
    );
  }

  Widget _subplanRow(ThemeData theme, SubPlanProgress s) {
    final pct = s.percent.clamp(0.0, 1.0);
    final done = s.closed || pct >= 1.0;
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => _openPlanDetail(s.planId),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: UtenSpacing.s4,
          horizontal: UtenSpacing.s8,
        ),
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
                    Text(
                      s.workshopName!,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              '${_fmt(s.inboundQty)} / ${_fmt(s.totalQty)}',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            _miniStatus(theme, s, done),
            const SizedBox(width: UtenSpacing.s4),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPlanDetail(String rawPlanId) async {
    final planId = rawPlanId.trim();
    if (planId.isEmpty) {
      context.appError('生产计划链接异常，请刷新后重试', force: true);
      return;
    }
    try {
      await context.push(RoutePath.productionPlanDetail(planId));
    } catch (_) {
      if (mounted) context.appError('无法打开生产计划，请刷新后重试', force: true);
    }
  }

  Widget _statusChip(
    ThemeData theme,
    PlanProgressRow r,
    bool done, {
    bool overdue = false,
  }) {
    final (label, color) = done
        ? ('已完成 ✓', Colors.green)
        : overdue
        ? ('已逾期', theme.colorScheme.error)
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
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _meta(
    ThemeData theme,
    IconData icon,
    String text, {
    Color? color,
    bool bold = false,
  }) {
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: c),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: c,
            fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  String _fmt(double? v) => v == null
      ? '—'
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
}
