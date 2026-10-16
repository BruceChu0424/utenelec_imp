import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/search/keyword_search.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/drafts/task_form_drafts.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_task_center_record.dart';
import '../models/warehouse_task_form_drafts.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/warehouse_task_center_repository.dart';
import 'warehouse_task_record_actions.dart';

/// One authorized, server-paged table underneath the two navigation rows.
class WarehouseTaskRecordsView extends ConsumerStatefulWidget {
  const WarehouseTaskRecordsView({
    super.key,
    required this.direction,
    required this.source,
    required this.sources,
    this.view = WarehouseTaskView.active,
    this.keyword = '',
    this.refreshTick = 0,
    this.externalHeader,
    this.initialStatus,
  });
  final WarehouseTaskDirection direction;
  final String source;
  final Map<String, String> sources;
  final WarehouseTaskView view;
  final String keyword;
  final int refreshTick;
  final Widget? externalHeader;
  final String? initialStatus;

  @override
  ConsumerState<WarehouseTaskRecordsView> createState() =>
      _WarehouseTaskRecordsViewState();
}

class _WarehouseTaskRecordsViewState
    extends ConsumerState<WarehouseTaskRecordsView> {
  WarehouseTaskCenterPageResult? _result;
  String? _status;
  String? _billNo;
  String? _sort;
  bool _ascending = true;
  DateTimeRange? _dates;
  String? _error;
  bool _loading = false;
  bool _busy = false;
  int _requestVersion = 0;
  Set<String> _selected = {};
  final _rows = MasterDataTableRowsController<WarehouseTaskCenterRecord>();
  final Map<String, WarehouseTaskCenterRecord> _selectedRows = {};
  String? _decisionFingerprint;
  String? _decisionKey;

  bool get _history => widget.view == WarehouseTaskView.history;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) _invalidate();
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) _invalidate();
    });
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _invalidate();
    });
    ref.listenManual(warehouseTaskScopeProvider, (previous, next) {
      if (previous != next) _invalidate();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(covariant WarehouseTaskRecordsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.direction != widget.direction ||
        oldWidget.view != widget.view) {
      _status = null;
      _billNo = null;
      _dates = null;
      _invalidate();
    } else if (oldWidget.initialStatus != widget.initialStatus) {
      _status = widget.initialStatus;
      _invalidate();
    } else if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _invalidate();
    }
  }

  void _clearSelection() {
    _selected = {};
    _selectedRows.clear();
  }

  void _invalidate() {
    ++_requestVersion;
    if (!mounted) return;
    setState(() {
      _result = null;
      _error = null;
      _clearSelection();
      _decisionFingerprint = null;
      _decisionKey = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(1);
    });
  }

  String get _effectiveSource => _status?.startsWith('source:') == true
      ? _status!.substring('source:'.length)
      : widget.source;
  String? get _effectiveStatus =>
      _status?.startsWith('source:') == true ? null : _status;

  Future<void> _load(int page) async {
    if (!mounted) return;
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(warehouseTaskCenterRepositoryProvider)
          .list(
            direction: widget.direction,
            source: _effectiveSource,
            view: widget.view,
            status: _effectiveStatus,
            keyword: widget.keyword,
            billNo: _billNo,
            dateFrom: _dates == null
                ? null
                : ChinaDateTime.formatDate(_dates!.start),
            dateTo: _dates == null
                ? null
                : ChinaDateTime.formatDate(_dates!.end),
            warehouseScope: WarehouseListScope.of(context),
            page: page,
            sort: _sort,
            order: _sort == null ? null : (_ascending ? 'asc' : 'desc'),
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        for (final row in result.items) {
          if (_selected.contains(row.rowKey)) _selectedRows[row.rowKey] = row;
        }
      });
    } catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '仓库单据加载失败，请重试';
      });
    }
  }

  void _filter(String key, String? value) {
    if (_busy) return;
    if (key == 'status') {
      if (value?.startsWith('source:') == true &&
          (widget.source != 'ALL' ||
              !widget.sources.containsKey(value!.substring(7)))) {
        return;
      }
      if (_status == value) return;
      _status = value;
    } else if (key == 'billNo') {
      if (_billNo == value) return;
      _billNo = value;
    } else {
      return;
    }
    _invalidate();
  }

  List<FormDraft> _draftsFor(WarehouseTaskCenterRecord row) {
    if (_history) return const [];
    if (row.recordType == 'LOCAL_FORM_DRAFT') {
      return ref
          .read(formDraftsProvider)
          .where((draft) => draft.id == row.id)
          .toList();
    }
    final recovering = _newDocumentDrafts
        .where((draft) => _matchesNewDocumentDraft(row, draft))
        .toList();
    if (recovering.isNotEmpty) return recovering;
    final drafts = ref.read(formDraftsProvider);
    final target = row.targetId ?? row.id;
    return switch (row.action) {
      'ARRIVAL_REGISTER' || 'ARRIVAL_CONTINUE' => arrivalTaskDrafts(
        drafts,
        row.dataId('expectationId') ?? target,
      ),
      'FINISHED_REGISTER' || 'FINISHED_COUNT' => finishedInboundTaskDrafts(
        drafts,
        reportId: row.dataId('reportId'),
        documentId: row.dataId('documentId'),
      ),
      'SALES_OUTBOUND' => salesOutboundTaskDrafts(drafts, target),
      'SUBCONTRACT_OUTBOUND' => subcontractOutboundTaskDrafts(drafts, target),
      'PRODUCTION_DRAW' || 'RETURN_RECEIVE' => stockTaskDrafts(drafts, target),
      'QUALITY_RESULT' => qualityStockInTaskDrafts(
        drafts,
        row.sourceType,
        target,
      ),
      _ => const [],
    };
  }

  Set<String> get _newDocumentPrefixes => _history
      ? const {}
      : widget.direction == WarehouseTaskDirection.inbound
      ? {
          if (_effectiveSource == 'ALL' || _effectiveSource == 'OTHER')
            '/warehouse/OTHER_IN/new',
          if (_effectiveSource == 'ALL' || _effectiveSource == 'FINISHED')
            '/warehouse/FINISHED_IN/new',
        }
      : {
          if (_effectiveSource == 'ALL' || _effectiveSource == 'OTHER')
            '/warehouse/OTHER_OUT/new',
          if (_effectiveSource == 'ALL' || _effectiveSource == 'FINISHED')
            '/warehouse/FINISHED_OUT/new',
          if (_effectiveSource == 'ALL' || _effectiveSource == 'DRAW')
            '/warehouse/DRAW/new',
        };

  List<FormDraft> get _newDocumentDrafts => _newDocumentPrefixes.isEmpty
      ? const []
      : ref.read(
          formDraftCategoryProvider(
            FormDraftCategoryScope(
              module: BadgeModule.warehouse,
              routePrefixes: _newDocumentPrefixes,
              excludeTaskDrafts: true,
            ),
          ),
        );

  bool _matchesNewDocumentDraft(
    WarehouseTaskCenterRecord row,
    FormDraft draft,
  ) =>
      {'STOCK_DOC', 'STOCK_DOCUMENT'}.contains(row.recordType) &&
      row.dataId('docType') ==
          Uri.parse(draft.route).path.split('/').elementAtOrNull(2) &&
      formDraftConfirmedIds(draft).contains(row.id);

  List<WarehouseTaskCenterRecord> get _localRows {
    final formalRows = _result?.items ?? const <WarehouseTaskCenterRecord>[];
    return [
      for (final draft in _newDocumentDrafts)
        if (!formalRows.any((row) => _matchesNewDocumentDraft(row, draft)) &&
            matchesKeywordSearch([
              draft.title,
              formDraftColumnValue(draft, 'billNo'),
            ], widget.keyword) &&
            (_billNo == null ||
                formDraftColumnValue(draft, 'billNo') == _billNo) &&
            (_dates == null ||
                !draft.updatedAt.isBefore(_dates!.start) &&
                    draft.updatedAt.isBefore(
                      _dates!.end.add(const Duration(days: 1)),
                    )) &&
            (_effectiveStatus == null ||
                _effectiveStatus ==
                    '${Uri.parse(draft.route).path.contains('FINISHED')
                        ? 'FINISHED'
                        : Uri.parse(draft.route).path.contains('/DRAW/')
                        ? 'DRAW'
                        : 'OTHER'}_DRAFT'))
          WarehouseTaskCenterRecord(
            rowKey: 'LOCAL_FORM_DRAFT:${draft.id}',
            id: draft.id,
            sourceType: Uri.parse(draft.route).path.contains('FINISHED')
                ? 'FINISHED'
                : Uri.parse(draft.route).path.contains('/DRAW/')
                ? 'DRAW'
                : 'OTHER',
            recordType: 'LOCAL_FORM_DRAFT',
            status: 'LOCAL_DRAFT',
            statusLabel: taskDraftStatus([draft]),
            billNo: formDraftColumnValue(draft, 'billNo') ?? draft.title,
            businessDate: ChinaDateTime.formatDate(draft.updatedAt),
            action: 'FORM_DRAFT',
            targetId: draft.id,
          ),
    ];
  }

  bool _canSelect(WarehouseTaskCenterRecord row) =>
      !_history &&
      !_loading &&
      !_busy &&
      ref.read(authenticatedScopeProvider)?.readOnly != true &&
      row.canHandle &&
      _draftsFor(row).isEmpty &&
      warehouseTaskRecordBatchFamily(row) != null;

  void _select(Set<String> ids) {
    if (_busy || _loading) return;
    final visible = {for (final row in _rows.items) row.rowKey: row};
    final next = <String, WarehouseTaskCenterRecord>{};
    for (final id in ids) {
      final row = visible[id] ?? _selectedRows[id];
      if (row != null && _canSelect(row)) next[id] = row;
    }
    setState(() {
      _selected = next.keys.toSet();
      _selectedRows
        ..clear()
        ..addAll(next);
    });
  }

  Future<void> _open(WarehouseTaskCenterRecord row) async {
    if (_busy || _loading) return;
    if (!_history &&
        row.action == 'ARRIVAL_CONTINUE' &&
        _draftsFor(row).isEmpty &&
        row.canHandle) {
      await _batch(targets: [row]);
      return;
    }
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    final drafts = _draftsFor(row);
    setState(() => _busy = true);
    try {
      if (drafts.isNotEmpty) {
        if (row.recordType == 'LOCAL_FORM_DRAFT') {
          await context.push<void>(drafts.single.resumeLocation);
        } else {
          await resumeTaskFormDraft(context, ref, drafts);
        }
      } else {
        await openWarehouseTaskRecord(context, ref, row);
      }
      if (!mounted ||
          scope != ref.read(authenticatedScopeProvider) ||
          server != ref.read(apiBaseUrlProvider)) {
        return;
      }
      invalidateWarehouseTaskCounts(ref);
      _invalidate();
    } catch (error) {
      if (mounted &&
          scope == ref.read(authenticatedScopeProvider) &&
          server == ref.read(apiBaseUrlProvider)) {
        context.appError(
          error is ApiException ? error.message : '单据打开失败，请刷新后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _batchFamily {
    if (_selectedRows.isEmpty || _selectedRows.length != _selected.length) {
      return null;
    }
    final families = _selectedRows.values
        .map(warehouseTaskRecordBatchFamily)
        .toSet();
    return families.length == 1 ? families.single : null;
  }

  bool _canRegisterBeforeInspection(WarehouseTaskCenterRecord row) =>
      row.canHandle &&
      {'ARRIVAL_REGISTER', 'FINISHED_REGISTER'}.contains(row.action) &&
      row.actionData['canRegisterBeforeInspection'] == true;

  Future<void> _batch({
    bool? preStock,
    List<WarehouseTaskCenterRecord>? targets,
  }) async {
    if (_busy || _loading || (targets == null && _selectedRows.isEmpty)) return;
    final rows = targets ?? _selectedRows.values.toList(growable: false);
    final families = rows.map(warehouseTaskRecordBatchFamily).toSet();
    final family = families.length == 1 ? families.single : null;
    if (family == null) {
      context.appWarning('请只选择可用同一种方式办理的单据');
      return;
    }
    final max = family == 'SUBCONTRACT_OUTBOUND' ? 50 : 100;
    if (rows.length > max) {
      context.appWarning('本次最多选择 $max 条，请分批办理');
      return;
    }
    if (rows.any((row) => !_canSelect(row))) {
      context.appWarning('单据状态或填写快照已变化，请刷新后重新选择');
      return;
    }
    if (preStock == true && !rows.every(_canRegisterBeforeInspection)) {
      context.appWarning('所选单据当前不能先入库后质检，请刷新后核对办理方式');
      return;
    }
    final requestVersion = _requestVersion;
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    setState(() => _busy = true);
    try {
      if (family == 'ARRIVAL_EXCEPTION' || family == 'ARRIVAL_CONTINUE') {
        final requestScope = await AuthenticatedRequestScope.capture(
          baseUrl: server,
          storage: ref.read(secureStorageProvider),
          isCurrent: () =>
              mounted &&
              requestVersion == _requestVersion &&
              scope == ref.read(authenticatedScopeProvider) &&
              server == ref.read(apiBaseUrlProvider),
        );
        if (!mounted || !requestScope.isCurrent) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => UtenAlertDialog(
            scrollable: false,
            title: Text(
              family == 'ARRIVAL_EXCEPTION'
                  ? '按批准量处理 ${rows.length} 条到货异常'
                  : '继续送检 ${rows.length} 条到货任务',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    family == 'ARRIVAL_EXCEPTION'
                        ? '按财务批准量送品质待检。任一版本、权限或资格变化，整批都不会生效。'
                        : '按原收货单继续送品质检验；超量仍先隔离审核。',
                  ),
                  const SizedBox(height: 12),
                  for (final row in rows)
                    Text(
                      family == 'ARRIVAL_EXCEPTION'
                          ? '${row.billNo ?? row.id} · ${row.actionData['goodsName'] ?? '物料'} · 批准接收 ${row.actionData['acceptedQty'] ?? '—'} ${row.actionData['unitName'] ?? ''}'
                          : '${row.billNo ?? row.id} · ${row.dataIds('draftReceiptIds').length} 张原收货单',
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认处理'),
              ),
            ],
          ),
        );
        if (confirmed != true ||
            !mounted ||
            requestVersion != _requestVersion ||
            scope != ref.read(authenticatedScopeProvider) ||
            server != ref.read(apiBaseUrlProvider)) {
          return;
        }
        final fingerprint =
            rows.map((row) => '${row.rowKey}:${row.expectedVersion}').toList()
              ..sort();
        fingerprint.insert(0, family);
        if (_decisionFingerprint != fingerprint.join('|')) {
          _decisionFingerprint = fingerprint.join('|');
          _decisionKey = 'arrival-stock-in-batch-${const Uuid().v4()}';
        }
        if (family == 'ARRIVAL_EXCEPTION') {
          final result = await requestScope.run(
            () => ref
                .read(procurementInboundRepositoryProvider)
                .batchStockInAccepted(
                  items: [
                    for (final row in rows)
                      (
                        exceptionId: row.targetId ?? row.id,
                        expectedVersion: row.expectedVersion!,
                      ),
                  ],
                  idempotencyKey: _decisionKey!,
                ),
          );
          if (mounted && requestScope.isCurrent) {
            context.appSuccess(
              result.replay
                  ? '这批 ${result.processedCount} 条异常此前已办理，本次没有重复处理'
                  : '已按批准量处理 ${result.processedCount} 条异常，请继续核对品质与入库状态',
            );
          }
        } else {
          final receipts =
              rows
                  .expand((row) => row.dataIds('draftReceiptIds'))
                  .toSet()
                  .toList()
                ..sort();
          if (receipts.isEmpty || receipts.length > 100) {
            if (mounted) context.appWarning('当前可送检原收货单为空或超过100张，请重新核对并分批办理');
            return;
          }
          final result = await requestScope.run(
            () => ref
                .read(procurementInboundRepositoryProvider)
                .batchCompleteArrivals(
                  receiptIds: receipts,
                  idempotencyKey: _decisionKey!,
                ),
          );
          if (mounted && requestScope.isCurrent) {
            final quarantined = result.items
                .where(
                  (item) =>
                      item.outcome ==
                      WarehouseArrivalRegistrationOutcome.excessQuarantined,
                )
                .length;
            final replayed = result.items
                .where((item) => item.alreadyCompleted)
                .length;
            final replayMessage = replayed > 0
                ? '（其中 $replayed 张此前已处理，本次没有重复送检）'
                : '';
            if (quarantined > 0) {
              context.appWarning(
                '已处理 ${result.processedCount} 张原收货单$replayMessage，其中 $quarantined 张超量隔离待审核，请核对到货异常',
              );
            } else {
              context.appSuccess(
                '已处理 ${result.processedCount} 张原收货单$replayMessage，请继续核对品质与入库状态',
              );
            }
          }
        }
        if (mounted &&
            scope == ref.read(authenticatedScopeProvider) &&
            server == ref.read(apiBaseUrlProvider)) {
          _decisionFingerprint = null;
          _decisionKey = null;
        }
      } else {
        await openWarehouseTaskRecordBatch(
          context,
          ref,
          rows,
          preStock: preStock,
        );
      }
      if (mounted &&
          requestVersion == _requestVersion &&
          scope == ref.read(authenticatedScopeProvider) &&
          server == ref.read(apiBaseUrlProvider)) {
        invalidateWarehouseTaskCounts(ref);
        _invalidate();
      }
    } catch (error) {
      if (mounted &&
          scope == ref.read(authenticatedScopeProvider) &&
          server == ref.read(apiBaseUrlProvider)) {
        context.appError(
          error is ApiException ? error.message : '操作未确认完成，请核对原单后再试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Widget> _batchActions(BuildContext context, Set<String> ids) {
    final family = _batchFamily;
    final hasRegistration =
        family == 'ARRIVAL_REGISTER' || family == 'FINISHED_REGISTER';
    final canPreStock =
        _selectedRows.isNotEmpty &&
        _selectedRows.values.every(_canRegisterBeforeInspection);
    if (hasRegistration) {
      return [
        if (canPreStock)
          UtenButton(
            type: UtenButtonType.tonal,
            onPressed: _busy ? null : () => _batch(preStock: true),
            child: Text('先入库后质检(${ids.length})'),
          ),
        UtenButton(
          onPressed: _busy ? null : () => _batch(preStock: false),
          child: Text('先质检后入库(${ids.length})'),
        ),
      ];
    }
    return [
      UtenButton(
        key: const Key('warehouse-task-record-batch'),
        onPressed: family == null || _busy ? null : _batch,
        onDisabledTap: ids.isNotEmpty && family == null
            ? () => context.appWarning('不同办理方式的单据，请分别选择后处理')
            : null,
        child: Text('${warehouseTaskRecordBatchLabel(family)}(${ids.length})'),
      ),
    ];
  }

  Future<void> _pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _dates,
    );
    if (!mounted || range == null) return;
    _dates = range;
    _invalidate();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    ref.watch(formDraftsProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final readOnly = ref.watch(authenticatedScopeProvider)?.readOnly ?? false;
    final selectable =
        !_history &&
        !readOnly &&
        (result?.items.any(
              (row) =>
                  row.canHandle && warehouseTaskRecordBatchFamily(row) != null,
            ) ??
            false);
    // Draft writes are observed so the originating row immediately changes its label.
    final columns = <MasterColumnDef<WarehouseTaskCenterRecord>>[
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 210,
        value: (row) {
          final matches = _draftsFor(row);
          return matches.isEmpty
              ? row.statusLabel
              : '${widget.sources[row.sourceType] ?? '仓库'} · ${taskDraftStatus(matches)}';
        },
        cellColor: (context, row) => utenStatusBadgeCellColor(
          _draftsFor(row).isEmpty
              ? row.statusType
              : UtenStatusBadgeType.neutral,
        ),
      ),
      MasterColumnDef(
        key: 'billNo',
        label: '单据 / 任务单号',
        width: 180,
        sortable: true,
        value: (row) => row.billNo ?? '—',
      ),
      MasterColumnDef(
        key: 'sourceDocNo',
        label: '来源单据',
        width: 180,
        value: (row) => row.sourceDocNo ?? '—',
      ),
      MasterColumnDef(
        key: 'partyName',
        label: '客户 / 供应商 / 委外商',
        width: 200,
        value: (row) => row.partyName ?? '—',
      ),
      MasterColumnDef(
        key: 'warehouseName',
        label: '仓库',
        width: 180,
        value: (row) => row.warehouseName ?? '未确定',
      ),
      MasterColumnDef(
        key: 'businessDate',
        label: '业务日期',
        width: 120,
        type: 'date',
        sortable: true,
        value: (row) => row.businessDate ?? '—',
      ),
      MasterColumnDef(
        key: 'lineCount',
        label: '明细行数',
        width: 100,
        type: 'number',
        value: (row) => row.lineCount?.toString() ?? '—',
      ),
      MasterColumnDef(
        key: 'responsibleName',
        label: '负责人 / 制单人',
        width: 150,
        value: (row) => row.responsibleName ?? '—',
      ),
    ];
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.externalHeader != null) widget.externalHeader!,
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
      body: MasterDataTableView<WarehouseTaskCenterRecord>(
        key: ValueKey('warehouse-task-records-${widget.direction.name}'),
        tableKey:
            'warehouse.task-center.${widget.direction.name}.${widget.source}${_history ? '.history' : ''}',
        requiredLeadingColumnKeys: const ['status'],
        primary: true,
        rowsController: _rows,
        paginationRevision: result,
        paginationScope: (
          widget.direction,
          widget.source,
          widget.view,
          _status,
          _billNo,
          _sort,
          _ascending,
          widget.keyword,
          _dates,
          WarehouseListScope.of(context),
        ),
        items: result?.items ?? const [],
        unpagedItems: _localRows,
        columns: columns,
        facets: {
          'billNo': result?.facets['billNo'] ?? const [],
          'status': [
            if (widget.source == 'ALL')
              for (final entry in widget.sources.entries)
                MasterFacetBucket(
                  value: 'source:${entry.key}',
                  label: '${entry.value} · 全部状态',
                  count: 0,
                ),
            ...?result?.statusFacets,
          ],
        },
        nullCounts: const {},
        filters: {'status': _status, 'billNo': _billNo},
        onFilterChanged: _filter,
        sortColumn: _sort,
        sortAscending: _ascending,
        onSortChange: (key, ascending) {
          if (_busy ||
              (key != null && !{'billNo', 'businessDate'}.contains(key))) {
            return;
          }
          _sort = key;
          _ascending = ascending;
          _invalidate();
        },
        // The source navigation owns the scope; a personal query cannot replace it.
        externalFilterKeys: const {'status'},
        selectable: selectable,
        idOf: (row) => _canSelect(row) ? row.rowKey : null,
        rowKeyOf: (row) => row.rowKey,
        selectedIds: _selected,
        onSelectedIdsChanged: _select,
        batchActionsBuilder: selectable ? _batchActions : null,
        canOpenRow: warehouseTaskRecordCanOpen,
        onRowTap: _open,
        rowMenuBuilder: (row) => [
          UtenMenuItem(
            label: !_history && row.canHandle ? '打开办理' : '查看原单',
            icon: Icons.open_in_new_rounded,
            onTap: () => _open(row),
          ),
        ],
        canShowRowMenu: warehouseTaskRecordCanOpen,
        toolbarActions: [
          if (!_history && !readOnly)
            for (final source in ['OTHER', 'FINISHED'])
              if (widget.sources.containsKey(source) &&
                  (widget.source == 'ALL' || widget.source == source) &&
                  locationAllowedFor(
                    permissions,
                    superAdmin,
                    RoutePath.stockDocNew(
                      '${source == 'OTHER' ? 'OTHER' : 'FINISHED'}_${widget.direction == WarehouseTaskDirection.inbound ? 'IN' : 'OUT'}',
                    ),
                  ))
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.add_rounded,
                  onPressed: _busy
                      ? null
                      : () => context.push<void>(
                          RoutePath.stockDocNew(
                            '${source == 'OTHER' ? 'OTHER' : 'FINISHED'}_${widget.direction == WarehouseTaskDirection.inbound ? 'IN' : 'OUT'}',
                          ),
                        ),
                  child: Text('新建${widget.sources[source]}'),
                ),
          TextButton.icon(
            onPressed: _busy ? null : _pickDates,
            icon: const Icon(Icons.date_range_outlined),
            label: Text(
              _dates == null
                  ? '全部日期'
                  : '${ChinaDateTime.formatDate(_dates!.start)} 至 ${ChinaDateTime.formatDate(_dates!.end)}',
            ),
          ),
          if (_dates != null)
            IconButton(
              tooltip: '清除日期范围',
              onPressed: _busy
                  ? null
                  : () {
                      _dates = null;
                      _invalidate();
                    },
              icon: const Icon(Icons.clear_rounded),
            ),
          Text('共 ${result?.total ?? 0} 条'),
        ],
        isLoading: _loading,
        loadingMore: _loading && result != null,
        error: _error,
        onRetry: () => _load(result?.page ?? 1),
        emptyMessage: '当前范围与筛选下没有单据',
        currentPage: result?.page ?? 1,
        totalPages: result?.totalPages ?? 0,
        onPageChange: _load,
      ),
    );
  }
}
