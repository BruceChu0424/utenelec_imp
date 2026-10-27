// 产成品「批量全量点收入库」页（2026-09-12 弹窗改页，对齐入库中心统一口径）。
//
// 用户口径：入库中心点击入库不要弹窗，都去对应页面。原「批量全量点收」的
// 确认弹窗 + 原地执行，改为独立页：所选待点收任务列成一张表（默认全勾），
// 底部「确认批量入库」→ 小结确认弹窗（UtenDialog 短要点）→ confirmAll 整批
// 同事务提交。幂等键按选择集指纹派生，选择不变重试复用同键，安全重放。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_finished_inbound_task.dart';
import '../models/warehouse_task_item_selection.dart';
import '../repositories/production_finished_inbound_task_repository.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class ProductionFinishedBatchStockInPage extends ConsumerStatefulWidget {
  const ProductionFinishedBatchStockInPage({
    super.key,
    required this.targets,
    this.selectedItemIds,
    this.selectedItemDocuments = const {},
  });

  /// 列表页多选的待点收任务（doc 类型；documentId 必须在场）。
  final List<ProductionFinishedInboundTask> targets;
  final List<String>? selectedItemIds;
  final Map<String, String> selectedItemDocuments;

  @override
  ConsumerState<ProductionFinishedBatchStockInPage> createState() =>
      _ProductionFinishedBatchStockInPageState();
}

class _ProductionFinishedBatchStockInPageState
    extends ConsumerState<ProductionFinishedBatchStockInPage>
    with FormDraftMixin<ProductionFinishedBatchStockInPage> {
  late List<ProductionFinishedInboundTask> _targets = widget.targets;
  late Map<String, String> _selectedItemDocuments = Map.of(
    widget.selectedItemDocuments,
  );
  final Set<String> _selectedDocumentIds = {};
  bool _saving = false;
  bool _preparing = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;
  bool _uncertain = false;

  @override
  bool get formDraftBusy => _busy;
  bool get _busy => _saving || _preparing;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.productionFinishedBatchStockIn.spec(
        title: '产成品批量点收',
        route: Uri(
          path: RouteName.warehouseProductionFinishedBatchStockIn,
          queryParameters: {
            'documentIds': _targets
                .map((task) => task.documentId)
                .whereType<String>()
                .join(','),
            ...WarehouseTaskItemSelection(
              widget.selectedItemIds,
            ).queryParameters,
            if (widget.selectedItemIds != null)
              'itemDocuments': jsonEncode(_orderedItemDocuments),
          },
        ).toString(),
      );
  @override
  Map<String, dynamic> captureFormDraft() => {
    'documentIds': _targets
        .map((task) => task.documentId)
        .whereType<String>()
        .toList(),
    'selectedDocumentIds': _selectedDocumentIds.toList()..sort(),
    'fingerprint': _batchSelectionFingerprint,
    'idempotencyKey': _batchIdempotencyKey,
    'uncertain': _uncertain,
    'selectedItemIds': widget.selectedItemIds,
    'selectedItemDocuments': _orderedItemDocuments,
    'targets': [
      for (final task in _targets)
        {
          'taskId': task.taskId,
          'taskStage': task.taskStage.code,
          'documentId': task.documentId,
          'documentNo': task.documentNo,
          'documentDate': task.documentDate.toIso8601String(),
          'reportId': task.reportId,
          'warehouseId': task.warehouseId,
          'warehouseName': task.warehouseName,
          'planId': task.planId,
          'planNo': task.planNo,
          'reportNos': task.reportNos,
          'goodsSummary': task.goodsSummary,
          'lineCount': task.lineCount,
          'pendingQty': task.pendingQty,
          'createdAt': task.createdAt.toIso8601String(),
          'residualTask': task.residualTask,
          'publicQty': task.publicQty,
          'actualSurplusQty': task.actualSurplusQty,
          'actualSurplusNote': task.actualSurplusNote,
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final originalDocuments = widget.targets
        .map((task) => task.documentId)
        .toList();
    if (originalDocuments.isEmpty ||
        originalDocuments.any((id) => id == null || id.isEmpty)) {
      throw const FormatException('当前点收入口缺少原单据身份，请从任务中心重新进入');
    }
    final originalIds = originalDocuments.cast<String>().toSet();
    if (data.containsKey('documentIds')) {
      final sources = data['documentIds'];
      if (sources is! List ||
          sources.any((id) => id is! String || id.isEmpty) ||
          sources.toSet().length != sources.length ||
          sources.length != originalIds.length ||
          !originalIds.containsAll(sources)) {
        throw const FormatException('点收草稿的来源单据与当前入口不一致，请保留原草稿核对');
      }
    }
    final savedItems = _readSelectedItems(data['selectedItemIds']);
    final currentItems = _readSelectedItems(widget.selectedItemIds);
    if (jsonEncode(savedItems) != jsonEncode(currentItems)) {
      throw const FormatException('原点收草稿的明细选择与当前不一致，请返回任务中心核对');
    }
    final saved = draftMaps(
      data['targets'],
    ).map(ProductionFinishedInboundTask.fromJson).toList();
    final targets = saved.isNotEmpty ? saved : _targets;
    final savedDocuments = targets.map((task) => task.documentId).toList();
    if (savedDocuments.any((id) => id == null || id.isEmpty) ||
        savedDocuments.toSet().length != targets.length ||
        savedDocuments.length != originalIds.length ||
        !originalIds.containsAll(savedDocuments)) {
      throw const FormatException('点收草稿的来源任务与当前入口不一致，请保留原草稿核对');
    }
    final documents = targets
        .map((task) => task.documentId)
        .whereType<String>()
        .toSet();
    final itemDocuments = _readItemDocuments(
      data.containsKey('selectedItemDocuments')
          ? data['selectedItemDocuments']
          : _selectedItemDocuments,
      savedItems,
      documents,
    );
    final routeItemDocuments = _readItemDocuments(
      _selectedItemDocuments,
      currentItems,
      documents,
    );
    if (jsonEncode(_sortedItemDocuments(routeItemDocuments)) !=
        jsonEncode(_sortedItemDocuments(itemDocuments))) {
      throw const FormatException('原点收草稿的明细所属单据与当前不一致，请返回任务中心核对');
    }
    final selectedDocuments = draftStrings(data['selectedDocumentIds']);
    if (selectedDocuments.toSet().length != selectedDocuments.length ||
        !documents.containsAll(selectedDocuments)) {
      throw const FormatException('原点收草稿的所选单据已变化，请返回任务中心核对');
    }
    final fingerprint = data['fingerprint'] as String?;
    final key = data['idempotencyKey'] as String?;
    final uncertain =
        data['uncertain'] == true || formDraftHasUnknownSubmission;
    final selected = selectedDocuments.toList()..sort();
    if (uncertain &&
        (key?.trim().isNotEmpty != true ||
            selected.isEmpty ||
            fingerprint != _fingerprint(selected, savedItems, itemDocuments))) {
      throw const FormatException('原批量点收提交身份不完整，请返回任务中心核对');
    }
    // Commit the restored snapshot only after every identity check succeeds.
    _targets = targets;
    _selectedItemDocuments = itemDocuments;
    _selectedDocumentIds
      ..clear()
      ..addAll(selectedDocuments);
    _batchSelectionFingerprint = fingerprint;
    _batchIdempotencyKey = key;
    _uncertain = uncertain;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    _selectedDocumentIds.addAll(
      widget.targets
          .map((task) => task.documentId)
          .whereType<String>()
          .where((id) => id.isNotEmpty),
    );
    Future.microtask(initializeFormDraft);
  }

  /// 幂等键随选择集派生：选择不变重试复用同键（服务端按 用户+键 去重安全重放）。
  String _batchKey(Set<String> ids) {
    final sorted = ids.toList()..sort();
    final fingerprint = _selectionFingerprint(sorted);
    if (_batchSelectionFingerprint != fingerprint ||
        _batchIdempotencyKey == null) {
      _batchSelectionFingerprint = fingerprint;
      _batchIdempotencyKey = 'finished-in-batch-${const Uuid().v4()}';
    }
    return _batchIdempotencyKey!;
  }

  Map<String, String> get _orderedItemDocuments =>
      _sortedItemDocuments(_selectedItemDocuments);

  static Map<String, String> _sortedItemDocuments(Map<String, String> values) =>
      {for (final item in values.keys.toList()..sort()) item: values[item]!};

  static List<String>? _readSelectedItems(Object? raw) {
    if (raw == null) return null;
    if (raw is! List || raw.any((id) => id is! String)) {
      throw const FormatException('原点收草稿的明细标识不完整，请返回任务中心核对');
    }
    final items = raw.cast<String>();
    WarehouseTaskItemSelection(items).validate(items);
    return items.toList()..sort();
  }

  static Map<String, String> _readItemDocuments(
    Object? raw,
    List<String>? items,
    Set<String> documents,
  ) {
    if (raw is! Map ||
        raw.entries.any(
          (entry) =>
              entry.key is! String ||
              entry.value is! String ||
              (entry.key as String).trim().isEmpty ||
              (entry.value as String).trim().isEmpty,
        )) {
      throw const FormatException('原点收草稿缺少明细所属单据，请返回任务中心核对');
    }
    final mapping = raw.cast<String, String>();
    if (items == null
        ? mapping.isNotEmpty
        : mapping.length != items.length ||
              !mapping.keys.toSet().containsAll(items) ||
              !documents.containsAll(mapping.values)) {
      throw const FormatException('原点收草稿的明细所属单据不完整，请返回任务中心核对');
    }
    return Map.of(mapping);
  }

  static String _fingerprint(
    List<String> documents,
    List<String>? items,
    Map<String, String> mapping,
  ) => items == null
      ? documents.join('|')
      : '${documents.join('|')}#${(items.where((item) => documents.contains(mapping[item])).toList()..sort()).join('|')}';

  String _selectionFingerprint(List<String> sorted) =>
      _fingerprint(sorted, widget.selectedItemIds, _selectedItemDocuments);

  List<String> _itemsForDocuments(Iterable<String> documents) {
    _readItemDocuments(
      _selectedItemDocuments,
      _readSelectedItems(widget.selectedItemIds),
      _targets.map((task) => task.documentId).whereType<String>().toSet(),
    );
    return [
      for (final item in widget.selectedItemIds ?? <String>[])
        if (documents.contains(_selectedItemDocuments[item])) item,
    ];
  }

  Future<void> _submit() async {
    if (_busy || _selectedDocumentIds.isEmpty || formDraftRestorationBlocked) {
      return;
    }
    setState(() => _preparing = true);
    try {
      final scope = await captureFormDraftRequestScope();
      await scope.run(() => _submitScoped(scope));
      scope.checkCurrent();
    } catch (error) {
      if (error is ApiException && error.code == 'SESSION_CHANGED') {
        invalidateFormDraftIdentity();
      }
      if (mounted) context.appApiError(error, fallback: '本次尚未发送，请保留页面后重试');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _submitScoped(AuthenticatedRequestScope requestScope) async {
    if (!ref.read(isSuperAdminProvider) &&
        !ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove)) {
      context.appWarning('当前账号没有仓库入库确认权限');
      return;
    }
    final ids = _selectedDocumentIds.toList()..sort();
    List<String>? items;
    try {
      if (widget.selectedItemIds != null) {
        items = _itemsForDocuments(ids);
        if (items.isEmpty) throw const FormatException('本次没有可点收的所选明细');
      }
    } on FormatException catch (error) {
      context.appWarning(error.message);
      return;
    }
    // 2026-09-12：原一整段连排确认文案改「短要点」，高度与宽度由 UtenDialog
    // 统一兜（限宽 460 / 限高 60% 屏高 / 超出自滚）。
    final confirmed = await UtenDialog.show(
      context,
      title: '确认所选点收（${ids.length} 张）',
      confirmLabel: '确认批量入库',
      content: _confirmPoints(Theme.of(context), [
        widget.selectedItemIds == null
            ? '按每张单当前全部待点收数量执行实物接收。'
            : '仅点收本次所选 ${items!.length} 项明细，未选明细继续保留待点收。',
        '整批一起办理：只要有一张填的有问题，本次入库整批都不会生效（不会只成功一半）。',
        '存在短收或拒收时，请取消并返回逐单处理。',
      ]),
    );
    if (confirmed != true || !mounted) return;
    requestScope.checkCurrent();
    if (!formDraftIdentityIsCurrent ||
        (!ref.read(isSuperAdminProvider) &&
            !ref
                .read(currentPermissionsProvider)
                .contains(Perm.stockDocApprove))) {
      return;
    }
    final key = _batchKey(ids.toSet());
    setState(() => _saving = true);
    try {
      _uncertain = true;
      final result = await runFormDraftSubmission(
        () => ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .confirmAll(documentIds: ids, idempotencyKey: key, itemIds: items),
      );
      requestScope.checkCurrent();
      if (!mounted) return;
      _uncertain = false;
      await completeFormDraft();
      requestScope.checkCurrent();
      if (!mounted) return;
      context.appSuccess(
        result.replay
            ? '该批次已办理过，本次没有重复入库（共 ${result.confirmedCount} 张）'
            : '已批量全量点收 ${result.confirmedCount} 张产成品入库任务',
      );
      // 徽章兜底：宿主待点收视图 pop 返回后会重拉任务计数，深链直入本页时
      // 仓库徽章也要即时跟上（与其它批量入库页口径一致）。
      refreshBadges(ref);
      if (context.canPop()) {
        context.pop(true);
      } else {
        backTo(
          context,
          defaultPath: RouteName.warehouseProductionFinishedInboundTasks,
        );
      }
    } on ApiException catch (error) {
      if (error.httpStatus == 400 ||
          error.httpStatus == 422 ||
          (error.httpStatus == 409 && error.code == 'CONFLICT')) {
        _uncertain = false;
        await saveFormDraftNow();
      }
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('批量点收入库失败，请保持当前选择后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _confirmPoints(ThemeData theme, List<String> points) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final point in points)
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Text('· $point', style: theme.textTheme.bodyMedium),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _targets
        .where((task) => (task.documentId ?? '').isNotEmpty)
        .toList(growable: false);
    return withFormDraft(
      PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: UtenAppBar(
            title: '批量点收 · ${rows.length} 张',
            leading: UtenBackButton(
              color: _busy ? theme.disabledColor : null,
              enabled: !_busy,
              onPressed: () => popOrBackTo(
                context,
                defaultPath: RouteName.warehouseProductionFinishedInboundTasks,
              ),
            ),
          ),
          body: SafeArea(
            child: Stack(
              children: [
                AbsorbPointer(
                  absorbing: _busy,
                  child: UtenContentContainer.wide(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: rows.isEmpty
                              ? const UtenEmpty(
                                  icon: Icons.inventory_rounded,
                                  message: '所选任务状态已变化',
                                  description: '请返回任务中心刷新后重新选择。',
                                )
                              : _buildTable(rows),
                        ),
                      ],
                    ),
                  ),
                ),
                // 2026-09-12 用户口径：批量全量点收提交期间屏幕中间加载动画。
                if (_saving)
                  const Positioned.fill(
                    child: UtenBusyOverlay(
                      title: '正在批量全量点收',
                      description: '正在一次性写入库存和入库记录，请稍候。',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable(List<ProductionFinishedInboundTask> rows) {
    return UtenPageEdgePadding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      // 上滑先把提示文案收完、表格顶到屏顶再滚表内（全站联动口径）。
      child: UtenCollapsingHeaderScrollView(
        collapsingHeader: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.selectedItemIds == null
                  ? '默认全选。取消勾选的单据继续保留待点收。'
                  : '只办理任务中心所选明细，未选明细继续保留待点收。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s8),
          ],
        ),
        body: MasterDataTableView<ProductionFinishedInboundTask>(
          expensiveRowMounts: false,
          tableKey:
              'features.warehouse.pages.production_finished_batch_stock_in_page.ProductionFinishedBatchStockInPageState._buildTable.1',
          key: const Key('production-finished-batch-stock-in-table'),
          // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
          primary: true,
          columns: _columns,
          items: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          selectable: true,
          batchActionsBuilder:
              ref
                  .watch(currentPermissionsProvider)
                  .contains(Perm.stockDocApprove)
              ? (_, _) => _batchActions()
              : null,
          idOf: (task) => task.documentId,
          selectedIds: _selectedDocumentIds,
          onSelectedIdsChanged: (next) => setState(() {
            if (_busy || _uncertain) return;
            _selectedDocumentIds
              ..clear()
              ..addAll(next);
          }),
          emptyMessage: '没有可点收任务',
          showFullscreenToggle: false,
          bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
        ),
      ),
    );
  }

  /// 表格统一管理唯一一组右下浮动「已选」与批量提交，不重复渲染顶部计数。
  List<Widget> _batchActions() {
    final count = _selectedDocumentIds.length;
    return [
      UtenButton(
        key: const Key('production-finished-batch-confirm'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.inventory_rounded,
        isLoading: _saving,
        onPressed: _busy || count == 0 ? null : _submit,
        onDisabledTap: count == 0
            ? () => context.appWarning('请先勾选待点收任务')
            : null,
        child: Text('确认批量入库($count)'),
      ),
    ];
  }

  List<MasterColumnDef<ProductionFinishedInboundTask>> get _columns => [
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'status',
      label: '状态',
      width: 120,
      value: (task) =>
          _uncertain && _selectedDocumentIds.contains(task.documentId)
          ? '结果待核对'
          : '待点收',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      // 2026-09-25 单号列统一：本页全量加载，就地排序+按值筛选。
      key: 'taskNo',
      sortable: true,
      filterFromRows: true,
      label: '入库单号',
      width: 180,
      value: (task) => task.documentNo ?? task.taskId,
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'planNo',
      sortable: true,
      filterFromRows: true,
      label: '生产计划',
      width: 160,
      value: (task) => task.planNo ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'reportNos',
      label: '报工单',
      width: 180,
      value: (task) => task.reportNos ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'goodsSummary',
      label: '货品',
      width: 260,
      value: (task) => task.goodsSummary ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'warehouseName',
      label: '仓库',
      width: 150,
      value: (task) => task.warehouseName ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'pendingQty',
      label: '待点收数量',
      width: 200,
      type: 'number',
      value: (task) => _quantity(task.pendingQty),
      // ADR-148：服务端拼好的「其中实际超产 N」跟在数量后(没有实际超产不显示)。
      cellBuilder: (context, task) {
        final note = task.actualSurplusNote;
        if (note == null || note.isEmpty) {
          return Text(_quantity(task.pendingQty));
        }
        final theme = Theme.of(context);
        return Text.rich(
          TextSpan(
            text: _quantity(task.pendingQty),
            children: [
              TextSpan(
                text: ' ($note)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'lineCount',
      label: '实物批数',
      // ADR-148：同一报工、同一产出批次的需求份 / 计划公共 / 实际超产合在一起算一批。
      info: '一批实物 = 同一报工、同一次录入送入仓库的需求份、计划公共备货与实际超产，合在一起登记、判定和点收。',
      width: 100,
      type: 'number',
      value: (task) => '${task.lineCount}',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'documentDate',
      label: '单据日期',
      width: 120,
      type: 'date',
      value: (task) => ChinaDateTime.formatDate(task.documentDate),
    ),
  ];

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
