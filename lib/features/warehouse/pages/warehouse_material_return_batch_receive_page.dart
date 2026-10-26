// 生产退料批量收料页（2026-09-27 用户口径「生产退料里应该支持多选批量入库，
// 和其他的比如出库可以批量操作一样」）：从仓库任务中心「生产退料」段勾选多张
// 待收料单进入；每张单选一个实际收料仓（范围=退料单主仓下的有效正常仓，与单张
// 详情页的收料弹窗同一约束），右下「确认批量收料(N)」逐张提交——幂等键与单张
// 收料同配方（material-return-confirm|单据|仓库），单张失败即停并保留进度。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/async/bounded_read_map.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../models/stock_doc.dart';
import '../models/warehouse_task_item_selection.dart';
import '../repositories/stock_doc_repository.dart';

class WarehouseMaterialReturnBatchReceivePage extends ConsumerStatefulWidget {
  const WarehouseMaterialReturnBatchReceivePage({
    super.key,
    required this.documentIds,
    this.selectedItemIds,
  });

  final List<String> documentIds;
  final List<String>? selectedItemIds;

  @override
  ConsumerState<WarehouseMaterialReturnBatchReceivePage> createState() =>
      _WarehouseMaterialReturnBatchReceivePageState();
}

class _Row {
  _Row(this.detail);

  final StockDocDetail detail;
  String? warehouseId;
  bool done = false;
  int warehouseEditRevision = 0;
}

class _WarehouseMaterialReturnBatchReceivePageState
    extends ConsumerState<WarehouseMaterialReturnBatchReceivePage>
    with FormDraftMixin<WarehouseMaterialReturnBatchReceivePage> {
  final List<_Row> _rows = [];
  bool _loading = false;
  bool _saving = false;
  String? _error;
  String? _pendingDocumentId;
  bool _uncertain = false;
  Map<String, dynamic>? _pendingCommand;
  final Set<String> _blockedSources = {};
  final Map<String, List<String>> _sourceItemIds = {};
  final Set<String> _incompleteDocuments = {};
  int _loadGeneration = 0;

  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  bool get formDraftHasUnknownSubmission =>
      _uncertain && _pendingDocumentId != null;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.materialReturnBatchReceive.spec(
        title: '批量生产退料收仓',
        route: Uri(
          path: FormDraftCatalog.materialReturnBatchReceive.route,
          queryParameters: {
            'documentIds': widget.documentIds.join(','),
            ...WarehouseTaskItemSelection(
              widget.selectedItemIds,
            ).queryParameters,
          },
        ).toString(),
      );
  @override
  Map<String, dynamic> captureFormDraft() => {
    'documentIds': widget.documentIds,
    'selectedItemIds': widget.selectedItemIds,
    'pendingDocumentId': _pendingDocumentId,
    'uncertain': _uncertain,
    'pendingCommand': _pendingCommand,
    'blockedSources': _blockedSources.toList(),
    'rows': [
      for (final row in _rows)
        {
          'documentId': row.detail.id,
          'warehouseId': row.warehouseId,
          'done': row.done,
          'itemIds':
              _sourceItemIds[row.detail.id] ??
              row.detail.items
                  .map((item) => item.id)
                  .whereType<String>()
                  .toList(),
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if ((draftStrings(data['selectedItemIds'])..sort()).join(',') !=
        ((widget.selectedItemIds ?? []).toList()..sort()).join(',')) {
      throw const FormatException('原退料草稿的所选明细与当前不一致，请返回任务中心核对');
    }
    final sources = draftStrings(data['documentIds']).toSet();
    if (sources.length != widget.documentIds.toSet().length ||
        !sources.containsAll(widget.documentIds)) {
      throw const FormatException('原批次退料来源不一致，填写保留，请返回任务中心核对');
    }
    final saved = {
      for (final row in draftMaps(data['rows'])) row['documentId']: row,
    };
    for (final row in _rows) {
      final checkpoint = saved[row.detail.id];
      if (checkpoint == null) continue;
      if (_blockedSources.contains(row.detail.id)) continue;
      row.warehouseEditRevision++;
      row.warehouseId = checkpoint['warehouseId'] as String?;
      row.done = checkpoint['done'] == true && row.detail.status == 1;
    }
    _pendingDocumentId = data['pendingDocumentId'] as String?;
    _uncertain = data['uncertain'] == true || formDraftHasUnknownSubmission;
    if (_uncertain && _pendingDocumentId == null) {
      throw const FormatException('原待核对收料缺少来源身份，请保留草稿核对');
    }
    if (_pendingDocumentId != null &&
        !widget.documentIds.contains(_pendingDocumentId)) {
      throw const FormatException('原待核对收料来源不属于本批');
    }
    if (data['pendingCommand'] case final Map<Object?, Object?> raw) {
      _pendingCommand = Map<String, dynamic>.from(raw);
      _validatePendingCommand();
    }
    if (mounted) setState(() {});
  }

  void _validatePendingCommand() {
    final command = _pendingCommand;
    if (command == null) return;
    final id = command['documentId'];
    final warehouse = command['warehouseId'];
    final items = command['itemIds'];
    if (id != _pendingDocumentId ||
        !widget.documentIds.contains(id) ||
        warehouse is! String ||
        warehouse.isEmpty ||
        command['idempotencyKey'] !=
            businessIdempotencyKey(
              'material-return-confirm',
              '$id|$warehouse',
            ) ||
        (widget.selectedItemIds != null && items == null) ||
        (items != null &&
            (items is! List ||
                items.isEmpty ||
                items.any(
                  (item) =>
                      item is! String ||
                      !WarehouseTaskItemSelection(
                        widget.selectedItemIds,
                      ).contains(item),
                ) ||
                items.toSet().length != items.length))) {
      throw const FormatException('原收料命令身份或明细不完整，请保留草稿核对');
    }
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    final generation = ++_loadGeneration;
    final ownerCurrent = captureReadOwner(ref);
    final sourceIds = widget.documentIds.toList(growable: false);
    final itemIds = widget.selectedItemIds?.toList(growable: false);
    bool current() =>
        ownerCurrent() &&
        formDraftIdentityIsCurrent &&
        generation == _loadGeneration &&
        listEquals(widget.documentIds, sourceIds) &&
        listEquals(widget.selectedItemIds, itemIds);
    final warehouseNames = ref
        .read(masterNameServiceProvider)
        .ensureWarehousesLoaded();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(formDraftsProvider.notifier).ready;
      if (!mounted || !formDraftIdentityIsCurrent) return;
      final resumeId = goRouterPageStateOrNull(
        context,
      )?.uri.queryParameters['draftId'];
      final saved = ref
          .read(formDraftsProvider)
          .where((draft) => draft.id == resumeId)
          .firstOrNull;
      if (saved != null) {
        if (!formDraftSpec.canRestore(
          saved,
          currentRoute: formDraftSpec.route,
        )) {
          throw const FormatException('原批次身份不一致');
        }
        _pendingDocumentId = saved.data['pendingDocumentId'] as String?;
        _uncertain =
            saved.data['uncertain'] == true || saved.hasUnknownSubmission;
        if (saved.data['pendingCommand'] case final Map<Object?, Object?> raw) {
          _pendingCommand = Map<String, dynamic>.from(raw);
        }
        _validatePendingCommand();
        for (final row in draftMaps(saved.data['rows'])) {
          final id = row['documentId'];
          if (id is String && widget.documentIds.contains(id)) {
            _sourceItemIds[id] = draftStrings(row['itemIds']);
          }
        }
      }
      final recovering =
          _uncertain ||
          _rows.any((row) => row.done) ||
          (saved != null &&
              (draftMaps(
                    saved.data['rows'],
                  ).any((row) => row['done'] == true) ||
                  draftStrings(saved.data['blockedSources']).isNotEmpty));
      final repo = ref.read(stockDocRepositoryProvider(StockDocType.wdraw));
      final blocked = <String>{};
      final details = await boundedReadMap(widget.documentIds, (id) async {
        try {
          final detail = await repo.detail(id);
          if (detail.id != id) throw const FormatException('退料来源不一致');
          return detail;
        } catch (_) {
          if (!recovering) rethrow;
          blocked.add(id);
          return StockDocDetail(id: id, docType: StockDocType.wdraw.code);
        }
      }, isCurrent: current);
      if (!current()) return;
      final selection = WarehouseTaskItemSelection(widget.selectedItemIds);
      selection.validate([
        ...details.expand((document) => document.items).map((item) => item.id),
        if (recovering && blocked.isNotEmpty) ...?widget.selectedItemIds,
      ]);
      _incompleteDocuments.clear();
      for (var index = 0; index < details.length; index++) {
        final detail = details[index];
        if (blocked.contains(detail.id)) continue;
        final originalIds = _sourceItemIds[detail.id];
        final currentIds = detail.items
            .map((item) => item.id)
            .whereType<String>()
            .toSet();
        if (recovering &&
            ((detail.status != 0 && detail.status != 1) ||
                (originalIds != null &&
                    originalIds.isNotEmpty &&
                    (currentIds.length != originalIds.length ||
                        !currentIds.containsAll(originalIds))))) {
          blocked.add(detail.id);
          details[index] = StockDocDetail(
            id: detail.id,
            docType: StockDocType.wdraw.code,
          );
          continue;
        }
        final items = detail.items
            .where((item) => selection.contains(item.id))
            .toList();
        if (items.length != detail.items.length) {
          if (recovering && detail.id != _pendingDocumentId) {
            blocked.add(detail.id);
            details[index] = StockDocDetail(
              id: detail.id,
              docType: StockDocType.wdraw.code,
            );
            continue;
          }
          _incompleteDocuments.add(detail.id);
        }
        details[index] = detail.withItems(items);
        final ids = items.map((item) => item.id).whereType<String>().toList();
        final frozen = _pendingCommand?['itemIds'];
        if (detail.id == _pendingDocumentId && frozen is List) {
          if (ids.length != frozen.length || !ids.toSet().containsAll(frozen)) {
            blocked.add(detail.id);
            details[index] = StockDocDetail(
              id: detail.id,
              docType: StockDocType.wdraw.code,
            );
            continue;
          }
        }
        if (detail.id != _pendingDocumentId ||
            !_sourceItemIds.containsKey(detail.id)) {
          _sourceItemIds[detail.id] = ids;
        }
      }
      if (!current()) return;
      final previous = {for (final row in _rows) row.detail.id: row};
      setState(() {
        _blockedSources
          ..clear()
          ..addAll(blocked);
        _rows
          ..clear()
          ..addAll([
            for (final detail in details)
              _Row(detail)
                ..warehouseId =
                    (_blockedSources.contains(detail.id)
                        ? null
                        : previous[detail.id]?.warehouseId) ??
                    _initialWarehouse(detail)
                ..warehouseEditRevision =
                    previous[detail.id]?.warehouseEditRevision ?? 0
                ..done =
                    !_blockedSources.contains(detail.id) &&
                    (previous[detail.id]?.done ?? false),
          ]);
      });
      unawaited(_publishWarehouseOptions(warehouseNames, current));
      await initializeFormDraft();
    } on ApiException catch (e) {
      if (!current()) return;
      setState(() => _error = '退料单没有加载出来：${e.message}');
    } catch (_) {
      if (!current()) return;
      setState(() => _error = '退料单没有加载出来，请稍后重试');
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  /// 默认收料仓：单据自带仓在本主仓有效范围内就直接沿用，否则留空待选。
  Future<void> _publishWarehouseOptions(
    Future<void> names,
    bool Function() current,
  ) async {
    final rows = {for (final row in _rows) row: row.warehouseEditRevision};
    try {
      await names;
      if (!current()) return;
      setState(() {
        for (final entry in rows.entries) {
          final row = entry.key;
          if (!_rows.contains(row) ||
              row.done ||
              _blockedSources.contains(row.detail.id) ||
              row.warehouseId != null ||
              row.warehouseEditRevision != 0 ||
              row.warehouseEditRevision != entry.value) {
            continue;
          }
          row.warehouseId = _initialWarehouse(row.detail);
        }
      });
    } catch (_) {
      // Warehouse options remain retryable; never replace entered row values.
    }
  }

  String? _initialWarehouse(StockDocDetail detail) {
    final allowed = _allowedWarehouseIds(detail);
    final initial = detail.warehouseId;
    return initial != null && allowed.contains(initial) ? initial : null;
  }

  Set<String> _allowedWarehouseIds(StockDocDetail detail) {
    final hierarchy = ref.read(masterNameServiceProvider).warehouseHierarchy;
    final eligible = WarehouseSelection(
      hierarchy,
      use: WarehouseUse.goodIn,
    ).selectableIds;
    final mainId = detail.materialReturnMainWarehouseId;
    return hierarchy
        .where(
          (entry) =>
              mainId != null &&
              warehousesShareMain(hierarchy, mainId, entry.id),
        )
        .map((entry) => entry.id)
        .where(eligible.contains)
        .toSet();
  }

  bool get _allPicked =>
      _rows.isNotEmpty &&
      (_uncertain && _pendingDocumentId != null
          ? _rows.any(
              (row) =>
                  row.detail.id == _pendingDocumentId &&
                  !_blockedSources.contains(row.detail.id) &&
                  row.warehouseId != null,
            )
          : _rows.any(
                  (row) =>
                      !row.done && !_blockedSources.contains(row.detail.id),
                ) &&
                _rows
                    .where((row) => !_blockedSources.contains(row.detail.id))
                    .every((row) => row.done || row.warehouseId != null));

  Future<void> _submit() async {
    if (_saving || !_allPicked) return;
    if (_rows.any(
      (row) =>
          !row.done &&
          !_blockedSources.contains(row.detail.id) &&
          (!_uncertain || row.detail.id == _pendingDocumentId) &&
          _incompleteDocuments.contains(row.detail.id),
    )) {
      context.appWarning('该退料单需整单确认，请返回任务中心选齐同单明细；本次未收料');
      return;
    }
    if (!formDraftIdentityIsCurrent ||
        (!ref.read(isSuperAdminProvider) &&
            !ref
                .read(currentPermissionsProvider)
                .contains(Perm.stockDocApprove))) {
      return;
    }
    if (!_uncertain &&
        _rows.any(
          (row) =>
              !row.done &&
              !_blockedSources.contains(row.detail.id) &&
              !_allowedWarehouseIds(row.detail).contains(row.warehouseId),
        )) {
      context.appWarning('实际收料仓范围已变化，请重新选择；已填写内容保留');
      return;
    }
    final requestScopeFuture = captureFormDraftRequestScope();
    setState(() => _saving = true);
    final repo = ref.read(stockDocRepositoryProvider(StockDocType.wdraw));
    final wasUnknown = _uncertain;
    try {
      final requestScope = await requestScopeFuture;
      var done = 0;
      _uncertain = true;
      await runFormDraftSubmission(
        () => requestScope.run(() async {
          for (final row in _rows.where(
            (row) =>
                !_blockedSources.contains(row.detail.id) &&
                (!wasUnknown || row.detail.id == _pendingDocumentId),
          )) {
            if (row.done) continue;
            requestScope.checkCurrent();
            if (!mounted ||
                !formDraftIdentityIsCurrent ||
                (!ref.read(isSuperAdminProvider) &&
                    !ref
                        .read(currentPermissionsProvider)
                        .contains(Perm.stockDocApprove))) {
              throw ApiException('SESSION_CHANGED', '身份或收料权限已变化，已成功收料保留，本次停止');
            }
            final warehouseId =
                (wasUnknown
                    ? (_pendingCommand?['warehouseId'] as String?)
                    : null) ??
                row.warehouseId!;
            _pendingDocumentId = row.detail.id;
            _pendingCommand ??= {
              'documentId': row.detail.id,
              'warehouseId': warehouseId,
              'idempotencyKey': businessIdempotencyKey(
                'material-return-confirm',
                '${row.detail.id}|$warehouseId',
              ),
              'itemIds': widget.selectedItemIds == null
                  ? null
                  : row.detail.items
                        .map((item) => item.id)
                        .whereType<String>()
                        .toList(),
            };
            _validatePendingCommand();
            if (wasUnknown) {
              final fresh = await repo.detail(row.detail.id);
              requestScope.checkCurrent();
              final expected = (_pendingCommand!['itemIds'] as List?)
                  ?.cast<String>();
              final actual = fresh.items
                  .map((item) => item.id)
                  .whereType<String>()
                  .toSet();
              if (fresh.id != row.detail.id ||
                  (expected != null &&
                      (actual.length != expected.length ||
                          !actual.containsAll(expected)))) {
                throw const FormatException('原收料明细范围已变化，请保留原命令核对');
              }
            }
            await saveFormDraftNow();
            requestScope.checkCurrent();
            final result = await repo.confirmMaterialReturn(
              row.detail.id,
              warehouseId: warehouseId,
              idempotencyKey: _pendingCommand!['idempotencyKey'] as String,
              itemIds: (_pendingCommand!['itemIds'] as List?)?.cast<String>(),
            );
            requestScope.checkCurrent();
            if (result.id != row.detail.id ||
                result.status != 1 ||
                result.warehouseId != warehouseId) {
              throw StateError('原收料回执不完整，继续保留原命令');
            }
            row.done = true;
            _pendingDocumentId = null;
            _pendingCommand = null;
            done++;
            await saveFormDraftNow();
          }
        }),
        isDefiniteRejection: (error) =>
            !wasUnknown &&
            (error.httpStatus == 400 ||
                error.httpStatus == 422 ||
                error.httpStatus == 409 && error.code == 'CONFLICT'),
      );
      if (!mounted) return;
      _uncertain = false;
      if (_rows.any((row) => !row.done)) {
        await saveFormDraftNow();
        if (mounted) context.appInfo('已核对收料 $done 张，其余来源继续保留未派发');
        return;
      }
      await completeFormDraft();
      if (!mounted) return;
      context.appSuccess('已收料 $done 张退料单，库存与车间台账已更新');
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        backTo(context, defaultPath: RouteName.warehouseTasks);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (wasUnknown &&
          _pendingDocumentId != null &&
          const [403, 404].contains(e.httpStatus)) {
        final id = _pendingDocumentId!;
        setState(() {
          _blockedSources.add(id);
          final index = _rows.indexWhere((row) => row.detail.id == id);
          if (index >= 0) {
            _rows[index] = _Row(
              StockDocDetail(id: id, docType: StockDocType.wdraw.code),
            );
          }
        });
      }
      context.appError('${e.message}（已收成功的都保留了，重试只会补收还没收的单）');
      if (!wasUnknown &&
          (e.httpStatus == 400 ||
              e.httpStatus == 422 ||
              (e.httpStatus == 409 && e.code == 'CONFLICT'))) {
        _uncertain = false;
        _pendingDocumentId = null;
        _pendingCommand = null;
        await saveFormDraftNow();
      }
    } catch (_) {
      if (!mounted) return;
      context.appError('批量收料中断，已收成功的都保留了；请稍后重试，重试只会补收还没收的单');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final canApprove =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.stockDocApprove);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '批量收料 · ${widget.documentIds.length} 张退料单',
          leading: const UtenBackButton(),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing: _saving,
                child: UtenContentContainer.wide(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!),
                              const SizedBox(height: UtenSpacing.s8),
                              UtenButton(
                                onPressed: _load,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          itemCount: _rows.length,
                          itemBuilder: (context, index) {
                            final row = _rows[index];
                            final detail = row.detail;
                            if (_blockedSources.contains(detail.id)) {
                              return Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(
                                    UtenSpacing.s12,
                                  ),
                                  child: Text(
                                    '来源 ${detail.id} 当前不可读取或原范围已变化；${detail.id == _pendingDocumentId ? '原结果继续待核对，不能重放' : '本次未派发，原范围保留'}',
                                  ),
                                ),
                              );
                            }
                            final allowed = _allowedWarehouseIds(detail);
                            final scoped = names.warehouseHierarchy
                                .where((entry) => allowed.contains(entry.id))
                                .toList();
                            final billDate = detail.billDate ?? '';
                            return Card(
                              margin: const EdgeInsets.only(
                                bottom: UtenSpacing.s8,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(UtenSpacing.s12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_incompleteDocuments.contains(
                                      detail.id,
                                    ))
                                      Text(
                                        '该退料单需整单确认，请返回任务中心选齐同单明细',
                                        style: TextStyle(
                                          color: theme.colorScheme.error,
                                        ),
                                      ),
                                    Row(
                                      children: [
                                        Text(
                                          detail.billNo ?? detail.id,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(width: UtenSpacing.s8),
                                        Expanded(
                                          child: Text(
                                            '${billDate.length >= 10 ? billDate.substring(0, 10) : billDate} · '
                                            '${names.department(detail.departmentId)} · '
                                            '${detail.items.length} 行物料',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                        if (row.done)
                                          Text(
                                            '已收料',
                                            style: theme.textTheme.labelLarge
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.primary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: UtenSpacing.s8),
                                    UtenDropdownField(
                                      key: ValueKey(
                                        'material-return-batch-warehouse-${detail.id}',
                                      ),
                                      label: '实际收料仓库',
                                      required: true,
                                      allowClear: false,
                                      value: row.warehouseId,
                                      items: warehouseHierarchyItems(
                                        scoped,
                                        use: WarehouseUse.goodIn,
                                      ),
                                      info: '余料进入这里选择的正常仓库；来源记录用于追溯。',
                                      errorMessage:
                                          detail.materialReturnMainWarehouseId ==
                                              null
                                          ? '来源主仓还没读到，请刷新'
                                          : allowed.isEmpty
                                          ? '此主仓下暂无有效正常收料仓库'
                                          : null,
                                      enabled: !row.done && !_uncertain,
                                      onChanged: (value) => setState(() {
                                        if (row.done || _uncertain) return;
                                        row.warehouseEditRevision++;
                                        row.warehouseId =
                                            allowed.contains(value)
                                            ? value
                                            : null;
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    onPressed: _saving
                        ? null
                        : () {
                            if (Navigator.of(context).canPop()) {
                              Navigator.of(context).pop(false);
                            } else {
                              backTo(
                                context,
                                defaultPath: RouteName.warehouseTasks,
                              );
                            }
                          },
                    child: const Text('取消'),
                  ),
                  UtenButton(
                    key: const Key('material-return-batch-confirm'),
                    icon: Icons.move_to_inbox_rounded,
                    isLoading: _saving,
                    onPressed: _saving || !_allPicked || !canApprove
                        ? null
                        : _submit,
                    child: Text(
                      _uncertain
                          ? '原样核对待确认收料'
                          : '确认批量收料(${_rows.where((r) => !r.done && !_blockedSources.contains(r.detail.id)).length})',
                    ),
                  ),
                ],
              ),
              if (_saving) const UtenBusyOverlay(title: '正在批量收料'),
            ],
          ),
        ),
      ),
    );
  }
}
