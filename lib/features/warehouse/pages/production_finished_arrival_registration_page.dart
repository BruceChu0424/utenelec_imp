import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/measurement/weight_mass_units.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../models/inbound_registration_line.dart';
import '../models/production_finished_inbound_task.dart';
import '../models/warehouse_form_draft_codec.dart';
import '../providers/inbound_warehouse_fill_memory.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';
import '../repositories/warehouse_place_suggestion_repository.dart';
import '../widgets/arrival_registration_reversal_dialog.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/inbound_registration_widgets.dart';

/// 生产报工审核后的仓库入库登记(单张报工单，任务中心双击「待登记入库」进入)。
///
/// 2026-09-27 用户口径「产成品入库与采购/委外入库 UI、逻辑、表格、记忆都一样」：本页与
/// 登记实际到货单张页(warehouse_arrival_receipt_page)同一骨架——表头卡 + 备注、库位建议
/// 提示条、勾选口径说明、共用列明细表(InboundGridColumns)+ 合计条、右下两条路线按钮并排
/// (单张页由双击进入、未预选路线)。入库仓库、库位号行级必填；**勾选多行后在任意一行
/// 改仓/写库位 = 批量落到全部勾选行**，右键可批量设置。仓库预填 = 货品主档归属仓 → 上次
/// 在登记页显式选的仓(账号记忆)；库位 = 所选仓记住的库位 → 货品资料通用库位(共用库位
/// 建议端点)；登记成功后服务端同一事务自动记住本次库位。
/// 提交按行仓分组，一个仓一个登记批次(V469 一批一仓)，每个批次同事务形成一张品质检查单
/// (V547)；部分仓失败停在本页，已成功仓不重复提交。已登记批次在品质未处理前可「撤回
/// 登记」(V548)，报工行回到待登记。数量来自已审核报工，只读；本页不写库存、不增加 iqty。
/// 实称重量(ADR-135)：数量组之后可选录净重，随登记行提交(千克 4 位，计入幂等键)，
/// 合格入库时按放行数量分摊进库存账；「称重核对」按学到的单重对比报工数量
/// (「比报工少约 N 个」)，只提示不改数量，本页不做称重计数回填。
class ProductionFinishedArrivalRegistrationPage extends ConsumerStatefulWidget {
  const ProductionFinishedArrivalRegistrationPage({
    super.key,
    required this.reportId,
    this.canRegister,
  });

  final String reportId;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限自行推导。
  final bool? canRegister;

  @override
  ConsumerState<ProductionFinishedArrivalRegistrationPage> createState() =>
      _ProductionFinishedArrivalRegistrationPageState();
}

class _ProductionFinishedArrivalRegistrationPageState
    extends ConsumerState<ProductionFinishedArrivalRegistrationPage>
    with FormDraftMixin<ProductionFinishedArrivalRegistrationPage> {
  final _grid = UtenEditableGridController<_FinishedArrivalLine>();
  final _scrollController = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  late final _suggestions = InboundPlaceSuggestionLoader(
    ref.read(warehousePlaceSuggestionRepositoryProvider),
  );
  // 登记备注（V542）：随每个登记批次提交并留痕。
  final _remarkController = TextEditingController();
  // 页面级幂等键；按仓提交时派生 `页面键:仓库UUID`，重试不重复登记已成功仓。
  String _idempotencyKey = const Uuid().v4();

  ProductionFinishedArrivalRegistration? _detail;
  String? _error;
  bool _loading = false;
  bool _saving = false;
  bool _reversing = false;
  bool _registrationCompletedThisSession = false;
  int _removedLineCount = 0;

  /// 最近一次点的路线(单张页两条路线并排；库位红框与本次实收校验跟着它走)。
  InboundRoute _route = InboundRoute.inspectFirst;

  /// 本会话已成功登记的仓 → 登记结果（部分失败重试时跳过）。
  final Map<String, ProductionFinishedArrivalRegistration> _registrations = {};

  bool get _hasRegisterPermission {
    final override = widget.canRegister;
    if (override != null) return override;
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);
  }

  bool get _canRegister =>
      _hasRegisterPermission && !(_detail?.registered ?? false);

  /// 「先入库后质检」需独立权限(服务端同样兜底)。
  bool get _canStockInFirst {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionFinishedInBeforeInspection);
  }

  List<_FinishedArrivalLine> get _editableRows =>
      _grid.rows.where((row) => !row.locked).toList(growable: false);

  bool get _busy => _saving || _reversing;

  @override
  bool get formDraftBusy => _busy;

  /// 幂等键随草稿持久化：丢响应后可安全重放。
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.finishedArrival.spec(
    title: '登记实际入库',
    route: RouteName.warehouseProductionFinishedArrivalRegistration
        .replaceFirst(':reportId', widget.reportId),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _remarkController,
    _grid,
    for (final row in _grid.rows) ...[
      row.place,
      row.warehouse,
      row.stockInQty,
      row.weight,
    ],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'remark': _remarkController.text,
    'idempotencyKey': _idempotencyKey,
    'preStock': _route.isStockInFirst,
    'removedLineCount': _removedLineCount,
    'rows': [
      for (final row in _grid.rows)
        {
          'reportItemId': row.item.reportItemId,
          'warehouseId': row.warehouseId,
          'warehouseAutofilled': row.warehouseAutofilled,
          'place': row.place.text,
          'placeAutofilled': row.place.autofilled,
          'stockInQty': row.stockInQty.text,
          'weight': weightEntryDraft(row.weight),
          'selected': _grid.isSelected(row),
          'registered': row.registered,
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _remarkController.text = draftText(data, 'remark');
    _idempotencyKey = data['idempotencyKey'] as String? ?? _idempotencyKey;
    _route = data['preStock'] == true && _canStockInFirst
        ? InboundRoute.stockInFirst
        : InboundRoute.inspectFirst;
    _removedLineCount = (data['removedLineCount'] as num?)?.toInt() ?? 0;
    final saved = draftMaps(data['rows']);
    final retained = saved.map((item) => item['reportItemId']).toSet();
    _grid.removeWhere(
      (row) => !row.registered && !retained.contains(row.item.reportItemId),
    );
    _grid.clearSelection();
    for (final item in saved) {
      final row = _grid.rows
          .where((row) => row.item.reportItemId == item['reportItemId'])
          .firstOrNull;
      // Current registration facts win over an old editable snapshot after a lost response.
      if (row == null && item['registered'] != true) {
        throw const FormatException('原登记明细已变化或已由其他人办理，填写草稿保留；请核对服务器登记结果');
      }
      if (row == null || row.registered) continue;
      row.setWarehouse(
        item['warehouseId'] as String?,
        autofilled: item['warehouseAutofilled'] == true,
      );
      final place = draftText(item, 'place');
      if (item['placeAutofilled'] == true) {
        row.place.setAutomaticText(place);
      } else {
        row.setCheckedPlace(place);
      }
      final qty = draftText(item, 'stockInQty');
      if (qty.isNotEmpty) row.stockInQty.text = qty;
      restoreWeightEntryDraft(row.weight, item['weight']);
      if (item['selected'] == true) _grid.setSelected([row], true);
    }
    if (mounted) setState(() {});
  }

  // ---- 实称重量(ADR-135)：单重参数按货品取(车间产出无供应商)，页面内缓存 ----

  /// 页面级单重参数缓存(build 里 watch，离开页面释放)。
  WeightParamsCache get _weightCache => ref.read(weightParamsCacheProvider);

  WeightParams? _paramsOf(_FinishedArrivalLine row) =>
      _weightCache.of(row.goodsId);

  /// 单位 -> 重量单位(报工单位本身按重量计时精确换算)。
  Map<String, WeightUnit> get _massUnits =>
      ref.read(warehouseUnitMassUnitsProvider).valueOrNull ?? const {};

  /// 已登记行也取参数：按重量计的货品显示「=N kg」，登记重量照样核对。
  void _ensureWeightParams() {
    if (!mounted) return;
    unawaited(
      _weightCache.ensure([
        for (final row in _grid.rows) WeightParamsLine(goodsId: row.goodsId),
      ]),
    );
  }

  /// 货品或报工单位按重量计时由报工数量精确换算(只读、不提交)；需要实称时为 null。
  double? _exactKg(_FinishedArrivalLine row) => warehouseExactLineKg(
    lineQty: row.item.reportedQty,
    lineMassUnit: _massUnits[row.item.unitId],
    unitRate: row.item.unitRate,
    params: _paramsOf(row),
  );

  /// 核对重量的数量口径是货品基本单位；报工单位不是基本单位时不借用它的名字。
  String? _baseUnitName(_FinishedArrivalLine row, MasterNameService names) =>
      row.item.unitRate == 1
      ? row.item.unitName ?? names.unit(row.item.unitId)
      : null;

  /// 随登记行提交的实称净重(千克)；精确换算行与没称的行不带。
  double? _sentKg(_FinishedArrivalLine row) =>
      _exactKg(row) == null ? row.weight.kg : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _suggestions.dispose();
    _grid.dispose();
    _gridPinned.dispose();
    _scrollController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _saving) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final names = ref.read(masterNameServiceProvider);
      await names.ensureLoaded();
      final detail = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .arrivalRegistration(widget.reportId);
      if (!mounted) return;
      final rows = [
        for (final item in detail.items)
          _FinishedArrivalLine(
            item,
            registered: detail.registered,
            registeredWarehouseId: detail.warehouseId,
          ),
      ];
      _grid.replaceAll(rows);
      // 进页默认全选：勾选=本次要登记的行，右下提交按钮只认勾选行。
      _grid.setSelected(
        rows.where((row) => !row.registered).toList(growable: false),
        true,
      );
      if (!detail.registered) {
        // 仓库预填链(与到货登记页同一口径，都不猜)：货品主档归属仓 → 上次在登记页
        // 显式选的仓(账号记忆)。预填一律黄框待核对，用户一动即清标。
        final selectable = WarehouseSelection(
          names.warehouseHierarchy,
        ).selectableIds;
        final memory = ref.read(
          inboundWarehouseFillMemoryProvider(InboundFillScope.finished),
        );
        final remembered = selectable.contains(memory.warehouseId)
            ? memory.warehouseId
            : null;
        for (final row in rows) {
          final master = row.item.lastWarehouseId;
          row.setWarehouse(
            selectable.contains(master) ? master : remembered,
            autofilled: true,
          );
        }
      }
      setState(() {
        _detail = detail;
        _registrations.clear();
        _removedLineCount = 0;
        _loading = false;
      });
      _ensureWeightParams();
      if (!detail.registered) await _suggestions.reload(_editableRows);
      if (!mounted) return;
      await initializeFormDraft();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '成品入库登记信息加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 本页移出是「暂不纳入本次登记」，不删除已审核报工明细。
  /// V469 后服务端只登记提交的 UUID；移出行保持仓库待登记且不产生 FQC/库存事实。
  void _removeFromThisRegistration(List<_FinishedArrivalLine> rows) {
    final removable = rows.where((row) => !row.locked).toList();
    if (_busy || !_canRegister || removable.isEmpty) return;
    _grid.removeRows(removable);
    if (!mounted) return;
    setState(() => _removedLineCount += removable.length);
    context.appInfo('已从本次登记移出 ${removable.length} 行；报工事实未删除，仍留在待登记');
  }

  /// 一次改动的落值范围：**勾选若干行 → 在其中任意一行改仓/写库位 = 批量落到全部
  /// 勾选行**；点的行不在勾选集里(或压根没勾)就只改这一行。
  List<_FinishedArrivalLine> _writeTargets(_FinishedArrivalLine row) {
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 选入库仓库(行内点击与右键批量共用)：落到目标行、记住这次选的仓，并按新仓
  /// 重新拉库位建议。
  Future<void> _pickWarehouseFor(List<_FinishedArrivalLine> rows) async {
    final targets = rows.where((row) => !row.locked).toList();
    if (_busy || targets.isEmpty) return;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      initialWarehouseId: targets.first.warehouseId,
      title: targets.length > 1
          ? '批量设置入库仓库(选中 ${targets.length} 行)'
          : '选择入库仓库 · ${targets.single.goodsName}',
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final target in targets) {
        target.setWarehouse(picked.id);
      }
    });
    ref
        .read(
          inboundWarehouseFillMemoryProvider(
            InboundFillScope.finished,
          ).notifier,
        )
        .rememberWarehouse(picked.id);
    if (targets.length > 1) {
      context.appInfo('已把入库仓库写到选中的 ${targets.length} 行');
    }
    await _suggestions.reload(targets);
  }

  /// 行内写库位：勾选多行时同步写到全部勾选行(逐字同步，不等失焦)。
  void _onPlaceChanged(_FinishedArrivalLine row, String value) {
    final targets = _writeTargets(row);
    if (targets.length <= 1) return;
    setState(() {
      for (final target in targets) {
        if (identical(target, row)) continue;
        target.setCheckedPlace(value);
      }
    });
  }

  /// 右键「批量设置库位号」：一次输入应用到全部选中行(整托同架场景)。
  Future<void> _batchFillPlace(List<_FinishedArrivalLine> rows) async {
    final targets = rows.where((row) => !row.locked).toList();
    if (_busy || targets.isEmpty) return;
    final place = await showBatchPlaceFillDialog(
      context,
      rowCount: targets.length,
    );
    if (place == null || !mounted) return;
    if (place.isEmpty) {
      context.appWarning('库位号不能为空');
      return;
    }
    setState(() {
      for (final row in targets) {
        row.setCheckedPlace(place);
      }
    });
  }

  /// [route] = 点的是哪条路线的按钮(两条并排)。
  Future<void> _save(InboundRoute route) async {
    if (_busy || !_canRegister) return;
    final effective = route.isStockInFirst && !_canStockInFirst
        ? InboundRoute.inspectFirst
        : route;
    if (_route != effective) setState(() => _route = effective);
    if (_suggestions.loading) {
      context.appInfo('正在读取所选仓库的默认库位，请稍候再提交');
      return;
    }
    final rows = _grid.selectedRows
        .where((row) => !row.locked)
        .toList(growable: false);
    if (rows.isEmpty) {
      context.appError('请先勾选要登记的明细行(未勾选的行本次不登记)');
      return;
    }
    final stockInFirst = effective.isStockInFirst;
    final excludedCount = _editableRows.length - rows.length;
    // 明细整表扫完再报：按类别各汇总成一条，不同类别分行列出。
    final badQty = <String>[];
    final missingWarehouse = <String>[];
    final missingPlace = <String>[];
    final placeTooLong = <String>[];
    for (final row in rows) {
      final label = '第 ${_grid.rows.indexOf(row) + 1} 行(${row.goodsName})';
      if (stockInFirst) {
        final qty = double.tryParse(row.stockInQty.text.trim());
        if (qty == null ||
            qty <= 0 ||
            (qty - row.item.reportedQty).abs() > 1e-9) {
          badQty.add(label);
        }
      }
      if (row.warehouseId?.isNotEmpty != true) missingWarehouse.add(label);
      final place = row.place.text.trim();
      if (place.isEmpty) {
        missingPlace.add(label);
      } else if (place.length > 100) {
        placeTooLong.add(label);
      }
    }
    final rowIssues = <String>[
      if (badQty.isNotEmpty)
        inboundRowIssueMessage(
          badQty,
          '的本次实收与报工数量不一致(先入库后质检须全量一致)',
          action: '请改正，或改点「先质检后入库」按实物点收',
        ),
      if (missingWarehouse.isNotEmpty)
        inboundRowIssueMessage(missingWarehouse, '未选择入库仓库', action: '请补齐后再提交'),
      if (missingPlace.isNotEmpty)
        inboundRowIssueMessage(missingPlace, '未填写库位号', action: '请补齐后再提交'),
      if (placeTooLong.isNotEmpty)
        inboundRowIssueMessage(placeTooLong, '的库位号超过 100 字', action: '请改短后再提交'),
    ];
    if (rowIssues.isNotEmpty) {
      context.appError(rowIssues.join('\n'));
      return;
    }

    // 按行仓分组：一个仓一个登记批次 + 一张品质检查单（V469 一批一仓，V547 一仓一单）。
    final byWarehouse = <String, List<_FinishedArrivalLine>>{};
    for (final row in rows) {
      byWarehouse.putIfAbsent(row.warehouseId!, () => []).add(row);
    }
    final confirmed = await UtenDialog.show(
      context,
      title: effective.label,
      confirmLabel: stockInFirst ? '确认登记并先入库' : '确认登记送检',
      content: InboundConfirmPoints([
        if (excludedCount > 0)
          '有 $excludedCount 行未勾选：本次不登记、不写库存，仍留在任务中心待登记，可稍后办理。',
        if (byWarehouse.length > 1)
          '本次按 ${byWarehouse.length} 个入库仓库分别登记，每个仓一张品质检查单。',
        ...(stockInFirst
            ? const [
                '登记入库仓库与库位，并把每行实物按库位上架(先入库后质检)，逐行送品质部检验。',
                '品质部到库位检验：合格由系统按本次登记的仓库与库位自动入库，仓库不再确认第二次；不合格不动库存。',
                '本次库位会记住为该仓默认库位，下次登记自动带出。',
              ]
            : const [
                '登记入库仓库与库位，逐行送品质部检验。',
                '品质放行后仓库再按实物最终点收入库，可短收。',
                '本次库位会记住为该仓默认库位，下次登记自动带出。',
              ]),
      ]),
    );
    if (confirmed != true || !mounted) return;

    final remark = _remarkController.text.trim();
    setState(() => _saving = true);
    await saveFormDraftNow();
    final repo = ref.read(productionFinishedInboundTaskRepositoryProvider);
    for (final entry in byWarehouse.entries) {
      if (_registrations.containsKey(entry.key)) continue;
      // 幂等键含路线与实称重量指纹：同一页改用另一条路线、或改了重量重提交是另一个
      // 请求，不是重放；一行都没称时键与不称重时一致。
      final weightSuffix = warehouseWeightKeySuffix([
        for (final row in entry.value)
          ?warehouseWeightKeyPart(row.item.reportItemId, _sentKg(row), false),
      ]);
      final body = <String, dynamic>{
        'idempotencyKey': stockInFirst
            ? '$_idempotencyKey:${entry.key}:prestock$weightSuffix'
            : '$_idempotencyKey:${entry.key}$weightSuffix',
        'warehouseId': entry.key,
        if (remark.isNotEmpty) 'remark': remark,
        if (stockInFirst) 'stockInBeforeInspection': true,
        'items': [
          for (final row in entry.value)
            {
              'reportItemId': row.item.reportItemId,
              'place': row.place.text.trim(),
              if (stockInFirst)
                'countedQty': double.parse(row.stockInQty.text.trim()),
              // 实称净重(千克 4 位)：没称或按重量计的货品不带。
              'weight': ?_sentKg(row),
            },
        ],
      };
      try {
        final registered = await runFormDraftSubmission(
          () => repo.saveArrivalRegistration(widget.reportId, body),
        );
        if (!mounted) return;
        _registrations[entry.key] = registered;
        setState(() {
          for (final row in entry.value) {
            row.registered = true;
          }
        });
      } on ApiException catch (error) {
        _registrationFailed(entry.key, error.message);
        return;
      } catch (_) {
        _registrationFailed(entry.key, '登记失败，请稍后重试');
        return;
      }
    }
    if (!mounted) return;
    await completeFormDraft();
    if (!mounted) return;
    setState(() {
      _detail = _registrations.values.last;
      _saving = false;
      _registrationCompletedThisSession = true;
    });
    invalidateWarehouseTaskCounts(ref);
    context.appSuccess(_registeredSummary(stockInFirst));
    _leave(changed: true);
  }

  /// 部分仓失败：停在原页保住已填内容；已成功仓同键重放，直接重试即可。
  void _registrationFailed(String warehouseId, String message) {
    if (!mounted) return;
    setState(() => _saving = false);
    if (_registrations.isEmpty) {
      context.appError(message);
      return;
    }
    invalidateWarehouseTaskCounts(ref);
    final label = _warehouseLabel(warehouseId) ?? warehouseId;
    context.appError(
      '已按 ${_registrations.length} 个仓库登记；仓库「$label」登记失败：$message。'
      '可直接重试，已成功部分不会重复登记',
    );
  }

  String _registeredSummary(bool stockInFirst) {
    final sheets = _registrations.values
        .map((registration) => registration.sheetNo)
        .whereType<String>()
        .where((sheetNo) => sheetNo.isNotEmpty)
        .toList(growable: false);
    final sheetText = sheets.isEmpty ? '' : '，品质检查单 ${sheets.join('、')}';
    final head = _registrations.length == 1
        ? '入库仓库和库位已登记'
        : '已按 ${_registrations.length} 个仓库分别登记';
    return stockInFirst
        ? '$head并按库位先入库$sheetText：品质部到库位检验，合格后系统自动入库'
        : '$head，已送品质部检验$sheetText：放行后在任务中心按实物最终点收';
  }

  /// V548 撤回登记（仅品质未处理）：原因弹窗 → 服务端校验每条 FQC 仍待检 → 报工行回到待登记。
  Future<void> _reverseBatch(ProductionFinishedRegistrationBatch batch) async {
    if (_busy || !_hasRegisterPermission) return;
    final reason = await showArrivalRegistrationReversalDialog(
      context,
      title: '撤回登记(仅品质未处理)',
      summary:
          '登记批次 ${batch.warehouseName ?? '—'} · ${batch.itemCount} 行'
          '${batch.sheetNo == null ? '' : ' · 检查单 ${batch.sheetNo}'}',
    );
    if (reason == null || !mounted) return;
    setState(() => _reversing = true);
    try {
      await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .reverseArrivalRegistration(
            batch.registrationId,
            reason: reason,
            idempotencyKey: 'arrival-reverse-${const Uuid().v4()}',
          );
      if (!mounted) return;
      setState(() => _reversing = false);
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('登记已撤回，相关待检任务已取消；报工行重新回到待登记');
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _reversing = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _reversing = false);
      context.appError('撤回登记失败，请稍后重试');
    }
  }

  String? _warehouseLabel(String? warehouseId) {
    final label = inboundWarehouseLabel(
      ref.read(masterNameServiceProvider),
      warehouseId,
    );
    if (label != null && label != '—') return label;
    return _detail?.warehouseId == warehouseId ? _detail?.warehouseName : null;
  }

  void _leave({bool changed = false}) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(changed ? true : null);
      return;
    }
    backTo(
      context,
      defaultPath: RouteName.warehouseProductionFinishedInboundTasks,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.canRegister == null) {
      ref.watch(isSuperAdminProvider);
      ref.watch(currentPermissionsProvider);
    }
    // 单重参数缓存随页面存活。
    ref.watch(weightParamsCacheProvider);
    ref.watch(warehouseUnitMassUnitsProvider);
    final theme = Theme.of(context);
    // 「先入库后质检」按钮随权限快照实时显隐(独立权限点)。
    final canPreStock =
        ref.watch(isSuperAdminProvider) ||
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.productionFinishedInBeforeInspection);
    final names = ref.watch(masterNameServiceProvider);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '登记实际入库',
          leading: UtenBackButton(
            onPressed: () => _leave(changed: _registrationCompletedThisSession),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s8),
              child: UtenButton(
                key: const Key('production-finished-arrival-refresh'),
                type: UtenButtonType.tonal,
                icon: Icons.refresh_rounded,
                isLoading: _loading,
                onPressed: _loading || _busy ? null : _load,
                child: const Text('刷新'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : _detail == null
                  ? UtenEmpty.error(
                      message: _error ?? '没有找到可登记的成品报工任务',
                      description: '任务可能已被其他仓库人员处理，请返回任务中心刷新。',
                      actionLabel: '重新加载',
                      onAction: _load,
                    )
                  : AbsorbPointer(
                      absorbing: _busy,
                      child: _buildForm(theme, names, canPreStock),
                    ),
              if (_busy)
                UtenBusyOverlay(
                  title: _saving ? '正在登记入库' : '正在撤销本次登记',
                  description: _saving
                      ? '正在按入库仓库逐张登记，请勿重复提交或离开本页。'
                      : '请稍候，完成后自动继续。',
                ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        // 提交集=勾选集：监听表格选择集与库位建议，一行都没勾或建议加载中时提交置灰。
        floatingActionButton: _detail == null
            ? null
            : ListenableBuilder(
                listenable: Listenable.merge([_grid, _suggestions]),
                builder: (context, _) => _buildBottomBar(canPreStock),
              ),
      ),
    );
  }

  Widget _buildForm(
    ThemeData theme,
    MasterNameService names,
    bool canPreStock,
  ) {
    final detail = _detail!;
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    return UtenGridPageScrollbar(
      pinned: _gridPinned,
      controller: _scrollController,
      // 滚动条贴屏幕右缘：包装在内容容器之外，不随限宽容器/列宽漂移。
      child: UtenContentContainer(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            _buildHeaderCard(detail),
            const SizedBox(height: UtenSpacing.s12),
            if (detail.batches.isNotEmpty) ...[
              _buildBatchesCard(theme, detail.batches),
              const SizedBox(height: UtenSpacing.s12),
            ],
            InboundPlaceSuggestionStatus(
              loader: _suggestions,
              onRetry: () => _suggestions.reload(_editableRows),
            ),
            InboundGridIntro(
              sourceSummary: '来源报工单 ${detail.reportNo}',
              submitLabel:
                  '${InboundRoute.stockInFirst.label} / ${InboundRoute.inspectFirst.label}',
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_FinishedArrivalLine>(
              tableKey:
                  'features.warehouse.pages.production_finished_arrival_registration_page.ProductionFinishedArrivalRegistrationPageState._buildForm.1',
              key: const Key('production-finished-arrival-registration-grid'),
              controller: _grid,
              stickyHeaderPinned: _gridPinned,
              columns: _columns(names, canPreStock, weightUnits.entry),
              createBlankRow: () =>
                  throw UnsupportedError('成品入库登记明细由已审核报工固定带入'),
              showAddRow: false,
              showRowDelete: false,
              selectable: _canRegister,
              selectionEnabled: !_busy,
              canSelectRow: (row) => !row.locked,
              onRemoveRows: _canRegister ? _removeFromThisRegistration : null,
              removeRowsActionLabel: '移出本次登记',
              removeRowsDialogTitle: '移出本次登记',
              removeRowsConfirmLabel: '确认移出',
              removeRowsMessageBuilder: (count) =>
                  '确认从本次登记移出选中的 $count 行？'
                  '报工明细不会删除，也不会产生 FQC、入库或库存事实；'
                  '返回任务中心后仍保持待登记。',
              showSelectAllToggle: false,
              showRemoveRowsAction: false,
              // 行末常驻 ⊖(已登记行 canSelectRow=false，组件自动只占位)。
              showInlineRemoveAction: true,
              rowMenuExtraBuilder: _canRegister && !_busy
                  ? (context, selected) => [
                      UtenMenuItem(
                        label: '批量设置入库仓库 (${selected.length})',
                        icon: Icons.warehouse_outlined,
                        enabled: selected.isNotEmpty,
                        onTap: () => _pickWarehouseFor(selected),
                      ),
                      UtenMenuItem(
                        label: '批量设置库位号 (${selected.length})',
                        icon: Icons.edit_note_outlined,
                        enabled: selected.isNotEmpty,
                        onTap: () => _batchFillPlace(selected),
                      ),
                    ]
                  : null,
              emptyMessage: '该报工单没有可登记明细，请返回任务中心刷新',
              // 「称重单位: 千克▾」：录入单位是用户级偏好，表头与已填重量跟着换。
              toolbarActions: const [WeightEntryUnitButton()],
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 重量逐行输入不触发整页重建：合计条自己听重量格与单重参数。
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      _weightCache,
                      for (final row in _grid.rows) row.weight,
                    ]),
                    builder: (context, _) =>
                        inboundTotalsBar<_FinishedArrivalLine>(
                          key: const Key('production-finished-arrival-totals'),
                          lines: _grid.rows,
                          qtyLabel: '报工数量',
                          qtyOf: (row) => row.item.reportedQty,
                          unitIdOf: (row) => row.item.unitId,
                          unitNameOf: (row) =>
                              row.item.unitName ?? names.unit(row.item.unitId),
                          // 已登记行带着登记时的实称重量，与数量合计同口径全表合计。
                          weight: warehouseWeightTotals<_FinishedArrivalLine>(
                            _grid.rows,
                            weightOf: (row) => row.weight,
                            exactKgOf: _exactKg,
                            paramsOf: _paramsOf,
                            qtyBaseOf: (row) => row.item.reportedBaseQty,
                          ),
                          weightDisplay: weightUnits.display,
                        ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    detail.registered
                        ? '该报工单已登记，仓库和库位仅供核对。'
                        : !_canRegister
                        ? '当前账号只有查看权限，不能修改仓库或库位。'
                        : _removedLineCount > 0
                        ? '已移出 $_removedLineCount 行(仅本页临时选择)；这些报工行未写入，仍在待登记。'
                              '明细默认全选，提交只含勾选行。'
                        : '按行仓分组登记：一个入库仓库一个登记批次、一张品质检查单。'
                              '仓库按货品归属仓或上次所选仓预填，库位按该仓记住的库位或货品资料带出'
                              '(黄框请核对)；登记成功后自动记住为该仓默认库位。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenFloatingActionGroup.scrollClearance),
          ],
        ),
      ),
    );
  }

  /// 右下：取消 + 两条路线按钮并排(单张页由双击进入、未预选路线；同名同义、同一组件)。
  Widget _buildBottomBar(bool canPreStock) {
    final hasChecked = _grid.selectedRows.any((row) => !row.locked);
    final canSubmit =
        !_busy && !_suggestions.loading && !_grid.isEmpty && hasChecked;
    final VoidCallback? onDisabledTap = _suggestions.loading
        ? () => context.appInfo('正在读取所选仓库的默认库位，请稍候再提交')
        : !hasChecked
        ? () => context.appWarning('请先勾选要登记的明细行(未勾选的行本次不登记)')
        : null;
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _busy
              ? null
              : () => _leave(changed: _registrationCompletedThisSession),
          child: Text(_canRegister ? '取消' : '返回任务'),
        ),
        if (_canRegister)
          for (final route in InboundRoute.values)
            if (!route.isStockInFirst || canPreStock)
              InboundRouteSubmitButton(
                route: route,
                isLoading: _saving && _route == route,
                onPressed: canSubmit ? () => _save(route) : null,
                onDisabledTap: onDisabledTap,
              ),
      ],
    );
  }

  Widget _buildHeaderCard(ProductionFinishedArrivalRegistration detail) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenFormGrid(
              children: [
                _readOnlyField('报工单', detail.reportNo),
                _readOnlyField(
                  '报工日期',
                  ChinaDateTime.formatDate(detail.reportDate),
                ),
                _readOnlyField(
                  '生产计划',
                  detail.planNos.isEmpty ? '—' : detail.planNos.join('、'),
                ),
                _readOnlyField('车间', detail.workshopName ?? '—'),
                _readOnlyField('收货人', detail.receiverName ?? '—'),
                if (detail.registeredAt != null)
                  _readOnlyField(
                    '登记时间',
                    ChinaDateTime.formatDateTime(detail.registeredAt!),
                  ),
                if (detail.registered && detail.sheetNo?.isNotEmpty == true)
                  _readOnlyField('品质检查单', detail.sheetNo!),
                if (detail.reversedAt != null)
                  _readOnlyField(
                    '撤回登记',
                    '${ChinaDateTime.formatDateTime(detail.reversedAt!)}'
                        '${detail.reversalReason == null ? '' : ' · ${detail.reversalReason}'}',
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (detail.registered)
              _readOnlyField('备注', detail.remark?.trim() ?? '—')
            else
              TextField(
                key: const Key('production-finished-arrival-remark'),
                controller: _remarkController,
                enabled: _canRegister && !_busy,
                maxLength: 500,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '选填；随本次每个登记批次与品质检查单留痕',
                  counterText: '',
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 同一报工的登记批次（含已撤回历史）；品质未处理的批次可在此撤回登记。
  Widget _buildBatchesCard(
    ThemeData theme,
    List<ProductionFinishedRegistrationBatch> batches,
  ) {
    return Card(
      key: const Key('production-finished-arrival-batches'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '登记批次 (${batches.length})',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '一个入库仓库一个登记批次、一张品质检查单；品质尚未处理的批次可撤回登记，'
              '撤回后这些报工行重新回到待登记。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (final batch in batches)
              ListTile(
                key: ValueKey(
                  'production-finished-arrival-batch-${batch.registrationId}',
                ),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  batch.reversed
                      ? Icons.undo_rounded
                      : Icons.fact_check_outlined,
                  color: batch.reversed
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
                title: Text(
                  '${batch.warehouseName ?? '—'} · ${batch.itemCount} 行'
                  '${batch.sheetNo == null ? '' : ' · 检查单 ${batch.sheetNo}'}'
                  '${batch.reversed ? ' · 已撤回' : ''}',
                  style: batch.reversed
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          decoration: TextDecoration.lineThrough,
                        )
                      : null,
                ),
                subtitle: Text(
                  [
                    if (batch.registeredAt != null)
                      ChinaDateTime.formatDateTime(batch.registeredAt!),
                    if (batch.receiverName?.isNotEmpty == true)
                      '收货人 ${batch.receiverName}',
                    if (batch.remark?.isNotEmpty == true) '备注 ${batch.remark}',
                    if (batch.reversed)
                      '撤回原因 ${batch.reversalReason ?? '—'}'
                    else if (!batch.reversible)
                      '品质已处理，不能撤回',
                  ].join(' · '),
                ),
                trailing: batch.reversible && _hasRegisterPermission
                    ? UtenButton(
                        key: ValueKey(
                          'production-finished-arrival-reverse-${batch.registrationId}',
                        ),
                        type: UtenButtonType.secondary,
                        icon: Icons.undo_rounded,
                        isLoading: _reversing,
                        onPressed: _busy ? null : () => _reverseBatch(batch),
                        child: const Text('撤回登记(仅品质未处理)'),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _readOnlyField(String label, String value) => TextFormField(
    errorBuilder: utenTextFieldErrorBuilder,
    readOnly: true,
    initialValue: value,
    decoration: UtenInputDecoration(
      InputDecoration(
        labelText: label,
        filled: true,
        suffixIcon: const Icon(Icons.lock_outline, size: 16),
      ),
    ),
  );

  // 明细表列(与批量登记页、到货登记页同一套共用列，列名/列序/格式一致)：
  // 货品名称 → 编号 → 颜色 → 报工数量 → 本次实收 → 单位 → 实称重量 → 称重核对 →
  // 入库仓库 → 库位号。
  List<EditableGridColumn<_FinishedArrivalLine>> _columns(
    MasterNameService names,
    bool canPreStock,
    WeightUnit weightEntryUnit,
  ) {
    final shared = InboundGridColumns<_FinishedArrivalLine>(
      names: names,
      keyPrefix: 'production-finished-arrival',
      lineKeyOf: (row) => row.item.reportItemId,
      goodsCodeOf: (row) => row.item.goodsCode,
      colorNameOf: (row) => row.item.colorName,
      unitNameOf: (row) => row.item.unitName ?? names.unit(row.item.unitId),
    );
    bool editable(_FinishedArrivalLine row) =>
        _canRegister && !_busy && !row.locked;
    final canEditReceived = canPreStock && _canRegister;
    final showReceived =
        canEditReceived || _grid.rows.any((row) => row.item.countedQty != null);
    return [
      shared.goodsName(),
      shared.goodsCode(),
      shared.color(),
      shared.quantity(
        key: 'reportedQty',
        label: '报工数量',
        textOf: (row) => inboundQty(row.item.reportedQty),
        exactValueOf: (row) => row.item.reportedQty.toString(),
      ),
      // 本次实收：「先入库后质检」登记即承诺品质合格按此数量自动入库，须与报工数量一致；
      // 已登记行显示当时的实收(没记录显示「—」)。
      if (showReceived)
        shared.receivedQuantity(
          controllerOf: (row) =>
              canEditReceived && !row.locked ? row.stockInQty : null,
          enabled: editable,
          readOnlyExactValueOf: (row) => row.item.countedQty?.toString(),
          readOnlyTextOf: (row) => row.item.countedQty == null
              ? '—'
              : inboundQty(row.item.countedQty!),
          headerInfo:
              '点「先入库后质检」时生效：登记即承诺品质合格按此数量自动入库，默认=报工数量且须一致；'
              '数量不符请点「先质检后入库」，由仓库按实物点收。',
        ),
      shared.unit(),
      // 实称重量(可选)：只核对报工数量(折成基本单位)，不回填数量(报工数量以审核报工为准)；
      // 已登记行只读显示登记时的实称重量。
      shared.weight(
        entryUnit: weightEntryUnit,
        enabled: editable,
        paramsOf: _paramsOf,
        paramsListenable: _weightCache,
        qtyBaseOf: (row) => row.item.reportedBaseQty,
        exactKgOf: _exactKg,
        baseUnitNameOf: (row) => _baseUnitName(row, names),
      ),
      shared.weightCheck(
        paramsOf: _paramsOf,
        paramsListenable: _weightCache,
        qtyBaseOf: (row) => row.item.reportedBaseQty,
        baseUnitNameOf: (row) => _baseUnitName(row, names),
        against: '比报工',
      ),
      shared.warehouse(
        required: _canRegister,
        enabled: editable,
        onTap: (row) => _pickWarehouseFor(_writeTargets(row)),
        autofillInfo: '已带入货品归属仓或上次所选仓，请核对本次实物入库仓库',
        lockedBuilder: (context, row) => Text(
          _warehouseLabel(row.warehouseId) ?? '—',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      shared.place(
        required: _canRegister,
        enabled: editable,
        onChanged: _onPlaceChanged,
        headerInfo:
            '必填，不超过 100 字。选定入库仓库后按「该仓记住的库位 → 货品资料通用库位」'
            '自动带出；黄框 = 预填待核对，可直接修改。登记成功后自动记住为该仓默认库位。',
      ),
    ];
  }
}

/// 一行入库登记明细：共用的入库仓库/库位状态 + 先入库后质检的实收数。
class _FinishedArrivalLine extends InboundRegistrationLine {
  _FinishedArrivalLine(
    this.item, {
    required this.registered,
    String? registeredWarehouseId,
  }) : stockInQty = TextEditingController(text: inboundQty(item.reportedQty)),
       super(
         warehouseId: registered ? registeredWarehouseId : null,
         place: item.place?.trim().isNotEmpty == true
             ? item.place!.trim()
             : item.placeHint?.trim() ?? '',
         placeAutofilled: !registered,
         placeSource: item.placeHint?.trim().isNotEmpty == true
             ? InboundPlaceSource.goodsMaster
             : InboundPlaceSource.none,
       ) {
    // 已登记批次：只读显示登记时的实称重量(没称的行空着)。
    if (registered) weight.setKg(item.weight);
  }

  final ProductionFinishedArrivalRegistrationItem item;

  /// 已登记（历史快照或本会话已成功提交的仓）：仓与库位只读、不可再选。
  bool registered;

  /// 「本次实收」(先入库后质检的实收数，默认=报工数量)。
  final TextEditingController stockInQty;

  @override
  bool get locked => registered;
  @override
  String get goodsId => item.goodsId;
  @override
  String? get colorId => item.colorId;
  @override
  String get goodsName => item.goodsName;

  @override
  void dispose() {
    stockInQty.dispose();
    super.dispose();
  }
}
