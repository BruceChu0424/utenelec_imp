import '../../../../core/performance/json_value_snapshot.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/inputs/uten_input_decoration.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../../components/layout/uten_collapsible_section.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/network/authenticated_request_scope.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/drafts/form_draft_catalog.dart';
import '../../../../shared/drafts/form_draft_mixin.dart';
import '../../../../shared/drafts/form_draft_store.dart';
import '../../../../shared/providers/master_name_provider.dart';
import '../../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../../shared/widgets/warehouse_selection.dart';
import '../../providers/warehouse_count_refresh.dart';
import '../../widgets/warehouse_task_session_guard.dart';
import '../models/workshop_material_models.dart';
import '../models/workshop_source_warehouse_option.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_first_use_card.dart';
import '../widgets/workshop_material_labels.dart';
import '../widgets/workshop_material_line_grid.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class _BatchSupplement {
  _BatchSupplement(this.periods);
  final List<WmPeriod> periods;
  final reason = TextEditingController();
  bool enabled = false;
  String? periodId;
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'periodId': periodId,
    'reason': reason.text,
  };
}

/// Selected lines share one editable inbound/outbound table and confirmation.
class WorkshopMaterialIssueBatchPage extends ConsumerStatefulWidget {
  const WorkshopMaterialIssueBatchPage({
    super.key,
    required this.selections,
    this.resumeDraftId,
  });
  final Map<String, List<String>> selections;
  final String? resumeDraftId;
  @override
  ConsumerState<WorkshopMaterialIssueBatchPage> createState() =>
      _WorkshopMaterialIssueBatchPageState();
}

class _WorkshopMaterialIssueBatchPageState
    extends ConsumerState<WorkshopMaterialIssueBatchPage>
    with
        FormDraftMixin<WorkshopMaterialIssueBatchPage>,
        WarehouseTaskSessionGuard<WorkshopMaterialIssueBatchPage> {
  final _grid = UtenEditableGridController<WmIssueLineRow>();
  final _requests = <String, WmRequisition>{};
  final _lineRequests = <String, String>{};
  final _commands = <String, Map<String, dynamic>>{};
  final _completed = <String>{};
  final _configuredGoods = <String>{};
  final _materialSetups = <String, Map<String, dynamic>>{};
  final _setupInitials = <String, Map<String, dynamic>>{};
  final _supplements = <String, _BatchSupplement>{};
  final _sourceProblems = <String, String>{};
  final _unavailableSources = <String>{};
  final _retainedRows = <Map<String, dynamic>>[];
  final _retainedSupplements = <String, Map<String, dynamic>>{};
  final _sourceVersions = <String, int>{};
  bool _recoveryValidated = false;
  List<WarehouseDictEntry> _warehouses = const [];
  String _nonce = const Uuid().v4();
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _isReturn = false;
  int _rowSequence = 0;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);
  bool get _explicitRecovery => widget.resumeDraftId != null;
  bool get _hasAuthority =>
      warehouseTaskCanWrite &&
      formDraftIdentityIsCurrent &&
      !formDraftRestorationBlocked &&
      (!_explicitRecovery || _recoveryValidated) &&
      (ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.workshopMaterialIssue));
  bool get _unknown =>
      _commands.values.any((command) => command['state'] == 'unknown');
  List<String> get _readableUnknownIds => [
    for (final id in _selection.keys)
      if (_commands[id]?['state'] == 'unknown' &&
          _requests.containsKey(id) &&
          !_unavailableSources.contains(id))
        id,
  ];
  bool get _hasSourceProblems =>
      _sourceProblems.keys.any((id) => !_completed.contains(id));
  String? _requestId(WmIssueLineRow row) =>
      _lineRequests[row.requisitionLine?.id];
  bool _editable(WmIssueLineRow row) =>
      _hasAuthority &&
      !_saving &&
      !_completed.contains(_requestId(row)) &&
      !_commands.containsKey(_requestId(row)) &&
      !_sourceProblems.containsKey(_requestId(row)) &&
      row.requisitionLine!.fulfilledQty == 0 &&
      _requests[_requestId(row)]?.can(WmAction.fulfil) == true;
  bool get _canSubmit =>
      _hasAuthority &&
      !_loading &&
      !_saving &&
      (_unknown
          ? _readableUnknownIds.isNotEmpty
          : !_hasSourceProblems &&
                _requests.keys.any(
                  (id) =>
                      !_completed.contains(id) &&
                      _requests[id]!.can(WmAction.fulfil),
                ));
  String get _confirmLabel => _unknown
      ? '原样重试核对结果'
      : _isReturn
      ? '确认入库'
      : '确认出库';
  String get _returnPath => Uri(
    path: RouteName.warehouseTasks,
    queryParameters: {
      'group': _isReturn ? 'inbound' : 'outbound',
      'section': _isReturn ? 'RETURN' : 'DRAW',
    },
  ).toString();
  static Map<String, List<String>> _canonical(
    Map<String, List<String>> selections,
  ) {
    final entries = selections.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return {
      for (final entry in entries) entry.key: entry.value.toList()..sort(),
    };
  }

  Map<String, List<String>> get _selection => _canonical(widget.selections);

  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.workshopMaterialBatchIssue
      .spec(routeParameters: {'selections': jsonEncode(_selection)});
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _saving || _loading;
  @override
  bool get formDraftCanReplaySubmission => _unknown;
  @override
  bool get formDraftHasUnknownSubmission =>
      _explicitRecovery && !_recoveryValidated
      ? super.formDraftHasUnknownSubmission
      : _unknown;
  @override
  Object? captureFormDraftPlatformFields() => null;
  @override
  Future<void> restoreFormDraftPlatformFields(Object? snapshot) async {}
  @override
  Iterable<Listenable> get formDraftListenables => [
    _grid,
    for (final supplement in _supplements.values) supplement.reason,
    for (final row in _grid.rows) ...[row.qty, row.bags, row.leafWarehouseId],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'selections': _selection,
    'nonce': _nonce,
    'versions': _sourceVersions,
    'commands': _commands,
    'configuredGoods': _configuredGoods.toList(),
    'materialSetups': {..._setupInitials, ..._materialSetups},
    'supplements': {
      for (final entry in _supplements.entries) entry.key: entry.value.toJson(),
      ..._retainedSupplements,
    },
    'rows': [
      for (final row in _grid.rows)
        {
          'lineId': row.requisitionLine!.id,
          'goodsId': row.goodsId,
          'colorId': row.colorId,
          'qty': row.qty.text,
          'bags': row.bags.text,
          'leafWarehouseId': row.leafWarehouseId.value,
          'platformFields': row.platformFields.exportDraft(),
        },
      ..._retainedRows,
    ],
    formDraftUnknownSubmissionKey: _unknown,
  };

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (jsonEncode(data['selections']) != jsonEncode(_selection) ||
        data['nonce'] is! String) {
      throw const FormatException('草稿与本次所选明细不一致');
    }
    _nonce = data['nonce'] as String;
    final commands = data['commands'];
    if (commands is! Map) throw const FormatException('草稿缺少原提交状态');
    for (final entry in commands.entries) {
      final id = entry.key as String;
      final command = Map<String, dynamic>.from(entry.value as Map);
      final body = command['body'];
      if (!_selection.containsKey(id) ||
          body is! Map ||
          body['id'] != id ||
          body['v'] is! int ||
          !const ['unknown', 'confirmed'].contains(command['state']) ||
          wmIdempotencyKey('fulfil', _nonce, body) != command['key']) {
        throw const FormatException('原提交身份不完整，请保留草稿核对');
      }
      final lineIds = (body['lines'] as List)
          .map((row) => (row as Map)['lineId'])
          .toSet();
      final rawPrior = body['priorHandledLineIds'] ?? const <String>[];
      if (rawPrior is! List ||
          rawPrior.any((line) => line is! String) ||
          rawPrior.toSet().length != rawPrior.length) {
        throw const FormatException('原提交缺少已办明细依据');
      }
      final prior = rawPrior.cast<String>().toSet();
      final scope = _selection[id]!.toSet();
      final all = {...lineIds, ...prior};
      if (lineIds.isEmpty ||
          lineIds.intersection(prior).isNotEmpty ||
          all.length != scope.length ||
          !scope.containsAll(all) ||
          (!_unavailableSources.contains(id) &&
              !prior.every(
                (line) => _requests[id]!.lines.any(
                  (current) => current.id == line && current.fulfilledQty > 0,
                ),
              ))) {
        throw const FormatException('原提交范围不属于本次选择');
      }
      _commands[id] = command;
      if (command['state'] == 'confirmed') {
        if (_requests[id]?.lines
                .where((line) => scope.contains(line.id))
                .every((line) => line.fulfilledQty > 0) ==
            true) {
          _completed.add(id);
        } else if (!_unavailableSources.contains(id)) {
          command['state'] = 'unknown';
          _completed.remove(id);
        }
      }
    }
    _configuredGoods.addAll((data['configuredGoods'] as List).cast<String>());
    final versions = data['versions'];
    if (versions is! Map ||
        versions.length != _selection.length ||
        !_selection.keys.every(
          (id) => versions[id] is int && (versions[id] as int) >= 0,
        )) {
      throw const FormatException('草稿缺少原申请版本依据');
    }
    _sourceVersions
      ..clear()
      ..addAll(versions.cast<String, int>());
    for (final entry in _requests.entries) {
      if (!_completed.contains(entry.key) &&
          !_commands.containsKey(entry.key) &&
          versions[entry.key] != entry.value.rowVersion) {
        _sourceProblems.putIfAbsent(entry.key, () => '申请已变化，本次未办理');
      }
    }
    final originals = {
      for (final row in _grid.rows) row.requisitionLine!.id: row,
    };
    final restored = <WmIssueLineRow>[];
    final owners = <String, String>{};
    for (final entry in _selection.entries) {
      for (final line in entry.value) {
        if (owners.putIfAbsent(line, () => entry.key) != entry.key) {
          throw const FormatException('同一明细不能属于两张申请');
        }
      }
    }
    final restoredIds = <String>{};
    _retainedRows.clear();
    for (final raw in data['rows'] as List) {
      final saved = raw as Map;
      final owner = owners[saved['lineId']];
      if (owner == null) throw const FormatException('草稿包含原选择以外的明细');
      restoredIds.add(saved['lineId'] as String);
      if (_unavailableSources.contains(owner)) {
        _retainedRows.add(Map<String, dynamic>.from(saved));
        continue;
      }
      final original = originals[saved['lineId']];
      if (original == null ||
          original.goodsId != saved['goodsId'] ||
          original.colorId != saved['colorId']) {
        throw const FormatException('草稿包含不属于本次选择的明细');
      }
      final row =
          _newRow(
              original.requisitionLine!,
              original.material.value,
              leaf: saved['leafWarehouseId'] as String?,
            )
            ..qty.text = saved['qty'] as String
            ..bags.text = saved['bags'] as String;
      row.platformFields.restoreDraft(saved['platformFields']);
      restored.add(row);
    }
    if (restoredIds.length != owners.length ||
        !restoredIds.containsAll(owners.keys)) {
      throw const FormatException('草稿缺少原选明细');
    }
    _grid.replaceAll(restored);
    for (final entry in (data['materialSetups'] as Map).entries) {
      _setupInitials[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    _materialSetups.clear();
    if (data['supplements'] case final Map<Object?, Object?> saved) {
      for (final entry in saved.entries) {
        final supplement = _supplements[entry.key];
        final raw = entry.value as Map;
        if (!_selection.containsKey(entry.key)) {
          throw const FormatException('补录来源不属于当前批次');
        }
        if (supplement == null && _sourceProblems.containsKey(entry.key)) {
          _retainedSupplements[entry.key as String] = Map<String, dynamic>.from(
            raw,
          );
          continue;
        }
        if (supplement == null) throw const FormatException('补录来源不属于当前批次');
        supplement.enabled = raw['enabled'] == true;
        supplement.periodId = raw['periodId'] as String?;
        supplement.reason.text = raw['reason'] as String? ?? '';
        if (supplement.enabled &&
            !_commands.containsKey(entry.key) &&
            !supplement.periods.any(
              (period) => period.id == supplement.periodId,
            )) {
          _sourceProblems.putIfAbsent(
            entry.key as String,
            () => '补录期间已变化，本次未办理',
          );
        }
      }
    }
    if (_unavailableSources.isNotEmpty &&
        (_commands.isEmpty || (_unknown && _readableUnknownIds.isEmpty))) {
      throw const FormatException('原提交当前不可读取，请保留草稿并重新核对查看权限');
    }
    _recoveryValidated = true;
  }

  @override
  void initState() {
    super.initState();
    startWarehouseTaskGuard();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant WorkshopMaterialIssueBatchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(_canonical(oldWidget.selections)) !=
            jsonEncode(_selection) ||
        oldWidget.resumeDraftId != widget.resumeDraftId) {
      invalidateWarehouseTask();
    }
  }

  @override
  void onWarehouseTaskInvalidated() {
    invalidateFormDraftIdentity();
    setState(() {
      _requests.clear();
      _lineRequests.clear();
      _warehouses = const [];
      _grid.replaceAll([]);
      _loading = false;
      _saving = false;
      _error = '登录身份、权限或服务器已变化，请重新进入任务列表';
    });
  }

  @override
  void dispose() {
    for (final supplement in _supplements.values) {
      supplement.reason.dispose();
    }
    _grid.dispose();
    super.dispose();
  }

  WmIssueLineRow _newRow(
    WmRequisitionLine line,
    WmMaterialOption? material, {
    String? leaf,
  }) => WmIssueLineRow(
    id: 'r${++_rowSequence}',
    requisitionLine: line,
    material: material,
    leafWarehouseId:
        leaf ??
        line.suggestedLeafWarehouseId ??
        material?.defaultLeafWarehouseId,
  );

  Future<void> _load() async {
    if (!warehouseTaskIsCurrent) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '请重新登录后进入任务列表';
        });
      }
      return;
    }
    try {
      final scope = await captureWarehouseTaskScope();
      await scope.run(() async {
        if (_selection.isEmpty ||
            _selection.length > 100 ||
            _selection.entries.any(
              (entry) =>
                  entry.key.isEmpty ||
                  entry.value.isEmpty ||
                  entry.value.toSet().length != entry.value.length ||
                  entry.value.any((id) => id.isEmpty),
            )) {
          throw ApiException('SELECTION_REQUIRED', '请返回任务列表选择要办理的明细');
        }
        var sources = <WmSourceWarehouse>[];
        bool warehousesUnavailable = false;
        try {
          sources = await _repo.sourceWarehouses();
        } catch (error) {
          scope.checkCurrent();
          if (!_explicitRecovery || isSessionBoundaryError(error)) rethrow;
          warehousesUnavailable = true;
        }
        scope.checkCurrent();
        final requests = <String, WmRequisition>{};
        final rows = <WmIssueLineRow>[];
        String? kind;
        for (final entry in _selection.entries) {
          late WmRequisition request;
          try {
            request = await _repo.requisition(entry.key);
            scope.checkCurrent();
            if (request.id != entry.key ||
                !entry.value.every(
                  (id) => request.lines.any((line) => line.id == id),
                )) {
              throw ApiException('SELECTION_CHANGED', '所选明细已变化，请返回任务列表刷新');
            }
          } catch (error) {
            scope.checkCurrent();
            if (!_explicitRecovery || isSessionBoundaryError(error)) rethrow;
            _unavailableSources.add(entry.key);
            _sourceProblems[entry.key] = '当前不可读取，本次未办理';
            continue;
          }
          kind ??= request.kind;
          if (request.kind != kind) {
            throw ApiException('SELECTION_CHANGED', '所选明细已变化，领料和退料请分别办理');
          }
          final selected = request.lines
              .where((line) => entry.value.contains(line.id))
              .toList();
          if (!request.isPending &&
              selected.any((line) => line.fulfilledQty == 0)) {
            if (!_explicitRecovery) {
              throw ApiException('SELECTION_CHANGED', '原申请状态已变化，请返回任务列表刷新');
            }
            _sourceProblems[entry.key] = request.status == 'CANCELLED'
                ? '已取消，本次未办理'
                : '申请已变化，本次未办理';
          }
          if (warehousesUnavailable) {
            _sourceProblems.putIfAbsent(entry.key, () => '仓库信息不可读取，本次未办理');
          }
          final materials = <WmMaterialOption>[];
          try {
            if (request.workshopDepartmentId case final workshop?) {
              if (request.isReturn) {
                materials.addAll(await _repo.materials(workshop));
              } else {
                var page = 1;
                while (true) {
                  final result = await _repo.requestMaterials(
                    workshop,
                    goodsIds: selected
                        .map((line) => line.goodsId)
                        .toSet()
                        .toList(),
                    page: page,
                    size: 100,
                  );
                  scope.checkCurrent();
                  materials.addAll(result.items);
                  if (page >= result.totalPages) break;
                  page++;
                }
              }
            }
          } catch (error) {
            scope.checkCurrent();
            if (!_explicitRecovery || isSessionBoundaryError(error)) rethrow;
            _sourceProblems.putIfAbsent(entry.key, () => '材料信息不可读取，本次未办理');
          }
          scope.checkCurrent();
          requests[entry.key] = request;
          _sourceVersions[entry.key] = request.rowVersion;
          if (!request.isReturn && request.binWarehouseId != null) {
            final bin = request.binWarehouseId!;
            try {
              final periods = await _repo.periods(bin);
              scope.checkCurrent();
              _supplements[entry.key] = _BatchSupplement(
                periods
                    .where(
                      (period) =>
                          period.status == WmPeriodStatus.counting ||
                          period.status == WmPeriodStatus.counted,
                    )
                    .toList(),
              );
            } catch (error) {
              scope.checkCurrent();
              if (!_explicitRecovery || isSessionBoundaryError(error)) rethrow;
              _sourceProblems.putIfAbsent(entry.key, () => '期间信息不可读取，本次未办理');
            }
          }
          for (final line in selected) {
            final material = materials
                .where((m) => m.key == line.key)
                .firstOrNull;
            rows.add(
              _newRow(line, material)
                ..qty.text = wmQty(
                  line.fulfilledQty > 0 ? line.fulfilledQty : line.requestedQty,
                  maxDecimals: 4,
                )
                ..bags.text = line.requestedBags == null
                    ? ''
                    : wmQty(line.requestedBags),
            );
          }
        }
        scope.checkCurrent();
        setState(() {
          _warehouses = [for (final source in sources) source.toDictEntry()];
          _requests.addAll(requests);
          for (final request in requests.values) {
            for (final line in request.lines) {
              _lineRequests[line.id] = request.id;
            }
            if (rows
                .where((row) => request.lines.contains(row.requisitionLine))
                .every((row) => row.requisitionLine!.fulfilledQty > 0)) {
              _completed.add(request.id);
            }
          }
          _grid.replaceAll(rows);
          _isReturn = kind == 'RETURN';
          _loading = false;
          if (_hasSourceProblems) {
            _error = '部分原申请已变化或当前不可读取；未办理明细仍保留在原批次，可先核对原提交结果。';
          }
        });
      });
      await initializeFormDraft();
    } catch (error) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _loading = false;
          _error = describeSubmitError(error, fallback: '加载失败，请重试');
        });
      }
    }
  }

  Map<String, WmRequisitionLine> get _firstUse => {
    if (!_isReturn)
      for (final row in _grid.rows)
        if (!_completed.contains(_requestId(row)) &&
            !_commands.containsKey(_requestId(row)) &&
            !_sourceProblems.containsKey(_requestId(row)) &&
            row.requisitionLine!.needsMaterialSetup &&
            !_configuredGoods.contains(row.goodsId))
          row.goodsId!: row.requisitionLine!,
  };
  bool get _canConfigure =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsEdit,
        Perm.goodsBomEdit,
      });
  Map<String, dynamic> _freeze(String id) {
    if (_sourceProblems[id] case final problem?) throw StateError(problem);
    if (_requests[id]?.can(WmAction.fulfil) != true ||
        _requests[id]?.isPending != true) {
      throw StateError('所选申请当前不可办理，请返回任务列表刷新');
    }
    final rows = _grid.rows
        .where(
          (row) =>
              _requestId(row) == id && row.requisitionLine!.fulfilledQty == 0,
        )
        .toList();
    WmIssueLineRow? firstInvalid;
    if (rows.isEmpty ||
        rows.any((row) {
          final invalid =
              (row.qtyValue ?? 0) <= 0 || row.leafWarehouseId.value == null;
          if (invalid) firstInvalid = row;
          return invalid;
        })) {
      if (firstInvalid case final row?) {
        unawaited(
          _grid.revealError(
            row,
            columnKey: (row.qtyValue ?? 0) <= 0 ? 'qty' : 'leaf',
          ),
        );
      }
      throw StateError('请核对每行的本次数量和仓库');
    }
    final seen = <String>{};
    if (rows.any((row) {
      final duplicate = !seen.add(
        '${row.requisitionLine!.id}|${row.leafWarehouseId.value}',
      );
      if (duplicate) firstInvalid = row;
      return duplicate;
    })) {
      if (firstInvalid case final row?) {
        unawaited(_grid.revealError(row, columnKey: 'leaf'));
      }
      throw StateError('同一明细在同一仓库填写了两行，请合并数量');
    }
    final setupIds =
        rows
            .where(
              (row) =>
                  row.requisitionLine!.needsMaterialSetup &&
                  !_configuredGoods.contains(row.goodsId),
            )
            .map((row) => row.goodsId!)
            .toSet()
            .toList()
          ..sort();
    if (!_isReturn &&
        setupIds.any(
          (id) => !_canConfigure || !_materialSetups.containsKey(id),
        )) {
      throw StateError('请先核对首次材料用途及全局 BOM 影响，再确认出库');
    }
    final supplement = _supplements[id];
    if (supplement?.enabled == true &&
        (!supplement!.periods.any(
              (period) => period.id == supplement.periodId,
            ) ||
            supplement.reason.text.trim().length < 2)) {
      throw StateError('请核对补录期间并填写漏录原因');
    }
    final body = {
      'id': id,
      'v': _requests[id]!.rowVersion,
      'priorHandledLineIds':
          (_grid.rows
              .where(
                (row) =>
                    _requestId(row) == id &&
                    row.requisitionLine!.fulfilledQty > 0,
              )
              .map((row) => row.requisitionLine!.id)
              .toSet()
              .toList()
            ..sort()),
      'lines': [
        for (final row in rows)
          {
            'lineId': row.requisitionLine!.id,
            'qty': row.qtyValue,
            'leafWarehouseId': row.leafWarehouseId.value,
          },
      ],
      'materialSetup': [
        if (!_isReturn)
          for (final id in setupIds) _materialSetups[id]!,
      ],
      'supplement': supplement?.enabled == true
          ? {
              'periodId': supplement!.periodId,
              'reason': supplement.reason.text.trim(),
            }
          : null,
    };
    return {
      'state': 'unknown',
      'body': JsonValueSnapshot.capture(body).data,
      'key': wmIdempotencyKey('fulfil', _nonce, body),
    };
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final recovering = _unknown;
    try {
      if (!recovering) {
        for (final id in _selection.keys) {
          if (!_completed.contains(id) && !_commands.containsKey(id)) {
            _freeze(id);
          }
        }
      }
    } catch (error) {
      setState(
        () => _error = describeSubmitError(error, fallback: '请核对本次数量和仓库'),
      );
      return;
    }
    setState(() {
      _saving = true;
      _confirming = true;
      _error = null;
    });
    try {
      final scope = await captureWarehouseTaskScope();
      if (!mounted) return;
      final confirmed = await UtenDialog.show(
        context,
        title: _isReturn ? '确认生产退料入库' : '确认生产领料出库',
        confirmLabel: _isReturn ? '确认入库' : '确认出库',
        danger: true,
        content: Text(
          '仅办理本次所选 ${_selection.values.fold<int>(0, (n, ids) => n + ids.length)} 项，未选明细继续保留待办。',
        ),
      );
      if (confirmed != true || !scope.isCurrent) return;
      setState(() => _confirming = false);
      final recoveryIds = _readableUnknownIds;
      final orderedIds = [
        ...recoveryIds,
        for (final id in _selection.keys)
          if (!recoveryIds.contains(id)) id,
      ];
      for (final id in orderedIds) {
        final existing = _commands[id];
        if (_completed.contains(id) && existing?['state'] != 'unknown') {
          continue;
        }
        final wasUnknown = existing?['state'] == 'unknown';
        if (_unavailableSources.contains(id) ||
            (!wasUnknown && (_sourceProblems.containsKey(id) || _unknown))) {
          continue;
        }
        var dispatched = false;
        try {
          final command = existing ?? _freeze(id);
          _commands[id] = command;
          await saveFormDraftNow();
          final body = command['body'] as Map;
          await runFormDraftSubmission(
            () => scope.run(() {
              dispatched = true;
              return _repo.fulfil(
                id,
                expectedVersion: body['v'] as int,
                lines: [
                  for (final row in body['lines'] as List)
                    Map<String, dynamic>.from(row as Map),
                ],
                materialSetup: [
                  for (final row in body['materialSetup'] as List)
                    Map<String, dynamic>.from(row as Map),
                ],
                supplement: body['supplement'] is Map
                    ? WmSupplement(
                        periodId:
                            (body['supplement'] as Map)['periodId'] as String,
                        reason: (body['supplement'] as Map)['reason'] as String,
                      )
                    : null,
                idempotencyKey: command['key'] as String,
              );
            }),
            isDefiniteRejection: (error) => !wasUnknown && _definite(error),
          );
          scope.checkCurrent();
          setState(() {
            command['state'] = 'confirmed';
            _completed.add(id);
            for (final setup in body['materialSetup'] as List) {
              _configuredGoods.add((setup as Map)['goodsId'] as String);
            }
          });
          await saveFormDraftNow();
        } catch (error) {
          if (!scope.isCurrent) return;
          final rejected =
              !wasUnknown &&
              (!dispatched || error is ApiException && _definite(error));
          if (rejected) {
            _commands.remove(id);
          }
          setState(
            () => _error = rejected
                ? describeSubmitError(error, fallback: '本次未提交，请保留页面重试')
                : '本批已暂停，原提交结果待确认；请原样重试核对结果，已完成的明细不会重复办理。',
          );
          try {
            if (rejected) await releaseFormDraftBeforeDispatch();
            await saveFormDraftNow();
          } catch (_) {}
          break;
        }
      }
      if (!mounted || !scope.isCurrent) return;
      if (recovering && !_unknown && _hasSourceProblems) {
        final checkpoint = ref
            .read(formDraftsProvider)
            .where((draft) => draft.id == formDraftRecoveryId)
            .firstOrNull;
        if (checkpoint != null && !checkpoint.hasUnknownSubmission) {
          adoptFormDraftRecoveryCheckpoint(checkpoint);
        }
        setState(() => _error = '原提交结果已核对；仍有申请已取消、变化或当前不可读取，相关明细本次未办理，草稿已保留。');
      }
      invalidateWarehouseTaskCounts(ref);
      if (_completed.length == _selection.length && !_unknown) {
        await completeFormDraft();
        if (mounted && warehouseTaskIsCurrent) {
          context.appSuccess(_isReturn ? '所选明细已入库' : '所选明细已出库');
        }
      }
    } catch (error) {
      if (warehouseTaskIsCurrent) {
        setState(
          () => _error = describeSubmitError(error, fallback: '请保留页面重试'),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _confirming = false;
        });
      }
    }
  }

  bool _definite(ApiException error) =>
      !isSessionBoundaryError(error) &&
      ((error.hasResponseCode &&
              const [400, 403, 404, 409, 422].contains(error.httpStatus) &&
              !const [
                'IDEMPOTENCY_IN_PROGRESS',
                'IDEMPOTENCY_CONFLICT',
              ].contains(error.code)) ||
          const ['STOCK_SHORT', 'CONFLICT'].contains(error.code));

  Future<String?> _pickWarehouse(WmIssueLineRow row) async {
    if (!_editable(row)) return null;
    final result = await showUtenWarehousePickerPanel(
      context,
      hierarchy: _warehouses,
      use: _isReturn ? WarehouseUse.goodIn : WarehouseUse.goodOut,
      initialWarehouseId: row.leafWarehouseId.value,
      title: _isReturn ? '选择入库仓库' : '选择出库仓库',
      subtitleOf: _isReturn
          ? null
          : (entry) {
              final quantity =
                  row.material.value?.leafWarehouses
                      .where((stock) => stock.warehouseId == entry.id)
                      .firstOrNull
                      ?.availableQty ??
                  0;
              return quantity > 0
                  ? '可发 ${wmQty(quantity)} ${row.requisitionLine!.unitName ?? ''}'
                  : null;
            },
    );
    return !_editable(row) || result == null || result.isAll ? null : result.id;
  }

  void _split(WmIssueLineRow row) {
    if (_editable(row)) {
      _grid.insertAt(
        _grid.rows.indexOf(row) + 1,
        _newRow(
          row.requisitionLine!,
          row.material.value,
          leaf: row.leafWarehouseId.value,
        ),
      );
    }
  }

  Future<void> _close() async {
    if (!_saving && await confirmFormDraftExit() && mounted) {
      backTo(context, defaultPath: _returnPath);
    }
  }

  String _status(WmIssueLineRow row) =>
      _commands[_requestId(row)]?['state'] == 'unknown'
      ? '结果待核对'
      : _completed.contains(_requestId(row)) ||
            row.requisitionLine!.fulfilledQty > 0
      ? (_isReturn ? '已入库' : '已出库')
      : _sourceProblems[_requestId(row)] ?? (_isReturn ? '待入库' : '待出库');

  List<EditableGridColumn<WmIssueLineRow>> _columns(AppLocalizations l10n) {
    final shared = wmIssueLineColumns(
      l10n: l10n,
      grid: _grid,
      materials: const [],
      materialLabel: '货品名称',
      propagateSelectedChanges: false,
      enabled: _hasAuthority && !_saving,
      editableOf: _editable,
      materialEditable: false,
      showLeafWarehouse: true,
      leafLabel: _isReturn ? '入库仓库' : '出库仓库',
      qtyLabel: _isReturn ? '本次入库' : '本次出库',
      showWarehouseAvailable: !_isReturn,
      pickLeafWarehouse: _pickWarehouse,
      warehouseNameOf: (id) => warehouseFullLabel(_warehouses, id) ?? '',
      onChanged: markFormDraftChanged,
    );
    final byKey = {for (final column in shared) column.key: column};
    return [
      EditableGridColumn(
        key: 'result',
        label: '状态',
        width: 180,
        cellBuilder: (context, row) => Text(_status(row)),
        textOf: _status,
      ),
      EditableGridColumn(
        key: 'billNo',
        label: '单号',
        width: 170,
        cellBuilder: (context, row) =>
            Text(_requests[_requestId(row)]!.requestNo),
        textOf: (row) => _requests[_requestId(row)]!.requestNo,
      ),
      EditableGridColumn(
        key: 'workshop',
        label: '车间',
        width: 110,
        cellBuilder: (context, row) =>
            Text(_requests[_requestId(row)]!.workshopName ?? ''),
        textOf: (row) => _requests[_requestId(row)]!.workshopName ?? '',
      ),
      byKey['material']!,
      byKey['qty']!,
      if (_grid.rows.any(
        (row) => (row.bagNet ?? 0) > 0 || row.bags.text.isNotEmpty,
      ))
        byKey['bags']!,
      byKey['leaf']!,
      for (final column in shared)
        if (!const {'material', 'qty', 'leaf', 'bags'}.contains(column.key))
          column,
    ];
  }

  bool _supplementEditable(String id) =>
      _hasAuthority &&
      !_saving &&
      !_completed.contains(id) &&
      !_commands.containsKey(id) &&
      !_sourceProblems.containsKey(id);

  Widget _supplementOptions() => UtenCollapsibleSection(
    title: '补录前期发料',
    initiallyExpanded: false,
    child: Column(
      children: [
        for (final entry in _supplements.entries)
          if (entry.value.periods.isNotEmpty) ...[
            CheckboxListTile(
              key: ValueKey('wm-batch-supplement-${entry.key}'),
              contentPadding: EdgeInsets.zero,
              value: entry.value.enabled,
              title: Text('${_requests[entry.key]!.requestNo} · 这批料是前期漏录的'),
              onChanged: !_supplementEditable(entry.key)
                  ? null
                  : (value) => setState(() {
                      entry.value.enabled = value == true;
                      if (entry.value.enabled &&
                          entry.value.periods.length == 1) {
                        entry.value.periodId = entry.value.periods.single.id;
                      }
                    }),
            ),
            if (entry.value.enabled)
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s12,
                children: [
                  SizedBox(
                    width: 300,
                    child: UtenDropdownField(
                      label: '补到哪一期',
                      value: entry.value.periodId,
                      allowClear: false,
                      enabled: _supplementEditable(entry.key),
                      items: [
                        for (final period in entry.value.periods)
                          UtenDropdownItem(
                            value: period.id,
                            label: wmPeriodLabel(period),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => entry.value.periodId = value),
                    ),
                  ),
                  SizedBox(
                    width: 420,
                    child: TextField(
                      key: ValueKey('wm-batch-supplement-reason-${entry.key}'),
                      controller: entry.value.reason,
                      enabled: _supplementEditable(entry.key),
                      maxLength: 500,
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '漏录原因', counterText: ''),
                      ),
                    ),
                  ),
                ],
              ),
          ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final l10n = AppLocalizations.of(context);
    final count = _selection.values.fold<int>(0, (n, ids) => n + ids.length);
    return withFormDraft(
      PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: UtenAppBar(
            title: _isReturn ? '生产退料批量入库' : '生产领料批量出库',
            leading: UtenBackButton(enabled: !_saving, onPressed: _close),
          ),
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton: _loading || _requests.isEmpty
              ? null
              : UtenFloatingActionGroup(
                  children: [
                    UtenSelectionSummaryPill(count: count),
                    if (_canSubmit)
                      UtenButton(
                        key: const Key('wm-issue-submit'),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
                        onPressed: _submit,
                        child: Text(_confirmLabel),
                      ),
                  ],
                ),
          body: Stack(
            children: [
              UtenContentContainer.wide(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _requests.isEmpty
                    ? UtenEmpty.error(
                        message: _error ?? '所选任务不可用',
                        actionLabel: '重试',
                        onAction: _load,
                      )
                    : UtenCollapsingHeaderScrollView(
                        collapsingHeader: UtenPageEdgePadding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final id in _unavailableSources)
                                UtenInlineNotice(
                                  key: ValueKey('wm-unavailable-source-$id'),
                                  title:
                                      '原申请 $id（已选 ${_selection[id]!.length} 项）',
                                  message:
                                      '${_commands[id]?['state'] == 'unknown' ? '当前不可读取，原提交结果仍待核对' : '当前不可读取，本次未办理'}。'
                                      '原选择明细：${_selection[id]!.join('、')}。原记录继续保留在本机草稿。',
                                ),
                              if (!_isReturn &&
                                  _supplements.values.any(
                                    (item) => item.periods.any(
                                      (period) =>
                                          period.status ==
                                          WmPeriodStatus.counting,
                                    ),
                                  ))
                                const UtenInlineNotice(
                                  message: '正在盘点的车间，本次发料计入下一期；前期漏录可展开补录。',
                                ),
                              if (!_isReturn &&
                                  _supplements.values.any(
                                    (item) => item.periods.isNotEmpty,
                                  ))
                                _supplementOptions(),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: UtenSpacing.s8,
                                  ),
                                  child: Text(
                                    _error!,
                                    key: const Key('wm-issue-error'),
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              for (final entry in _firstUse.entries)
                                WorkshopMaterialFirstUseCard(
                                  key: ValueKey(
                                    'wm-batch-first-use-${entry.key}',
                                  ),
                                  goodsId: entry.key,
                                  goodsName:
                                      entry.value.goodsName ??
                                      entry.value.displayName,
                                  canConfigure: _canConfigure,
                                  initialSetup: _setupInitials[entry.key],
                                  enabled: !_saving && _hasAuthority,
                                  onChanged: (setup) => setState(() {
                                    if (setup == null) {
                                      _materialSetups.remove(entry.key);
                                    } else {
                                      _materialSetups[entry.key] = setup;
                                    }
                                  }),
                                ),
                            ],
                          ),
                        ),
                        body: Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenFloatingActionGroup.scrollClearance,
                          ),
                          child: UtenEditableGrid<WmIssueLineRow>(
                            key: const Key('wm-issue-grid'),
                            controller: _grid,
                            tableKey:
                                'warehouse.workshopRequisition.batchOutbound',
                            columns: _columns(l10n),
                            showAddRow: false,
                            canSelectRow: _editable,
                            canDeleteRow: (row) =>
                                _editable(row) &&
                                _grid.rows
                                        .where(
                                          (other) =>
                                              other.requisitionLine!.id ==
                                              row.requisitionLine!.id,
                                        )
                                        .length >
                                    1,
                            confirmDelete: false,
                            rowMenuExtraBuilder: (context, selected) => [
                              UtenMenuItem(
                                label: '分到另一个仓库',
                                icon: Icons.call_split_outlined,
                                enabled:
                                    selected.length == 1 &&
                                    _editable(selected.first),
                                onTap: () => _split(selected.first),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              if (_saving && !_confirming)
                const UtenBusyOverlay(title: '正在办理所选明细'),
            ],
          ),
        ),
      ),
    );
  }
}
