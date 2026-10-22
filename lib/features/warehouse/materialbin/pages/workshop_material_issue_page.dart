// 仓库发料到车间内料仓 (/workshop-material/issue, ADR-131 §5.2 / §5.3)。
//
// 三种用法, 同一页:
// - 直接发料 (?mode=direct, 主路径): 选车间、料、数量(几袋) (重量按每袋净重自动算, 可改)、
//   出库仓库 (默认货品归属仓)、领料人 (默认该车间上一次的领料人), 一次确认;
//   同一种料从两个仓库出就填两行。
// - 按申请发料 (?requisitionId=, 车间申请领料): 预填申请量与建议出库仓库, 可按整袋改,
//   同一行可"从另一个仓库再发一部分"。
// - 收退回 (?requisitionId=, 车间退回): 按实收填重量, 选退到哪个仓库。
// 内料仓正在盘点时, 发的料自动算到下一期 (页面提示); 盘点前漏录的发料可勾选
// "这批料是上一期漏录的", 选补到哪一期并写原因。
// 库存不足、版本冲突整笔不成功, 页面保留输入; 原样再点确认是同一个请求号, 不会重复发。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/required_field_decoration.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/inputs/uten_employee_picker.dart';
import '../../../../components/layout/uten_app_bar.dart';
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
import '../../../../core/utils/china_datetime.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/drafts/form_draft_catalog.dart';
import '../../../../shared/drafts/form_draft_mixin.dart';
import '../../../../shared/providers/master_name_provider.dart';
import '../../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../../shared/widgets/warehouse_selection.dart';
import '../../../employee/repositories/employee_repository.dart';
import '../../providers/warehouse_count_refresh.dart';
import '../../widgets/warehouse_task_session_guard.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_labels.dart';
import '../widgets/workshop_material_line_grid.dart';
import '../widgets/workshop_material_first_use_card.dart';
import '../../../employee/repositories/employee_picker_candidates.dart';

class WorkshopMaterialIssuePage extends ConsumerStatefulWidget {
  const WorkshopMaterialIssuePage({
    super.key,
    this.requisitionId,
    this.mode,
    this.selectedLineIds,
    this.onCompleted,
    this.onClose,
    this.batchProgress,
    this.resumeDraftId,
  });

  /// 按申请发料 / 收退回的申请单; 为空 = 直接发料。
  final String? requisitionId;

  /// `direct` = 直接发料 (与不带 requisitionId 等价)。
  final String? mode;
  final Set<String>? selectedLineIds;
  final VoidCallback? onCompleted;
  final VoidCallback? onClose;
  final String? batchProgress;
  final String? resumeDraftId;

  @override
  ConsumerState<WorkshopMaterialIssuePage> createState() =>
      _WorkshopMaterialIssuePageState();
}

class _WorkshopMaterialIssuePageState
    extends ConsumerState<WorkshopMaterialIssuePage>
    with
        FormDraftMixin<WorkshopMaterialIssuePage>,
        WarehouseTaskSessionGuard<WorkshopMaterialIssuePage> {
  final _grid = UtenEditableGridController<WmIssueLineRow>();
  final _supplementReason = TextEditingController();
  String _nonce = const Uuid().v4();
  Map<String, dynamic>? _command;
  int _nextRow = 0;

  bool _loading = true;
  String? _loadError;
  List<WmSetting> _settings = const [];
  String? _workshopId;
  WmRequisition? _requisition;
  List<WmMaterialOption> _materials = const [];

  /// 出库仓库滑窗的仓库层级 (只有元数据; 发料权限就能读, ADR-147)。
  List<WarehouseDictEntry> _leafHierarchy = const [];
  List<WmPeriod> _periods = const [];
  UtenEmployeePickerItem? _receiver;
  bool _supplement = false;
  String? _supplementPeriodId;
  bool _saving = false;
  String? _submitError;
  bool _showValidation = false;
  bool _selectionHandled = false;
  final Map<String, Map<String, dynamic>> _materialSetups = {};
  final Map<String, Map<String, dynamic>> _setupInitials = {};
  int _materialSetupRevision = 0;

  bool get _direct => widget.requisitionId == null || widget.mode == 'direct';
  bool get _editable => _command == null && _canSubmit;
  bool get _canSubmit =>
      warehouseTaskCanWrite &&
      formDraftIdentityIsCurrent &&
      !formDraftRestorationBlocked &&
      (ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.workshopMaterialIssue)) &&
      (_command != null ||
          _direct ||
          (!_selectionHandled &&
              _requisition?.isPending == true &&
              _requisition!.can(WmAction.fulfil)));
  String get _taskCenterPath => Uri(
    path: RouteName.warehouseTasks,
    queryParameters: {
      'group': _isReturn ? 'inbound' : 'outbound',
      'section': _isReturn ? 'RETURN' : 'DRAW',
    },
  ).toString();

  Future<void> _close() async {
    if (_saving || !await confirmFormDraftExit() || !mounted) return;
    if (widget.onClose case final callback?) {
      callback();
    } else {
      backTo(context, defaultPath: _taskCenterPath);
    }
  }

  bool get _canConfigureFirstUse =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsEdit,
        Perm.goodsBomEdit,
      });

  Map<String, WmRequisitionLine> get _firstUseGoods => {
    if (!_direct && !_isReturn)
      for (final row in _filledRows)
        if (row.requisitionLine?.needsMaterialSetup == true)
          row.goodsId!: row.requisitionLine!,
  };

  bool get _firstUseReady =>
      _firstUseGoods.isEmpty ||
      (_canConfigureFirstUse &&
          _firstUseGoods.keys.every(_materialSetups.containsKey));

  List<Map<String, dynamic>> get _materialSetupPayload {
    final ids = _firstUseGoods.keys.toList()..sort();
    return [for (final id in ids) _materialSetups[id]!];
  }

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  WmSetting? get _setting {
    for (final s in _settings) {
      if (s.workshopDepartmentId == _workshopId) return s;
    }
    return null;
  }

  List<WmSetting> get _enabledSettings => [
    for (final s in _settings)
      if (s.periodicEnabled && s.binWarehouseId != null) s,
  ];

  /// 可补录的期间: 盘点中、或已盘点还没结算。
  List<WmPeriod> get _supplementPeriods => [
    for (final p in _periods)
      if (p.status == WmPeriodStatus.counting ||
          p.status == WmPeriodStatus.counted)
        p,
  ];

  bool get _counting =>
      _periods.any((p) => p.status == WmPeriodStatus.counting);

  @override
  void initState() {
    super.initState();
    startWarehouseTaskGuard();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant WorkshopMaterialIssuePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    String source(WorkshopMaterialIssuePage page) => jsonEncode([
      page.requisitionId,
      page.mode,
      page.selectedLineIds == null
          ? null
          : (page.selectedLineIds!.toList()..sort()),
      page.resumeDraftId,
    ]);
    if (source(oldWidget) != source(widget)) invalidateWarehouseTask();
  }

  @override
  void onWarehouseTaskInvalidated() {
    invalidateFormDraftIdentity();
    setState(() {
      _loading = false;
      _saving = false;
      _loadError = '登录身份、权限或服务器已变化，请重新进入页面';
      _materials = const [];
      _requisition = null;
      _settings = const [];
      _leafHierarchy = const [];
      _periods = const [];
      _grid.replaceAll([]);
      _receiver = null;
    });
  }

  @override
  bool get formDraftBusy => _saving || _loading;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftUsesRouterGuard => widget.onClose == null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission => _command != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _grid,
    _supplementReason,
    for (final row in _grid.rows) ...[
      row.qty,
      row.bags,
      row.material,
      row.leafWarehouseId,
    ],
  ];
  @override
  Object? captureFormDraftPlatformFields() => null;
  @override
  Future<void> restoreFormDraftPlatformFields(Object? snapshot) async {}
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.workshopMaterialIssue.spec(
        routeParameters: {
          if (_direct) 'mode': 'direct',
          if (!_direct) 'requisitionId': widget.requisitionId!,
          if (widget.selectedLineIds case final ids?)
            'lineIds': (ids.toList()..sort()).join(','),
        },
      );

  @override
  Map<String, dynamic> captureFormDraft() => {
    'requisitionId': widget.requisitionId,
    'selectedLineIds': widget.selectedLineIds == null
        ? null
        : (widget.selectedLineIds!.toList()..sort()),
    'version': _requisition?.rowVersion,
    'workshopId': _workshopId,
    'receiver': _receiver == null
        ? null
        : {
            'id': _receiver!.id,
            'name': _receiver!.name,
            'code': _receiver!.employeeCode,
          },
    'nonce': _nonce,
    'rows': [
      for (final row in _grid.rows)
        {
          'lineId': row.requisitionLine?.id,
          'goodsId': row.goodsId,
          'colorId': row.colorId,
          'qty': row.qty.text,
          'bags': row.bags.text,
          'leafWarehouseId': row.leafWarehouseId.value,
          'platformFields': row.platformFields.exportDraft(),
        },
    ],
    'supplement': _supplement,
    'supplementPeriodId': _supplementPeriodId,
    'supplementReason': _supplementReason.text,
    'materialSetups': {..._setupInitials, ..._materialSetups},
    'command': _command,
    formDraftUnknownSubmissionKey: _command != null,
  };

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final savedIds = data['selectedLineIds'];
    final selected = widget.selectedLineIds;
    if (data['requisitionId'] != widget.requisitionId ||
        (selected == null
            ? savedIds != null
            : savedIds is! List ||
                  savedIds.length != selected.length ||
                  !selected.containsAll(savedIds.cast<String>()))) {
      throw const FormatException('草稿与当前所选明细不一致');
    }
    final command = data['command'];
    if (command != null) {
      if (command is! Map ||
          command['idempotencyKey'] is! String ||
          (command['idempotencyKey'] as String).isEmpty ||
          !const ['direct', 'fulfil', 'cancel'].contains(command['kind']) ||
          (_direct
              ? command['kind'] != 'direct'
              : command['id'] != widget.requisitionId)) {
        throw const FormatException('原提交身份不完整，请保留草稿核对');
      }
      _command = Map<String, dynamic>.from(command);
    }
    if (!_direct &&
        _command == null &&
        (data['version'] != _requisition?.rowVersion || _selectionHandled)) {
      throw const FormatException('原申请已变化，请保留原草稿并重新核对');
    }
    if (_direct &&
        data['workshopId'] is String &&
        data['workshopId'] != _workshopId) {
      _workshopId = data['workshopId'] as String;
      await _loadWorkshop(_workshopId!, resetRows: true);
    }
    if (!warehouseTaskIsCurrent) throw AuthenticatedRequestScope.changed();
    if (data['nonce'] is! String) throw const FormatException('草稿缺少请求身份');
    _nonce = data['nonce'] as String;
    if (_command case final frozen?) {
      final body = Map<String, dynamic>.of(frozen)..remove('idempotencyKey');
      final kind = frozen['kind'];
      final action = kind == 'direct' ? 'direct-issue' : kind as String;
      if (wmIdempotencyKey(action, _nonce, body) != frozen['idempotencyKey'] ||
          (!_direct && frozen['v'] != data['version']) ||
          (_direct && frozen['workshop'] != data['workshopId'])) {
        throw const FormatException('原提交内容与请求身份不一致，请保留草稿核对');
      }
      if (kind == 'fulfil') {
        final commandLines = frozen['lines'];
        final rowLines = data['rows'];
        if (commandLines is! List || rowLines is! List) {
          throw const FormatException('原提交缺少明细范围');
        }
        final commandIds = commandLines
            .map((r) => (r as Map)['lineId'])
            .toSet();
        final rowIds = rowLines.map((r) => (r as Map)['lineId']).toSet();
        if (commandIds.isEmpty ||
            commandIds.length != rowIds.length ||
            !commandIds.containsAll(rowIds) ||
            (selected != null &&
                (selected.length != commandIds.length ||
                    !selected.containsAll(commandIds)))) {
          throw const FormatException('原提交范围与草稿明细不一致');
        }
      }
    }
    final rows = data['rows'];
    if (rows is! List) throw const FormatException('草稿明细不完整');
    final restored = <WmIssueLineRow>[];
    for (final raw in rows) {
      if (raw is! Map) throw const FormatException('草稿明细不完整');
      final line = _requisition?.lines
          .where((l) => l.id == raw['lineId'])
          .firstOrNull;
      if (!_direct &&
          (line == null ||
              (selected != null && !selected.contains(line.id)) ||
              line.goodsId != raw['goodsId'] ||
              line.colorId != raw['colorId'])) {
        throw const FormatException('草稿包含不属于本次选择的明细');
      }
      final material = _materials
          .where(
            (m) => m.goodsId == raw['goodsId'] && m.colorId == raw['colorId'],
          )
          .firstOrNull;
      if (_direct &&
          material == null &&
          raw['goodsId'] != null &&
          _command == null) {
        throw const FormatException('原材料选项已变化，请重新核对');
      }
      final row =
          _newRow(
              material: material,
              line: line,
              leafWarehouseId: raw['leafWarehouseId'] as String?,
            )
            ..qty.text = raw['qty'] as String? ?? ''
            ..bags.text = raw['bags'] as String? ?? '';
      row.platformFields.restoreDraft(raw['platformFields']);
      restored.add(row);
    }
    if (selected != null &&
        !selected.every(
          (id) => restored.any((row) => row.requisitionLine?.id == id),
        )) {
      throw const FormatException('草稿缺少原选明细');
    }
    _grid.replaceAll(restored);
    final receiver = data['receiver'];
    _receiver = receiver is Map
        ? UtenEmployeePickerItem(
            id: receiver['id'] as String,
            name: receiver['name'] as String,
            employeeCode: receiver['code'] as String?,
          )
        : null;
    _supplement = data['supplement'] == true;
    _supplementPeriodId = data['supplementPeriodId'] as String?;
    _supplementReason.text = data['supplementReason'] as String? ?? '';
    _materialSetups.clear();
    if (data['materialSetups'] case final Map<Object?, Object?> setups) {
      for (final entry in setups.entries) {
        _setupInitials[entry.key as String] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }
    _materialSetupRevision++;
    if (_command != null) {
      _submitError = '原提交结果待确认，填写已锁定；请原样重试核对，不会重新制单。';
    }
  }

  @override
  void dispose() {
    _grid.dispose();
    _supplementReason.dispose();
    super.dispose();
  }

  WmIssueLineRow _newRow({
    WmMaterialOption? material,
    WmRequisitionLine? line,
    String? leafWarehouseId,
  }) => WmIssueLineRow(
    id: 'r${++_nextRow}',
    material: material,
    requisitionLine: line,
    leafWarehouseId: leafWarehouseId,
  );

  WmMaterialOption? _materialFor(String key) {
    for (final m in _materials) {
      if (m.key == key) return m;
    }
    return null;
  }

  Future<void> _load() async {
    if (!warehouseTaskIsCurrent) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '当前登录身份不可用，请重新进入页面';
        });
      }
      return;
    }
    if (_command != null) return;
    try {
      final scope = await captureWarehouseTaskScope();
      await scope.run(_loadSource);
      scope.checkCurrent();
      if (_loadError == null) await initializeFormDraft();
    } catch (error) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _loading = false;
          _loadError = error is ApiException ? error.message : '加载失败，请重试';
        });
      }
    }
  }

  Future<void> _loadSource() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _materialSetups.clear();
      _materialSetupRevision++;
    });
    try {
      final sources = await _repo.sourceWarehouses();
      if (!warehouseTaskIsCurrent) return;
      _leafHierarchy = [for (final w in sources) w.toDictEntry()];
      if (_direct) {
        final settings = await _repo.settings();
        if (!warehouseTaskIsCurrent) return;
        _settings = settings;
        final enabled = _enabledSettings;
        if (enabled.length == 1) {
          _workshopId = enabled.first.workshopDepartmentId;
        }
        if (_workshopId != null) {
          await _loadWorkshop(_workshopId!, resetRows: true);
        } else {
          setState(() => _loading = false);
        }
      } else {
        final requisition = await _repo.requisition(widget.requisitionId!);
        if (!warehouseTaskIsCurrent) return;
        _requisition = requisition;
        final selectedIds = widget.selectedLineIds;
        if (selectedIds != null &&
            (selectedIds.isEmpty ||
                !selectedIds.every(
                  (id) => requisition.lines.any((line) => line.id == id),
                ))) {
          throw ApiException('SELECTION_CHANGED', '所选明细已变化，请返回任务列表重新选择');
        }
        final selectedLines = [
          for (final line in requisition.lines)
            if (selectedIds == null
                ? !requisition.isPending || line.fulfilledQty == 0
                : selectedIds.contains(line.id))
              line,
        ];
        _selectionHandled =
            selectedLines.isNotEmpty &&
            selectedLines.every((line) => line.fulfilledQty > 0);
        if (requisition.isPending &&
            !_selectionHandled &&
            selectedLines.any((line) => line.fulfilledQty > 0)) {
          throw ApiException('SELECTION_CHANGED', '所选明细已经办理，请返回任务列表刷新');
        }
        _workshopId = requisition.workshopDepartmentId;
        final workshopId = requisition.workshopDepartmentId;
        final binId = requisition.binWarehouseId;
        final results = await Future.wait<Object>([
          if (workshopId != null)
            requisition.isReturn
                ? _repo.materials(workshopId)
                : _loadRequestMaterials(workshopId, selectedLines),
          if (binId != null) _repo.periods(binId),
        ]);
        if (!warehouseTaskIsCurrent) return;
        var index = 0;
        if (workshopId != null) {
          _materials = results[index++] as List<WmMaterialOption>;
        }
        if (binId != null) _periods = results[index] as List<WmPeriod>;
        _grid.replaceAll([
          for (final line in selectedLines)
            _newRow(
                line: line,
                material: _materialFor(line.key),
                leafWarehouseId:
                    line.suggestedLeafWarehouseId ??
                    _materialFor(line.key)?.defaultLeafWarehouseId,
              )
              ..qty.text = wmQty(
                line.fulfilledQty > 0 ? line.fulfilledQty : line.requestedQty,
                maxDecimals: 4,
              )
              ..bags.text = line.requestedBags == null
                  ? ''
                  : wmQty(line.requestedBags),
        ]);
        setState(() => _loading = false);
      }
    } on ApiException catch (e) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    } catch (_) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _loading = false;
          _loadError = '加载失败, 请重试';
        });
      }
    }
  }

  /// 按申请精确读取申请里的料，包含仓库尚未确认用途的按单原料。
  Future<List<WmMaterialOption>> _loadRequestMaterials(
    String workshopId,
    List<WmRequisitionLine> lines,
  ) async {
    final goodsIds = lines.map((line) => line.goodsId).toSet().toList();
    if (goodsIds.isEmpty) return const [];
    final materials = <WmMaterialOption>[];
    var page = 1;
    while (true) {
      final result = await _repo.requestMaterials(
        workshopId,
        goodsIds: goodsIds,
        page: page,
        size: 100,
      );
      materials.addAll(result.items);
      if (page >= result.totalPages) return materials;
      page++;
    }
  }

  /// 直接发料换车间: 料的清单、上一次的领料人、期间 (盘点中提示与补录)。
  Future<void> _loadWorkshop(
    String workshopId, {
    bool resetRows = false,
  }) async {
    final scope = await captureWarehouseTaskScope();
    await scope.run(() => _readWorkshop(workshopId, resetRows: resetRows));
    scope.checkCurrent();
  }

  Future<void> _readWorkshop(
    String workshopId, {
    bool resetRows = false,
  }) async {
    final setting = _settings
        .where((s) => s.workshopDepartmentId == workshopId)
        .firstOrNull;
    final binId = setting?.binWarehouseId;
    final results = await Future.wait<Object>([
      _repo.materials(workshopId),
      _repo.directIssueDefaults(workshopId),
      if (binId != null) _repo.periods(binId),
    ]);
    if (!warehouseTaskIsCurrent || _workshopId != workshopId) return;
    final defaults = results[1] as WmDirectIssueDefaults;
    setState(() {
      _materials = results[0] as List<WmMaterialOption>;
      _periods = binId == null ? const [] : results[2] as List<WmPeriod>;
      _receiver =
          defaults.receiverEmployeeId == null || defaults.receiverName == null
          ? null
          : UtenEmployeePickerItem(
              id: defaults.receiverEmployeeId!,
              name: defaults.receiverName!,
              employeeCode: defaults.receiverCode,
            );
      if (_supplementPeriodId != null &&
          !_supplementPeriods.any((p) => p.id == _supplementPeriodId)) {
        _supplementPeriodId = null;
      }
      if (resetRows || _grid.isEmpty) {
        _grid.replaceAll([_newRow()]);
      } else {
        // 换车间后料的清单变了: 行里的料按新清单重新对齐 (对不上的清掉)。
        for (final row in _grid.rows) {
          final current = row.material.value;
          row.applyMaterial(current == null ? null : _materialFor(current.key));
        }
      }
      _loading = false;
    });
  }

  Future<void> _changeWorkshop(String? workshopId) async {
    if (!_editable || workshopId == null || workshopId == _workshopId) return;
    setState(() {
      _workshopId = workshopId;
      _loading = true;
      _receiver = null;
    });
    try {
      await _loadWorkshop(workshopId);
    } on ApiException catch (e) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    } catch (_) {
      if (warehouseTaskIsCurrent) {
        setState(() {
          _loading = false;
          _loadError = '加载失败, 请重试';
        });
      }
    }
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final scope = await captureWarehouseTaskScope();
    final kw = keyword?.trim() ?? '';
    final result = await scope.run(
      () => ref
          .read(employeeRepositoryProvider)
          .listPickerCandidates(
            size: 30,
            search: kw.isEmpty ? null : kw,
            // 没输入搜索词时只列本车间 (含下级) 的人; 输入后全公司搜。
            departmentId: kw.isEmpty ? _workshopId : null,
            includeSubtree: kw.isEmpty,
          ),
    );
    scope.checkCurrent();
    return [
      for (final e in result)
        UtenEmployeePickerItem(
          id: e.id,
          name: e.fullName,
          employeeCode: e.code,
          accountStatus: e.accountStatus,
          employmentStatus: e.status,
          departmentId: e.departmentId,
          departmentName: e.departmentName,
        ),
    ];
  }

  List<WmIssueLineRow> get _filledRows =>
      _grid.rows.where((r) => !r.isBlank).toList(growable: false);

  String? _validate() {
    final rows = _filledRows;
    if (_direct && _workshopId == null) return '请选择车间';
    if (_direct && _receiver == null) return '请选择领料人';
    if (rows.isEmpty) return '请至少填一行';
    final seen = <String>{};
    for (final row in rows) {
      final name =
          row.material.value?.displayName ??
          row.requisitionLine?.displayName ??
          '';
      if (row.goodsId == null) return '有一行还没选料';
      if ((row.qtyValue ?? 0) <= 0) {
        final unit =
            row.material.value?.unitName ?? row.requisitionLine?.unitName;
        return '「$name」请填数量${unit == null || unit.isEmpty ? '' : '（$unit）'}';
      }
      if (row.leafWarehouseId.value == null) {
        return '「$name」请选${_isReturn ? '退到哪个仓库' : '出库仓库'}';
      }
      final key =
          '${row.requisitionLine?.id ?? row.material.value?.key}|${row.leafWarehouseId.value}';
      if (!seen.add(key)) return '「$name」同一个仓库填了两行, 请合成一行';
    }
    if (!_firstUseReady) {
      return _canConfigureFirstUse
          ? '请先核对首次材料用途及全局 BOM 影响，再确认发料'
          : '首次材料用途需要货品编辑和 BOM 编辑权限，请有权限的同事办理；申请继续保留';
    }
    if (_supplement) {
      if (_supplementPeriodId == null) return '请选补到哪一期';
      if (_supplementReason.text.trim().length < 2) {
        return '请写清楚漏录的原因 (至少 2 个字)';
      }
    }
    return null;
  }

  bool get _isReturn => _requisition?.isReturn ?? false;

  WmSupplement? get _supplementPayload => _supplement
      ? WmSupplement(
          periodId: _supplementPeriodId!,
          reason: _supplementReason.text.trim(),
        )
      : null;

  Map<String, dynamic> _freezeIssueCommand() {
    final supplement = _supplementPayload?.toJson();
    final lines = [
      for (final row in _filledRows)
        {
          if (!_direct) 'lineId': row.requisitionLine!.id,
          if (_direct) 'goodsId': row.goodsId,
          if (_direct) 'colorId': row.colorId,
          if (_direct) 'bags': row.bagsValue,
          'qty': row.qtyValue,
          'leafWarehouseId': row.leafWarehouseId.value,
        },
    ];
    final payload = <String, dynamic>{
      'kind': _direct ? 'direct' : 'fulfil',
      if (_direct) 'workshop': _workshopId,
      if (_direct) 'receiver': _receiver!.id,
      if (!_direct) 'id': _requisition!.id,
      if (!_direct) 'v': _requisition!.rowVersion,
      'lines': lines,
      if (!_direct) 'materialSetup': _materialSetupPayload,
      'supplement': supplement,
    };
    payload['idempotencyKey'] = wmIdempotencyKey(
      _direct ? 'direct-issue' : 'fulfil',
      _nonce,
      payload,
    );
    // Detach nested first-use maps and line values from mutable form controls.
    return jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
  }

  WmSupplement? _commandSupplement(Map<String, dynamic> command) {
    final raw = command['supplement'];
    return raw is Map
        ? WmSupplement(
            periodId: raw['periodId'] as String,
            reason: raw['reason'] as String,
          )
        : null;
  }

  Future<WmIssueResult> _sendCommand(Map<String, dynamic> command) async {
    final key = command['idempotencyKey'] as String;
    if (command['kind'] == 'cancel') {
      await _repo.cancelRequisition(
        command['id'] as String,
        expectedVersion: command['v'] as int,
        reason: command['reason'] as String,
        idempotencyKey: key,
      );
      return WmIssueResult(requestNo: _requisition?.requestNo);
    }
    final lines = [
      for (final row in command['lines'] as List)
        Map<String, dynamic>.from(row as Map),
    ];
    if (command['kind'] == 'direct') {
      return _repo.directIssue(
        workshopDepartmentId: command['workshop'] as String,
        receiverEmployeeId: command['receiver'] as String,
        lines: lines,
        supplement: _commandSupplement(command),
        idempotencyKey: key,
      );
    }
    return _repo.fulfil(
      command['id'] as String,
      expectedVersion: command['v'] as int,
      lines: lines,
      materialSetup: [
        for (final row in command['materialSetup'] as List)
          Map<String, dynamic>.from(row as Map),
      ],
      supplement: _commandSupplement(command),
      idempotencyKey: key,
    );
  }

  bool _definiteRejection(ApiException error) =>
      !isSessionBoundaryError(error) &&
      ((error.hasResponseCode &&
              const [400, 403, 404, 409, 422].contains(error.httpStatus) &&
              !const [
                'IDEMPOTENCY_IN_PROGRESS',
                'IDEMPOTENCY_CONFLICT',
              ].contains(error.code)) ||
          const ['STOCK_SHORT', 'CONFLICT'].contains(error.code));

  Future<void> _submitPreparedCancellation() =>
      _submit(freshCancellation: true);

  Future<void> _submit({bool freshCancellation = false}) async {
    if (_saving || _loading || !_canSubmit) return;
    if (_command == null) {
      final problem = _validate();
      if (problem != null) {
        setState(() {
          _submitError = problem;
          _showValidation = true;
        });
        return;
      }
    }
    final wasPending = _command != null && !freshCancellation;
    final command = _command ?? _freezeIssueCommand();
    var dispatched = false;
    setState(() {
      _saving = true;
      _submitError = null;
      _command = command;
    });
    try {
      final scope = await captureWarehouseTaskScope();
      final result = await runFormDraftSubmission(
        () => scope.run(() {
          scope.checkCurrent();
          dispatched = true;
          return _sendCommand(command);
        }),
        isDefiniteRejection: (error) =>
            !wasPending && _definiteRejection(error),
      );
      scope.checkCurrent();
      await completeFormDraft();
      if (!warehouseTaskIsCurrent) return;
      setState(() {
        _saving = false;
        _command = null;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !warehouseTaskIsCurrent) return;
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess(
        command['kind'] == 'cancel'
            ? '已取消 ${_requisition?.requestNo ?? ''}'
            : _successMessage(result),
      );
      if (_direct) {
        await resetFormDraftAfterSubmission(
          prepare: () async {
            _nonce = const Uuid().v4();
            _grid.replaceAll([_newRow()]);
            _supplement = false;
            _supplementPeriodId = null;
            _supplementReason.clear();
            _showValidation = false;
          },
        );
      } else if (widget.onCompleted case final callback?) {
        callback();
      } else {
        await _close();
      }
    } catch (error) {
      if (!warehouseTaskIsCurrent) return;
      final rejected =
          !wasPending &&
          (!dispatched || error is ApiException && _definiteRejection(error));
      setState(() {
        _saving = false;
        if (rejected) _command = null;
        _submitError = rejected
            ? describeSubmitError(error, fallback: '本次未提交，填写已保留，请重试')
            : '原提交结果待确认，填写已锁定；请原样重试核对，不会重新制单。';
      });
      try {
        if (rejected) await releaseFormDraftBeforeDispatch();
        await saveFormDraftNow();
      } catch (checkpointError) {
        if (warehouseTaskIsCurrent) {
          setState(() {
            _submitError = describeSubmitError(
              checkpointError,
              fallback: '本机草稿暂未保存成功，请保留页面重试',
            );
          });
        }
      }
    }
  }

  String _successMessage(WmIssueResult result) {
    final docs = [
      for (final d in result.documents)
        if (d.docNo != null && d.docNo!.isNotEmpty) d.docNo!,
    ];
    final parts = <String>[
      _isReturn ? '已收退回' : '已发到内料仓',
      if (result.requestNo != null && result.requestNo!.isNotEmpty)
        '单号 ${result.requestNo}',
      if (docs.isNotEmpty) '调拨单 ${docs.join('、')}',
      if (result.period != null) '记进${wmPeriodLabel(result.period!)}',
    ];
    return parts.join(', ');
  }

  Future<void> _cancel() async {
    if (_saving || !_editable) return;
    final scope = await captureWarehouseTaskScope();
    final requisition = _requisition;
    if (requisition == null || !mounted) return;
    final controller = TextEditingController();
    late final String? reason;
    try {
      reason = await UtenDialog.showAndWaitForExit<String>(
        context,
        builder: (dialogContext) => UtenAlertDialog(
          title: const Text('取消这张申请'),
          content: TextField(
            key: const Key('wm-issue-cancel-reason'),
            controller: controller,
            autofocus: true,
            maxLength: 500,
            decoration: const UtenInputDecoration(
              InputDecoration(labelText: '取消原因', counterText: ''),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('返回'),
            ),
            UtenButton(
              type: UtenButtonType.danger,
              onPressed: () {
                final text = controller.text.trim();
                if (text.length >= 2) Navigator.of(dialogContext).pop(text);
              },
              child: const Text('取消申请'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
    if (reason == null || !warehouseTaskCanWrite || !scope.isCurrent) return;
    scope.checkCurrent();
    final payload = {
      'kind': 'cancel',
      'id': requisition.id,
      'v': requisition.rowVersion,
      'reason': reason,
    };
    _command = {
      ...payload,
      'idempotencyKey': wmIdempotencyKey('cancel', _nonce, payload),
    };
    await _submitPreparedCancellation();
  }

  String _title(AppLocalizations l10n) {
    if (_direct) return l10n.wmDirectIssue;
    if (_requisition == null) return l10n.wmPendingIssue;
    return _isReturn ? l10n.wmReceiveReturn : l10n.wmIssueByRequest;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return withFormDraft(
      PopScope(
        canPop: !_saving,
        child: Scaffold(
          floatingActionButton: _loading || _loadError != null
              ? null
              : UtenFloatingActionGroup(children: _actions()),
          appBar: UtenAppBar(
            title: widget.batchProgress == null
                ? _title(l10n)
                : '${_title(l10n)} · ${widget.batchProgress}',
            leading: UtenBackButton(onPressed: _close),
          ),
          body: SafeArea(
            child: Stack(
              children: [
                UtenContentContainer.wide(
                  child: _loading && _materials.isEmpty && _requisition == null
                      ? const Center(child: CircularProgressIndicator())
                      : _loadError != null
                      ? UtenEmpty.error(
                          message: _loadError,
                          actionLabel: '重试',
                          onAction: _load,
                        )
                      : SingleChildScrollView(
                          padding:
                              const EdgeInsets.symmetric(
                                horizontal: UtenSpacing.s4,
                              ).copyWith(
                                top: UtenSpacing.s16,
                                bottom: UtenFloatingActionGroup.scrollClearance,
                              ),
                          child: _form(l10n, theme),
                        ),
                ),
                if (_saving)
                  UtenBusyOverlay(
                    title: _direct
                        ? '正在发料'
                        : _isReturn
                        ? '正在收退回'
                        : '正在按申请发料',
                    description: '正在建调拨单并记进车间内料仓',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(AppLocalizations l10n, ThemeData theme) {
    final requisition = _requisition;
    final editable = _editable;
    final children = <Widget>[];
    if (_direct) {
      final enabled = _enabledSettings;
      if (enabled.isEmpty) {
        return UtenEmpty(
          icon: Icons.inventory_2_outlined,
          message: '还没有开启整批领料的车间',
          description: '请先在"${l10n.workshopMaterialSetup}"里开启。',
        );
      }
      children.add(
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            SizedBox(
              width: 280,
              child: UtenDropdownField(
                key: const Key('wm-issue-workshop'),
                label: '发到哪个车间',
                required: true,
                allowClear: false,
                enabled: _editable && !_saving,
                value: _workshopId,
                items: [
                  for (final s in enabled)
                    UtenDropdownItem(
                      value: s.workshopDepartmentId,
                      label: s.binWarehouseName == null
                          ? s.workshopName
                          : '${s.workshopName} (${s.binWarehouseName})',
                    ),
                ],
                onChanged: _changeWorkshop,
              ),
            ),
            SizedBox(
              width: 280,
              child: UtenEmployeePicker(
                candidateScopeKey: ('workshop-receiver', _workshopId),
                key: ValueKey(
                  'wm-issue-receiver-$_workshopId-${_receiver?.id}',
                ),
                label: l10n.wmReceiver,
                required: true,
                enabled: _editable && !_saving && _workshopId != null,
                initial: _receiver,
                sheetTitle: '选择${l10n.wmReceiver}',
                departmentName: _setting?.workshopName,
                loader: _loadEmployees,
                onChanged: (item) => setState(() => _receiver = item),
              ),
            ),
          ],
        ),
      );
    } else if (requisition != null) {
      children.add(_requisitionHeader(l10n, theme, requisition));
    }
    children.add(const SizedBox(height: UtenSpacing.s12));

    if (editable && _firstUseGoods.isNotEmpty) {
      for (final entry in _firstUseGoods.entries) {
        children.add(
          WorkshopMaterialFirstUseCard(
            key: ValueKey('wm-first-use-$_materialSetupRevision-${entry.key}'),
            goodsId: entry.key,
            goodsName: entry.value.goodsName ?? entry.value.displayName,
            canConfigure: _canConfigureFirstUse,
            initialSetup: _setupInitials[entry.key],
            enabled: _editable && !_saving,
            onChanged: (setup) {
              if (setup == null && !_materialSetups.containsKey(entry.key)) {
                return;
              }
              setState(() {
                if (setup == null) {
                  _materialSetups.remove(entry.key);
                } else {
                  _materialSetups[entry.key] = setup;
                }
                _submitError = null;
              });
            },
          ),
        );
      }
    }

    if (_counting && !_supplement && editable && !_isReturn) {
      children.add(
        UtenInlineNotice(
          key: const Key('wm-issue-counting-hint'),
          level: UtenInlineNoticeLevel.warning,
          message: l10n.wmCountingNextPeriod,
        ),
      );
      children.add(const SizedBox(height: UtenSpacing.s12));
    }

    if (_direct && _workshopId == null) {
      children.add(
        const UtenEmpty(icon: Icons.touch_app_outlined, message: '先选发到哪个车间'),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    if (_direct && _materials.isEmpty && !_loading) {
      children.add(
        UtenEmpty(
          message: '还没有整批领料的料',
          description: '请先在基础资料里把颗粒等料的发料方式改为"${l10n.wmIssueMethodPeriodic}"。',
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    children.add(
      UtenEditableGrid<WmIssueLineRow>(
        tableKey:
            'features.warehouse.materialbin.pages.workshop_material_issue_page.WorkshopMaterialIssuePageState._form.1',
        key: const Key('wm-issue-grid'),
        controller: _grid,
        columns: wmIssueLineColumns(
          l10n: l10n,
          grid: _grid,
          materials: _materials,
          enabled: editable && !_saving,
          materialEditable: _direct,
          showLeafWarehouse: true,
          leafLabel: _isReturn ? l10n.wmLeafReturnColumn : l10n.wmLeafColumn,
          pickLeafWarehouse: (row) => _pickLeaf(l10n, row),
          warehouseNameOf: (id) => warehouseFullLabel(_leafHierarchy, id) ?? '',
          showWarehouseAvailable: !_isReturn,
          qtyLabel: _isReturn ? '实收重量' : null,
          onChanged: () {
            if (_submitError != null && _showValidation) {
              setState(() => _submitError = null);
            }
          },
        ),
        createBlankRow: _direct ? _newRow : null,
        showAddRow: _direct && editable,
        selectable: !_direct && editable,
        showRowDelete: editable,
        canDeleteRow: (row) =>
            _direct ||
            _grid.rows
                    .where(
                      (r) => r.requisitionLine?.id == row.requisitionLine?.id,
                    )
                    .length >
                1,
        confirmDelete: false,
        showColumnSettings: false,
        cloneRow: _direct
            ? (row) => _newRow(
                material: row.material.value,
                leafWarehouseId: row.leafWarehouseId.value,
              )
            : null,
        rowMenuExtraBuilder: !_direct && editable
            ? (context, selected) => [
                UtenMenuItem(
                  label: _isReturn ? '分到另一个仓库收一部分' : '从另一个仓库再发一部分',
                  icon: Icons.call_split_outlined,
                  enabled: selected.length == 1,
                  onTap: () => _splitRow(selected.first),
                ),
              ]
            : null,
      ),
    );

    if (editable && !_isReturn) {
      children.add(const SizedBox(height: UtenSpacing.s12));
      children.add(_supplementSection(l10n, theme));
    }

    if (_submitError != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _submitError!,
              key: const Key('wm-issue-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  List<Widget> _actions() {
    final requisition = _requisition;
    return [
      if (!_direct)
        UtenSelectionSummaryPill(
          count: widget.selectedLineIds?.length ?? _filledRows.length,
        ),
      if (!_direct &&
          requisition != null &&
          requisition.isPending &&
          requisition.can(WmAction.cancel) &&
          widget.selectedLineIds == null)
        UtenButton(
          key: const Key('wm-issue-cancel'),
          type: UtenButtonType.secondary,
          onPressed: _saving ? null : _cancel,
          child: const Text('取消这张申请'),
        ),
      if (_canSubmit)
        UtenButton(
          key: const Key('wm-issue-submit'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: _isReturn
              ? Icons.move_to_inbox_outlined
              : Icons.local_shipping_outlined,
          isLoading: _saving,
          onPressed:
              _saving || _loading || (_command == null && !_firstUseReady)
              ? null
              : _submit,
          child: Text(
            _command != null
                ? '原样重试核对结果'
                : _isReturn
                ? '确认收退回'
                : '确认发料',
          ),
        ),
    ];
  }

  /// 出库仓库 (收退回时是退到哪个仓库): 全站仓库滑窗, 先主仓再子仓, 只能选启用中的良品子仓;
  /// 有货的仓在副行写「可发 N 单位」(数字来自服务端)。
  Future<String?> _pickLeaf(AppLocalizations l10n, WmIssueLineRow row) async {
    final line = row.requisitionLine;
    final material =
        row.material.value ?? (line == null ? null : _materialFor(line.key));
    final unit = material?.unitName ?? line?.unitName ?? '';
    final available = {
      for (final w in wmLeafOptions(material)) w.warehouseId: w.availableQty,
    };
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: _leafHierarchy,
      use: _isReturn ? WarehouseUse.goodIn : WarehouseUse.goodOut,
      initialWarehouseId: row.leafWarehouseId.value,
      title: _isReturn ? l10n.wmLeafReturnPickerTitle : l10n.wmLeafPickerTitle,
      subtitleOf: _isReturn
          ? null
          : (entry) {
              final qty = available[entry.id];
              return qty == null || qty <= 0
                  ? null
                  : l10n.wmLeafAvailable(wmQty(qty), unit);
            },
    );
    if (!warehouseTaskCanWrite ||
        !_editable ||
        picked == null ||
        picked.isAll) {
      return null;
    }
    return picked.id;
  }

  void _splitRow(WmIssueLineRow source) {
    final index = _grid.rows.indexOf(source);
    final line = source.requisitionLine;
    if (index < 0 || line == null) return;
    final material = _materialFor(line.key);
    final used = source.leafWarehouseId.value;
    String? other;
    for (final w in wmLeafOptions(material)) {
      if (w.warehouseId != used) {
        other = w.warehouseId;
        break;
      }
    }
    _grid.insertAt(
      index + 1,
      _newRow(line: line, material: material, leafWarehouseId: other),
    );
  }

  Widget _requisitionHeader(
    AppLocalizations l10n,
    ThemeData theme,
    WmRequisition r,
  ) {
    final rows = <(String, String)>[
      ('单号', r.requestNo),
      ('车间', r.workshopName ?? ''),
      ('内料仓', r.binWarehouseName ?? ''),
      ('状态', wmRequisitionStatusLabel(r.status)),
      ('申请人', r.requestedByName ?? ''),
      ('申请时间', ChinaDateTime.formatIsoInstant(r.requestedAt)),
      if (r.doneByName != null) ('经办', r.doneByName!),
      if (r.doneAt != null) ('完成时间', ChinaDateTime.formatIsoInstant(r.doneAt)),
      if (r.cancelReason != null) ('取消原因', r.cancelReason!),
      if (r.remark != null) ('备注', r.remark!),
    ];
    return Wrap(
      spacing: UtenSpacing.s24,
      runSpacing: UtenSpacing.s8,
      children: [
        for (final (label, value) in rows)
          if (value.isNotEmpty)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  TextSpan(text: value, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
      ],
    );
  }

  Widget _supplementSection(AppLocalizations l10n, ThemeData theme) {
    final periods = _supplementPeriods;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const Key('wm-issue-supplement'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _supplement,
          onChanged: !_editable || _saving || periods.isEmpty
              ? null
              : (v) => setState(() {
                  _supplement = v ?? false;
                  if (_supplement && periods.length == 1) {
                    _supplementPeriodId = periods.first.id;
                  }
                }),
          title: Text(l10n.wmSupplementFlag),
          subtitle: Text(
            periods.isEmpty
                ? '现在没有盘点中或已盘点还没结算的期间, 不用补录'
                : '盘点开始前已经发了、当时忘了录的料才勾; 只能补到盘点中或已盘点还没结算的那一期',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (_supplement) ...[
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s12,
            children: [
              SizedBox(
                width: 320,
                child: UtenDropdownField(
                  key: const Key('wm-issue-supplement-period'),
                  label: l10n.wmSupplementPeriod,
                  required: true,
                  allowClear: false,
                  enabled: _editable && !_saving,
                  value: _supplementPeriodId,
                  items: [
                    for (final p in periods)
                      UtenDropdownItem(
                        value: p.id,
                        label:
                            '${wmPeriodLabel(p)} · ${wmPeriodStatusLabel(p.status)}',
                      ),
                  ],
                  onChanged: (v) => setState(() => _supplementPeriodId = v),
                ),
              ),
              SizedBox(
                width: 420,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _supplementReason,
                  builder: (context, value, _) => TextField(
                    key: const Key('wm-issue-supplement-reason'),
                    controller: _supplementReason,
                    enabled: _editable && !_saving,
                    maxLength: 500,
                    decoration: applyRequiredEmpty(
                      InputDecoration(
                        label: requiredLabel('漏录原因', theme, required: true),
                        counterText: '',
                      ),
                      theme,
                      requiredEmpty: value.text.trim().length < 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
