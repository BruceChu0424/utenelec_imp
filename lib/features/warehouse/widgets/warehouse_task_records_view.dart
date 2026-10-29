import '../../../shared/paging/paged_query_identity.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/components/layout/uten_refresh_scope.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_date_range_picker.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/page_navigation_session.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/search/keyword_search.dart';
import '../../../shared/search/numeric_column_query.dart';
import '../../../shared/search/calendar_column_query.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/drafts/task_form_drafts.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_task_center_record.dart';
import '../models/arrival_registration_selection.dart';
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
    extends ConsumerState<WarehouseTaskRecordsView>
    with
        UtenRefreshParticipant<WarehouseTaskRecordsView>,
        ScopedPagedReadViewMixin<WarehouseTaskRecordsView> {
  int get _refreshPage => _rows.visiblePage ?? (_result?.page ?? 1);

  @override
  void scopedPagedReadOwnerChanged() {
    ++_requestVersion;
    if (!mounted) return;
    setState(() {
      _result = null;
      _loading = false;
      _error = scopedPagedReadRejection?.message;
      _selected = <String>{};
      _selectedRows.clear();
      _rows.update(const []);
    });
  }

  WarehouseTaskCenterPageResult? _result;
  String? _status;
  String? _billNo;
  final _headerColumns = <String, String?>{};

  /// 默认排序：业务日期倒序（新单在前，与服务端无 sort 时的默认序一致）。
  /// 显式携带排序状态让表头指示与数据顺序一致（2026-10-29 用户口径）。
  static const _defaultSort = 'businessDate';
  static const _defaultAscending = false;
  String? _sort = _defaultSort;
  bool _ascending = _defaultAscending;
  DateTimeRange? _dates;
  String? _error;
  bool _loading = false;
  bool _busy = false;
  final _navigation = PageNavigationSession();

  /// 批量确认弹窗/批量办理页打开中：拦截重复触发，但不进入 [_busy]（busy 语义
  /// =网络进行中）。此前弹窗一开就置 busy，接上按钮转圈后用户阅读确认框的整段
  /// 时间里按钮无限转圈（也是 widget 测试 pumpAndSettle 不落定的根因）。
  bool _batchPromptOpen = false;
  int _requestVersion = 0;
  Set<String> _selected = {};
  final _rows = MasterDataTableRowsController<WarehouseTaskCenterRecord>();
  final Map<String, WarehouseTaskCenterRecord> _selectedRows = {};
  String? _decisionFingerprint;
  String? _decisionKey;

  bool get _history => widget.view == WarehouseTaskView.history;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
  }

  @override
  void dispose() {
    _navigation.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) _invalidate(reset: true);
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) _invalidate(reset: true);
    });
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _invalidate(reset: true);
    });
    ref.listenManual(warehouseTaskScopeProvider, (previous, next) {
      if (previous != next) _invalidate(reset: true);
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
      _headerColumns.clear();
      _dates = null;
      _invalidate(reset: true);
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

  /// [reset]=true 表示换了视图/身份（不同单据族，旧行不串台）；关键词/筛选/刷新
  /// 变化保留旧行到新数据落地（keepPreviousData）——此前一律清空，任务中心每
  /// 次搜索停顿 300ms 就整表闪一次全屏骨架（2026-10-18 口径统一）。
  void _invalidate({bool reset = false}) {
    final revision = ++_requestVersion;
    if (!mounted) return;
    setState(() {
      if (reset) {
        _result = null;
        _headerColumns.clear();
        _sort = _defaultSort;
        _ascending = _defaultAscending;
      }
      _error = null;
      _clearSelection();
      _decisionFingerprint = null;
      _decisionKey = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revision == _requestVersion) _load(1);
    });
  }

  String get _effectiveSource => _status?.startsWith('source:') == true
      ? _status!.substring('source:'.length)
      : widget.source;
  String? get _effectiveStatus =>
      _status?.startsWith('source:') == true ? null : _status;

  Future<void> _load(int page, {bool useCache = false}) =>
      trackRefresh(_loadPage(page, useCache: useCache), replaceKey: 'rows');

  Future<void> _loadPage(int page, {bool useCache = false}) async {
    if (!mounted) return;
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pageRepository = ref.read(warehouseTaskCenterRepositoryProvider);
      final pageDirection = widget.direction;
      final pageSource = _effectiveSource;
      final pageView = widget.view;
      final pageStatus = _effectiveStatus;
      final pageKeyword = widget.keyword;
      final pageBillNo = _billNo;
      final pageColumns = Map<String, String?>.of(_headerColumns);
      final pageDateFrom = _dates == null
          ? null
          : ChinaDateTime.formatDate(_dates!.start);
      final pageDateTo = _dates == null
          ? null
          : ChinaDateTime.formatDate(_dates!.end);
      final pageWarehouseScope = WarehouseListScope.of(context);
      final pageSort = _sort;
      final pageOrder = _sort == null ? null : (_ascending ? 'asc' : 'desc');

      final cached = await readScopedPage<WarehouseTaskCenterRecord>(
        page,
        slot: '_loadPage',
        query: [
          pageRepository,
          pageDirection,
          pageSource,
          pageView,
          pageStatus,
          pageKeyword,
          pageBillNo,
          pageColumns,
          pageDateFrom,
          pageDateTo,
          pageWarehouseScope,
          pageSort,
          pageOrder,
        ],
        currentQuery: () => [
          ref.read(warehouseTaskCenterRepositoryProvider),
          widget.direction,
          _effectiveSource,
          widget.view,
          _effectiveStatus,
          widget.keyword,
          _billNo,
          Map<String, String?>.of(_headerColumns),
          _dates == null ? null : ChinaDateTime.formatDate(_dates!.start),
          _dates == null ? null : ChinaDateTime.formatDate(_dates!.end),
          WarehouseListScope.of(context),
          _sort,
          _sort == null ? null : (_ascending ? 'asc' : 'desc'),
        ],
        useCache: useCache,
        fetchPage: (target) async {
          final snapshot = await pageRepository.list(
            direction: pageDirection,
            source: pageSource,
            view: pageView,
            status: pageStatus,
            keyword: pageKeyword,
            billNo: pageBillNo,
            columns: pageColumns,
            dateFrom: pageDateFrom,
            dateTo: pageDateTo,
            warehouseScope: pageWarehouseScope,
            page: target,
            sort: pageSort,
            order: pageOrder,
          );
          return PagedReadSnapshot<
            WarehouseTaskCenterRecord,
            WarehouseTaskCenterPageResult
          >(page: snapshot, snapshot: snapshot);
        },
      );
      final result =
          (cached
                  as PagedReadSnapshot<
                    WarehouseTaskCenterRecord,
                    WarehouseTaskCenterPageResult
                  >)
              .snapshot;
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        for (final row in result.items) {
          if (_selected.contains(row.rowKey)) _selectedRows[row.rowKey] = row;
        }
      });
    } catch (error) {
      if (!mounted) return;
      if (version != _requestVersion) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '仓库单据加载失败，请重试';
      });
    }
  }

  void _filter(String key, String? value) {
    if (_busy || _batchPromptOpen) return;
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
    } else if (key.startsWith('search.')) {
      if (_headerColumns[key] == value) return;
      if (value == null || value.trim().isEmpty) {
        _headerColumns.remove(key);
      } else {
        _headerColumns[key] = value;
      }
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
    if (row.line != null &&
        row.action != 'MATERIAL_DISCOVERY' &&
        row.line!.itemId?.isNotEmpty != true) {
      return const [];
    }
    return switch (row.action) {
      'ARRIVAL_REGISTER' || 'ARRIVAL_CONTINUE' => arrivalTaskDrafts(
        drafts,
        row.dataId('expectationId') ?? target,
        expectationItemId: row.action == 'ARRIVAL_REGISTER'
            ? row.dataId('expectationItemId') ?? row.line?.itemId
            : null,
      ),
      'FINISHED_REGISTER' || 'FINISHED_COUNT' => finishedInboundTaskDrafts(
        drafts,
        reportId: row.dataId('reportId'),
        lotId: row.dataId('lotId'),
        documentId: row.dataId('documentId'),
        itemId: row.line?.itemId,
      ),
      'SALES_OUTBOUND' => salesOutboundTaskDrafts(
        drafts,
        target,
        itemId: row.line?.itemId,
      ),
      'SUBCONTRACT_OUTBOUND' => subcontractOutboundTaskDrafts(
        drafts,
        target,
        itemId: row.line?.itemId,
      ),
      'PRODUCTION_DRAW' || 'RETURN_RECEIVE' => stockTaskDrafts(
        drafts,
        target,
        itemId: row.line?.itemId,
      ),
      'MATERIAL_DISCOVERY' => materialDiscoveryTaskDrafts(
        drafts,
        row.dataId('requestId') ?? target,
        suggestionKey: row.line?.key,
        expectedVersion: row.expectedVersion,
      ),
      'WORKSHOP_REQUISITION' => workshopMaterialTaskDrafts(
        drafts,
        row.dataId('requisitionId') ?? target,
        lineId: row.line?.itemId,
      ),
      'QUALITY_RESULT' => qualityStockInTaskDrafts(
        drafts,
        row.sourceType,
        target,
        inspectionItemIds: row.line == null
            ? null
            : row.dataIds('inspectionItemIds'),
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

  bool _localHeaderMatches(FormDraft draft) =>
      _headerColumns.entries.every((entry) {
        final column = entry.key.substring(7), query = entry.value;
        if (query == null) return true;
        final value = switch (column) {
          'billNo' => formDraftColumnValue(draft, 'billNo') ?? draft.title,
          'businessDate' => _localDate(draft),
          'quantity' => null,
          'warehouseName' => '未确定',
          _ => '—',
        };
        if (column == 'businessDate') {
          return CalendarColumnQuery.tryParse(query)?.matches(value) ?? false;
        }
        if (column == 'quantity') {
          return NumericColumnQuery.tryParse(query)?.matches(value) ?? false;
        }
        return matchesKeywordSearch([value], query);
      });

  String _localDate(FormDraft draft) =>
      ChinaDateTime.formatDate(ChinaDateTime.fromInstant(draft.updatedAt));

  List<WarehouseTaskCenterRecord> get _localRows {
    final formalRows = _result?.items ?? const <WarehouseTaskCenterRecord>[];
    return [
      for (final draft in _newDocumentDrafts)
        if (!formalRows.any((row) => _matchesNewDocumentDraft(row, draft)) &&
            _localHeaderMatches(draft) &&
            matchesKeywordSearch([
              draft.title,
              formDraftColumnValue(draft, 'billNo'),
            ], widget.keyword) &&
            (_billNo == null ||
                formDraftColumnValue(draft, 'billNo') == _billNo) &&
            (_dates == null ||
                CalendarColumnQuery.tryParse(
                  '${ChinaDateTime.formatDate(_dates!.start)}..${ChinaDateTime.formatDate(_dates!.end)}',
                )!.matches(_localDate(draft))) &&
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
            businessDate: _localDate(draft),
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
    if (_busy || _batchPromptOpen || _loading) return;
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
          await _navigation.push<void>(drafts.single.resumeLocation);
        } else {
          await resumeTaskFormDraft(
            context,
            ref,
            drafts,
            navigation: _navigation,
          );
        }
      } else {
        await openWarehouseTaskRecord(
          context,
          ref,
          row,
          navigation: _navigation,
        );
      }
      // Returning also clears the host search after this frame. Let that state
      // reach the next build before scheduling the one current list request.
      await WidgetsBinding.instance.endOfFrame;
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
          error is ApiException
              ? error.message
              : error is FormatException
              ? error.message
              : '单据打开失败，请刷新后重试',
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
    if (_busy ||
        _batchPromptOpen ||
        _loading ||
        (targets == null && _selectedRows.isEmpty)) {
      return;
    }
    final selectedRows =
        targets ?? _selectedRows.values.toList(growable: false);
    final rows = warehouseTaskCommandTargets(selectedRows);
    final families = rows.map(warehouseTaskRecordBatchFamily).toSet();
    final family = families.length == 1 ? families.single : null;
    if (family == null) {
      context.appWarning('请只选择可用同一种方式办理的单据');
      return;
    }
    final max = family == 'ARRIVAL_REGISTER'
        ? arrivalRegistrationMaxSources
        : family == 'SUBCONTRACT_OUTBOUND'
        ? 50
        : 100;
    final commandCount = family == 'ARRIVAL_CONTINUE'
        ? rows.expand((row) => row.dataIds('draftReceiptIds')).toSet().length
        : rows.map((row) => row.targetId ?? row.id).toSet().length;
    if (commandCount > max) {
      context.appWarning('本次最多办理 $max 张单据，请分批办理');
      return;
    }
    if (family == 'ARRIVAL_REGISTER' &&
        rows.length > arrivalRegistrationMaxItems) {
      context.appWarning('本次最多登记 $arrivalRegistrationMaxItems 行到货明细，请分批办理');
      return;
    }
    if (selectedRows.any((row) => !_canSelect(row))) {
      context.appWarning('单据状态或填写快照已变化，请刷新后重新选择');
      return;
    }
    if (preStock == true && !selectedRows.every(_canRegisterBeforeInspection)) {
      context.appWarning('所选单据当前不能先入库后质检，请刷新后核对办理方式');
      return;
    }
    final requestVersion = _requestVersion;
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    setState(() => _batchPromptOpen = true);
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
                  : '继续送检 $commandCount 张收货单',
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
        // 网络段才开始转圈：确认后的提交期间按钮 isLoading 生效。
        setState(() => _busy = true);
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
          navigation: _navigation,
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
          error is ApiException
              ? error.message
              : error is FormatException
              ? error.message
              : '操作未确认完成，请核对原单后再试',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _batchPromptOpen = false;
          _busy = false;
        });
      }
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
            isLoading: _busy,
            onPressed: _busy ? null : () => _batch(preStock: true),
            child: Text('${warehouseTaskRecordBatchLabel(family)}（先入库后质检）'),
          ),
        UtenButton(
          isLoading: _busy,
          onPressed: _busy ? null : () => _batch(preStock: false),
          child: Text('${warehouseTaskRecordBatchLabel(family)}（先质检后入库）'),
        ),
      ];
    }
    return [
      UtenButton(
        key: const Key('warehouse-task-record-batch'),
        isLoading: _busy,
        onPressed: family == null || _busy ? null : _batch,
        onDisabledTap: ids.isNotEmpty && family == null
            ? () => context.appWarning('不同办理方式的单据，请分别选择后处理')
            : null,
        child: Text(
          warehouseTaskRecordBatchLabel(family, rows: _selectedRows.values),
        ),
      ),
    ];
  }

  Future<void> _pickDates() async {
    final range = await showUtenDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _dates,
    );
    if (!mounted || range == null) return;
    _dates = range;
    _invalidate();
  }

  /// 表格列定义（打印预览与导出白名单共用同一口径）。
  List<MasterColumnDef<WarehouseTaskCenterRecord>> _buildColumns() => [
        MasterColumnDef(
          key: 'status',
          label: '状态',
          facetSearchEnabled: true,
          columnSearchEnabled: false,
          info: '按服务端工作阶段筛选。本地草稿标签保留原任务阶段和恢复入口。',
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
          key: 'goodsName',
          sortable: true,
          label: '货品名称',
          width: 200,
          value: (row) => row.line?.goodsName ?? '—',
        ),
        MasterColumnDef(
          key: 'goodsCode',
          sortable: true,
          label: '货品编码',
          width: 150,
          value: (row) => row.line?.goodsCode ?? '—',
        ),
        MasterColumnDef(
          key: 'colorName',
          sortable: true,
          label: '颜色',
          width: 100,
          value: (row) => row.line?.colorName ?? '—',
        ),
        MasterColumnDef(
          key: 'specification',
          sortable: true,
          label: '规格',
          width: 140,
          value: (row) => row.line?.specification ?? '—',
        ),
        MasterColumnDef(
          key: 'quantity',
          label: '数量',
          width: 130,
          type: 'number',
          sortable: true,
          columnSearchEnabled: true,
          exactValueOf: (row) =>
              row.line?.quantityText ?? row.line?.quantity?.toString(),
          value: (row) => row.line?.quantityLabel ?? '—',
        ),
        MasterColumnDef(
          key: 'sourceDocNo',
          sortable: true,
          label: '来源单据',
          width: 180,
          value: (row) => row.sourceDocNo ?? '—',
        ),
        // 领料单关联的生产工单（2026-10-29 用户批注）：链路 = 计划包单据/明细行执行段/
        // 计划包明细-需求 → production_execution_segments.segment_code；非领料行为「—」。
        if (widget.direction == WarehouseTaskDirection.outbound)
          MasterColumnDef(
            key: 'productionOrderNo',
            sortable: true,
            label: '生产工单',
            width: 150,
            value: (row) => row.productionOrderNo ?? '—',
            // 多工单不撑宽表格（2026-10-29 用户口径，参照车间任务物料摘要格）：
            // 格内最多显示 1 个工单 +「等 N 个」，点击弹窗列全部，可按单跳详情。
            cellBuilder: (context, row) {
              final orders = row.productionOrderNo?.split('、') ??
                  const <String>[];
              if (orders.isEmpty) return const Text('—');
              final planIdOf = <String, String?>{
                for (final entry in row.productionOrderEntries)
                  entry.$1: entry.$2,
              };
              final permissions = ref.read(currentPermissionsProvider);
              final superAdmin = ref.read(isSuperAdminProvider);
              final canOpenPlan = locationAllowedFor(
                permissions,
                superAdmin,
                RouteName.productionPlanList,
              );
              return UtenMultiValueCell(
                key: ValueKey('warehouse-production-orders-${row.rowKey}'),
                values: orders,
                title: '生产工单（${row.billNo ?? row.id}）',
                enabled: !_busy && !_batchPromptOpen && !_loading,
                detailAvailableOf: (order) =>
                    canOpenPlan && planIdOf[order] != null,
                onDetail: (order) => _navigation.push<void>(
                  RoutePath.productionPlanDetail(planIdOf[order]!),
                ),
              );
            },
          ),
        MasterColumnDef(
          key: 'partyName',
          sortable: true,
          label: '客户 / 供应商 / 委外商',
          width: 200,
          value: (row) => row.partyName ?? '—',
        ),
        MasterColumnDef(
          key: 'warehouseName',
          sortable: true,
          label: '仓库',
          width: 180,
          value: (row) => row.warehouseName ?? '未确定',
        ),
        MasterColumnDef(
          key: 'businessDate',
          label: '业务日期',
          width: 120,
          type: 'date',
          columnSearchEnabled: true,
          sortable: true,
          value: (row) => row.businessDate ?? '—',
        ),
        MasterColumnDef(
          key: 'responsibleName',
          sortable: true,
          label: '负责人',
          width: 110,
          value: (row) => row.responsibleName ?? '—',
        ),
        MasterColumnDef(
          key: 'makerName',
          sortable: true,
          label: '制单人',
          width: 110,
          value: (row) => row.makerName ?? '—',
        ),
      ];

  String get _directionLabel => widget.direction == WarehouseTaskDirection.outbound
      ? '出库'
      : '入库';
  String get _exportTitle => '仓库$_directionLabel任务';

  /// 导出查询参数：与 [_loadPage] 同一筛选口径（不含分页；列筛选以 search.* 透传）。
  Map<String, dynamic> _exportQueryOf(WarehouseTaskScope warehouseScope) =>
      <String, dynamic>{
        'source': _effectiveSource,
        'view': widget.view.apiValue,
        if (_effectiveStatus != null && _effectiveStatus!.isNotEmpty)
          'status': _effectiveStatus,
        if (widget.keyword.trim().isNotEmpty) 'keyword': widget.keyword.trim(),
        if (_billNo != null && _billNo!.trim().isNotEmpty)
          'billNo': _billNo!.trim(),
        if (_dates != null)
          'dateFrom': ChinaDateTime.formatDate(_dates!.start),
        if (_dates != null) 'dateTo': ChinaDateTime.formatDate(_dates!.end),
        if (_sort != null) 'sort': _sort,
        if (_sort != null) 'order': _ascending ? 'asc' : 'desc',
        for (final entry in _headerColumns.entries)
          if (entry.key.startsWith('search.') &&
              entry.value?.trim().isNotEmpty == true)
            entry.key: entry.value!.trim(),
        ...warehouseScope.queryParameters,
      };

  Map<String, dynamic> get _exportQuery =>
      _exportQueryOf(WarehouseListScope.of(context));

  /// 预览打印（2026-10-29 用户批注）：按当前筛选翻页取前 2000 行，
  /// 列取 [_buildColumns] 的表头与显示值，与服务端导出列集同源。
  Future<UtenPrintTable> _loadPrintTable() async {
    final repository = ref.read(warehouseTaskCenterRepositoryProvider);
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final warehouseScope = WarehouseListScope.of(context);
    final version = _requestVersion;
    final pageDirection = widget.direction;
    final pageSource = _effectiveSource;
    final pageView = widget.view;
    final pageStatus = _effectiveStatus;
    final pageKeyword = widget.keyword;
    final pageBillNo = _billNo;
    final pageColumns = Map<String, String?>.of(_headerColumns);
    final pageDateFrom = _dates == null
        ? null
        : ChinaDateTime.formatDate(_dates!.start);
    final pageDateTo = _dates == null
        ? null
        : ChinaDateTime.formatDate(_dates!.end);
    final pageSort = _sort;
    final pageOrder = _sort == null ? null : (_ascending ? 'asc' : 'desc');
    bool current() =>
        mounted &&
        version == _requestVersion &&
        scope == ref.read(authenticatedScopeProvider) &&
        server == ref.read(apiBaseUrlProvider) &&
        epoch == ref.read(exportContextEpochProvider);
    const rowLimit = 2000;
    const pageSize = 100;
    final records = <WarehouseTaskCenterRecord>[];
    for (var page = 1; records.length < rowLimit; page++) {
      final result = await repository.list(
        direction: pageDirection,
        source: pageSource,
        view: pageView,
        status: pageStatus,
        keyword: pageKeyword,
        billNo: pageBillNo,
        columns: pageColumns,
        dateFrom: pageDateFrom,
        dateTo: pageDateTo,
        warehouseScope: warehouseScope,
        page: page,
        size: pageSize,
        sort: pageSort,
        order: pageOrder,
      );
      if (!current()) {
        throw const FormatException('打印期间筛选或登录状态已变化，请重新预览');
      }
      records.addAll(result.items.take(rowLimit - records.length));
      if (records.length >= result.total || result.items.length < pageSize) {
        break;
      }
    }
    final columns = _buildColumns();
    return UtenPrintTable(
      columnKeys: List.unmodifiable(columns.map((column) => column.key)),
      headers: List.unmodifiable(columns.map((column) => column.label)),
      rows: List.unmodifiable(
        records.map(
          (record) => List<String>.unmodifiable(
            columns.map((column) => column.value(record)),
          ),
        ),
      ),
      rowIds: List.unmodifiable(records.map((record) => record.rowKey)),
    );
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
    final columns = _buildColumns();
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.externalHeader != null) widget.externalHeader!,
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
      body: MasterDataTableView<WarehouseTaskCenterRecord>(
        expensiveRowMounts: false,
        key: ValueKey('warehouse-task-records-${widget.direction.name}'),
        tableKey:
            'warehouse.task-center.${widget.direction.name}.${widget.source}${_history ? '.history' : ''}',
        requiredLeadingColumnKeys: const ['status', 'billNo'],
        primary: true,
        serverColumnSearch: true,
        rowsController: _rows,
        paginationRevision: result,
        paginationScope: (
          widget.direction,
          widget.source,
          widget.view,
          _status,
          _billNo,
          PagedReadQueryKey(_headerColumns),
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
        filters: {'status': _status, 'billNo': _billNo, ..._headerColumns},
        onFilterChanged: _filter,
        sortColumn: _sort,
        sortAscending: _ascending,
        onSortChange: (key, ascending) {
          if (_busy ||
              (key != null &&
                  !columns.any(
                    (column) => column.key == key && column.sortable,
                  ))) {
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
          // 预览打印 + 下载表格（2026-10-29 用户批注）：按当前筛选结果，全部分类共用本表。
          UtenPrintPreviewButton(
            title: _exportTitle,
            subtitle: '按当前筛选（最多前 2000 行）',
            enabled: !_busy && !_loading,
            loader: _loadPrintTable,
            exportEndpoint:
                '/warehouse/task-center/${widget.direction.name}/export',
            exportReport: widget.direction.name,
            exportQuery: _exportQuery,
            exportFilename: _exportTitle,
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
          ),
          UtenExportButton(
            endpoint: '/warehouse/task-center/${widget.direction.name}/export',
            report: widget.direction.name,
            queryParams: _exportQuery,
            filename: _exportTitle,
            enabled: !_busy,
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
          ),
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
        onRetry: () => _load(_refreshPage),
        emptyMessage: '当前范围与筛选下没有单据',
        currentPage: result?.page ?? 1,
        totalPages: result?.totalPages ?? 0,
        onPageChange: (page) => _load(page, useCache: true),
      ),
    );
  }
}
