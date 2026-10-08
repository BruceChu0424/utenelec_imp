// 产成品登记实际入库页(ADR-151 §5 单批合一：任务中心双击 = 1 张报工，多选 = N 张报工，同一个页面)。
//
// 2026-09-27 用户口径「产成品入库与采购/委外入库 UI、逻辑、表格、记忆都一样，能公用的
// 都公用」：本页与登记实际到货页(inbound_arrival_registration_page)同一骨架——
//   - 路线：任务中心多选时已选定(`?preStock=1` 先入库后质检 / `?preStock=0` 先质检后入库)，
//     右下只有这一条路线的提交按钮；双击进来没选路线，两条路线按钮并排；
//   - 明细表一行 = 一批实物(ADR-148：同一报工、同一产出批次、送入仓库的需求份 / 计划公共 /
//     实际超产是同一堆货)，「其中」列显示服务端算好的拆分，库位、实点、称重都是整批一个；
//   - 入库仓库、库位号行级必填(空时红框)；**勾选多行后在其中任意一行改仓/写库位 =
//     批量落到全部勾选行**，右键选中集可「批量设置入库仓库 / 批量设置库位号」；
//   - 同一张报工的不同批可以登记到不同仓库(服务端按「报工 x 实际仓」分成几个登记批次)；
//   - 记忆同一套：仓库预填 = 货品主档归属仓 → 上次在登记页显式选的仓(账号记忆，
//     InboundFillScope.finished)；库位 = 所选仓 × 货品 × 颜色的记忆库位 → 货品资料通用
//     库位(共用库位建议端点)；登记成功后服务端在同一事务里自动记住本次库位。
// 提交 = 一个事务按「报工 x 实际仓」逐组登记并生成各自的 FQC 送检(同一入库仓库合并成一张品质检查单)。
// 已登记的登记批次在品质未处理前可撤回登记。
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
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
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
import '../../../shared/measurement/widgets/weight_params_load_notice.dart';
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

class ProductionFinishedArrivalRegistrationPage extends ConsumerStatefulWidget {
  const ProductionFinishedArrivalRegistrationPage({
    super.key,
    required this.reportIds,
    this.returnTo,
    this.canRegister,
    this.route,
  });

  /// 来源报工(1..N)：双击 = 1 张，多选 = N 张。
  final List<String> reportIds;
  final String? returnTo;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限自行推导。
  final bool? canRegister;

  /// 任务中心进页时选定的路线(多选点哪条路线就带哪条)；为空 = 双击进来，两条路线并排。
  final InboundRoute? route;

  @override
  ConsumerState<ProductionFinishedArrivalRegistrationPage> createState() =>
      _ProductionFinishedArrivalRegistrationPageState();
}

class _ProductionFinishedArrivalRegistrationPageState
    extends ConsumerState<ProductionFinishedArrivalRegistrationPage>
    with FormDraftMixin<ProductionFinishedArrivalRegistrationPage> {
  final _grid = UtenEditableGridController<_FinishedLotLine>();
  final _scrollController = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  late final _suggestions = InboundPlaceSuggestionLoader(
    ref.read(warehousePlaceSuggestionRepositoryProvider),
  );
  String _idempotencyKey = 'finished-arrival-${const Uuid().v4()}';

  List<ProductionFinishedArrivalRegistration>? _reports;
  // 整批备注(V542)：落到本批每个登记批次。
  final _remarkController = TextEditingController();
  String? _error;
  bool _loading = false;
  bool _saving = false;
  bool _submitted = false;
  bool _reversing = false;
  int _removedLineCount = 0;

  /// 选定的路线(多选进页即定)；双击进页为空，两条路线按钮并排，点哪条走哪条。
  InboundRoute? _route;

  /// 最近一次点的路线(两条并排时，本次实收列跟着它走)。
  InboundRoute _activeRoute = InboundRoute.inspectFirst;

  bool get _canRegister {
    final override = widget.canRegister;
    if (override != null) return override;
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);
  }

  /// 「先入库后质检」需独立权限(服务端同样兜底)。
  bool get _canStockInFirst {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionFinishedInBeforeInspection);
  }

  List<_FinishedLotLine> get _editableRows =>
      _grid.rows.where((row) => !row.locked).toList(growable: false);

  /// 是否勾了可登记行(提交集=勾选集，右下按钮置灰门控)。
  bool get _hasCheckedEditableRow =>
      _grid.selectedRows.any((row) => !row.locked);

  bool get _busy => _saving || _reversing;

  /// 本次实收列是否可填：选定了先入库后质检，或两条并排且有权限(点哪条按哪条校验)。
  bool get _stockInQtyEditable =>
      (_route ?? _activeRoute).isStockInFirst ||
      (_route == null && _canStockInFirst);

  @override
  bool get formDraftBusy => _busy;

  @override
  Future<void> Function()? get formDraftReloadSource => _reloadLatestForDraft;

  Future<void> _reloadLatestForDraft() async {
    _remarkController.clear();
    _idempotencyKey = 'finished-arrival-${const Uuid().v4()}';
    _submitted = false;
    _route = _initialRoute();
    await _load();
    if (_error != null || _reports == null) {
      throw StateError(_error ?? '最新登记单据没有加载出来');
    }
  }

  InboundRoute? _initialRoute() {
    final route = widget.route;
    if (route == null) return null;
    return route.isStockInFirst && !_canStockInFirst
        ? InboundRoute.inspectFirst
        : route;
  }

  /// 幂等键随草稿持久化：丢响应后可安全重放。
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.finishedArrival.spec(
    title: workflowFieldText(context).handoffLotRegistrationTitle,
    route: RoutePath.warehouseProductionFinishedArrivalRegistration(
      widget.reportIds,
      stockInBeforeInspection: widget.route?.isStockInFirst,
    ),
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
    'route': _route?.name,
    'removedLineCount': _removedLineCount,
    'rows': [
      for (final row in _grid.rows)
        {
          'reportId': row.report.reportId,
          'lotId': row.lot.lotId,
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
    final savedRoute = InboundRoute.values
        .where((route) => route.name == data['route'])
        .firstOrNull;
    _route = savedRoute == null
        ? null
        : savedRoute.isStockInFirst && !_canStockInFirst
        ? InboundRoute.inspectFirst
        : savedRoute;
    _removedLineCount = (data['removedLineCount'] as num?)?.toInt() ?? 0;
    final saved = draftMaps(data['rows']);
    final retained = saved.map((item) => item['lotId']).toSet();
    _grid.removeWhere(
      (row) => !row.registered && !retained.contains(row.lot.lotId),
    );
    _grid.clearSelection();
    for (final item in saved) {
      final row = _grid.rows
          .where((row) => row.lot.lotId == item['lotId'])
          .firstOrNull;
      // Current registration facts win over an old editable snapshot after a lost response.
      if (row == null && item['registered'] != true) {
        throw const FormatException('原登记明细已变化或已由其他人办理，你填写的内容都还在；请刷新核对最新登记结果');
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
    _ensureWeightParams();
    if (mounted) setState(() {});
  }

  // ---- 实称重量(ADR-135)：单重参数按货品取(车间产出无供应商)，页面内缓存 ----

  /// 页面级单重参数缓存(build 里 watch，离开页面释放)。
  WeightParamsCache get _weightCache => ref.read(weightParamsCacheProvider);

  WeightParams? _paramsOf(_FinishedLotLine row) => _weightCache.of(
    row.goodsId,
    warehouseId: row.warehouseId,
    colorId: row.colorId,
  );

  /// 单位 -> 重量单位(报工单位本身按重量计时精确换算)。
  Map<String, WeightUnit> get _massUnits =>
      ref.read(warehouseUnitMassUnitsProvider).valueOrNull ?? const {};

  /// 已登记行也取参数：按重量计的货品显示「=N kg」，登记重量照样核对。
  void _ensureWeightParams() {
    if (!mounted) return;
    unawaited(
      _weightCache.ensure([
        for (final row in _grid.rows)
          WeightParamsLine(
            goodsId: row.goodsId,
            warehouseId: row.warehouseId,
            colorId: row.colorId,
          ),
      ]),
    );
  }

  /// 货品或报工单位按重量计时由报工数量精确换算(只读、不提交)；需要实称时为 null。
  double? _exactKg(_FinishedLotLine row) => warehouseExactLineKg(
    lineQty: row.lot.reportedQty,
    lineMassUnit: _massUnits[row.lot.unitId],
    unitRate: row.lot.unitRate,
    params: _paramsOf(row),
  );

  /// 核对重量的数量口径是货品基本单位；报工单位不是基本单位时不借用它的名字。
  String? _baseUnitName(_FinishedLotLine row, MasterNameService names) =>
      row.lot.unitRate == 1
      ? row.lot.unitName ?? names.unit(row.lot.unitId)
      : null;

  /// 随登记提交的整批实称净重(千克)；精确换算行与没称的批不带。
  double? _sentKg(_FinishedLotLine row) =>
      _exactKg(row) == null ? row.weight.kg : null;

  @override
  void initState() {
    super.initState();
    _route = _initialRoute();
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
      final reports = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .batchArrivalRegistrations(widget.reportIds);
      if (!mounted) return;
      final rows = [
        for (final report in reports)
          for (final lot in report.lots) _FinishedLotLine(report, lot),
      ];
      _grid.replaceAll(rows);
      // 进页默认全选：勾选=本次要登记的行，右下提交按钮只认勾选行。
      _grid.setSelected(
        rows.where((row) => !row.registered).toList(growable: false),
        true,
      );
      // 仓库预填链(与到货登记页同一口径，都不猜)：货品主档归属仓 → 上次在登记页
      // 显式选的仓(账号记忆)。预填一律黄框待核对，用户一动即清标。
      final selectable = WarehouseSelection(
        names.warehouseHierarchy,
        use: WarehouseUse.goodIn,
      ).selectableIds;
      final memory = ref.read(
        inboundWarehouseFillMemoryProvider(InboundFillScope.finished),
      );
      final remembered = selectable.contains(memory.warehouseId)
          ? memory.warehouseId
          : null;
      for (final row in rows) {
        if (row.registered) continue;
        final master = row.lot.lastWarehouseId;
        row.setWarehouse(
          selectable.contains(master) ? master : remembered,
          autofilled: true,
        );
      }
      setState(() {
        _reports = reports;
        _removedLineCount = 0;
        _loading = false;
      });
      _ensureWeightParams();
      await _suggestions.reload(_editableRows);
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
        _error = '成品登记信息加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 一次改动的落值范围：**勾选若干行 → 在其中任意一行改仓/写库位 = 批量落到全部
  /// 勾选行**；点的行不在勾选集里(或压根没勾)就只改这一行。
  List<_FinishedLotLine> _writeTargets(_FinishedLotLine row) {
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 选入库仓库(行内点击与右键批量共用)：落到目标行、记住这次选的仓，并按新仓
  /// 重新拉库位建议(只覆盖没手填过的行)。
  Future<void> _pickWarehouseFor(List<_FinishedLotLine> rows) async {
    final targets = rows.where((row) => !row.locked).toList();
    if (_busy || targets.isEmpty) return;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      use: WarehouseUse.goodIn,
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
    _ensureWeightParams();
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
  void _onPlaceChanged(_FinishedLotLine row, String value) {
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
  Future<void> _batchFillPlace(List<_FinishedLotLine> rows) async {
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

  /// V548 撤回登记批次(仅品质未处理)：原因弹窗 → 服务端校验 → 重新拉取本页。
  Future<void> _reverseBatch(
    ProductionFinishedArrivalRegistration report,
    ProductionFinishedRegistrationBatch batch,
  ) async {
    if (_busy || !_canRegister) return;
    final reason = await showArrivalRegistrationReversalDialog(
      context,
      title: '撤回登记(仅品质未处理)',
      summary:
          '报工单 ${report.reportNo} · ${batch.warehouseName ?? '—'} · '
          '${batch.itemCount} 行'
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
    } catch (error) {
      if (!mounted) return;
      setState(() => _reversing = false);
      context.appError(describeSubmitError(error, fallback: '撤回登记失败，请稍后重试'));
    }
  }

  /// 仅从本次登记移出：来源报工、库存和历史均不变，返回任务中心仍待登记。
  void _removeFromThisRegistration(List<_FinishedLotLine> rows) {
    final removable = rows.where((row) => !row.locked).toList();
    if (_busy || _submitted || !_canRegister || removable.isEmpty) return;
    _grid.removeRows(removable);
    if (!mounted) return;
    setState(() => _removedLineCount += removable.length);
    context.appInfo('已从本次登记移出 ${removable.length} 行；未写入数据库，返回任务中心后仍可继续登记');
  }

  Future<void> _save(InboundRoute route) async {
    if (_busy || !_canRegister || _submitted) return;
    if (route.isStockInFirst && !_canStockInFirst) {
      // 路线进页已定，这里只会因权限被收回而退回原流程：说明原因并换成
      // 「先质检后入库」按钮，由用户决定是否继续，不静默换路线提交。
      setState(() => _route = InboundRoute.inspectFirst);
      context.appWarning('当前账号没有「产成品先入库后质检」权限，已切换为「先质检后入库」，请确认后再提交');
      return;
    }
    setState(() => _activeRoute = route);
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
    final stockInFirst = route.isStockInFirst;
    final submitted = rows.toSet();
    final excludedCount = _editableRows.length - rows.length;
    // 整批一次扫完再报：按类别各汇总成一条，不同类别分行列出。
    final badQty = <String>[];
    final missingWarehouse = <String>[];
    final missingPlace = <String>[];
    final placeTooLong = <String>[];
    for (var index = 0; index < _grid.rows.length; index++) {
      final row = _grid.rows[index];
      if (!submitted.contains(row)) continue;
      final label = '第 ${index + 1} 行(${row.report.reportNo} ${row.goodsName})';
      if (stockInFirst) {
        final qty = double.tryParse(row.stockInQty.text.trim());
        if (qty == null ||
            qty <= 0 ||
            (qty - row.lot.reportedQty).abs() > 1e-9) {
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
          '的本次实收与报工数量不一致(先入库后质检须整批全量一致)',
          action: '请改正，或改走「先质检后入库」按实物点收',
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
    final reportCount = rows.map((row) => row.report.reportId).toSet().length;
    final confirmed = await UtenDialog.show(
      context,
      title: '${route.label}($reportCount 张报工单)',
      confirmLabel: stockInFirst ? '确认登记并先入库' : '确认登记送检',
      content: InboundConfirmPoints([
        if (excludedCount > 0)
          '有 $excludedCount 行未勾选：本次不登记、不写库存，仍留在任务中心待登记，可稍后办理。',
        ...(stockInFirst
            ? const [
                '按「报工单 x 入库仓库」逐组登记入库仓库与库位，并把每批实物按库位上架(先入库后质检)，一起送品质部检验。整批一起生效，不会只成功一半。',
                '品质部到库位按整批检验：合格由系统按本次登记的仓库与库位自动入库，仓库不再确认第二次；不合格不动库存。',
                '本次库位会记住为该仓默认库位，下次登记自动带出。',
              ]
            : const [
                '按「报工单 x 入库仓库」逐组登记入库仓库与库位，送品质部按整批检验；同一仓库的行合并成一张品质检查单。',
                '品质放行后仓库再按实物最终点收入库，可短收(短收先扣实际超产)。',
                '本次库位会记住为该仓默认库位，下次登记自动带出。',
              ]),
      ]),
    );
    if (confirmed != true || !mounted) return;

    // 幂等键含路线与实称重量指纹：换路线或改了重量重提交是另一个请求，不是重放；
    // 一批都没称时键与不称重时一致。
    final weightSuffix = warehouseWeightKeySuffix([
      for (final row in rows)
        ?warehouseWeightKeyPart(row.lot.lotId, _sentKg(row), false),
    ]);
    setState(() => _saving = true);
    ProductionFinishedBatchRegistrationResult result;
    try {
      await saveFormDraftNow();
      result = await runFormDraftSubmission(
        () => ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .saveArrivalRegistrationBatch({
              'idempotencyKey': stockInFirst
                  ? '$_idempotencyKey:prestock$weightSuffix'
                  : '$_idempotencyKey$weightSuffix',
              if (stockInFirst) 'stockInBeforeInspection': true,
              if (_remarkController.text.trim().isNotEmpty)
                'remark': _remarkController.text.trim(),
              // 一行一批实物：库位、实点、称重都是整批一个，服务端按「报工 x 实际仓」分组展开到各份。
              'lots': [
                for (final row in rows)
                  {
                    'lotId': row.lot.lotId,
                    'warehouseId': row.warehouseId,
                    'place': row.place.text.trim(),
                    if (stockInFirst)
                      'countedQty': double.parse(row.stockInQty.text.trim()),
                    // 实称净重(千克 4 位)：没称或按重量计的货品不带。
                    'weight': ?_sentKg(row),
                  },
              ],
            }),
      );
    } catch (error, stack) {
      // 服务端拒绝与本机草稿保护的原因都如实给人看(ADR-151 §2), 不再一律吞成兜底句。
      if (error is! ApiException) {
        debugPrint('登记产成品入库失败: $error\n$stack');
      }
      if (mounted) {
        setState(() => _saving = false);
        context.appError(
          describeSubmitError(error, fallback: '登记失败，请保持当前内容后重试'),
        );
      }
      return;
    }
    await completeFormDraft();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _submitted = true;
    });
    invalidateWarehouseTaskCounts(ref);
    context.appSuccess(
      stockInFirst
          ? '已登记 ${result.registeredCount} 张报工单并按库位先入库：品质部到库位检验，'
                '合格后系统自动入库${_sheetSummary(result)}'
          : '已登记 ${result.registeredCount} 张报工单，已送品质部检验：'
                '放行后在任务中心按实物最终点收${_sheetSummary(result)}',
    );
    _leave(changed: true);
  }

  /// 同仓合并成一张品质检查单；成功提示带单号，便于品质部对单。
  static String _sheetSummary(
    ProductionFinishedBatchRegistrationResult result,
  ) {
    if (result.sheets.isEmpty) return '';
    final labels = result.sheets
        .map(
          (sheet) =>
              '${sheet.sheetNo}(${sheet.warehouseName ?? '—'} ${sheet.itemCount} 行)',
        )
        .join('、');
    return '；品质检查单 ${result.sheets.length} 张：$labels';
  }

  void _leave({bool changed = false}) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(changed ? true : null);
      return;
    }
    final returnTo = widget.returnTo;
    if (returnTo != null && returnTo.isNotEmpty) {
      goFrom(context, returnTo);
      return;
    }
    backTo(
      context,
      defaultPath: RouteName.warehouseProductionFinishedInboundTasks,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = workflowFieldText(context);
    if (widget.reportIds.isEmpty) {
      return Scaffold(
        appBar: UtenAppBar(title: l10n.handoffLotRegistrationTitle),
        body: UtenEmpty.error(
          message: '没有选择待登记的报工单',
          description: '请返回任务中心重新选择任务。',
        ),
      );
    }
    // 建立权限快照订阅；授权刷新/撤销时整页重建并即时收起写操作。
    if (widget.canRegister == null) {
      ref.watch(isSuperAdminProvider);
      ref.watch(currentPermissionsProvider);
    }
    // 单重参数缓存随页面存活。
    ref.watch(weightParamsCacheProvider);
    ref.watch(warehouseUnitMassUnitsProvider);
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final canRegister = _canRegister;
    final route = _route;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: l10n.handoffLotRegistrationTitle,
          // 多选时路线在任务中心已选定：标题下标明本页走哪条。
          subtitle: route == null ? null : '路线：${route.label}',
          leading: UtenBackButton(onPressed: () => _leave(changed: _submitted)),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : _reports == null
                  ? UtenEmpty.error(
                      message: _error ?? '没有找到可登记的成品报工任务',
                      description: '任务可能已被其他仓库人员处理，请返回任务中心刷新。',
                      actionLabel: '重新加载',
                      onAction: _load,
                    )
                  : AbsorbPointer(
                      absorbing: _busy,
                      child: _buildForm(context, theme, names, canRegister),
                    ),
              if (_busy)
                UtenBusyOverlay(
                  title: _saving ? '正在登记入库' : '正在撤销本次登记',
                  description: _saving
                      ? '正在按报工单与入库仓库逐组登记，请勿重复提交或离开本页。'
                      : '请稍候，完成后自动继续。',
                ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        // 提交集=勾选集：监听表格选择集与库位建议，一行都没勾或建议加载中时提交置灰。
        floatingActionButton: _reports == null
            ? null
            : ListenableBuilder(
                listenable: Listenable.merge([_grid, _suggestions]),
                builder: (context, _) => _buildBottomBar(canRegister),
              ),
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    ThemeData theme,
    MasterNameService names,
    bool canRegister,
  ) {
    final l10n = workflowFieldText(context);
    final reports = _reports!;
    final registeredReports = reports.where((r) => r.registered).length;
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    final batches = [
      for (final report in reports)
        for (final batch in report.batches) (report, batch),
    ];
    return UtenGridPageScrollbar(
      pinned: _gridPinned,
      controller: _scrollController,
      // 滚动条贴屏幕右缘：包装在内容容器之外，不随限宽容器/列宽漂移。
      child: UtenContentContainer(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            _buildHeaderCard(reports, canRegister),
            const SizedBox(height: UtenSpacing.s12),
            InboundPlaceSuggestionStatus(
              loader: _suggestions,
              onRetry: () => _suggestions.reload(_editableRows),
            ),
            WeightParamsLoadNotice(cache: _weightCache),
            InboundGridIntro(
              sourceSummary:
                  '来自 ${reports.length} 张报工单'
                  '${registeredReports > 0 ? '(其中 $registeredReports 张已登记，只读)' : ''}',
              submitLabel: _route?.label ?? '提交按钮',
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_FinishedLotLine>(
              tableKey:
                  'features.warehouse.pages.production_finished_arrival_registration_page.ProductionFinishedArrivalRegistrationPageState._buildForm.1',
              key: const Key('production-finished-arrival-grid'),
              controller: _grid,
              stickyHeaderPinned: _gridPinned,
              columns: _columns(names, canRegister, weightUnits.entry, l10n),
              createBlankRow: () => throw UnsupportedError('明细由所选报工单固定带入'),
              showAddRow: false,
              showRowDelete: false,
              selectable: canRegister && !_submitted,
              selectionEnabled: !_busy && !_submitted,
              canSelectRow: (row) => !row.locked && !_submitted,
              onRemoveRows: canRegister && !_submitted
                  ? _removeFromThisRegistration
                  : null,
              removeRowsActionLabel: '移出本次登记',
              removeRowsDialogTitle: '移出本次登记',
              removeRowsConfirmLabel: '确认移出',
              removeRowsMessageBuilder: (count) =>
                  '确认从本次登记移出选中的 $count 行？'
                  '报工事实不会删除，也不会产生 FQC、入库或库存事实；'
                  '返回任务中心后仍保持待登记。',
              showSelectAllToggle: false,
              showRemoveRowsAction: false,
              // 行末常驻 ⊖(已登记行与提交后 canSelectRow=false，自动只占位)。
              showInlineRemoveAction: true,
              rowMenuExtraBuilder: canRegister && !_busy && !_submitted
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
              emptyMessage: '所选报工单没有可登记明细，请返回任务中心刷新',
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
                      for (final row in _editableRows) row.weight,
                    ]),
                    builder: (context, _) => inboundTotalsBar<_FinishedLotLine>(
                      key: const Key('production-finished-arrival-totals'),
                      lines: _editableRows,
                      qtyLabel: '报工数量',
                      qtyOf: (row) => row.lot.reportedQty,
                      unitIdOf: (row) => row.lot.unitId,
                      unitNameOf: (row) =>
                          row.lot.unitName ?? names.unit(row.lot.unitId),
                      weight: warehouseWeightTotals<_FinishedLotLine>(
                        _editableRows,
                        weightOf: (row) => row.weight,
                        exactKgOf: _exactKg,
                        paramsOf: _paramsOf,
                        qtyBaseOf: (row) => row.lot.reportedBaseQty,
                      ),
                      weightDisplay: weightUnits.display,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    !canRegister
                        ? '当前账号只有查看权限，不能修改仓库或库位。'
                        : _removedLineCount > 0
                        ? '已移出 $_removedLineCount 行(仅本页临时选择)；这些报工行未写入，仍在待登记。'
                              '明细默认全选，提交只含勾选行。'
                        : l10n.handoffLotRegistrationFooter,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (batches.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              _buildBatchesCard(theme, l10n, batches),
            ],
            const SizedBox(height: UtenFloatingActionGroup.scrollClearance),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard(
    List<ProductionFinishedArrivalRegistration> reports,
    bool canRegister,
  ) {
    final receiverName = reports.isNotEmpty ? reports.first.receiverName : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenFormGrid(
              children: [
                _readOnlyField(
                  '报工日期',
                  ChinaDateTime.formatDate(
                    reports
                        .map((r) => r.reportDate)
                        .reduce((a, b) => a.isBefore(b) ? a : b),
                  ),
                ),
                _readOnlyField('收货人', receiverName ?? '—'),
              ],
            ),
            // 备注随本次登记留痕：只剩已登记的只读批时不出输入框。
            if (_editableRows.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const Key('production-finished-arrival-remark'),
                controller: _remarkController,
                enabled: canRegister && !_busy && !_submitted,
                maxLength: 500,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '选填；随本次登记留痕',
                  counterText: '',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 已有的登记批次(含已撤回历史)：一张报工可能按仓分成几批；品质未处理的批次可撤回。
  Widget _buildBatchesCard(
    ThemeData theme,
    AppLocalizations l10n,
    List<
      (
        ProductionFinishedArrivalRegistration,
        ProductionFinishedRegistrationBatch,
      )
    >
    batches,
  ) {
    return Card(
      key: const Key('production-finished-arrival-batches'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.handoffLotBatchesTitle(batches.length),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              l10n.handoffLotBatchesHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (final (report, batch) in batches)
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
                  '${report.reportNo} · ${batch.warehouseName ?? '—'} · ${batch.itemCount} 份'
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
                trailing: batch.reversible && _canRegister
                    ? UtenButton(
                        key: ValueKey(
                          'production-finished-arrival-reverse-${batch.registrationId}',
                        ),
                        type: UtenButtonType.secondary,
                        icon: Icons.undo_rounded,
                        isLoading: _reversing,
                        onPressed: _busy
                            ? null
                            : () => _reverseBatch(report, batch),
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

  Widget _buildBottomBar(bool canRegister) {
    final hasChecked = _hasCheckedEditableRow;
    final canSubmit =
        canRegister &&
        !_busy &&
        !_submitted &&
        !_suggestions.loading &&
        !_grid.isEmpty &&
        hasChecked;
    final routes = _route != null
        ? [_route!]
        : [
            if (_canStockInFirst) InboundRoute.stockInFirst,
            InboundRoute.inspectFirst,
          ];
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _busy ? null : () => _leave(changed: _submitted),
          child: Text(canRegister ? '取消' : '返回任务'),
        ),
        // 多选时任务中心选定了路线就只显示这一条；双击进来两条并排(同名同义、同一组件)。
        // 所选报工都已登记(只剩只读批)时不出提交按钮。
        if (canRegister && !_submitted && _editableRows.isNotEmpty)
          for (final route in routes)
            InboundRouteSubmitButton(
              route: route,
              isLoading: _saving && _activeRoute == route,
              onPressed: canSubmit ? () => _save(route) : null,
              onDisabledTap: _suggestions.loading
                  ? () => context.appInfo('正在读取所选仓库的默认库位，请稍候再提交')
                  : !hasChecked
                  ? () => context.appWarning('请先勾选要登记的明细行(未勾选的行本次不登记)')
                  : null,
            ),
      ],
    );
  }

  List<EditableGridColumn<_FinishedLotLine>> _columns(
    MasterNameService names,
    bool canRegister,
    WeightUnit weightEntryUnit,
    AppLocalizations l10n,
  ) {
    final shared = InboundGridColumns<_FinishedLotLine>(
      names: names,
      keyPrefix: 'production-finished-arrival',
      lineKeyOf: (row) => row.lot.lotId,
      goodsCodeOf: (row) => row.lot.goodsCode,
      colorNameOf: (row) => row.lot.colorName,
      unitNameOf: (row) => row.lot.unitName ?? names.unit(row.lot.unitId),
    );
    bool editable(_FinishedLotLine row) =>
        canRegister && !_busy && !_submitted && !row.locked;
    final showReceived =
        _stockInQtyEditable ||
        _grid.rows.any((row) => row.lot.countedQty != null);
    return [
      EditableGridColumn(
        key: 'reportNo',
        label: '来源报工单',
        width: 150,
        filterValueOf: (row) => inboundBucket(row.report.reportNo),
        textOf: (row) => row.report.reportNo,
        cellBuilder: (context, row) => Text(
          row.report.reportNo,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      shared.goodsName(),
      shared.goodsCode(),
      shared.color(),
      shared.quantity(
        key: 'reportedQty',
        label: '报工数量',
        textOf: (row) => inboundQty(row.lot.reportedQty),
        exactValueOf: (row) => row.lot.reportedQty.toString(),
      ),
      // 一批实物里需求份 / 计划公共 / 实际超产各多少(服务端算好)；整批都是需求份时空着。
      EditableGridColumn(
        key: 'lotSplit',
        label: l10n.handoffLotSplitColumn,
        headerInfo: l10n.handoffLotSplitColumnInfo,
        width: 190,
        textOf: (row) => row.lot.splitText ?? '',
        cellBuilder: (context, row) => Text(
          row.lot.splitText ?? '',
          key: ValueKey('production-finished-arrival-split-${row.lot.lotId}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // 本次实收：先入库后质检 = 登记即承诺合格按此数量自动入库，须与整批报工数量一致；
      // 已登记行显示当时的实收(没记录显示「—」)。
      if (showReceived)
        shared.receivedQuantity(
          controllerOf: (row) =>
              _stockInQtyEditable && !row.locked ? row.stockInQty : null,
          enabled: editable,
          readOnlyExactValueOf: (row) => row.lot.countedQty?.toString(),
          readOnlyTextOf: (row) => row.lot.countedQty == null
              ? '—'
              : inboundQty(row.lot.countedQty!),
          headerInfo:
              '先入库后质检：登记即承诺品质合格按此数量自动入库，默认=整批报工数量且须一致；'
              '数量不符请改走「先质检后入库」，由仓库按实物点收。',
        ),
      shared.unit(),
      // 实称重量(可选)：整批一个称重，只核对报工数量(折成基本单位)，不回填数量。
      shared.weight(
        entryUnit: weightEntryUnit,
        enabled: editable,
        paramsOf: _paramsOf,
        paramsListenable: _weightCache,
        qtyBaseOf: (row) => row.lot.reportedBaseQty,
        exactKgOf: _exactKg,
        baseUnitNameOf: (row) => _baseUnitName(row, names),
      ),
      shared.weightCheck(
        paramsOf: _paramsOf,
        paramsListenable: _weightCache,
        qtyBaseOf: (row) => row.lot.reportedBaseQty,
        baseUnitNameOf: (row) => _baseUnitName(row, names),
        against: '比报工',
      ),
      shared.warehouse(
        required: canRegister && !_submitted,
        enabled: editable,
        onTap: (row) => _pickWarehouseFor(_writeTargets(row)),
        autofillInfo: '已带入货品归属仓或上次所选仓，请核对本次实物入库仓库',
        lockedBuilder: (context, row) => Text(
          '${inboundWarehouseLabel(names, row.warehouseId) ?? row.report.warehouseName ?? '—'}'
          '${row.report.sheetNo == null ? '' : ' · ${row.report.sheetNo}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      shared.place(
        required: canRegister && !_submitted,
        enabled: editable,
        onChanged: _onPlaceChanged,
        headerInfo:
            '必填，不超过 100 字。选定入库仓库后按「该仓记住的库位 → 货品资料通用库位」'
            '自动带出；黄框 = 预填待核对，可直接修改。登记成功后自动记住为该仓默认库位。',
      ),
    ];
  }
}

/// 一行 = 一批实物：挂来源报工单 + 共用的入库仓库/库位状态 + 先入库后质检的整批实收数。
class _FinishedLotLine extends InboundRegistrationLine {
  _FinishedLotLine(this.report, this.lot)
    : registered = report.registered,
      stockInQty = TextEditingController(text: inboundQty(lot.reportedQty)),
      super(
        warehouseId: report.registered ? report.warehouseId : null,
        place: lot.place?.trim().isNotEmpty == true
            ? lot.place!.trim()
            : lot.placeHint?.trim() ?? '',
        placeAutofilled: !report.registered,
        placeSource: lot.placeHint?.trim().isNotEmpty == true
            ? InboundPlaceSource.goodsMaster
            : InboundPlaceSource.none,
      ) {
    // 已登记的批：只读显示登记时的整批实称重量(没称的空着)。
    if (registered) weight.setKg(lot.weight);
  }

  final ProductionFinishedArrivalRegistration report;
  final ProductionFinishedArrivalLot lot;
  final bool registered;

  /// 「本次实收」(先入库后质检的整批实收数，默认=整批报工数量)。
  final TextEditingController stockInQty;

  @override
  bool get locked => registered;
  @override
  String get goodsId => lot.goodsId;
  @override
  String? get colorId => lot.colorId;
  @override
  String get goodsName => lot.goodsName;

  @override
  void dispose() {
    stockInQty.dispose();
    super.dispose();
  }
}
