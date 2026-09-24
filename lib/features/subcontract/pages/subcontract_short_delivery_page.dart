// 委外回厂短交判定（/subcontract/short-deliveries，ADR-098）。
//
// 仓库登记回厂时累计数量少于订货量即按订货行开案件；本页让委外跟单员判定：
//  - 分批到货，继续等（填预计到齐日；到了还没到齐系统再提醒）；
//  - 接受损耗，结清（登记损耗、保留订货量和来源申请占用、记录损耗率）。
// 分段：待判定（红徽章；含分批等待已过预计到齐日）/ 分批等待中（中性括号）/
// 历史记录（时间门控，ADR-066）。严重短交置顶并加「严重」标签。
// 入口：委外 hub 卡片、任务中心状态列「回厂短交待判定」（?orderId=）、通知卡片（?caseId=）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/models/subcontract_short_delivery.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_short_delivery_repository.dart';
import '../widgets/subcontract_short_delivery_decision_dialogs.dart';
import '../../../shared/badges/badge_registry.dart';

enum SubcontractShortDeliverySegment {
  pending('PENDING', '待判定'),
  tolerant('TOLERANT', '容差内待结案'),
  waiting('WAITING', '分批等待中'),
  history('HISTORY', '历史记录');

  const SubcontractShortDeliverySegment(this.api, this.label);

  final String api;
  final String label;
}

class SubcontractShortDeliveryPage extends ConsumerStatefulWidget {
  const SubcontractShortDeliveryPage({
    super.key,
    this.initialCaseId,
    this.initialOrderId,
    this.initialSupplierId,
    this.repository,
  });

  /// 通知卡片深链：进页后直接打开该案件详情。
  final String? initialCaseId;

  /// 任务中心状态列深链：只看这张订货单的案件。
  final String? initialOrderId;

  /// 供应商详情深链：只看这个委外商的案件。
  final String? initialSupplierId;

  /// 测试注入。
  final SubcontractShortDeliveryRepository? repository;

  @override
  ConsumerState<SubcontractShortDeliveryPage> createState() =>
      _SubcontractShortDeliveryPageState();
}

class _SubcontractShortDeliveryPageState
    extends ConsumerState<SubcontractShortDeliveryPage> {
  PagedResult<SubcontractShortDeliveryCase>? _result;
  SubcontractShortDeliveryCounts _counts =
      const SubcontractShortDeliveryCounts();
  bool _loading = true;
  String? _error;
  int _requestId = 0;
  int _page = 1;
  String _keyword = '';
  String? _orderId;
  String? _supplierId;
  String? _decidingId;

  /// 任务型页面默认落在「待判定」段（通知点进来就是要办这件事）；历史段仍时间门控。
  SubcontractShortDeliverySegment _seg =
      SubcontractShortDeliverySegment.pending;
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  SubcontractShortDeliveryRepository get _repo =>
      widget.repository ?? ref.read(subcontractShortDeliveryRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _orderId = widget.initialOrderId;
    _supplierId = widget.initialSupplierId;
    Future<void>.microtask(() async {
      await _load(page: 1);
      final caseId = widget.initialCaseId;
      if (caseId != null && caseId.isNotEmpty && mounted) {
        await _openDetailById(caseId);
      }
    });
  }

  bool get _historyBlocked =>
      _seg == SubcontractShortDeliverySegment.history && _historyTime.isNone;

  Future<void> _load({int? page}) async {
    if (!mounted) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      PagedResult<SubcontractShortDeliveryCase>? next;
      if (!_historyBlocked) {
        final range = _seg == SubcontractShortDeliverySegment.history
            ? _historyTime.range
            : null;
        next = await _repo.list(
          segment: _seg.api,
          keyword: _keyword,
          supplierId: _supplierId,
          orderId: _orderId,
          dateFrom: range == null
              ? null
              : ChinaDateTime.formatDate(range.start),
          dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          page: page ?? _page,
        );
      }
      final counts = await _repo.counts();
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _result = next;
        _counts = counts;
        _page = next?.page ?? 1;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '短交案件加载失败，请稍后重试';
      });
    }
  }

  void _selectSeg(SubcontractShortDeliverySegment seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _page = 1;
      if (seg != SubcontractShortDeliverySegment.history) {
        _historyTime = const UtenHistoryTimeValue.none();
      }
    });
    _load(page: 1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() {
      _historyTime = value;
      _page = 1;
    });
    _load(page: 1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    _keyword = normalized;
    _load(page: 1);
  }

  void _clearScope() {
    setState(() {
      _orderId = null;
      _supplierId = null;
      _page = 1;
    });
    _load(page: 1);
  }

  Future<void> _afterDecision(SubcontractShortDeliveryDetail detail) async {
    final row = detail.row;
    final decided = row.status == 'WAITING_MORE'
        ? '已判定为分批到货，预计 ${row.expectedCompleteBy ?? '—'} 到齐；仓库继续等后面的批次'
        : row.status == 'ACCEPTED_LOSS'
        ? '已接受损耗结清：订货 ${formatSubcontractQty(row.orderedQty, row.unitName)}'
              '，累计回厂 ${formatSubcontractQty(row.deliveredQty, row.unitName)}'
              '，核销损耗 ${row.lossQty == null ? '—' : formatSubcontractQty(row.lossQty!, row.unitName)}'
              '${row.wasteBillNo == null ? '' : '，损耗单 ${row.wasteBillNo} 已登记'}'
        : '案件已更新';
    if (mounted) context.appSuccess(decided);
    // 判定会把订货单挪出/挪进任务中心的「进行中」(结案即离场), 红黄两数随徽章汇总
    // 一次重拉(ADR-108)。
    refreshBadges(ref);
    // 接受损耗结清会让订货单整单结案：bump 委外订货列表精准刷新（栈下列表立即
    // 换新，与详情页写动作口径一致）。
    bumpListRefresh(
      ref,
      SubcontractDocConfig.by(SubcontractDocType.order).refreshKey,
    );
    await _load();
  }

  Future<void> _decide(
    SubcontractShortDeliveryCase row, {
    required String decision,
  }) async {
    if (_decidingId != null) return;
    final answer = decision == 'WAIT_MORE'
        ? await showSubcontractShortDeliveryWaitDialog(context, row: row)
        : await showSubcontractShortDeliveryAcceptDialog(context, row: row);
    if (answer == null || !mounted) return;
    setState(() => _decidingId = row.id);
    try {
      final detail = await _repo.decide(
        row.id,
        decision: answer.decision,
        expectedVersion: row.version,
        expectedCompleteBy: answer.expectedCompleteBy == null
            ? null
            : ChinaDateTime.formatDate(answer.expectedCompleteBy!),
        note: answer.note,
      );
      if (!mounted) return;
      await _afterDecision(detail);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('判定失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _decidingId = null);
    }
  }

  Future<void> _openDetailById(String caseId) async {
    try {
      final detail = await _repo.detail(caseId);
      if (!mounted) return;
      await _showDetail(detail);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('案件详情加载失败，请稍后重试');
    }
  }

  Future<void> _showDetail(SubcontractShortDeliveryDetail detail) async {
    final row = detail.row;
    final decision = await showDialog<String>(
      context: context,
      builder: (ctx) => _CaseDetailDialog(detail: detail),
    );
    if (decision == null || !mounted) return;
    await _decide(row, decision: decision);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外回厂短交判定',
        subtitle: '回厂数量少于订货量 · 判定分批到货继续等，或接受损耗结案',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.subcontract),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(page: 1),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s16,
          ),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    final scoped = _orderId != null || _supplierId != null;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<SubcontractShortDeliverySegment>(
          segmentsKey: const Key('subcontract-short-delivery-segments'),
          segments: [
            UtenFilterSegment(
              value: SubcontractShortDeliverySegment.pending,
              label: SubcontractShortDeliverySegment.pending.label,
              count: _counts.pending,
              countForm: UtenSegmentCountForm.actionable,
            ),
            // 容差内待结案 / 分批等待中: 案子已经在跑(等下一批到货、等损耗单走完),
            // 还没结但现在不用本人动手 → 黄色在办徽章(ADR-100, 2026-09-21 由中性
            // 括号改)。真要判定的「待判定」段仍是红徽章。
            UtenFilterSegment(
              value: SubcontractShortDeliverySegment.tolerant,
              label: SubcontractShortDeliverySegment.tolerant.label,
              count: _counts.tolerant,
              countForm: UtenSegmentCountForm.inProgress,
            ),
            UtenFilterSegment(
              value: SubcontractShortDeliverySegment.waiting,
              label: SubcontractShortDeliverySegment.waiting.label,
              count: _counts.waiting,
              countForm: UtenSegmentCountForm.inProgress,
            ),
            UtenFilterSegment(
              value: SubcontractShortDeliverySegment.history,
              label: SubcontractShortDeliverySegment.history.label,
            ),
          ],
          selected: {_seg},
          onSelectionChanged: _selectSeg,
          searchHint: '搜索订货单号、委外商、货品或收货单号',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestId++,
          onSearchChanged: _applyKeyword,
          trailing: scoped
              ? TextButton.icon(
                  key: const Key('subcontract-short-delivery-clear-scope'),
                  onPressed: _clearScope,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: Text(
                    _orderId != null ? '只看这张订货单 · 取消' : '只看这个委外商 · 取消',
                  ),
                )
              : null,
        ),
        if (_seg == SubcontractShortDeliverySegment.history) ...[
          const SizedBox(height: UtenSpacing.s8),
          UtenHistoryTimeFilter(
            key: const Key('subcontract-short-delivery-history-time'),
            value: _historyTime,
            onChanged: _onHistoryTime,
          ),
        ],
        const SizedBox(height: UtenSpacing.s8),
        Text(
          switch (_seg) {
            SubcontractShortDeliverySegment.pending =>
              '低于允许损耗下限的短交与过了预计到齐日的分批等待；「严重」为短交率超过允许损耗两倍或 20%。仓库照实登记，判定权在委外。',
            SubcontractShortDeliverySegment.tolerant =>
              '已达到允许损耗下限的行，在质检与入库完成后自动结清；未设允许损耗或无法自动核销的行由委外判定。',
            SubcontractShortDeliverySegment.waiting =>
              '已判定分批到货；累计回厂进入允许损耗范围并完成入库后自动结清，仍低于下限且逾期的回到「待判定」。',
            SubcontractShortDeliverySegment.history =>
              '已接受损耗结清、自然到齐或作废的案件；原订货量保留，实收与核销损耗分别记录。',
          },
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    // 2026-09-22 全站表格滚动口径：上滑先收分段/说明（表头随之顶到视口顶），
    // 继续滚动才滚表格内容；竖向滚动条由联动门控（外滚阶段不显示）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
        child: header,
      ),
      body: Builder(
        builder: (context) => _historyBlocked
            ? const UtenHistoryTimePlaceholder()
            : _buildTable(),
      ),
    );
  }

  Widget _buildTable() {
    final theme = Theme.of(context);
    final result = _result;
    final pendingSeg = _seg == SubcontractShortDeliverySegment.pending;
    final historySeg = _seg == SubcontractShortDeliverySegment.history;
    final openSeg =
        pendingSeg || _seg == SubcontractShortDeliverySegment.tolerant;
    return MasterDataTableView<SubcontractShortDeliveryCase>(
      key: const Key('subcontract-short-delivery-table'),
      // primary:true → 表体参与「分段行折叠 → 表格内滚」联动。
      primary: true,
      columns: [
        MasterColumnDef(
          key: 'orderBillNo',
          label: '订货单号',
          width: 140,
          value: (c) => c.orderBillNo,
        ),
        MasterColumnDef(
          key: 'supplierName',
          label: '委外商',
          width: 140,
          value: (c) => c.supplierName,
        ),
        MasterColumnDef(
          key: 'goodsName',
          label: '货品名称',
          width: 170,
          value: (c) => c.goodsName,
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 120,
          value: (c) => c.goodsCode,
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 90,
          value: (c) => c.colorName,
        ),
        MasterColumnDef(
          key: 'orderedQty',
          label: '原订货量',
          width: 100,
          type: 'number',
          value: (c) => formatSubcontractQty(c.orderedQty, c.unitName),
        ),
        MasterColumnDef(
          key: 'allowedLossPct',
          label: '允许损耗',
          width: 90,
          type: 'number',
          value: (c) => c.allowedLossPct == null
              ? '未设'
              : formatSubcontractPct(c.allowedLossPct),
        ),
        MasterColumnDef(
          key: 'floorQty',
          label: '最少应到',
          width: 100,
          type: 'number',
          value: (c) => c.floorQty == null
              ? '—'
              : formatSubcontractQty(c.floorQty!, c.unitName),
        ),
        MasterColumnDef(
          key: 'deliveredQty',
          label: '累计回厂',
          width: 100,
          type: 'number',
          value: (c) => formatSubcontractQty(c.deliveredQty, c.unitName),
        ),
        MasterColumnDef(
          key: 'shortfallQty',
          label: '短交量',
          width: 100,
          type: 'number',
          value: (c) => formatSubcontractQty(c.shortfallQty, c.unitName),
        ),
        MasterColumnDef(
          key: 'shortfallPct',
          label: '短交率',
          width: 90,
          type: 'number',
          value: (c) => formatSubcontractPct(c.shortfallPct),
        ),
        MasterColumnDef(
          key: 'severity',
          label: '程度',
          width: 130,
          value: (c) => c.severityLabel,
          cellBuilder: (context, c) => Align(
            alignment: Alignment.centerLeft,
            child: UtenStatusBadge(
              label: c.severityLabel,
              type: _severityType(c),
              size: UtenStatusBadgeSize.small,
            ),
          ),
        ),
        MasterColumnDef(
          key: 'receiptBillNo',
          label: '最近收货单',
          width: 140,
          value: (c) => c.receiptBillNo,
        ),
        MasterColumnDef(
          key: 'arrivalCount',
          label: '到货次数',
          width: 80,
          type: 'number',
          value: (c) => c.arrivalCount.toString(),
        ),
        MasterColumnDef(
          key: 'detectedAt',
          label: '发现时间',
          width: 150,
          type: 'date',
          value: (c) =>
              ChinaDateTime.formatIsoInstant(c.detectedAt, fallback: '—'),
        ),
        if (!openSeg)
          MasterColumnDef(
            key: 'expectedCompleteBy',
            label: '预计到齐',
            width: 110,
            type: 'date',
            value: (c) => c.expectedCompleteBy ?? '—',
          ),
        if (historySeg) ...[
          MasterColumnDef(
            key: 'lossQty',
            label: '核销损耗',
            width: 110,
            type: 'number',
            value: (c) => c.lossQty == null
                ? '—'
                : formatSubcontractQty(c.lossQty!, c.unitName),
          ),
          MasterColumnDef(
            key: 'lossPct',
            label: '损耗率',
            width: 90,
            type: 'number',
            value: (c) =>
                c.lossPct == null ? '—' : formatSubcontractPct(c.lossPct),
          ),
          MasterColumnDef(
            key: 'wasteBillNo',
            label: '损耗单',
            width: 140,
            value: (c) => c.wasteBillNo ?? '—',
          ),
          MasterColumnDef(
            key: 'closedAt',
            label: '结案时间',
            width: 150,
            type: 'date',
            value: (c) =>
                ChinaDateTime.formatIsoInstant(c.closedAt, fallback: '—'),
          ),
        ],
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 160,
          value: (c) =>
              c.status == 'ACCEPTED_LOSS' ? '已结清（接受损耗）' : c.statusLabel,
          cellBuilder: (context, c) => Align(
            alignment: Alignment.centerLeft,
            child: UtenStatusBadge(
              label: c.status == 'ACCEPTED_LOSS' ? '已结清（接受损耗）' : c.statusLabel,
              type: _statusType(c),
              size: UtenStatusBadgeSize.small,
            ),
          ),
        ),
        MasterColumnDef(
          key: 'ownerName',
          label: '负责人',
          width: 100,
          value: (c) => c.ownerName,
        ),
        if (!historySeg)
          MasterColumnDef(
            key: 'actions',
            label: '操作',
            width: 240,
            value: (c) => c.canDecide ? '分批到货 / 接受损耗' : '—',
            cellBuilderHandlesSemantics: true,
            cellBuilder: (context, c) => c.canDecide && c.isOpen
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UtenButton(
                        key: ValueKey('short-delivery-wait-${c.id}'),
                        type: UtenButtonType.tonal,
                        size: UtenButtonSize.small,
                        isLoading: _decidingId == c.id,
                        onPressed: _decidingId != null
                            ? null
                            : () => _decide(c, decision: 'WAIT_MORE'),
                        child: const Text('分批到货'),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      UtenButton(
                        key: ValueKey('short-delivery-accept-${c.id}'),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.small,
                        onPressed: _decidingId != null
                            ? null
                            : () => _decide(c, decision: 'ACCEPT_LOSS'),
                        child: const Text('接受损耗结案'),
                      ),
                    ],
                  )
                : Text(
                    c.isOpen ? '无判定权限' : '—',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
      ],
      items: result?.items ?? const [],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (c) => _openDetailById(c.id),
      canOpenRow: (_) => true,
      rowColor: (c) => pendingSeg && c.isBelowFloor
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.35)
          : null,
      isLoading: _loading,
      error: _error,
      onRetry: () => _load(),
      emptyMessage: switch (_seg) {
        SubcontractShortDeliverySegment.pending => '没有待判定的回厂短交',
        SubcontractShortDeliverySegment.tolerant => '没有容差内待结案的短交',
        SubcontractShortDeliverySegment.waiting => '没有分批等待中的案件',
        SubcontractShortDeliverySegment.history => '该时间段内没有短交记录',
      },
      currentPage: result?.page ?? 1,
      totalPages: result?.totalPages ?? 1,
      onPageChange: (page) {
        setState(() => _page = page);
        _load(page: page);
      },
    );
  }

  static UtenStatusBadgeType _severityType(SubcontractShortDeliveryCase c) =>
      switch (c.severity) {
        'SEVERE' => UtenStatusBadgeType.danger,
        'BELOW_FLOOR' => UtenStatusBadgeType.warning,
        'WITHIN_TOLERANCE' => UtenStatusBadgeType.info,
        _ => UtenStatusBadgeType.neutral,
      };

  static UtenStatusBadgeType _statusType(SubcontractShortDeliveryCase c) =>
      switch (c.effectiveStatus) {
        'PENDING_OWNER' =>
          c.overdue ? UtenStatusBadgeType.danger : UtenStatusBadgeType.warning,
        'WAITING_MORE' => UtenStatusBadgeType.fuchsia,
        'ACCEPTED_LOSS' => UtenStatusBadgeType.violet,
        'COMPLETED' => UtenStatusBadgeType.success,
        _ => UtenStatusBadgeType.neutral,
      };
}

/// 案件详情：数字摘要 + 事件时间线；开放案件且有判定权限时给两个判定按钮。
class _CaseDetailDialog extends StatelessWidget {
  const _CaseDetailDialog({required this.detail});

  final SubcontractShortDeliveryDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = detail.row;
    final unit = row.unitName;
    final canAct = row.canDecide && row.isOpen;
    return AlertDialog(
      title: Text('短交案件 · ${row.orderBillNo}'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  UtenStatusBadge(
                    label: row.status == 'ACCEPTED_LOSS'
                        ? '已结清（接受损耗）'
                        : row.statusLabel,
                    type: _SubcontractShortDeliveryPageState._statusType(row),
                    size: UtenStatusBadgeSize.small,
                  ),
                  UtenStatusBadge(
                    label: row.severityLabel,
                    type: _SubcontractShortDeliveryPageState._severityType(row),
                    size: UtenStatusBadgeSize.small,
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              _kv('委外商', row.supplierName ?? '—'),
              _kv('货品', row.goodsLabel),
              _kv('原订货量', formatSubcontractQty(row.orderedQty, unit)),
              _kv(
                '允许损耗',
                '${row.allowedLossPct == null ? '未设' : formatSubcontractPct(row.allowedLossPct)}'
                    '${row.floorQty == null ? '' : '(最少应到 ${formatSubcontractQty(row.floorQty!, unit)})'}',
              ),
              _kv(
                '累计回厂 / 短交',
                '${formatSubcontractQty(row.deliveredQty, unit)} / '
                    '${formatSubcontractQty(row.shortfallQty, unit)}'
                    '(${formatSubcontractPct(row.shortfallPct)})',
              ),
              _kv('最近收货单', row.receiptBillNo ?? '—'),
              _kv('到货次数', row.arrivalCount.toString()),
              _kv('负责人', row.ownerName ?? '—'),
              if (row.expectedCompleteBy != null)
                _kv('预计到齐', row.expectedCompleteBy!),
              if (row.decisionNote?.isNotEmpty == true)
                _kv('判定说明', row.decisionNote!),
              if (row.lossQty != null || row.lossPct != null)
                _kv(
                  '核销损耗',
                  '${row.lossQty == null ? '—' : formatSubcontractQty(row.lossQty!, unit)}'
                      '${row.lossPct == null ? '' : '(${formatSubcontractPct(row.lossPct)})'}',
                ),
              if (row.wasteBillNo != null) _kv('损耗单', row.wasteBillNo!),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '过程记录',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              if (detail.events.isEmpty)
                Text(
                  '暂无记录',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                for (final event in detail.events)
                  Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                    child: Text(
                      '${ChinaDateTime.formatIsoInstant(event.createdAt, fallback: '—')}'
                      ' · ${event.label}'
                      '${event.actorName == null || event.actorName!.isEmpty ? '' : ' · ${event.actorName}'}'
                      '${event.snapshot['note'] == null ? '' : ' · ${event.snapshot['note']}'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (canAct) ...[
          UtenButton(
            key: const Key('short-delivery-detail-wait'),
            type: UtenButtonType.tonal,
            onPressed: () => Navigator.pop(context, 'WAIT_MORE'),
            child: const Text('分批到货，继续等'),
          ),
          UtenButton(
            key: const Key('short-delivery-detail-accept'),
            type: UtenButtonType.danger,
            onPressed: () => Navigator.pop(context, 'ACCEPT_LOSS'),
            child: const Text('接受损耗，结案'),
          ),
        ],
      ],
    );
  }

  Widget _kv(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
