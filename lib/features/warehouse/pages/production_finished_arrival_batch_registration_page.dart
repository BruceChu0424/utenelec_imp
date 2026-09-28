// 多报工单汇总登记入库(任务中心多选「先入库后质检(N)」/「先质检后入库(N)」落点)。
//
// 2026-09-27 用户口径「产成品入库与采购/委外入库 UI、逻辑、表格、记忆都一样，能公用的
// 都公用」：本页与批量登记实际到货页(warehouse_arrival_batch_receipt_page)同一骨架——
//   - 路线由任务中心进页时定死(`?preStock=1` = 先入库后质检)，标题下「路线：…」，
//     右下只有这一条路线的提交按钮(InboundRouteSubmitButton)；
//   - 明细表列名/列序/格式与到货页一致(InboundGridColumns 共用列)：来源报工单 →
//     货品名称 → 编号 → 颜色 → 报工数量 → 本次实收 → 单位 → 入库仓库 → 库位号；
//   - 入库仓库、库位号行级必填(空时红框)；**勾选多行后在其中任意一行改仓/写库位 =
//     批量落到全部勾选行**，右键选中集可「批量设置入库仓库 / 批量设置库位号」；
//   - 记忆同一套：仓库预填 = 货品主档归属仓 → 上次在登记页显式选的仓(账号记忆，
//     InboundFillScope.finished)；库位 = 所选仓 × 货品 × 颜色的记忆库位 → 货品资料通用
//     库位(共用库位建议端点)；登记成功后服务端在同一事务里自动记住本次库位，不再有
//     「同时记住」开关与单独的记忆请求。
// 提交 = 一个事务逐单登记并生成各自的 FQC 送检(同一入库仓库的行合并成一张品质检查单)。
// 已登记(只读)报工在品质未处理前可撤回登记。
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
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../models/inbound_registration_line.dart';
import '../models/production_finished_inbound_task.dart';
import '../providers/inbound_warehouse_fill_memory.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';
import '../repositories/warehouse_place_suggestion_repository.dart';
import '../widgets/arrival_registration_reversal_dialog.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/inbound_registration_widgets.dart';

class ProductionFinishedArrivalBatchRegistrationPage
    extends ConsumerStatefulWidget {
  const ProductionFinishedArrivalBatchRegistrationPage({
    super.key,
    required this.reportIds,
    this.returnTo,
    this.canRegister,
    this.stockInBeforeInspection = false,
  });

  final List<String> reportIds;
  final String? returnTo;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限自行推导。
  final bool? canRegister;

  /// 任务中心进页时选定的路线：true = 「先入库后质检(N)」直达(`?preStock=1`)，
  /// false = 「先质检后入库(N)」直达。本页只显示这一条路线的提交按钮。
  final bool stockInBeforeInspection;

  @override
  ConsumerState<ProductionFinishedArrivalBatchRegistrationPage> createState() =>
      _ProductionFinishedArrivalBatchRegistrationPageState();
}

class _ProductionFinishedArrivalBatchRegistrationPageState
    extends ConsumerState<ProductionFinishedArrivalBatchRegistrationPage>
    with FormDraftMixin<ProductionFinishedArrivalBatchRegistrationPage> {
  final _grid = UtenEditableGridController<_FinishedBatchLine>();
  final _scrollController = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  late final _suggestions = InboundPlaceSuggestionLoader(
    ref.read(warehousePlaceSuggestionRepositoryProvider),
  );
  String _idempotencyKey = 'finished-arrival-batch-${const Uuid().v4()}';

  List<ProductionFinishedArrivalRegistration>? _reports;
  // 整批备注（V542）：落到本批每个登记批次。
  final _remarkController = TextEditingController();
  String? _error;
  bool _loading = false;
  bool _saving = false;
  bool _submitted = false;
  bool _reversing = false;
  int _removedLineCount = 0;

  /// 本页路线(进页即定；没有独立权限时退回「先质检后入库」)。
  InboundRoute _route = InboundRoute.inspectFirst;

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

  List<_FinishedBatchLine> get _editableRows =>
      _grid.rows.where((row) => !row.locked).toList(growable: false);

  /// 是否勾了可登记行(提交集=勾选集，右下按钮置灰门控)。
  bool get _hasCheckedEditableRow =>
      _grid.selectedRows.any((row) => !row.locked);

  bool get _busy => _saving || _reversing;

  @override
  bool get formDraftBusy => _busy;

  /// 幂等键随草稿持久化：丢响应后可安全重放。
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.finishedArrivalBatch.spec(
    title: '批量登记实际入库',
    route: Uri(
      path: RouteName.warehouseProductionFinishedArrivalBatchRegistration,
      queryParameters: {
        'reportIds': widget.reportIds.join(','),
        if (widget.stockInBeforeInspection) InboundRoute.queryKey: '1',
      },
    ).toString(),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _remarkController,
    _grid,
    for (final row in _grid.rows) ...[row.place, row.warehouse, row.stockInQty],
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
          'reportId': row.report.reportId,
          'reportItemId': row.item.reportItemId,
          'warehouseId': row.warehouseId,
          'warehouseAutofilled': row.warehouseAutofilled,
          'place': row.place.text,
          'placeAutofilled': row.place.autofilled,
          'stockInQty': row.stockInQty.text,
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
      if (item['selected'] == true) _grid.setSelected([row], true);
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _route = widget.stockInBeforeInspection && _canStockInFirst
        ? InboundRoute.stockInFirst
        : InboundRoute.inspectFirst;
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
          for (final item in report.items) _FinishedBatchLine(report, item),
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
      ).selectableIds;
      final memory = ref.read(
        inboundWarehouseFillMemoryProvider(InboundFillScope.finished),
      );
      final remembered = selectable.contains(memory.warehouseId)
          ? memory.warehouseId
          : null;
      for (final row in rows) {
        if (row.registered) continue;
        final master = row.item.lastWarehouseId;
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
        _error = '成品汇总登记信息加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 一次改动的落值范围：**勾选若干行 → 在其中任意一行改仓/写库位 = 批量落到全部
  /// 勾选行**；点的行不在勾选集里(或压根没勾)就只改这一行。
  List<_FinishedBatchLine> _writeTargets(_FinishedBatchLine row) {
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 选入库仓库(行内点击与右键批量共用)：落到目标行、记住这次选的仓，并按新仓
  /// 重新拉库位建议(只覆盖没手填过的行)。
  Future<void> _pickWarehouseFor(List<_FinishedBatchLine> rows) async {
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
  void _onPlaceChanged(_FinishedBatchLine row, String value) {
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
  Future<void> _batchFillPlace(List<_FinishedBatchLine> rows) async {
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

  /// V548 撤回已登记报工（仅品质未处理）：原因弹窗 → 服务端校验 → 重新拉取本页。
  Future<void> _reverseRegistered(
    ProductionFinishedArrivalRegistration report,
  ) async {
    final registrationId = report.registrationId;
    if (registrationId == null || _busy || !_canRegister) return;
    final reason = await showArrivalRegistrationReversalDialog(
      context,
      title: '撤回登记(仅品质未处理)',
      summary:
          '报工单 ${report.reportNo} · ${report.warehouseName ?? '—'} · '
          '${report.items.length} 行'
          '${report.sheetNo == null ? '' : ' · 检查单 ${report.sheetNo}'}',
    );
    if (reason == null || !mounted) return;
    setState(() => _reversing = true);
    try {
      await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .reverseArrivalRegistration(
            registrationId,
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

  /// 仅从本次登记移出：来源报工、库存和历史均不变，返回任务中心仍待登记。
  void _removeFromThisRegistration(List<_FinishedBatchLine> rows) {
    final removable = rows.where((row) => !row.locked).toList();
    if (_busy || _submitted || !_canRegister || removable.isEmpty) return;
    _grid.removeRows(removable);
    if (!mounted) return;
    setState(() => _removedLineCount += removable.length);
    context.appInfo('已从本次登记移出 ${removable.length} 行；未写入数据库，返回任务中心后仍可继续登记');
  }

  Future<void> _save() async {
    if (_busy || !_canRegister || _submitted) return;
    if (_route.isStockInFirst && !_canStockInFirst) {
      // 路线进页已定，这里只会因权限被收回而退回原流程：说明原因并换成
      // 「先质检后入库」按钮，由用户决定是否继续，不静默换路线提交。
      setState(() => _route = InboundRoute.inspectFirst);
      context.appWarning('当前账号没有「产成品先入库后质检」权限，已切换为「先质检后入库」，请确认后再提交');
      return;
    }
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
    final stockInFirst = _route.isStockInFirst;
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
    // 按报工单分组：同一批次中，同一报工的所选行必须同仓。
    final byReport = <String, List<_FinishedBatchLine>>{};
    for (final row in rows) {
      byReport.putIfAbsent(row.report.reportId, () => []).add(row);
    }
    final mixedWarehouseReports = [
      for (final entry in byReport.entries)
        if (entry.value.map((row) => row.warehouseId).toSet().length > 1)
          entry.value.first.report.reportNo,
    ];
    final rowIssues = <String>[
      if (badQty.isNotEmpty)
        inboundRowIssueMessage(
          badQty,
          '的本次实收与报工数量不一致(先入库后质检须全量一致)',
          action: '请改正，或返回任务中心改走「先质检后入库」按实物点收',
        ),
      if (missingWarehouse.isNotEmpty)
        inboundRowIssueMessage(missingWarehouse, '未选择入库仓库', action: '请补齐后再提交'),
      if (missingPlace.isNotEmpty)
        inboundRowIssueMessage(missingPlace, '未填写库位号', action: '请补齐后再提交'),
      if (placeTooLong.isNotEmpty)
        inboundRowIssueMessage(placeTooLong, '的库位号超过 100 字', action: '请改短后再提交'),
      if (mixedWarehouseReports.isNotEmpty)
        inboundRowIssueMessage(
          mixedWarehouseReports,
          '的明细行选择了不同入库仓库，同一张报工单只能登记到一个仓',
          action: '请统一后再提交',
          unit: '张报工单',
        ),
    ];
    if (rowIssues.isNotEmpty) {
      context.appError(rowIssues.join('\n'));
      return;
    }
    final reportIds = byReport.keys.toList()..sort();
    final confirmed = await UtenDialog.show(
      context,
      title: '${_route.label}(${reportIds.length} 张报工单)',
      confirmLabel: stockInFirst ? '确认登记并先入库' : '确认登记送检',
      content: InboundConfirmPoints([
        if (excludedCount > 0)
          '有 $excludedCount 行未勾选：本次不登记、不写库存，仍留在任务中心待登记，可稍后办理。',
        ...(stockInFirst
            ? const [
                '同一事务逐单登记入库仓库与库位，并把每行实物按库位上架(先入库后质检)，逐行送品质部检验。',
                '品质部到库位检验：合格由系统按本次登记的仓库与库位自动入库，仓库不再确认第二次；不合格不动库存。',
                '本次库位会记住为该仓默认库位，下次登记自动带出。',
              ]
            : const [
                '同一事务逐单登记入库仓库与库位，逐行送品质部检验；同一仓库的行合并成一张品质检查单。',
                '品质放行后仓库再按实物最终点收入库，可短收。',
                '本次库位会记住为该仓默认库位，下次登记自动带出。',
              ]),
      ]),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    ProductionFinishedBatchRegistrationResult result;
    try {
      await saveFormDraftNow();
      result = await runFormDraftSubmission(
        () => ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .saveArrivalRegistrationBatch({
              // 幂等键含路线：换路线重提交是另一个请求，不是重放。
              'idempotencyKey': stockInFirst
                  ? '$_idempotencyKey:prestock'
                  : _idempotencyKey,
              if (stockInFirst) 'stockInBeforeInspection': true,
              if (_remarkController.text.trim().isNotEmpty)
                'remark': _remarkController.text.trim(),
              'reports': [
                for (final reportId in reportIds)
                  {
                    'reportId': reportId,
                    'warehouseId': byReport[reportId]!.first.warehouseId,
                    'items': [
                      for (final row in byReport[reportId]!)
                        {
                          'reportItemId': row.item.reportItemId,
                          'place': row.place.text.trim(),
                          if (stockInFirst)
                            'countedQty': double.parse(
                              row.stockInQty.text.trim(),
                            ),
                        },
                    ],
                  },
              ],
            }),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        context.appError(error.message);
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        context.appError('批量登记失败，请保持当前内容后重试');
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
              '${sheet.sheetNo}（${sheet.warehouseName ?? '—'} ${sheet.itemCount} 行）',
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
    if (widget.reportIds.isEmpty) {
      return Scaffold(
        appBar: const UtenAppBar(title: '批量登记实际入库'),
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
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final canRegister = _canRegister;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '批量登记实际入库',
          // 路线在任务中心已选定：标题下标明本页走哪条，右下只此一个提交按钮。
          subtitle: '路线：${_route.label}',
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
                  title: _saving ? '正在批量登记入库' : '正在撤销本次登记',
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
    final reports = _reports!;
    final registeredReports = reports.where((r) => r.registered).length;
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
            InboundGridIntro(
              sourceSummary:
                  '来自 ${reports.length} 张报工单'
                  '${registeredReports > 0 ? '(其中 $registeredReports 张已登记，只读)' : ''}',
              submitLabel: _route.label,
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_FinishedBatchLine>(
              key: const Key('production-finished-arrival-batch-grid'),
              controller: _grid,
              stickyHeaderPinned: _gridPinned,
              columns: _columns(names, canRegister),
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
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  inboundTotalsBar<_FinishedBatchLine>(
                    key: const Key('production-finished-arrival-batch-totals'),
                    lines: _editableRows,
                    qtyLabel: _route.isStockInFirst ? '本次实收' : '报工数量',
                    qtyOf: (row) => _route.isStockInFirst
                        ? double.tryParse(row.stockInQty.text.trim()) ?? 0
                        : row.item.reportedQty,
                    unitIdOf: (row) => row.item.unitId,
                    unitNameOf: (row) =>
                        row.item.unitName ?? names.unit(row.item.unitId),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    !canRegister
                        ? '当前账号只有查看权限，不能修改仓库或库位。'
                        : _removedLineCount > 0
                        ? '已移出 $_removedLineCount 行(仅本页临时选择)；这些报工行未写入，仍在待登记。'
                              '明细默认全选，提交只含勾选行。'
                        : '入库仓库、库位号行级必填(仓库按货品归属仓或上次所选仓预填，'
                              '库位按该仓记住的库位或货品资料带出，黄框请核对)；'
                              '登记成功后自动记住为该仓默认库位。明细默认全选，提交只含勾选行。',
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
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('production-finished-arrival-batch-remark'),
              controller: _remarkController,
              enabled: canRegister && !_busy && !_submitted,
              maxLength: 500,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '选填；随本批登记留痕',
                counterText: '',
              ),
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
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _busy ? null : () => _leave(changed: _submitted),
          child: Text(canRegister ? '取消' : '返回任务'),
        ),
        // 任务中心点哪条路线进来就只显示哪条路线的提交按钮(与到货批量页一致)。
        if (canRegister && !_submitted)
          InboundRouteSubmitButton(
            route: _route,
            isLoading: _saving,
            onPressed: canSubmit ? _save : null,
            onDisabledTap: _suggestions.loading
                ? () => context.appInfo('正在读取所选仓库的默认库位，请稍候再提交')
                : !hasChecked
                ? () => context.appWarning('请先勾选要登记的明细行(未勾选的行本次不登记)')
                : null,
          ),
      ],
    );
  }

  List<EditableGridColumn<_FinishedBatchLine>> _columns(
    MasterNameService names,
    bool canRegister,
  ) {
    final shared = InboundGridColumns<_FinishedBatchLine>(
      names: names,
      keyPrefix: 'production-finished-arrival-batch',
      lineKeyOf: (row) => row.item.reportItemId,
      goodsCodeOf: (row) => row.item.goodsCode,
      colorNameOf: (row) => row.item.colorName,
      unitNameOf: (row) => row.item.unitName ?? names.unit(row.item.unitId),
    );
    bool editable(_FinishedBatchLine row) =>
        canRegister && !_busy && !_submitted && !row.locked;
    final showReceived =
        _route.isStockInFirst ||
        _grid.rows.any((row) => row.item.countedQty != null);
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
        textOf: (row) => inboundQty(row.item.reportedQty),
      ),
      // 本次实收：先入库后质检 = 登记即承诺合格按此数量自动入库，须与报工数量一致；
      // 已登记行显示当时的实收(没记录显示「—」)。
      if (showReceived)
        shared.receivedQuantity(
          controllerOf: (row) =>
              _route.isStockInFirst && !row.locked ? row.stockInQty : null,
          enabled: editable,
          readOnlyTextOf: (row) => row.item.countedQty == null
              ? '—'
              : inboundQty(row.item.countedQty!),
          headerInfo:
              '先入库后质检：登记即承诺品质合格按此数量自动入库，默认=报工数量且须一致；'
              '数量不符请返回任务中心改走「先质检后入库」，由仓库按实物点收。',
        ),
      shared.unit(),
      shared.warehouse(
        required: canRegister && !_submitted,
        enabled: editable,
        onTap: (row) => _pickWarehouseFor(_writeTargets(row)),
        autofillInfo: '已带入货品归属仓或上次所选仓，请核对本次实物入库仓库',
        lockedBuilder: (context, row) => _registeredWarehouseCell(row, names),
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

  /// 已登记(只读)行：登记仓 + 检查单号，品质未处理时可撤回登记。
  Widget _registeredWarehouseCell(
    _FinishedBatchLine row,
    MasterNameService names,
  ) {
    final report = row.report;
    return Row(
      children: [
        Expanded(
          child: Text(
            '${inboundWarehouseLabel(names, row.warehouseId) ?? report.warehouseName ?? '—'}'
            '${report.sheetNo == null ? '' : ' · ${report.sheetNo}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (report.reversible && _canRegister)
          Tooltip(
            message: '撤回登记(仅品质未处理)：本报工的待检任务取消，报工行回到待登记',
            child: IconButton(
              key: ValueKey(
                'production-finished-arrival-batch-reverse-${report.reportId}',
              ),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.undo_rounded, size: 18),
              onPressed: _busy ? null : () => _reverseRegistered(report),
            ),
          ),
      ],
    );
  }
}

/// 一行汇总登记明细：挂来源报工单 + 共用的入库仓库/库位状态 + 先入库后质检的实收数。
class _FinishedBatchLine extends InboundRegistrationLine {
  _FinishedBatchLine(this.report, this.item)
    : registered = report.registered,
      stockInQty = TextEditingController(text: inboundQty(item.reportedQty)),
      super(
        warehouseId: report.registered ? report.warehouseId : null,
        place: item.place?.trim().isNotEmpty == true
            ? item.place!.trim()
            : item.placeHint?.trim() ?? '',
        placeAutofilled: !report.registered,
        placeSource: item.placeHint?.trim().isNotEmpty == true
            ? InboundPlaceSource.goodsMaster
            : InboundPlaceSource.none,
      );

  final ProductionFinishedArrivalRegistration report;
  final ProductionFinishedArrivalRegistrationItem item;
  final bool registered;

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
