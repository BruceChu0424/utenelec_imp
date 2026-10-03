// 仓库发料到车间内料仓 (/workshop-material/issue, ADR-131 §5.2 / §5.3)。
//
// 三种用法, 同一页:
// - 直接发料 (?mode=direct, 主路径): 选车间、料、袋数 (公斤按每袋净重自动算, 可改)、
//   出库仓库 (默认货品归属仓)、领料人 (默认该车间上一次的领料人), 一次确认;
//   同一种料从两个仓库出就填两行。
// - 按申请发料 (?requisitionId=, 车间申请领料): 预填申请量与建议出库仓库, 可按整袋改,
//   同一行可"从另一个仓库再发一部分"。
// - 收退回 (?requisitionId=, 车间退回): 按实收填公斤, 选退到哪个仓库。
// 内料仓正在盘点时, 发的料自动算到下一期 (页面提示); 盘点前漏录的发料可勾选
// "这批料是上一期漏录的", 选补到哪一期并写原因。
// 库存不足、版本冲突整笔不成功, 页面保留输入; 原样再点确认是同一个请求号, 不会重复发。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
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
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/china_datetime.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../employee/repositories/employee_repository.dart';
import '../../providers/warehouse_count_refresh.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_labels.dart';
import '../widgets/workshop_material_line_grid.dart';
import '../widgets/workshop_material_first_use_card.dart';

/// 仓库任务中心「车间内料仓」大类 (发料完成后返回这里)。
final String wmWarehouseTaskCenterPath = Uri(
  path: RouteName.warehouseTasks,
  queryParameters: const {'group': 'workshopMaterial'},
).toString();

class WorkshopMaterialIssuePage extends ConsumerStatefulWidget {
  const WorkshopMaterialIssuePage({super.key, this.requisitionId, this.mode});

  /// 按申请发料 / 收退回的申请单; 为空 = 直接发料。
  final String? requisitionId;

  /// `direct` = 直接发料 (与不带 requisitionId 等价)。
  final String? mode;

  @override
  ConsumerState<WorkshopMaterialIssuePage> createState() =>
      _WorkshopMaterialIssuePageState();
}

class _WorkshopMaterialIssuePageState
    extends ConsumerState<WorkshopMaterialIssuePage> {
  final _grid = UtenEditableGridController<WmIssueLineRow>();
  final _supplementReason = TextEditingController();
  final _nonce = const Uuid().v4();
  int _nextRow = 0;

  bool _loading = true;
  String? _loadError;
  List<WmSetting> _settings = const [];
  String? _workshopId;
  WmRequisition? _requisition;
  List<WmMaterialOption> _materials = const [];
  List<WmPeriod> _periods = const [];
  UtenEmployeePickerItem? _receiver;
  bool _supplement = false;
  String? _supplementPeriodId;
  bool _saving = false;
  String? _submitError;
  bool _showValidation = false;
  final Map<String, Map<String, dynamic>> _materialSetups = {};
  int _materialSetupRevision = 0;

  bool get _direct => widget.requisitionId == null || widget.mode == 'direct';

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
    setState(() {
      _loading = true;
      _loadError = null;
      _materialSetups.clear();
      _materialSetupRevision++;
    });
    try {
      if (_direct) {
        final settings = await _repo.settings();
        if (!mounted) return;
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
        if (!mounted) return;
        _requisition = requisition;
        _workshopId = requisition.workshopDepartmentId;
        final workshopId = requisition.workshopDepartmentId;
        final binId = requisition.binWarehouseId;
        final results = await Future.wait<Object>([
          if (workshopId != null)
            requisition.isReturn
                ? _repo.materials(workshopId)
                : _loadRequestMaterials(workshopId, requisition.lines),
          if (binId != null) _repo.periods(binId),
        ]);
        if (!mounted) return;
        var index = 0;
        if (workshopId != null) {
          _materials = results[index++] as List<WmMaterialOption>;
        }
        if (binId != null) _periods = results[index] as List<WmPeriod>;
        _grid.replaceAll([
          for (final line in requisition.lines)
            _newRow(
                line: line,
                material: _materialFor(line.key),
                leafWarehouseId:
                    line.suggestedLeafWarehouseId ??
                    _materialFor(line.key)?.defaultLeafWarehouseId,
              )
              ..qty.text = wmQty(
                (line.requestedQty - line.fulfilledQty).clamp(
                  0,
                  double.infinity,
                ),
                maxDecimals: 4,
              )
              ..bags.text = line.requestedBags == null
                  ? ''
                  : wmQty(line.requestedBags),
        ]);
        setState(() => _loading = false);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
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
    final setting = _settings
        .where((s) => s.workshopDepartmentId == workshopId)
        .firstOrNull;
    final binId = setting?.binWarehouseId;
    final results = await Future.wait<Object>([
      _repo.materials(workshopId),
      _repo.directIssueDefaults(workshopId),
      if (binId != null) _repo.periods(binId),
    ]);
    if (!mounted || _workshopId != workshopId) return;
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
    if (workshopId == null || workshopId == _workshopId) return;
    setState(() {
      _workshopId = workshopId;
      _loading = true;
      _receiver = null;
    });
    try {
      await _loadWorkshop(workshopId);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '加载失败, 请重试';
        });
      }
    }
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final kw = keyword?.trim() ?? '';
    final result = await ref
        .read(employeeRepositoryProvider)
        .list(
          size: 30,
          search: kw.isEmpty ? null : kw,
          // 没输入搜索词时只列本车间 (含下级) 的人; 输入后全公司搜。
          departmentId: kw.isEmpty ? _workshopId : null,
          includeSubtree: kw.isEmpty,
        );
    return [
      for (final e in result.items)
        UtenEmployeePickerItem(
          id: e.id,
          name: e.fullName,
          employeeCode: e.code,
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

  Future<void> _submit() async {
    if (_saving || _loading) return;
    final problem = _validate();
    if (problem != null) {
      setState(() {
        _submitError = problem;
        _showValidation = true;
      });
      return;
    }
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final WmIssueResult result;
      if (_direct) {
        final lines = [
          for (final row in _filledRows)
            {
              'goodsId': row.goodsId,
              'colorId': row.colorId,
              'bags': row.bagsValue,
              'qty': row.qtyValue,
              'leafWarehouseId': row.leafWarehouseId.value,
            },
        ];
        final payload = {
          'workshop': _workshopId,
          'receiver': _receiver!.id,
          'lines': lines,
          'supplement': _supplementPayload?.toJson(),
        };
        result = await _repo.directIssue(
          workshopDepartmentId: _workshopId!,
          receiverEmployeeId: _receiver!.id,
          lines: lines,
          supplement: _supplementPayload,
          idempotencyKey: wmIdempotencyKey('direct-issue', _nonce, payload),
        );
      } else {
        final requisition = _requisition!;
        final materialSetup = _materialSetupPayload;
        final lines = [
          for (final row in _filledRows)
            {
              'lineId': row.requisitionLine!.id,
              'leafWarehouseId': row.leafWarehouseId.value,
              'qty': row.qtyValue,
            },
        ];
        result = await _repo.fulfil(
          requisition.id,
          expectedVersion: requisition.rowVersion,
          lines: lines,
          materialSetup: materialSetup,
          supplement: _supplementPayload,
          idempotencyKey: wmIdempotencyKey('fulfil', _nonce, {
            'id': requisition.id,
            'v': requisition.rowVersion,
            'lines': lines,
            'materialSetup': materialSetup,
            'supplement': _supplementPayload?.toJson(),
          }),
        );
      }
      if (!mounted) return;
      // 提示与跳转之前先撤遮罩并等这一帧画完。
      setState(() => _saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess(_successMessage(result));
      if (_direct) {
        setState(() {
          _grid.replaceAll([_newRow()]);
          _supplement = false;
          _supplementPeriodId = null;
          _supplementReason.clear();
          _showValidation = false;
        });
      } else {
        backTo(context, defaultPath: wmWarehouseTaskCenterPath);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _submitError = e.fieldErrors?.firstOrNull?.message ?? e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _submitError = '网络不稳定, 暂时没确认结果。填写的内容已保留, 请再点一次确认 (不会重复发料)。';
        });
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
    final requisition = _requisition;
    if (requisition == null) return;
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消这张申请'),
        content: TextField(
          key: const Key('wm-issue-cancel-reason'),
          controller: controller,
          autofocus: true,
          maxLength: 500,
          decoration: const InputDecoration(labelText: '取消原因', counterText: ''),
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
    controller.dispose();
    if (reason == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await _repo.cancelRequisition(
        requisition.id,
        expectedVersion: requisition.rowVersion,
        reason: reason,
        idempotencyKey: wmIdempotencyKey('cancel', _nonce, {
          'id': requisition.id,
          'v': requisition.rowVersion,
          'reason': reason,
        }),
      );
      if (!mounted) return;
      setState(() => _saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('已取消 ${requisition.requestNo}');
      backTo(context, defaultPath: wmWarehouseTaskCenterPath);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _submitError = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _submitError = '网络不稳定, 请刷新后看看是否已取消';
        });
      }
    }
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
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: _title(l10n),
          leading: UtenBackButton(
            onPressed: () =>
                backTo(context, defaultPath: wmWarehouseTaskCenterPath),
          ),
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
                        padding: const EdgeInsets.symmetric(
                          vertical: UtenSpacing.s16,
                          horizontal: UtenSpacing.s4,
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
    );
  }

  Widget _form(AppLocalizations l10n, ThemeData theme) {
    final requisition = _requisition;
    final editable =
        _direct ||
        (requisition != null &&
            requisition.isPending &&
            requisition.can(WmAction.fulfil));
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
                enabled: !_saving,
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
                key: ValueKey(
                  'wm-issue-receiver-$_workshopId-${_receiver?.id}',
                ),
                label: l10n.wmReceiver,
                required: true,
                enabled: !_saving && _workshopId != null,
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
            enabled: !_saving,
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
          leafLabel: _isReturn ? '退到哪个仓库' : '出库仓库',
          showWarehouseAvailable: !_isReturn,
          qtyLabel: _isReturn ? '实收数量' : null,
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

    children.add(const SizedBox(height: UtenSpacing.s16));
    children.add(
      Wrap(
        alignment: WrapAlignment.center,
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s8,
        children: [
          if (!_direct &&
              requisition != null &&
              requisition.isPending &&
              requisition.can(WmAction.cancel))
            UtenButton(
              key: const Key('wm-issue-cancel'),
              type: UtenButtonType.secondary,
              onPressed: _saving ? null : _cancel,
              child: const Text('取消这张申请'),
            ),
          if (editable)
            UtenButton(
              key: const Key('wm-issue-submit'),
              size: UtenButtonSize.large,
              icon: _isReturn
                  ? Icons.move_to_inbox_outlined
                  : Icons.local_shipping_outlined,
              isLoading: _saving,
              onPressed: _saving || _loading || !_firstUseReady
                  ? null
                  : _submit,
              child: Text(_isReturn ? '确认收退回' : '确认发料'),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
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
          onChanged: _saving || periods.isEmpty
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
                  enabled: !_saving,
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
                    enabled: !_saving,
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
