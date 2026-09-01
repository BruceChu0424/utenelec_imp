import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/quality_inspection_record.dart';
import '../repositories/quality_inspection_record_repository.dart';

class QualityInspectionRecordsPage extends ConsumerStatefulWidget {
  const QualityInspectionRecordsPage({super.key, this.initialDomain});

  final QualityInspectionRecordDomain? initialDomain;

  @override
  ConsumerState<QualityInspectionRecordsPage> createState() =>
      _QualityInspectionRecordsPageState();
}

class _QualityInspectionRecordsPageState
    extends ConsumerState<QualityInspectionRecordsPage> {
  QualityInspectionRecordPage? _data;
  QualityInspectionRecordDomain? _domain;
  String? _decision;
  String _keyword = '';
  QualityInspectionDateRange? _dateRange;
  bool _loading = true;
  String? _error;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _domain = _resolveInitialDomain();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(page: 1));
  }

  List<QualityInspectionRecordDomain> get _allowedDomains {
    final permissions = ref.read(currentPermissionsProvider);
    final superAdmin = ref.read(isSuperAdminProvider);
    return [
      if (superAdmin || permissions.contains(Perm.procurementInspectionView))
        QualityInspectionRecordDomain.iqc,
      if (superAdmin ||
          permissions.contains(Perm.productionQualityInspectionView))
        QualityInspectionRecordDomain.fqc,
    ];
  }

  QualityInspectionRecordDomain? _resolveInitialDomain() {
    final allowed = _allowedDomains;
    if (allowed.isEmpty) return null;
    final requested = widget.initialDomain;
    return requested != null && allowed.contains(requested)
        ? requested
        : allowed.first;
  }

  Future<void> _load({int? page}) async {
    final domain = _domain;
    if (domain == null) return;
    final requestVersion = ++_requestVersion;
    final requestedPage = page ?? _data?.page ?? 1;
    final requestedDecision = _decision;
    final requestedKeyword = _keyword;
    final requestedRange = _dateRange;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(qualityInspectionRecordRepositoryProvider)
          .list(
            domain: domain,
            decision: requestedDecision,
            keyword: requestedKeyword,
            dateRange: requestedRange,
            page: requestedPage,
          );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _data = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '检测记录加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _selectDomain(QualityInspectionRecordDomain domain) async {
    if (_domain == domain) return;
    setState(() {
      _domain = domain;
      _decision = null;
      _data = null;
      _error = null;
    });
    await _load(page: 1);
  }

  Future<void> _selectDecision(String? decision) async {
    final normalized = decision?.trim().toUpperCase();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_decision == next) return;
    setState(() => _decision = next);
    await _load(page: 1);
  }

  Future<void> _applyKeyword(String value) async {
    final normalized = value.trim();
    if (_keyword == normalized) return;
    _keyword = normalized;
    await _load(page: 1);
  }

  Future<void> _pickDateRange() async {
    final today = ChinaDateTime.today();
    final current = _dateRange;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(2020),
      lastDate: today,
      initialDateRange: current == null
          ? null
          : DateTimeRange(start: current.start, end: current.end),
      helpText: '选择检验决定日期范围',
      saveText: '应用',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateRange = QualityInspectionDateRange(
        start: ChinaDateTime.asWallTime(picked.start),
        end: ChinaDateTime.asWallTime(picked.end),
      );
    });
    await _load(page: 1);
  }

  Future<void> _clearDateRange() async {
    if (_dateRange == null) return;
    setState(() => _dateRange = null);
    await _load(page: 1);
  }

  Future<void> _openDetail(QualityInspectionRecord record) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QualityInspectionRecordDetailDialog(record: record),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.qualityInspectionRecords, _load);
    final allowedDomains = _allowedDomains;
    return Scaffold(
      appBar: UtenAppBar(
        title: '检测记录',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _data != null,
              onPressed: _loading || _domain == null ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _domain == null || allowedDomains.isEmpty
            ? const UtenEmpty(
                icon: Icons.lock_outline_rounded,
                message: '您暂无检测记录查看权限',
                description: '请联系品质主管开通来料检验或生产成品质检查看权限。',
              )
            : _loading && _data == null
            ? const UtenSkeletonList()
            : _error != null && _data == null
            ? UtenEmpty.error(
                message: _error,
                description: '记录来源仍保留在服务端，重新加载不会改写检验事实。',
                actionLabel: '重新加载',
                onAction: () => _load(page: 1),
              )
            : _buildContent(allowedDomains),
      ),
    );
  }

  Widget _buildContent(List<QualityInspectionRecordDomain> allowedDomains) {
    final data =
        _data ??
        const QualityInspectionRecordPage(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
          metrics: [],
        );
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 840;
            final overview = _buildOverview(data, constraints.maxWidth);
            final filters = _buildFilters(allowedDomains);
            const hint = _InspectionRecordScopeHint();
            final inlineError = _error == null || _data == null
                ? const SizedBox.shrink()
                : _InlineRecordError(message: _error!, onRetry: _load);
            if (compact) {
              return ListView(
                key: const Key('quality-inspection-record-mobile-list'),
                padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
                children: [
                  overview,
                  const SizedBox(height: UtenSpacing.s16),
                  filters,
                  const SizedBox(height: UtenSpacing.s12),
                  hint,
                  if (_error != null && _data != null) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    inlineError,
                  ],
                  const SizedBox(height: UtenSpacing.s12),
                  if (data.items.isEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 300),
                      child: UtenEmpty(
                        icon: Icons.fact_check_outlined,
                        message: '当前筛选下没有检测记录',
                        description: _hasActiveFilter
                            ? '可切换检验类型、结果、日期或关键词后重试。'
                            : '检验员保存决定后，追加式记录会显示在这里。',
                      ),
                    )
                  else
                    for (final record in data.items) ...[
                      _InspectionRecordCard(
                        record: record,
                        onTap: () => _openDetail(record),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                    ],
                  _MobileRecordPager(
                    page: data.page,
                    totalPages: data.totalPages,
                    loading: _loading,
                    onPageChanged: (page) => _load(page: page),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                overview,
                const SizedBox(height: UtenSpacing.s16),
                filters,
                const SizedBox(height: UtenSpacing.s12),
                hint,
                if (_error != null && _data != null) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  inlineError,
                ],
                const SizedBox(height: UtenSpacing.s12),
                Expanded(child: _buildTable(data)),
              ],
            );
          },
        ),
      ),
    );
  }

  bool get _hasActiveFilter =>
      _decision != null || _keyword.isNotEmpty || _dateRange != null;

  Widget _buildOverview(QualityInspectionRecordPage data, double width) {
    final metrics = data.metrics;
    if (metrics.isEmpty) {
      final theme = Theme.of(context);
      return Container(
        key: const Key('quality-inspection-record-metrics-unavailable'),
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: const Text('后端尚未返回检测记录概览，系统不会用当前分页推算或伪造计数。'),
      );
    }
    final itemWidth = width < 600 ? (width - UtenSpacing.s12) / 2 : 200.0;
    return MetricFilterCards(
      key: const Key('quality-inspection-record-metrics'),
      itemWidth: itemWidth,
      items: [
        for (final metric in metrics)
          MetricFilterCardItem(
            key: metric.key,
            label: metric.label,
            value: metric.value,
            tone: metric.tone,
            icon: _metricIcon(metric.key),
            selected: (metric.decisionFilter?.isEmpty ?? true)
                ? _decision == null
                : _decision == metric.decisionFilter,
            onTap: () => _selectDecision(metric.decisionFilter),
          ),
      ],
    );
  }

  Widget _buildFilters(List<QualityInspectionRecordDomain> allowedDomains) {
    // 全平台统一筛选工具条：检验域分段 + 胶囊搜索框（尾挂总数文案）；
    // 决定日期筛选保留在工具条下一行。
    final theme = Theme.of(context);
    final range = _dateRange;
    final dateLabel = range == null
        ? '决定日期'
        : '${ChinaDateTime.formatDate(range.start)} 至 '
              '${ChinaDateTime.formatDate(range.end)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<QualityInspectionRecordDomain>(
          segmentsKey: const Key('quality-inspection-record-domain-filter'),
          searchKey: const Key('quality-inspection-record-search'),
          segments: [
            for (final domain in allowedDomains)
              UtenFilterSegment(value: domain, label: domain.label),
          ],
          selected: _domain!,
          onSelectionChanged: _selectDomain,
          searchHint: '搜索来源单号 / 计划 / 货品 / 供应商 / 检验员',
          initialSearchValue: _keyword,
          onSearchChanged: _applyKeyword,
          trailing: Text(
            '共 ${_data?.total ?? 0} 条 · 双击查看完整证据',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton.icon(
                key: const Key('quality-inspection-record-date-filter'),
                onPressed: _pickDateRange,
                icon: const Icon(Icons.date_range_outlined),
                label: Text(dateLabel),
              ),
            ),
            if (range != null)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: TextButton.icon(
                  onPressed: _clearDateRange,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('清除日期'),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTable(QualityInspectionRecordPage data) =>
      MasterDataTableView<QualityInspectionRecord>(
        key: const Key('quality-inspection-record-table'),
        columns: _columns,
        items: data.items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        idOf: (record) => record.recordId,
        onRowTap: _openDetail,
        rowMenuBuilder: (record) => [
          UtenMenuItem(
            label: '查看检测记录详情',
            icon: Icons.visibility_outlined,
            onTap: () => _openDetail(record),
          ),
        ],
        isLoading: _loading,
        loadingMore: _loading && _data != null,
        error: _data == null ? _error : null,
        onRetry: () => _load(page: data.page),
        emptyMessage: '当前筛选下没有检测记录',
        currentPage: data.page,
        totalPages: data.totalPages,
        onPageChange: (page) => _load(page: page),
      );

  List<MasterColumnDef<QualityInspectionRecord>> get _columns => [
    MasterColumnDef(
      key: 'decision',
      label: '检验结果',
      width: 120,
      value: (record) => record.decisionLabel,
    ),
    MasterColumnDef(
      key: 'effective',
      label: '当前效力',
      width: 105,
      value: (record) => record.effectLabel,
    ),
    MasterColumnDef(
      key: 'sourceType',
      label: '检验类型',
      width: 120,
      value: (record) => record.sourceTypeLabel,
    ),
    MasterColumnDef(
      key: 'sourceNo',
      label: '来源单号',
      width: 180,
      value: (record) => _text(record.sourceNo),
    ),
    MasterColumnDef(
      key: 'referenceNo',
      label: '关联单号',
      width: 180,
      value: (record) => _text(record.referenceNo),
    ),
    MasterColumnDef(
      key: 'partnerName',
      label: '供应商',
      width: 180,
      value: (record) => _text(record.partnerName),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '货品编码',
      width: 140,
      value: (record) => _text(record.goodsCode),
    ),
    MasterColumnDef(
      key: 'goodsName',
      label: '货品名称',
      width: 240,
      value: (record) => _text(record.goodsName),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 110,
      value: (record) => _text(record.colorName),
    ),
    MasterColumnDef(
      key: 'passQty',
      label: '本次合格',
      width: 110,
      type: 'number',
      value: (record) => _qty(record.passQty),
    ),
    MasterColumnDef(
      key: 'failQty',
      label: '本次不合格',
      width: 120,
      type: 'number',
      value: (record) => _qty(record.failQty),
    ),
    MasterColumnDef(
      key: 'disposition',
      label: '不良处置',
      width: 120,
      value: (record) => record.dispositionLabel,
    ),
    MasterColumnDef(
      key: 'inspectorName',
      label: '检验员',
      width: 120,
      value: (record) => _text(record.inspectorName),
    ),
    MasterColumnDef(
      key: 'decidedAt',
      label: '决定时间',
      width: 170,
      value: (record) => ChinaDateTime.formatInstant(record.decidedAt),
    ),
  ];
}

class _InspectionRecordScopeHint extends StatelessWidget {
  const _InspectionRecordScopeHint();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(
          child: Text(
            '这里按每一次不可变检验决定展示，部分处置不会被合并。'
            '来源红冲后的决定仍保留，但会明确标为“历史失效”；本页只读，待处理动作请回到品质任务中心。',
          ),
        ),
      ],
    ),
  );
}

class _InspectionRecordCard extends StatelessWidget {
  const _InspectionRecordCard({required this.record, required this.onTap});

  final QualityInspectionRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goods = [
      record.goodsCode,
      record.goodsName,
      record.colorName,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 152),
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  UtenStatusBadge(
                    label: record.decisionLabel,
                    type: _decisionBadgeType(record.decision),
                    icon: _decisionIcon(record.decision),
                  ),
                  UtenStatusBadge(
                    label: record.effectLabel,
                    type: record.effective
                        ? UtenStatusBadgeType.info
                        : UtenStatusBadgeType.neutral,
                  ),
                  Text(
                    record.sourceTypeLabel,
                    style: theme.textTheme.labelLarge,
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                _text(record.sourceNo),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (goods.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s4),
                Text(goods, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s4,
                children: [
                  Text('合格 ${_qty(record.passQty)} ${record.unitName ?? ''}'),
                  Text('不合格 ${_qty(record.failQty)} ${record.unitName ?? ''}'),
                  if (record.dispositionLabel != '—')
                    Text('处置 ${record.dispositionLabel}'),
                ],
              ),
              if (record.reason?.trim().isNotEmpty == true) ...[
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  '原因：${record.reason}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '${record.inspectorName ?? '系统'} · '
                '${ChinaDateTime.formatInstant(record.decidedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QualityInspectionRecordDetailDialog extends ConsumerStatefulWidget {
  const _QualityInspectionRecordDetailDialog({required this.record});

  final QualityInspectionRecord record;

  @override
  ConsumerState<_QualityInspectionRecordDetailDialog> createState() =>
      _QualityInspectionRecordDetailDialogState();
}

class _QualityInspectionRecordDetailDialogState
    extends ConsumerState<_QualityInspectionRecordDetailDialog> {
  QualityInspectionRecord? _record;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final record = await ref
          .read(qualityInspectionRecordRepositoryProvider)
          .detail(
            domain: widget.record.domain,
            recordId: widget.record.recordId,
          );
      if (!mounted) return;
      setState(() {
        _record = record;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '检测记录详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      key: ValueKey('quality-inspection-record-${widget.record.recordId}'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width < 600 ? UtenSpacing.s12 : UtenSpacing.s40,
        vertical: UtenSpacing.s24,
      ),
      title: const Text('检测记录详情'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: size.height * 0.72,
        ),
        child: _loading
            ? const SizedBox(
                height: 360,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null
            ? SizedBox(
                height: 360,
                child: UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                ),
              )
            : SingleChildScrollView(child: _buildDetail(_record!)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildDetail(QualityInspectionRecord record) {
    final theme = Theme.of(context);
    final unit = record.unitName ?? '';
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: record.effective
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                UtenStatusBadge(
                  label: record.decisionLabel,
                  type: _decisionBadgeType(record.decision),
                  icon: _decisionIcon(record.decision),
                  size: UtenStatusBadgeSize.large,
                ),
                UtenStatusBadge(
                  label: record.effectLabel,
                  type: record.effective
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.neutral,
                ),
                Text(
                  '${record.domain.label} · ${record.sourceTypeLabel}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (!record.effective) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '该决定是不可变历史证据，但来源已红冲/取消，不代表当前可用库存或当前成品放行。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '来源与货品',
            children: [
              _DetailLine(label: '来源单号', value: _text(record.sourceNo)),
              _DetailLine(label: '来源日期', value: _date(record.sourceDate)),
              _DetailLine(label: '关联单号', value: _text(record.referenceNo)),
              _DetailLine(label: '供应商', value: _text(record.partnerName)),
              _DetailLine(label: '仓库', value: _text(record.warehouseName)),
              _DetailLine(
                label: '货品',
                value: [
                  record.goodsCode,
                  record.goodsName,
                ].whereType<String>().join(' '),
              ),
              _DetailLine(label: '颜色', value: _text(record.colorName)),
              _DetailLine(label: '单位', value: _text(record.unitName)),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '本次不可变决定',
            children: [
              _DetailLine(label: '检验结果', value: record.decisionLabel),
              _DetailLine(
                label: '本次合格',
                value: '${_qty(record.passQty)} $unit',
              ),
              _DetailLine(
                label: '本次不合格',
                value: '${_qty(record.failQty)} $unit',
              ),
              _DetailLine(label: '不良处置', value: record.dispositionLabel),
              _DetailLine(label: '原因', value: _text(record.reason)),
              _DetailLine(
                label: '检验员',
                value: _text(record.inspectorName, fallback: '系统'),
              ),
              _DetailLine(
                label: '决定时间',
                value: ChinaDateTime.formatInstant(record.decidedAt),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '当前累计状态',
            children: [
              _DetailLine(
                label: '送检数量',
                value: '${_qty(record.inspectedQty)} $unit',
              ),
              _DetailLine(
                label: '累计合格',
                value: '${_qty(record.currentPassedQty)} $unit',
              ),
              _DetailLine(
                label: '累计不合格',
                value: '${_qty(record.currentFailedQty)} $unit',
              ),
              _DetailLine(
                label: '剩余待检',
                value: '${_qty(record.currentRemainingQty)} $unit',
              ),
              _DetailLine(label: '当前状态', value: record.currentStatusLabel),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '追溯标识',
            children: [
              _DetailLine(label: '记录 UUID', value: record.recordId),
              _DetailLine(label: '检验 UUID', value: record.inspectionId),
              _DetailLine(label: '来源 UUID', value: _text(record.sourceId)),
              _DetailLine(label: '来源行 UUID', value: _text(record.sourceItemId)),
              _DetailLine(label: '供应商 UUID', value: _text(record.partnerId)),
              _DetailLine(label: '仓库 UUID', value: _text(record.warehouseId)),
              _DetailLine(label: '货品 UUID', value: _text(record.goodsId)),
              _DetailLine(label: '颜色 UUID', value: _text(record.colorId)),
              _DetailLine(label: '单位 UUID', value: _text(record.unitId)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: UtenSpacing.s8),
        ...children,
      ],
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            '$label：',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value.isEmpty ? '—' : value)),
      ],
    ),
  );
}

class _InlineRecordError extends StatelessWidget {
  const _InlineRecordError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '刷新失败：$message；当前仍显示上次成功结果。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _MobileRecordPager extends StatelessWidget {
  const _MobileRecordPager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.secondary,
            onPressed: loading || page <= 1
                ? null
                : () => onPageChanged(page - 1),
            child: const Text('上一页'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            child: Text('$page / $totalPages'),
          ),
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.secondary,
            onPressed: loading || page >= totalPages
                ? null
                : () => onPageChanged(page + 1),
            child: const Text('下一页'),
          ),
        ],
      ),
    );
  }
}

IconData _metricIcon(String key) => switch (key.toUpperCase()) {
  'PASS' => Icons.check_circle_outline_rounded,
  'PARTIAL' => Icons.rule_folder_outlined,
  'FAIL' => Icons.cancel_outlined,
  'CANCELLED' => Icons.history_rounded,
  _ => Icons.fact_check_outlined,
};

IconData _decisionIcon(String decision) => switch (decision) {
  'PASS' => Icons.check_rounded,
  'PARTIAL' => Icons.rule_rounded,
  'FAIL' => Icons.close_rounded,
  'CANCELLED' => Icons.history_rounded,
  _ => Icons.fact_check_outlined,
};

UtenStatusBadgeType _decisionBadgeType(String decision) => switch (decision) {
  'PASS' => UtenStatusBadgeType.success,
  'PARTIAL' => UtenStatusBadgeType.warning,
  'FAIL' => UtenStatusBadgeType.danger,
  'CANCELLED' => UtenStatusBadgeType.neutral,
  _ => UtenStatusBadgeType.info,
};

String _qty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

String _text(String? value, {String fallback = '—'}) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? fallback : normalized;
}

String _date(DateTime? value) =>
    value == null ? '—' : ChinaDateTime.formatDate(value);
