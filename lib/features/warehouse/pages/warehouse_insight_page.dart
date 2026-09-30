// 库存分析页 (ADR-135 §6.4, review/product.md §1.6; /warehouse/insights, stock_report:view)。
//
// 顶部 KPI 卡 (点一下跳到对应分段并带上筛选): 呆滞品项 / 库龄超180天 / 今日建议盘点 /
// 近30天称重异常 / 待称样货品。下面四个分段 (视图切换, 始终选中一个):
// 1. 呆滞与库龄: 库龄 (先进先出分层) + 周转 + ABC 合在一张表, 服务端分页/排序/合计;
//    筛选 仅呆滞 / 库龄>180天 / A B C; 双击行 (或右键「查看流水」) 进库存详情的出入库流水。
// 2. 盘点建议: 勾选 → 「生成盘点单」。一张盘点单只盘一个仓: 勾了几个仓就先问先盘哪个,
//    带着这些货品打开新建盘点单页 (只预填、不落库; 实盘由仓管现场填), 其余仓的勾选保留。
// 3. 称重异常: 来料少数 / 领料超发 / 退料不符 / 盘点差异 / 单重可能变化;
//    可切「按往来方汇总」(供应商来料少数 + 车间领料超发)。
// 4. 单重学习: 上线批量称样的可编辑表 (抽样数量 + 抽样重量 → 保存 = 一条称样记录, 立即重算);
//    筛选 需称样 (默认: 有动态但单重未学准) / 与设计单重不符 / 仅按领料推算 / 全部。
// 仓库范围沿用仓库任务中心的「仓库范围」(我的仓库 / 全部仓库 / 某个仓, 按账号记忆),
// 只影响按仓统计的两段 (呆滞与库龄、盘点建议); 称重异常与单重学习是货品级口径。
// 数字全部由服务端算好 (合计也是服务端算), 本页不做加法; 重量按用户显示单位换算,
// 估算带「≈」, 没称显示「未称」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_sample_dialog.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/stock_ledger/stock_ledger_models.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_total.dart';
import '../models/stock_check_prefill.dart';
import '../models/stock_doc.dart';
import '../models/warehouse_insight.dart';
import '../repositories/warehouse_insight_repository.dart';
import '../widgets/warehouse_insight_tables.dart';
import '../widgets/warehouse_scope_selector.dart';

class WarehouseInsightPage extends ConsumerStatefulWidget {
  const WarehouseInsightPage({super.key, this.initialSegment});

  /// ?segment= 深链: health | cycle-count | weight-alerts | learning。
  final String? initialSegment;

  @override
  ConsumerState<WarehouseInsightPage> createState() =>
      _WarehouseInsightPageState();
}

class _WarehouseInsightPageState extends ConsumerState<WarehouseInsightPage> {
  late WarehouseInsightSegment _segment;
  final _search = TextEditingController();
  String _keyword = '';
  final _openedAt = DateTime.now().microsecondsSinceEpoch;

  // —— 呆滞与库龄 (同一请求带回顶部 KPI 概览) ——
  final _healthRequests = LatestRequestGuard();
  InsightHealthResult? _health;
  bool _healthLoading = false;
  String? _healthError;
  String? _healthLoadedKey;
  bool _onlyDead = false;
  bool _agedOver180 = false;
  String? _abc;
  String? _healthSort;
  bool _healthAsc = true;

  // —— 盘点建议 ——
  final _cycleRequests = LatestRequestGuard();
  PagedResult<InsightCycleCountRow>? _cycle;
  bool _cycleLoading = false;
  String? _cycleError;
  String? _cycleLoadedKey;
  Set<String> _cycleSelected = {};
  final Map<String, InsightCycleCountRow> _cycleSelectedRows = {};

  // —— 称重异常 ——
  final _alertRequests = LatestRequestGuard();
  InsightWeightAlertsResult? _alerts;
  bool _alertsLoading = false;
  String? _alertsError;
  String? _alertsLoadedKey;
  int _alertDays = 30;
  bool _groupByCounterpart = false;

  // —— 单重学习 ——
  final _learningRequests = LatestRequestGuard();
  PagedResult<InsightLearningRow>? _learning;
  bool _learningLoading = false;
  String? _learningError;
  String? _learningLoadedKey;
  InsightLearningFilter _learningFilter = InsightLearningFilter.needsSample;
  final Map<String, InsightSampleDraft> _drafts = {};

  /// 称样保存后服务端刷新的行 (翻页/切段回来仍显示新单重, 重新拉取后以服务端为准)。
  final Map<String, InsightLearningRow> _learningUpdates = {};

  @override
  void initState() {
    super.initState();
    _segment =
        WarehouseInsightSegment.parse(widget.initialSegment) ??
        WarehouseInsightSegment.health;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadHealth(1);
      _loadCycle(1);
      _ensureLoaded(_segment);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    for (final d in _drafts.values) {
      d.dispose();
    }
    super.dispose();
  }

  WarehouseInsightRepository get _repo =>
      ref.read(warehouseInsightRepositoryProvider);

  WarehouseTaskScope get _scope => ref.read(warehouseTaskScopeProvider);

  String get _scopeKey => '${_scope.mode.name}|${_scope.warehouseId ?? ''}';

  String get _healthKey =>
      '$_scopeKey|$_keyword|$_abc|$_onlyDead|$_agedOver180|$_healthSort|$_healthAsc';

  String get _cycleKey => _scopeKey;

  String get _alertsKey => '$_alertDays';

  String get _learningKey => '${_learningFilter.code}|$_keyword';

  String _errorText(Object e) => e is ApiException ? e.message : '加载失败, 请重试';

  // ---- 取数 ----

  Future<void> _loadHealth(int page) async {
    final generation = _healthRequests.begin();
    final key = _healthKey;
    setState(() {
      _healthLoading = true;
      _healthError = null;
    });
    try {
      final r = await _repo.health(
        scope: _scope,
        page: page,
        keyword: _keyword,
        abc: _abc,
        onlyDead: _onlyDead,
        agedOver180: _agedOver180,
        sort: _healthSort,
        ascending: _healthAsc,
      );
      if (!mounted || !_healthRequests.isCurrent(generation)) return;
      setState(() {
        _health = r;
        _healthLoadedKey = key;
      });
    } catch (e) {
      if (!mounted || !_healthRequests.isCurrent(generation)) return;
      setState(() => _healthError = _errorText(e));
    } finally {
      if (mounted && _healthRequests.isCurrent(generation)) {
        setState(() => _healthLoading = false);
      }
    }
  }

  Future<void> _loadCycle(int page) async {
    final generation = _cycleRequests.begin();
    final key = _cycleKey;
    setState(() {
      _cycleLoading = true;
      _cycleError = null;
    });
    try {
      final r = await _repo.cycleCount(scope: _scope, page: page);
      if (!mounted || !_cycleRequests.isCurrent(generation)) return;
      setState(() {
        _cycle = r;
        _cycleLoadedKey = key;
      });
    } catch (e) {
      if (!mounted || !_cycleRequests.isCurrent(generation)) return;
      setState(() => _cycleError = _errorText(e));
    } finally {
      if (mounted && _cycleRequests.isCurrent(generation)) {
        setState(() => _cycleLoading = false);
      }
    }
  }

  Future<void> _loadAlerts(int page) async {
    final generation = _alertRequests.begin();
    final key = _alertsKey;
    setState(() {
      _alertsLoading = true;
      _alertsError = null;
    });
    try {
      final r = await _repo.weightAlerts(days: _alertDays, page: page);
      if (!mounted || !_alertRequests.isCurrent(generation)) return;
      setState(() {
        _alerts = r;
        _alertsLoadedKey = key;
      });
    } catch (e) {
      if (!mounted || !_alertRequests.isCurrent(generation)) return;
      setState(() => _alertsError = _errorText(e));
    } finally {
      if (mounted && _alertRequests.isCurrent(generation)) {
        setState(() => _alertsLoading = false);
      }
    }
  }

  Future<void> _loadLearning(int page) async {
    final generation = _learningRequests.begin();
    final key = _learningKey;
    setState(() {
      _learningLoading = true;
      _learningError = null;
    });
    try {
      final r = await _repo.learning(
        filter: _learningFilter,
        keyword: _keyword,
        page: page,
      );
      if (!mounted || !_learningRequests.isCurrent(generation)) return;
      setState(() {
        _learning = r;
        _learningLoadedKey = key;
        // 重新拉取后以服务端为准。
        for (final row in r.items) {
          _learningUpdates.remove(row.goodsId);
        }
      });
    } catch (e) {
      if (!mounted || !_learningRequests.isCurrent(generation)) return;
      setState(() => _learningError = _errorText(e));
    } finally {
      if (mounted && _learningRequests.isCurrent(generation)) {
        setState(() => _learningLoading = false);
      }
    }
  }

  /// 切到某段时: 查询条件变过 (或从没取过) 才重拉第 1 页。
  void _ensureLoaded(WarehouseInsightSegment segment) {
    switch (segment) {
      case WarehouseInsightSegment.health:
        if (_healthLoadedKey != _healthKey && !_healthLoading) _loadHealth(1);
      case WarehouseInsightSegment.cycleCount:
        if (_cycleLoadedKey != _cycleKey && !_cycleLoading) _loadCycle(1);
      case WarehouseInsightSegment.weightAlerts:
        if (_alertsLoadedKey != _alertsKey && !_alertsLoading) _loadAlerts(1);
      case WarehouseInsightSegment.learning:
        if (_learningLoadedKey != _learningKey && !_learningLoading) {
          _loadLearning(1);
        }
    }
  }

  /// 刷新: 概览 + 盘点建议 (KPI 要用) + 当前段, 都停在当前页。
  void _refresh() {
    _loadHealth(_health?.rows.page ?? 1);
    _loadCycle(_cycle?.page ?? 1);
    switch (_segment) {
      case WarehouseInsightSegment.weightAlerts:
        _loadAlerts(_alerts?.rows.page ?? 1);
      case WarehouseInsightSegment.learning:
        _loadLearning(_learning?.page ?? 1);
      case WarehouseInsightSegment.health:
      case WarehouseInsightSegment.cycleCount:
        break;
    }
  }

  void _select(WarehouseInsightSegment segment) {
    if (segment != _segment) setState(() => _segment = segment);
    _ensureLoaded(segment);
  }

  void _openHealth({bool onlyDead = false, bool agedOver180 = false}) {
    setState(() {
      _segment = WarehouseInsightSegment.health;
      _onlyDead = onlyDead;
      _agedOver180 = agedOver180;
    });
    _ensureLoaded(WarehouseInsightSegment.health);
  }

  void _openAlerts() {
    setState(() {
      _segment = WarehouseInsightSegment.weightAlerts;
      _alertDays = 30;
    });
    _ensureLoaded(WarehouseInsightSegment.weightAlerts);
  }

  void _openLearning(InsightLearningFilter filter) {
    setState(() {
      _segment = WarehouseInsightSegment.learning;
      _learningFilter = filter;
    });
    _ensureLoaded(WarehouseInsightSegment.learning);
  }

  void _onKeyword(String value) {
    final next = value.trim();
    if (next == _keyword) return;
    setState(() => _keyword = next);
    _ensureLoaded(_segment);
  }

  void _onScopeChanged() {
    setState(() {
      _cycleSelected = {};
      _cycleSelectedRows.clear();
    });
    _loadHealth(1);
    _loadCycle(1);
  }

  // ---- 跳转 ----

  bool _canOpen(String location) => locationAllowedFor(
    ref.read(currentPermissionsProvider),
    ref.read(isSuperAdminProvider),
    location,
  );

  /// 库存详情的路由守卫与具体货品无关 (stock:view), 任取一个货品路径判定即可。
  bool get _canOpenStockItem => _canOpen(RouteName.stockItemDetail('goods'));

  void _openStockItem(String goodsId, String tab) {
    final path = RouteName.stockItemDetail(goodsId, tab: tab);
    if (!_canOpen(path)) {
      context.appWarning('没有库存查看权限, 打不开库存详情');
      return;
    }
    context.push(path);
  }

  Widget _billCell(BuildContext context, InsightWeightAlertRow row) {
    final label = row.billNo ?? '—';
    // 称重记录与出入库流水同一套来源单据路由 (认不出的类型不给链接)。
    final path = stockSourceDocPath(
      sourceDocType: row.sourceDocType,
      sourceDocId: row.sourceDocId,
      sourceDocCode: row.sourceDocCode,
    );
    if (path == null || row.billNo == null || !_canOpen(path)) {
      return Text(label);
    }
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('insight-alert-bill-${row.id}'),
      onTap: () => context.push(path),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        ),
      ),
    );
  }

  // ---- 盘点建议: 生成盘点单 ----

  void _setCycleSelected(Set<String> next) {
    final onPage = <String, InsightCycleCountRow>{
      for (final r in _cycle?.items ?? const <InsightCycleCountRow>[])
        r.rowKey: r,
    };
    setState(() {
      _cycleSelected = next;
      _cycleSelectedRows.removeWhere((key, _) => !next.contains(key));
      for (final id in next) {
        final row = onPage[id];
        if (row != null) _cycleSelectedRows[id] = row;
      }
    });
  }

  Future<void> _generateCheck() async {
    final rows = _cycleSelectedRows.values.toList(growable: false);
    if (rows.isEmpty) {
      context.appWarning('请先勾选要盘点的货品');
      return;
    }
    final byWarehouse = <String, List<InsightCycleCountRow>>{};
    for (final row in rows) {
      byWarehouse.putIfAbsent(row.warehouseId, () => []).add(row);
    }
    final warehouseId = byWarehouse.length == 1
        ? byWarehouse.keys.first
        : await _askWarehouse(byWarehouse);
    if (warehouseId == null || !mounted) return;
    final picked = byWarehouse[warehouseId]!;
    final seen = <String>{};
    final lines = [
      for (final row in picked)
        if (seen.add('${row.goodsId}|${row.colorId ?? ''}'))
          StockCheckPrefillLine(goodsId: row.goodsId, colorId: row.colorId),
    ];
    final remaining = byWarehouse.length - 1;
    // 已带走的这个仓从勾选里去掉; 其余仓保留, 回来接着生成。
    setState(() {
      for (final row in picked) {
        _cycleSelectedRows.remove(row.rowKey);
      }
      _cycleSelected = _cycleSelected
          .where(_cycleSelectedRows.containsKey)
          .toSet();
    });
    if (remaining > 0) {
      context.appInfo('还有 $remaining 个仓库的勾选保留着, 这张盘完回来接着生成');
    }
    await context.push(
      RoutePath.stockDocNew(StockDocType.check.code),
      extra: StockCheckPrefill(warehouseId: warehouseId, lines: lines),
    );
  }

  Future<String?> _askWarehouse(
    Map<String, List<InsightCycleCountRow>> byWarehouse,
  ) => showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('先为哪个仓库生成盘点单?'),
      // 定宽: AlertDialog 会量内容的固有宽度, 定宽后不必逐个量仓库行。
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('一张盘点单只盘一个仓库。先选一个仓, 其余仓库的勾选会保留, 回来后接着生成。'),
              const SizedBox(height: UtenSpacing.s8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in byWarehouse.entries)
                        ListTile(
                          key: ValueKey('insight-check-warehouse-${entry.key}'),
                          leading: const Icon(Icons.warehouse_outlined),
                          title: Text(
                            entry.value.first.warehouseName ?? '未命名仓库',
                          ),
                          subtitle: Text('${entry.value.length} 项'),
                          onTap: () =>
                              Navigator.of(dialogContext).pop(entry.key),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // 按钮整体居中 (全仓弹窗统一规范)。
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );

  // ---- 单重学习: 批量称样 ----

  InsightSampleDraft _draftOf(String goodsId) =>
      _drafts.putIfAbsent(goodsId, InsightSampleDraft.new);

  void _onSampleEdited(InsightLearningRow row) {
    final draft = _drafts[row.goodsId];
    if (draft == null || (draft.error == null && !draft.saved)) return;
    setState(() {
      draft.error = null;
      draft.saved = false;
    });
  }

  Future<void> _saveSample(InsightLearningRow row) async {
    final draft = _draftOf(row.goodsId);
    if (draft.saving) return;
    final sampleUnit = ref.read(warehouseWeightUnitsPrefsProvider).sample;
    final qtyText = draft.qty.text.trim();
    final qty = double.tryParse(qtyText);
    final weight = parseWithSuffix(draft.weight.text, sampleUnit);
    String? error;
    if (qty == null || qty <= 0) {
      error = '先填抽样数量';
    } else if (row.integerQty && qty != qty.roundToDouble()) {
      error = '按件计的抽样数量要填整数';
    } else if (weight == null || weight.value <= 0) {
      error = '重量格式不对, 如 46.2 或 46.2g';
    }
    if (error != null) {
      setState(() => draft.error = error);
      return;
    }
    setState(() {
      draft.saving = true;
      draft.error = null;
    });
    try {
      final detail = await ref
          .read(weightRepositoryProvider)
          .recordSample(
            row.goodsId,
            WeightSampleRequest(
              qty: qty!,
              weight: weight!.value,
              weightUnitCode: weight.unit.code,
              remark: '库存分析批量称样',
              idempotencyKey: businessIdempotencyKey(
                'weight-sample',
                '${row.goodsId}|$qtyText|${weight.numberText}|'
                    '${weight.unit.code}|$_openedAt|${draft.attempt}',
              ),
            ),
          );
      if (!mounted) return;
      final updated = _rowFromDetail(row, detail);
      setState(() {
        draft
          ..saving = false
          ..saved = true
          ..attempt += 1;
        draft.qty.clear();
        draft.weight.clear();
        _learningUpdates[row.goodsId] = updated;
      });
      context.appSuccess(
        '已保存「${row.name ?? row.code ?? ''}」的抽样, 当前单重 '
        '${formatUnitWeight(updated.unitWeightKg, unitName: row.unitName)} '
        '(${(updated.tier ?? WeightTier.red).label})',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        draft.saving = false;
        draft.error = e is ApiException ? e.message : '没保存成功, 请重试';
      });
    }
  }

  InsightLearningRow _rowFromDetail(
    InsightLearningRow row,
    GoodsWeightDetail detail,
  ) {
    final resolved = detail.resolved;
    final goodsRow = detail.goodsRow;
    return row.copyWith(
      basis: resolved?.basis.code,
      evidence: resolved?.evidence ?? goodsRow?.evidence,
      tier: resolved?.tier ?? goodsRow?.tier,
      unitWeightKg: resolved?.currentUnitWeightKg ?? goodsRow?.unitWeightKg,
      relHalfWidth: resolved?.relHalfWidth ?? goodsRow?.relHalfWidth,
      nInliers: resolved?.nInliers ?? goodsRow?.nInliers,
      lastObservedAt: goodsRow?.lastObservedAt ?? resolved?.lastObservedAt,
      suggestedSampleSize: resolved?.suggestedSampleSize,
      stale: resolved?.stale,
    );
  }

  /// 右键「称样校准…」: 完整的称样弹窗 (可选供应商、扣皮重、从本次起作为新批次)。
  Future<void> _openSampleDialog(InsightLearningRow row) async {
    final detail = await showWeightSampleDialog(
      context,
      goodsId: row.goodsId,
      goodsTitle: [
        row.name ?? '',
        row.code ?? '',
      ].where((s) => s.isNotEmpty).join(' '),
      baseUnitName: row.unitName,
      remark: '库存分析称样校准',
    );
    if (detail == null || !mounted) return;
    setState(() => _learningUpdates[row.goodsId] = _rowFromDetail(row, detail));
  }

  // ---- 界面 ----

  num? _oneDecimal(double? v) {
    if (v == null) return null;
    final r = (v * 10).round() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }

  Widget _kpis() {
    final o = _health?.overview;
    final receiptShort = o?.receiptShort30d;
    final drawOver = o?.drawOver30d;
    final items = <MetricFilterCardItem>[
      MetricFilterCardItem(
        key: 'dead',
        label: '呆滞品项 (≥90天无消耗)',
        value: o?.deadSku,
        tone: 'warning',
        icon: Icons.hourglass_bottom_rounded,
        selected: _segment == WarehouseInsightSegment.health && _onlyDead,
        onTap: () => _openHealth(onlyDead: true),
      ),
      MetricFilterCardItem(
        key: 'aged',
        label: '库龄超180天 (占库存数量%)',
        value: _oneDecimal(o?.aged180QtyPct),
        tone: 'attention',
        icon: Icons.history_toggle_off_rounded,
        selected: _segment == WarehouseInsightSegment.health && _agedOver180,
        onTap: () => _openHealth(agedOver180: true),
      ),
      MetricFilterCardItem(
        key: 'cycle',
        label: '今日建议盘点',
        value: _cycle?.total,
        tone: 'info',
        icon: Icons.fact_check_outlined,
        selected: _segment == WarehouseInsightSegment.cycleCount,
        onTap: () => _select(WarehouseInsightSegment.cycleCount),
      ),
      MetricFilterCardItem(
        key: 'alerts',
        label: '近30天称重异常',
        value: o?.alerts30d,
        description: receiptShort == null || drawOver == null
            ? null
            : '来料少数 $receiptShort / 领料超发 $drawOver',
        tone: 'error',
        icon: Icons.scale_outlined,
        selected: _segment == WarehouseInsightSegment.weightAlerts,
        onTap: _openAlerts,
      ),
      MetricFilterCardItem(
        key: 'sample',
        label: '待称样货品',
        value: o?.needsSample,
        tone: 'primary',
        icon: Icons.science_outlined,
        selected:
            _segment == WarehouseInsightSegment.learning &&
            _learningFilter == InsightLearningFilter.needsSample,
        onTap: () => _openLearning(InsightLearningFilter.needsSample),
      ),
    ];
    // 一行横排, 放不下左右滑 (手机上不把表格挤到屏幕外)。
    return SingleChildScrollView(
      key: const Key('insight-kpis'),
      scrollDirection: Axis.horizontal,
      child: MetricFilterCards(items: items, itemWidth: 210),
    );
  }

  Widget _countText(String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  Widget _trailing() {
    final children = <Widget>[];
    switch (_segment) {
      case WarehouseInsightSegment.health:
        children.addAll([
          FilterChip(
            key: const Key('insight-only-dead'),
            label: const Text('仅呆滞'),
            selected: _onlyDead,
            onSelected: (v) {
              setState(() => _onlyDead = v);
              _loadHealth(1);
            },
          ),
          FilterChip(
            key: const Key('insight-aged-180'),
            label: const Text('库龄>180天'),
            selected: _agedOver180,
            onSelected: (v) {
              setState(() => _agedOver180 = v);
              _loadHealth(1);
            },
          ),
          for (final abc in const ['A', 'B', 'C'])
            ChoiceChip(
              key: ValueKey('insight-abc-$abc'),
              label: Text(abc),
              selected: _abc == abc,
              onSelected: (v) {
                setState(() => _abc = v ? abc : null);
                _loadHealth(1);
              },
            ),
          _countText('共 ${_health?.rows.total ?? 0} 项'),
        ]);
      case WarehouseInsightSegment.cycleCount:
        children.addAll([
          _countText('每仓每天最多 20 条, 按优先级排'),
          _countText('共 ${_cycle?.total ?? 0} 项'),
        ]);
      case WarehouseInsightSegment.weightAlerts:
        children.addAll([
          for (final days in const [7, 30, 90])
            ChoiceChip(
              key: ValueKey('insight-alert-days-$days'),
              label: Text('近$days天'),
              selected: _alertDays == days,
              onSelected: (v) {
                if (!v || days == _alertDays) return;
                setState(() => _alertDays = days);
                _loadAlerts(1);
              },
            ),
          FilterChip(
            key: const Key('insight-group-by-counterpart'),
            label: const Text('按往来方汇总'),
            selected: _groupByCounterpart,
            onSelected: (v) => setState(() => _groupByCounterpart = v),
          ),
          _countText('共 ${_alerts?.rows.total ?? 0} 条'),
        ]);
      case WarehouseInsightSegment.learning:
        final coverage = _health?.overview.weighedCoveragePct;
        children.addAll([
          for (final filter in InsightLearningFilter.values)
            ChoiceChip(
              key: ValueKey('insight-learning-${filter.code}'),
              label: Text(filter.label),
              selected: _learningFilter == filter,
              onSelected: (v) {
                if (!v || filter == _learningFilter) return;
                setState(() => _learningFilter = filter);
                _loadLearning(1);
              },
            ),
          if (coverage != null)
            _countText(
              '称重覆盖率 ${formatMeasurementValue(coverage, scale: 1)}% (库存行重量为实称的占比)',
            ),
          _countText('共 ${_learning?.total ?? 0} 项'),
        ]);
    }
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  Widget _body(WeightUnitsPrefs units) => switch (_segment) {
    WarehouseInsightSegment.health => _healthTable(units.display),
    WarehouseInsightSegment.cycleCount => _cycleTable(units.display),
    WarehouseInsightSegment.weightAlerts =>
      _groupByCounterpart
          ? _counterpartTable(units.display)
          : _alertsTable(units.display),
    WarehouseInsightSegment.learning => _learningTable(units.sample),
  };

  Widget _healthTable(WeightDisplay display) {
    final rows = _health?.rows;
    final canOpenLedger = _canOpenStockItem;
    return MasterDataTableView<InsightHealthRow>(
      tableKey:
          'features.warehouse.pages.warehouse_insight_page.WarehouseInsightPageState._healthTable.1',
      key: const Key('insight-health-table'),
      // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
      primary: true,
      columns: insightHealthColumns(
        display: display,
        // 服务端只对持 goods:cost:view 的人下发金额 (costMasked = false)。
        showAmount: rows?.items.any((r) => !r.costMasked) ?? false,
      ),
      items: rows?.items ?? const [],
      rowKeyOf: (r) => r.rowKey,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      toolbarActions: const [WeightDisplayUnitButton()],
      sortColumn: _healthSort,
      sortAscending: _healthAsc,
      onSortChange: (column, ascending) {
        setState(() {
          _healthSort = column;
          _healthAsc = ascending;
        });
        _loadHealth(1);
      },
      onRowTap: canOpenLedger
          ? (r) => _openStockItem(r.goodsId, 'ledger')
          : null,
      rowMenuBuilder: (r) => [
        UtenMenuItem(
          label: '查看流水',
          icon: Icons.receipt_long_outlined,
          enabled: canOpenLedger,
          onTap: () => _openStockItem(r.goodsId, 'ledger'),
        ),
        UtenMenuItem(
          label: '查看单重学习',
          icon: Icons.scale_outlined,
          enabled: canOpenLedger,
          onTap: () => _openStockItem(r.goodsId, 'weight'),
        ),
      ],
      isLoading: _healthLoading && rows == null,
      loadingMore: _healthLoading && rows != null,
      error: _healthError,
      onRetry: () => _loadHealth(rows?.page ?? 1),
      emptyMessage: _onlyDead || _agedOver180 || _abc != null
          ? '当前筛选下没有货品'
          : '当前范围没有库存',
      summaryBar: reportTotalsBar(
        rows?.totals ?? const [],
        weightDisplay: display,
      ),
      currentPage: rows?.page ?? 1,
      totalPages: rows?.totalPages ?? 1,
      paginationScope: (_scope, _keyword, _abc, _onlyDead, _agedOver180),
      onPageChange: _loadHealth,
    );
  }

  Widget _cycleTable(WeightDisplay display) {
    final rows = _cycle;
    final checkPath = RoutePath.stockDocNew(StockDocType.check.code);
    final canCreateCheck = _canOpen(checkPath);
    return MasterDataTableView<InsightCycleCountRow>(
      tableKey:
          'features.warehouse.pages.warehouse_insight_page.WarehouseInsightPageState._cycleTable.1',
      key: const Key('insight-cycle-table'),
      primary: true,
      columns: insightCycleCountColumns(display: display),
      items: rows?.items ?? const [],
      selectable: true,
      idOf: (r) => r.rowKey,
      selectedIds: _cycleSelected,
      onSelectedIdsChanged: _setCycleSelected,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      toolbarActions: const [WeightDisplayUnitButton()],
      onRowTap: (r) => _openStockItem(r.goodsId, 'balance'),
      batchActionsBuilder: (context, selected) => [
        Tooltip(
          message: canCreateCheck
              ? '按仓库带着勾选的货品打开新建盘点单 (只预填, 实盘数量现场填)'
              : '没有新建盘点单的权限',
          child: UtenButton(
            key: const Key('insight-generate-check'),
            size: UtenButtonSize.large,
            icon: Icons.fact_check_outlined,
            onPressed: selected.isEmpty || !canCreateCheck
                ? null
                : _generateCheck,
            onDisabledTap: selected.isEmpty
                ? () => context.appWarning('请先勾选要盘点的货品')
                : null,
            child: Text(
              selected.isEmpty ? '生成盘点单' : '生成盘点单(${selected.length})',
            ),
          ),
        ),
      ],
      isLoading: _cycleLoading && rows == null,
      loadingMore: _cycleLoading && rows != null,
      error: _cycleError,
      onRetry: () => _loadCycle(rows?.page ?? 1),
      emptyMessage: '今天没有建议盘点的货品',
      currentPage: rows?.page ?? 1,
      totalPages: rows?.totalPages ?? 1,
      paginationScope: _scope,
      onPageChange: _loadCycle,
    );
  }

  Widget _alertsTable(WeightDisplay display) {
    final rows = _alerts?.rows;
    return MasterDataTableView<InsightWeightAlertRow>(
      tableKey:
          'features.warehouse.pages.warehouse_insight_page.WarehouseInsightPageState._alertsTable.1',
      key: const Key('insight-alerts-table'),
      primary: true,
      columns: insightWeightAlertColumns(billCell: _billCell),
      items: rows?.items ?? const [],
      rowKeyOf: (r) => r.id,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (r) => _openStockItem(r.goodsId, 'weight'),
      rowMenuBuilder: (r) => [
        UtenMenuItem(
          label: '查看单重学习',
          icon: Icons.scale_outlined,
          onTap: () => _openStockItem(r.goodsId, 'weight'),
        ),
        UtenMenuItem(
          label: '查看流水',
          icon: Icons.receipt_long_outlined,
          onTap: () => _openStockItem(r.goodsId, 'ledger'),
        ),
      ],
      isLoading: _alertsLoading && rows == null,
      loadingMore: _alertsLoading && rows != null,
      error: _alertsError,
      onRetry: () => _loadAlerts(rows?.page ?? 1),
      emptyMessage: '近$_alertDays天没有称重异常',
      currentPage: rows?.page ?? 1,
      totalPages: rows?.totalPages ?? 1,
      paginationScope: _alertDays,
      onPageChange: _loadAlerts,
    );
  }

  Widget _counterpartTable(WeightDisplay display) {
    final alerts = _alerts;
    return MasterDataTableView<InsightCounterpartSummary>(
      tableKey:
          'features.warehouse.pages.warehouse_insight_page.WarehouseInsightPageState._counterpartTable.1',
      key: const Key('insight-counterpart-table'),
      primary: true,
      columns: insightCounterpartColumns(display: display),
      items: [...?alerts?.supplierSummary, ...?alerts?.workshopSummary],
      rowKeyOf: (s) => s.rowKey,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      isLoading: _alertsLoading && alerts == null,
      error: _alertsError,
      onRetry: () => _loadAlerts(1),
      emptyMessage: '近$_alertDays天没有需要汇总的来料少数或领料超发',
    );
  }

  Widget _learningTable(WeightUnit sampleUnit) {
    final rows = _learning;
    final canSample = ref.watch(weightSampleAllowedProvider);
    final items = [
      for (final r in rows?.items ?? const <InsightLearningRow>[])
        _learningUpdates[r.goodsId] ?? r,
    ];
    return MasterDataTableView<InsightLearningRow>(
      tableKey:
          'features.warehouse.pages.warehouse_insight_page.WarehouseInsightPageState._learningTable.1',
      key: const Key('insight-learning-table'),
      // 2026-09-29 用户口径：学习表正由并行任务改（表格动态变化），本批只动
      // 页面布局（KPI/工具条进折叠头）；表内联动滚动留待该任务收口后再接。
      columns: insightLearningColumns(
        sampleUnit: sampleUnit,
        draftOf: _draftOf,
        canSample: canSample,
        onSave: _saveSample,
        onEdited: _onSampleEdited,
      ),
      items: items,
      rowKeyOf: (r) => r.goodsId,
      // 表内有输入框: 关掉表体文字框选, 免得拖选与输入打架。
      enableTextSelection: false,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (r) => _openStockItem(r.goodsId, 'weight'),
      rowMenuBuilder: (r) => [
        UtenMenuItem(
          label: '称样校准…',
          icon: Icons.science_outlined,
          enabled: canSample && r.learningEnabled,
          onTap: () => _openSampleDialog(r),
        ),
        UtenMenuItem(
          label: '查看单重学习',
          icon: Icons.scale_outlined,
          onTap: () => _openStockItem(r.goodsId, 'weight'),
        ),
      ],
      isLoading: _learningLoading && rows == null,
      loadingMore: _learningLoading && rows != null,
      error: _learningError,
      onRetry: () => _loadLearning(rows?.page ?? 1),
      emptyMessage: switch (_learningFilter) {
        InsightLearningFilter.needsSample => '没有待称样的货品, 单重都学得差不多了',
        InsightLearningFilter.masterMismatch => '学到的单重与货品资料设计单重都对得上',
        InsightLearningFilter.drawOnly => '没有只靠领料推算单重的货品',
        InsightLearningFilter.conflict => '没有称重记录互相矛盾的货品',
        InsightLearningFilter.all => '还没有任何单重学习记录',
      },
      currentPage: rows?.page ?? 1,
      totalPages: rows?.totalPages ?? 1,
      paginationScope: (_learningFilter, _keyword),
      onPageChange: _loadLearning,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 仓库范围变了 (含「我的仓库」加载完才定下来的默认范围): 按仓统计的两段重拉。
    ref.listen<WarehouseTaskScope>(warehouseTaskScopeProvider, (prev, next) {
      if (prev != next && mounted) _onScopeChanged();
    });
    // 返回即刷新: 从盘点单/库存详情回来时数字可能已变。
    ref.onPageResume(RouteName.warehouseInsights, _refresh);
    final units = ref.watch(warehouseWeightUnitsPrefsProvider);
    final searchable =
        _segment == WarehouseInsightSegment.health ||
        _segment == WarehouseInsightSegment.learning;
    return Scaffold(
      appBar: UtenAppBar(
        title: '库存分析',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          const WarehouseScopeSelector(),
          IconButton(
            key: const Key('insight-refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
          // 上滑先把 KPI 条+分段工具条收完、表格顶到屏顶再滚表内（全站联动口径）。
          child: UtenCollapsingHeaderScrollView(
            collapsingHeader: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _kpis(),
                const SizedBox(height: UtenSpacing.s12),
                UtenFilterToolbar<WarehouseInsightSegment>(
                  segmentsKey: const Key('insight-segments'),
                  segments: [
                    for (final s in WarehouseInsightSegment.values)
                      UtenFilterSegment(value: s, label: s.label),
                  ],
                  selected: {_segment},
                  onSelectionChanged: _select,
                  searchKey: const Key('insight-search'),
                  searchController: searchable ? _search : null,
                  searchHint: searchable ? '搜索货品名称/编号' : null,
                  onSearchChanged: _onKeyword,
                  onSearchSubmitted: _onKeyword,
                  trailing: _trailing(),
                ),
                const SizedBox(height: UtenSpacing.s8),
              ],
            ),
            body: _body(units),
          ),
        ),
      ),
    );
  }
}
