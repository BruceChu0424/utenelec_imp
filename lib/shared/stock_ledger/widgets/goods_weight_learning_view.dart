// 库存面板「单重学习」分段 (ADR-135 §6.3 / review/product.md §1.4)。
//
// - 顶部卡片: 当前单重 · 可靠度 · 依据 (称重学习 N 次(有效 M)) · 最近一次称重;
//   按钮「称样校准」(到货入库/仓库单据编辑/单重管理 任一权限) · 「设定单重」·
//   「从今天起重新学习」(单重管理 stock:weight:manage)。
// - 子分段: 称重记录 (排除/恢复需单重管理) | 各供应商 (需库存报表查看或单重管理) |
//   学习设置 (默认皮重 · 核对容差% · 单件离散% · 参与学习 · 批次切换 自动/手动, 需单重管理)。
// - 学到的单重只在仓库口径使用, 从不回写货品资料的「单重」。
// - 按重量计的货品 (基本单位就是重量单位) 不需要学习, 只显示说明。
import 'package:flutter/material.dart';
import '../../../components/layout/uten_segment_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../features/basic_data/models/master_facet.dart';
import '../../../features/basic_data/widgets/master_data_table_view.dart';
import '../../auth/permissions.dart';
import '../../measurement/weight_params.dart';
import '../../measurement/weight_predictor.dart';
import '../../measurement/weight_prefs.dart';
import '../../measurement/weight_unit.dart';
import '../../measurement/widgets/weight_sample_dialog.dart';
import '../../measurement/widgets/weight_text.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../models/paged_result.dart';
import '../stock_ledger_models.dart';

enum _LearningTab {
  records('称重记录'),
  suppliers('各供应商'),
  settings('学习设置');

  const _LearningTab(this.label);

  final String label;
}

class GoodsWeightLearningView extends ConsumerStatefulWidget {
  const GoodsWeightLearningView({
    super.key,
    required this.goodsId,
    required this.goodsTitle,
    this.unitName,
    this.reloadTick = 0,
    this.onChanged,
  });

  final String goodsId;

  /// 弹窗标题里的货品名 (名称 + 编号)。
  final String goodsTitle;

  /// 基本单位名 (单重显示「2.312 g/个」)。
  final String? unitName;
  final int reloadTick;

  /// 称样/设定单重等改动了单重后通知宿主 (刷新 KPI 条)。
  final VoidCallback? onChanged;

  @override
  ConsumerState<GoodsWeightLearningView> createState() =>
      _GoodsWeightLearningViewState();
}

class _GoodsWeightLearningViewState
    extends ConsumerState<GoodsWeightLearningView> {
  GoodsWeightDetail? _detail;
  bool _loading = false;
  String? _error;
  int _version = 0;

  _LearningTab _tab = _LearningTab.records;
  PagedResult<WeightObservation>? _records;
  bool _recordsLoading = false;
  String? _recordsError;
  int _recordsVersion = 0;
  String? _kindFilter;
  String? _stageFilter;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDetail();
      _loadRecords(1);
    });
  }

  @override
  void didUpdateWidget(covariant GoodsWeightLearningView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick ||
        oldWidget.goodsId != widget.goodsId) {
      _loadDetail();
      _loadRecords(_records?.page ?? 1);
    }
  }

  bool get _isAdmin => ref.read(isSuperAdminProvider);
  bool get _canManage => _isAdmin || ref.read(weightManageAllowedProvider);
  bool get _canSample => _isAdmin || ref.read(weightSampleAllowedProvider);
  bool get _canSeeSuppliers =>
      _canManage ||
      ref.read(currentPermissionsProvider).contains(Perm.stockReportView);

  WeightParams? get _resolved => _detail?.resolved;
  bool get _exact => _resolved?.isExact == true;
  bool get _learningEnabled => _detail?.profile?.learningEnabled ?? true;

  Future<void> _loadDetail() async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(weightRepositoryProvider)
          .goods(widget.goodsId);
      if (!mounted || version != _version) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || version != _version) return;
      setState(() {
        _error = e is ApiException ? e.message : '单重学习加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _loadRecords(int page) async {
    final version = ++_recordsVersion;
    setState(() {
      _recordsLoading = true;
      _recordsError = null;
    });
    try {
      final result = await ref
          .read(weightRepositoryProvider)
          .observations(
            widget.goodsId,
            page: page,
            kind: _kindFilter,
            stage: _stageFilter,
          );
      if (!mounted || version != _recordsVersion) return;
      setState(() {
        _records = result;
        _recordsLoading = false;
      });
    } catch (e) {
      if (!mounted || version != _recordsVersion) return;
      setState(() {
        _recordsError = e is ApiException ? e.message : '称重记录加载失败，请稍后重试';
        _recordsLoading = false;
      });
    }
  }

  /// 写操作后的统一收尾: 刷新卡片与记录, 通知宿主。
  Future<void> _afterChange({GoodsWeightDetail? detail}) async {
    if (!mounted) return;
    if (detail != null) {
      setState(() => _detail = detail);
    } else {
      await _loadDetail();
    }
    await _loadRecords(1);
    widget.onChanged?.call();
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    required String success,
    required String fallback,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      context.appSuccess(success);
      await _afterChange();
    } catch (e) {
      if (!mounted) return;
      context.appApiError(e, fallback: fallback);
      // 版本冲突/已被他人改过: 重新取一次最新状态。
      await _loadDetail();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sample() async {
    final detail = _detail;
    final result = await showWeightSampleDialog(
      context,
      goodsId: widget.goodsId,
      goodsTitle: widget.goodsTitle,
      baseUnitName: widget.unitName,
      params: _resolved,
      supplierOptions: [
        for (final row
            in detail?.supplierRows ?? const <GoodsWeightEstimateRow>[])
          if (row.supplierId != null && (row.supplierName ?? '').isNotEmpty)
            WeightSupplierOption(id: row.supplierId!, name: row.supplierName!),
      ],
    );
    if (result == null || !mounted) return;
    context.appSuccess('称样已记录, 单重已重新计算');
    await _afterChange(detail: result);
  }

  Future<void> _setManual() async {
    final profile = _detail?.profile;
    final result = await showDialog<_ManualUnitWeight>(
      context: context,
      builder: (_) => _ManualUnitWeightDialog(
        goodsTitle: widget.goodsTitle,
        unitName: widget.unitName,
        currentKg: profile?.manualUnitWeightKg,
        currentReason: profile?.manualReason,
        learnedKg: _detail?.goodsRow?.unitWeightKg,
      ),
    );
    if (result == null || !mounted) return;
    final update = WeightProfileUpdate.from(profile);
    await _runBusy(
      () => ref
          .read(weightRepositoryProvider)
          .updateProfile(
            widget.goodsId,
            result.clear
                ? update.copyWith(clearManual: true)
                : update.copyWith(
                    manualUnitWeightKg: result.kgPerUnit,
                    manualReason: result.reason,
                  ),
          ),
      success: result.clear ? '已取消人工单重, 改用称重学习结果' : '单重已设定',
      fallback: '设定单重失败，请刷新后重试',
    );
  }

  Future<void> _resetRegime() async {
    final ok = await UtenDialog.show(
      context,
      title: '从今天起重新学习',
      content: const Text(
        '以今天为新批次的起点: 之前的称重记录保留可查, 但不再参与当前单重。'
        '适合换了供应商、换了原料或模具之后使用。确定吗?',
      ),
      confirmLabel: '重新学习',
    );
    if (ok != true || !mounted) return;
    await _runBusy(
      () => ref.read(weightRepositoryProvider).resetRegime(widget.goodsId),
      success: '已从今天起重新学习单重',
      fallback: '操作失败，请稍后重试',
    );
  }

  Future<void> _exclude(WeightObservation obs) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ExcludeReasonDialog(),
    );
    if (reason == null || !mounted) return;
    await _runBusy(
      () =>
          ref.read(weightRepositoryProvider).excludeObservation(obs.id, reason),
      success: '已排除这条称重记录',
      fallback: '排除失败，请稍后重试',
    );
  }

  Future<void> _include(WeightObservation obs) => _runBusy(
    () => ref.read(weightRepositoryProvider).includeObservation(obs.id),
    success: '已恢复这条称重记录',
    fallback: '恢复失败，请稍后重试',
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(weightManageAllowedProvider);
    ref.watch(weightSampleAllowedProvider);
    final theme = Theme.of(context);
    if (_detail == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '单重学习加载失败'),
            const SizedBox(height: UtenSpacing.s12),
            UtenButton(
              icon: Icons.refresh_rounded,
              onPressed: _loadDetail,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final tabs = <_LearningTab>[
      _LearningTab.records,
      if (_canSeeSuppliers) _LearningTab.suppliers,
      if (_canManage) _LearningTab.settings,
    ];
    final tab = tabs.contains(_tab) ? _tab : _LearningTab.records;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(theme),
        const SizedBox(height: UtenSpacing.s12),
        UtenFilterToolbar<_LearningTab>(
          segmentsKey: const Key('goods-weight-learning-tabs'),
          segments: [
            for (final t in tabs) UtenFilterSegment(value: t, label: t.label),
          ],
          selected: {tab},
          onSelectionChanged: (t) => setState(() => _tab = t),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: switch (tab) {
            _LearningTab.records => _recordsTable(theme),
            _LearningTab.suppliers => _suppliersTable(),
            _LearningTab.settings => _SettingsForm(
              key: ValueKey(
                'weight-settings-${_detail?.profile?.version ?? 0}',
              ),
              profile: _detail?.profile,
              busy: _busy,
              onSave: (update) => _runBusy(
                () => ref
                    .read(weightRepositoryProvider)
                    .updateProfile(widget.goodsId, update),
                success: '学习设置已保存',
                fallback: '保存失败, 设置可能已被他人修改, 已刷新',
              ),
            ),
          },
        ),
      ],
    );
  }

  Widget _card(ThemeData theme) {
    final detail = _detail!;
    final resolved = _resolved;
    final row = detail.goodsRow;
    final current = resolved?.currentUnitWeightKg;
    final basisLine = _basisLine(detail);
    final notices = <String>[
      if (!_learningEnabled) '本货品已停止参与学习, 称重记录只保留不计算。',
      if (detail.regimeChangedAt != null)
        '单重可能已变化 (换批/换料?) - ${_monthDay(detail.regimeChangedAt)} 起的称重明显不同, 建议称样确认。',
      if ((resolved?.manualConflictPct ?? 0).abs() >= 5)
        '人工设定的单重与称重学习相差 ${formatSignedPct(resolved!.manualConflictPct!)}, 请核对。',
      if (resolved?.conflict == true) '最近两次称重互相矛盾, 暂时给不出单重, 请称样确认。',
    ];
    final drawBias = detail.drawBiasPct ?? row?.drawBiasPct;
    return Container(
      key: const ValueKey('goods-weight-learning-card'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _exact
                    ? '按重量计 (1 ${widget.unitName ?? '基本单位'} = '
                          '${formatWeight(resolved?.massFactorKg)})'
                    : '当前单重 ${formatUnitWeight(current, unitName: widget.unitName)}',
                key: const ValueKey('goods-weight-current'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!_exact &&
                  resolved != null &&
                  resolved.basis != WeightBasis.none)
                WeightTierBadge(tier: resolved.effectiveTier),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            basisLine,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (drawBias != null && drawBias.abs() >= 0.1 && !_exact)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s4),
              child: Text(
                '领料实发比应发 ${formatSignedPct(drawBias)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final notice in notices)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: UtenInlineNotice(
                level: UtenInlineNoticeLevel.warning,
                message: notice,
              ),
            ),
          if (!_exact) ...[
            const SizedBox(height: UtenSpacing.s12),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (_canSample)
                  UtenButton(
                    key: const ValueKey('goods-weight-sample'),
                    icon: Icons.scale_outlined,
                    onPressed: _busy || !_learningEnabled ? null : _sample,
                    child: const Text('称样校准'),
                  ),
                if (_canManage) ...[
                  UtenButton(
                    key: const ValueKey('goods-weight-set-manual'),
                    type: UtenButtonType.secondary,
                    icon: Icons.edit_outlined,
                    onPressed: _busy ? null : _setManual,
                    child: const Text('设定单重'),
                  ),
                  UtenButton(
                    key: const ValueKey('goods-weight-reset-regime'),
                    type: UtenButtonType.ghost,
                    icon: Icons.restart_alt_rounded,
                    onPressed: _busy ? null : _resetRegime,
                    child: const Text('从今天起重新学习'),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _basisLine(GoodsWeightDetail detail) {
    final resolved = detail.resolved;
    final row = detail.goodsRow;
    final last = _monthDay(row?.lastObservedAt ?? resolved?.lastObservedAt);
    String withLast(String text) => last == null ? text : '$text · 最近 $last';
    switch (resolved?.basis ?? WeightBasis.none) {
      case WeightBasis.exact:
        return '基本单位就是重量单位, 重量按数量精确换算, 不需要学习单重。';
      case WeightBasis.manual:
        final profile = detail.profile;
        return [
          '依据 人工设定',
          if ((profile?.manualSetByName ?? '').isNotEmpty)
            profile!.manualSetByName!,
          if ((profile?.manualReason ?? '').isNotEmpty)
            '原因: ${profile!.manualReason}',
        ].join(' · ');
      case WeightBasis.learned:
        if (resolved!.drawOnly) {
          return withLast('依据 按过往领料推算 (领料 ${row?.nDraw ?? 0} 次)');
        }
        final total = row?.nObs ?? resolved.nInliers;
        final valid = row?.nInliers ?? resolved.nInliers;
        final stale = resolved.stale ? ' · 超过一年没称过' : '';
        return withLast('依据 称重学习 ${total ?? 0} 次(有效${valid ?? 0})$stale');
      case WeightBasis.masterPrior:
        return '依据 货品资料的设计单重 (还没称重核实, 未学准)';
      case WeightBasis.none:
        return '还没有称重记录: 到货、盘点时称一下, 或点「称样校准」数一小把称重。';
    }
  }

  Widget _recordsTable(ThemeData theme) {
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final rows = _records?.items ?? const <WeightObservation>[];
    return MasterDataTableView<WeightObservation>(
      tableKey:
          'shared.stock_ledger.widgets.goods_weight_learning_view.GoodsWeightLearningViewState._recordsTable.1',
      key: const Key('goods-weight-records-table'),
      // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
      primary: true,
      columns: _recordColumns(theme, display),
      items: rows,
      rowKeyOf: (o) => o.id,
      facets: {
        'kind': [
          for (final kind in WeightSourceKind.values)
            MasterFacetBucket(
              value: kind.code,
              label: weightObservationKindLabel(kind.code),
              count: 0,
            ),
        ],
        'status': const [
          MasterFacetBucket(value: 'ACTIVE', label: '有效', count: 0),
          MasterFacetBucket(value: 'EXCLUDED', label: '已排除', count: 0),
          MasterFacetBucket(value: 'REVERSED', label: '已红冲', count: 0),
        ],
      },
      nullCounts: const {},
      filters: {
        if (_kindFilter != null) 'kind': _kindFilter,
        if (_stageFilter != null) 'status': _stageFilter,
      },
      onFilterChanged: (key, value) {
        setState(() {
          if (key == 'kind') _kindFilter = value;
          if (key == 'status') _stageFilter = value;
        });
        _loadRecords(1);
      },
      onRowTap: (o) {
        final path = stockSourceDocPath(
          sourceDocType: o.sourceDocType,
          sourceDocId: o.sourceDocId,
          sourceDocCode: o.sourceDocCode,
        );
        if (path != null && !o.sourceGone) context.push(path);
      },
      canOpenRow: (o) =>
          !o.sourceGone &&
          stockSourceDocPath(
                sourceDocType: o.sourceDocType,
                sourceDocId: o.sourceDocId,
                sourceDocCode: o.sourceDocCode,
              ) !=
              null,
      isLoading: _recordsLoading && _records == null,
      loadingMore: _recordsLoading && _records != null,
      error: rows.isEmpty ? _recordsError : null,
      onRetry: () => _loadRecords(1),
      emptyMessage: '还没有称重记录',
      currentPage: _records?.page ?? 1,
      totalPages: _records?.totalPages ?? 1,
      paginationScope: (widget.goodsId, _kindFilter, _stageFilter),
      onPageChange: _loadRecords,
    );
  }

  List<MasterColumnDef<WeightObservation>> _recordColumns(
    ThemeData theme,
    WeightDisplay display,
  ) {
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final integer = _resolved?.integerQty ?? true;
    return [
      MasterColumnDef(
        key: 'observedAt',
        label: '日期',
        width: 130,
        type: 'date',
        value: (o) => o.observedAt == null
            ? ''
            : ChinaDateTime.formatInstant(o.observedAt!),
      ),
      MasterColumnDef(
        key: 'kind',
        label: '来源',
        width: 96,
        value: (o) => weightObservationKindLabel(o.sourceKind),
      ),
      MasterColumnDef(
        key: 'billNo',
        label: '单号',
        width: 150,
        value: (o) => o.sourceGone ? '来源单据已清空' : (o.billNo ?? ''),
        cellBuilder: (_, o) =>
            o.sourceGone ? Text('来源单据已清空', style: muted) : Text(o.billNo ?? ''),
      ),
      MasterColumnDef(
        key: 'party',
        label: '供应商/车间',
        width: 140,
        value: (o) => o.supplierName ?? o.counterpartName ?? '',
      ),
      MasterColumnDef(
        key: 'qty',
        label: '数量',
        width: 100,
        type: 'number',
        value: (o) => formatWeighQty(o.qtyBase, integer: integer),
      ),
      MasterColumnDef(
        key: 'weight',
        label: '重量',
        width: 110,
        type: 'weight',
        value: (o) => formatWeight(o.weightKg, display: display),
      ),
      MasterColumnDef(
        key: 'unitWeight',
        label: '单重',
        width: 110,
        value: (o) => formatUnitWeight(o.unitWeightKg),
      ),
      MasterColumnDef(
        key: 'deviation',
        label: '偏差',
        width: 90,
        value: (o) =>
            o.deviationPct == null ? '' : formatSignedPct(o.deviationPct!),
        cellBuilder: (_, o) {
          final pct = o.deviationPct;
          if (pct == null) return const Text('');
          final color = weightAlertColor(theme, o.alertLevel);
          return Text(
            formatSignedPct(pct),
            style: color == null ? null : TextStyle(color: color),
          );
        },
      ),
      MasterColumnDef(
        key: 'recordedBy',
        label: '称重人',
        width: 90,
        value: (o) => o.recordedByName ?? '',
      ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 90,
        value: weightObservationStatusLabel,
        cellBuilder: (_, o) {
          final label = weightObservationStatusLabel(o);
          final reason = weightObservationExcludedReasonLabel(o.excludedReason);
          final text = Text(label, style: label == '正常' ? null : muted);
          return reason.isEmpty ? text : Tooltip(message: reason, child: text);
        },
      ),
      if (_canManage)
        MasterColumnDef(
          key: 'actions',
          label: '操作',
          width: 80,
          value: (_) => '',
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, o) {
            if (o.reversed) return const SizedBox.shrink();
            return TextButton(
              key: ValueKey('weight-observation-toggle-${o.id}'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _busy
                  ? null
                  : () => o.excluded ? _include(o) : _exclude(o),
              child: Text(o.excluded ? '恢复' : '排除'),
            );
          },
        ),
    ];
  }

  Widget _suppliersTable() {
    final rows = _detail?.supplierRows ?? const <GoodsWeightEstimateRow>[];
    return MasterDataTableView<GoodsWeightEstimateRow>(
      tableKey:
          'shared.stock_ledger.widgets.goods_weight_learning_view.GoodsWeightLearningViewState._suppliersTable.1',
      key: const Key('goods-weight-suppliers-table'),
      // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
      primary: true,
      columns: [
        MasterColumnDef(
          key: 'supplier',
          label: '供应商',
          width: 200,
          value: (r) => r.supplierName ?? '—',
        ),
        MasterColumnDef(
          key: 'unitWeight',
          label: '单重',
          width: 120,
          value: (r) =>
              formatUnitWeight(r.unitWeightKg, unitName: widget.unitName),
        ),
        MasterColumnDef(
          key: 'diff',
          label: '与总体差异',
          width: 110,
          value: (r) => r.diffPct == null ? '' : formatSignedPct(r.diffPct!),
        ),
        MasterColumnDef(
          key: 'nRef',
          label: '抽样次数',
          width: 90,
          type: 'number',
          value: (r) => r.nRef == null ? '' : '${r.nRef}',
        ),
        MasterColumnDef(
          key: 'last',
          label: '最近',
          width: 100,
          value: (r) => _monthDay(r.lastObservedAt) ?? '',
        ),
        MasterColumnDef(
          key: 'tier',
          label: '可靠度',
          width: 90,
          value: (r) => r.tier?.label ?? '',
          // 2026-09-27 用户口径「格内胶囊改单元格背景色」：档位色铺整格。
          cellColor: (context, r) => r.tier == null
              ? null
              : udenStatusBadgeCellColor(context, weightTierBadgeType(r.tier!)),
        ),
      ],
      items: rows,
      rowKeyOf: (r) => r.supplierId,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      emptyMessage: '还没有按供应商分开的单重 (供应商称样后出现)',
    );
  }
}

/// 称重记录来源 -> 中文。
String weightObservationKindLabel(String? kind) =>
    switch (kind?.trim().toUpperCase()) {
      'SAMPLE' => '称样',
      'COUNT' => '盘点',
      'RECEIPT' => '到货',
      'FINISHED' => '产成品',
      'OTHER_IN' => '其它入库',
      'DRAW' => '领料',
      'ISSUE' => '委外发料',
      'SHIPMENT' => '销售出库',
      'RETURN' => '退料',
      'OTHER_OUT' => '其它出库',
      'TRANSFER' => '调拨',
      _ => kind ?? '',
    };

/// 称重记录状态 (服务端 status): 已红冲 / 已排除 / 离群 / 正常。
String weightObservationStatusLabel(WeightObservation o) =>
    switch (o.status.toUpperCase()) {
      'REVERSED' => '已红冲',
      'EXCLUDED' => '已排除',
      'OUTLIER' => '离群',
      _ => '正常',
    };

/// 排除原因说明 (悬停)。
String weightObservationExcludedReasonLabel(String? reason) =>
    switch (reason?.trim().toUpperCase()) {
      'MANUAL_EXCLUDE' => '人工排除',
      'ECHO' => '重量与系统估算完全一样 (照抄了估算), 不参与学习',
      'QTY_ECHO' => '数量正好等于按称重折算的件数 (不是独立点数), 不参与学习',
      _ => '',
    };

String? _monthDay(DateTime? value) {
  if (value == null) return null;
  final wall = ChinaDateTime.fromInstant(value);
  return '${wall.month.toString().padLeft(2, '0')}-'
      '${wall.day.toString().padLeft(2, '0')}';
}

/// 设定单重弹窗结果 ([clear] = 取消人工单重)。
class _ManualUnitWeight {
  const _ManualUnitWeight({this.kgPerUnit, this.reason, this.clear = false});

  final double? kgPerUnit;
  final String? reason;
  final bool clear;
}

class _ManualUnitWeightDialog extends StatefulWidget {
  const _ManualUnitWeightDialog({
    required this.goodsTitle,
    required this.unitName,
    required this.currentKg,
    required this.currentReason,
    required this.learnedKg,
  });

  final String goodsTitle;
  final String? unitName;
  final double? currentKg;
  final String? currentReason;
  final double? learnedKg;

  @override
  State<_ManualUnitWeightDialog> createState() =>
      _ManualUnitWeightDialogState();
}

class _ManualUnitWeightDialogState extends State<_ManualUnitWeightDialog> {
  late final TextEditingController _value;
  late final TextEditingController _reason;

  /// 单重单位: 克或千克 (每个基本单位)。
  late WeightUnit _unit;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = widget.currentKg;
    _unit = current != null && current >= 1 ? WeightUnit.kg : WeightUnit.g;
    _value = TextEditingController(
      text: current == null ? '' : _plain(_unit.fromKg(current)),
    );
    _reason = TextEditingController(text: widget.currentReason ?? '');
  }

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  static String _plain(double v) =>
      NumberFormat('0.########', 'en_US').format(v);

  void _save() {
    final value = double.tryParse(_value.text.trim());
    final reason = _reason.text.trim();
    if (value == null || value <= 0) {
      setState(() => _error = '请填写大于 0 的单重');
      return;
    }
    if (reason.length < 2) {
      setState(() => _error = '请写明设定原因 (至少 2 个字)');
      return;
    }
    final kg = (_unit.toKg(value) * 1e12).roundToDouble() / 1e12;
    Navigator.of(context).pop(_ManualUnitWeight(kgPerUnit: kg, reason: reason));
  }

  @override
  Widget build(BuildContext context) {
    final unitName = widget.unitName ?? '基本单位';
    return AlertDialog(
      title: Text('设定单重 · ${widget.goodsTitle}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '人工设定的单重优先于称重学习, 只在仓库称重核对与估算里使用, 不改货品资料。'
              '${widget.learnedKg == null ? '' : ' 称重学习当前为 ${formatUnitWeight(widget.learnedKg, unitName: widget.unitName)}。'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('manual-unit-weight-value'),
                    controller: _value,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: '每$unitName重'),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                DropdownButton<WeightUnit>(
                  key: const ValueKey('manual-unit-weight-unit'),
                  value: _unit,
                  items: const [
                    DropdownMenuItem(value: WeightUnit.g, child: Text('克')),
                    DropdownMenuItem(value: WeightUnit.kg, child: Text('千克')),
                  ],
                  onChanged: (u) => setState(() => _unit = u ?? _unit),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const ValueKey('manual-unit-weight-reason'),
              controller: _reason,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: '设定原因 *',
                hintText: '例如: 供应商图纸标注单重 2.3 g',
                counterText: '',
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (widget.currentKg != null)
          UtenButton(
            key: const ValueKey('manual-unit-weight-clear'),
            type: UtenButtonType.secondary,
            onPressed: () =>
                Navigator.of(context).pop(const _ManualUnitWeight(clear: true)),
            child: const Text('取消人工单重'),
          ),
        UtenButton(
          key: const ValueKey('manual-unit-weight-save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ExcludeReasonDialog extends StatefulWidget {
  const _ExcludeReasonDialog();

  @override
  State<_ExcludeReasonDialog> createState() => _ExcludeReasonDialogState();
}

class _ExcludeReasonDialogState extends State<_ExcludeReasonDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _confirm() {
    final reason = _reason.text.trim();
    if (reason.isNotEmpty && reason.length < 2) {
      setState(() => _error = '原因至少写 2 个字, 或者不写');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('排除这条称重记录'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('排除后这条记录不再参与单重学习, 随时可以恢复。'),
          const SizedBox(height: UtenSpacing.s12),
          TextField(
            key: const ValueKey('weight-exclude-reason'),
            controller: _reason,
            autofocus: true,
            maxLength: 200,
            decoration: UtenInputDecoration(
              InputDecoration(
                labelText: '原因 (可选)',
                hintText: '例如: 称的时候没扣托盘',
                counterText: '',
                error: utenFieldError(_error),
              ),
            ),
          ),
        ],
      ),
    ),
    actionsAlignment: MainAxisAlignment.center,
    actions: [
      UtenButton(
        type: UtenButtonType.ghost,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      UtenButton(
        key: const ValueKey('weight-exclude-confirm'),
        type: UtenButtonType.danger,
        onPressed: _confirm,
        child: const Text('排除'),
      ),
    ],
  );
}

/// 学习设置表单 (单重管理权限): 默认皮重 · 核对容差% · 单件离散% · 参与学习 · 批次切换。
class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({
    super.key,
    required this.profile,
    required this.busy,
    required this.onSave,
  });

  final GoodsWeightProfile? profile;
  final bool busy;
  final Future<void> Function(WeightProfileUpdate update) onSave;

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  late final TextEditingController _tare;
  late final TextEditingController _tolerance;
  late final TextEditingController _pieceCv;
  late bool _learningEnabled;
  late String _regimeMode;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    final entry = ref.read(warehouseWeightUnitsPrefsProvider).entry;
    _tare = TextEditingController(
      text: p?.defaultTareKg == null ? '' : entry.editText(p!.defaultTareKg!),
    );
    _tolerance = TextEditingController(text: _plain(p?.tolerancePct));
    _pieceCv = TextEditingController(text: _plain(p?.pieceCvPct));
    _learningEnabled = p?.learningEnabled ?? true;
    _regimeMode = p?.regimeMode ?? 'AUTO';
  }

  @override
  void dispose() {
    _tare.dispose();
    _tolerance.dispose();
    _pieceCv.dispose();
    super.dispose();
  }

  static String _plain(double? v) =>
      v == null ? '' : NumberFormat('0.###', 'en_US').format(v);

  double? _pct(TextEditingController c, String label, {required double max}) {
    final text = c.text.trim();
    if (text.isEmpty) return null;
    final v = double.tryParse(text);
    if (v == null || v <= 0 || v > max) {
      throw FormatException('$label 请填 0 到 $max 之间的数');
    }
    return v;
  }

  Future<void> _save() async {
    final entry = ref.read(warehouseWeightUnitsPrefsProvider).entry;
    try {
      double? tareKg;
      final tareText = _tare.text.trim();
      if (tareText.isNotEmpty) {
        final input = parseWithSuffix(tareText, entry);
        if (input == null) throw const FormatException('默认皮重格式不对');
        tareKg = input.kg <= 0 ? null : (input.kg * 1e6).roundToDouble() / 1e6;
      }
      final update = WeightProfileUpdate(
        expectedVersion: widget.profile?.version ?? 0,
        defaultTareKg: tareKg,
        tolerancePct: _pct(_tolerance, '核对容差%', max: 50),
        pieceCvPct: _pct(_pieceCv, '单件离散%', max: 50),
        manualUnitWeightKg: widget.profile?.manualUnitWeightKg,
        manualReason: widget.profile?.manualReason,
        learningEnabled: _learningEnabled,
        regimeMode: _regimeMode,
      );
      setState(() => _error = null);
      await widget.onSave(update);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = ref.watch(warehouseWeightUnitsPrefsProvider).entry;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('weight-settings-tare'),
              controller: _tare,
              decoration: UtenInputDecoration(
                InputDecoration(labelText: '默认皮重', suffixText: entry.symbol),
                info: '称重计数时预填的箱/袋/托盘重量; 可直接写 850g、1.2kg',
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const ValueKey('weight-settings-tolerance'),
              controller: _tolerance,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '核对容差%', hintText: '默认 3'),
                info: '称重与数量差多少以内不提醒 (还会按单重可信度自动放宽)',
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const ValueKey('weight-settings-piece-cv'),
              controller: _pieceCv,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '单件离散%', hintText: '默认 2'),
                info: '同一批里单件重量的正常波动',
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            SwitchListTile(
              key: const ValueKey('weight-settings-learning'),
              contentPadding: EdgeInsets.zero,
              title: const Text('参与学习'),
              subtitle: const Text('关闭后称重记录只保留, 不再计算单重'),
              value: _learningEnabled,
              onChanged: (v) => setState(() => _learningEnabled = v),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text('批次切换', style: theme.textTheme.labelLarge),
            const SizedBox(height: UtenSpacing.s4),
            UtenSegmentRow<String>(
              key: const ValueKey('weight-settings-regime'),
              segments: const [
                ButtonSegment(value: 'AUTO', label: Text('自动')),
                ButtonSegment(value: 'MANUAL', label: Text('手动')),
              ],
              selected: {_regimeMode},
              onSelectionChanged: (s) => setState(() => _regimeMode = s.first),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              _regimeMode == 'AUTO'
                  ? '自动: 发现单重明显变了就从变化处重新学习, 并在称重异常里提醒。'
                  : '手动: 只在称样勾选「从本次起作为新批次」或点「从今天起重新学习」时切换, 自动发现只提醒。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                _error!,
                key: const ValueKey('weight-settings-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            Align(
              alignment: Alignment.centerRight,
              child: UtenButton(
                key: const ValueKey('weight-settings-save'),
                icon: Icons.save_outlined,
                isLoading: widget.busy,
                onPressed: widget.busy ? null : _save,
                child: const Text('保存设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
