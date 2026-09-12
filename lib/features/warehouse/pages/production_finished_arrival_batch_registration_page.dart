// 多报工单汇总登记成品仓与库位（任务列表多选「批量登记成品仓并送检」落点）。
//
// 2026-09-12 对齐采购到货登记明细表口径：表头不再有「默认成品仓」下拉与
// 「统一设置成品仓 / 统一填写库位」批量按钮——成品仓、库位号行级必填（空时红框），
// **勾选多行后在其中任意一行改仓/写库位 = 批量落到全部选中行**，右键选中集可
// 「批量设置成品仓 / 批量设置库位号」；上次登记仓（服务端 last-warehouse）与本页
// 上次显式选择（账号记忆）预填全部未提交行（黄框待核对）。成品仓选定后逐行批量拉
// 默认库位建议（V431 偏好链，一次请求合并全部行）。提交 = 一个事务逐单登记并生成
// 各自的 FQC 送检（逐报工分批、逐行 FQC，行级 UUID 锚定不变）；V547 起同一成品仓
// 的行合并成一张品质检查单（结果 sheets 每仓一张）。已登记（只读）报工在品质未
// 处理前可撤回登记。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../widgets/arrival_registration_reversal_dialog.dart';
import '../widgets/batch_place_fill_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_finished_inbound_task.dart';
import '../providers/production_finished_arrival_fill_memory.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

class ProductionFinishedArrivalBatchRegistrationPage
    extends ConsumerStatefulWidget {
  const ProductionFinishedArrivalBatchRegistrationPage({
    super.key,
    required this.reportIds,
    this.returnTo,
    this.canRegister,
  });

  final List<String> reportIds;
  final String? returnTo;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限自行推导。
  final bool? canRegister;

  @override
  ConsumerState<ProductionFinishedArrivalBatchRegistrationPage> createState() =>
      _ProductionFinishedArrivalBatchRegistrationPageState();
}

class _ProductionFinishedArrivalBatchRegistrationPageState
    extends ConsumerState<ProductionFinishedArrivalBatchRegistrationPage> {
  final _grid = UtenEditableGridController<_BatchArrivalRegistrationRow>();
  final _scrollController = ScrollController();
  final String _idempotencyKey = 'finished-arrival-batch-${const Uuid().v4()}';

  List<ProductionFinishedArrivalRegistration>? _reports;
  // 整批备注（V542）：落到本批每个登记批次。
  final _remarkController = TextEditingController();
  String? _error;
  String? _validationError;
  bool _loading = false;
  bool _saving = false;
  bool _remembering = false;
  bool _rememberPlaces = true;
  bool _suggestionsLoading = false;
  String? _suggestionError;
  int _suggestionGeneration = 0;
  bool _submitted = false;
  bool _reversing = false;
  int _removedLineCount = 0;

  bool get _canRegister {
    final override = widget.canRegister;
    if (override != null) return override;
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);
  }

  List<_BatchArrivalRegistrationRow> get _editableRows =>
      _grid.rows.where((row) => !row.registered).toList(growable: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _grid.dispose();
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
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final reports = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .batchArrivalRegistrations(widget.reportIds);
      if (!mounted) return;
      final rows = <_BatchArrivalRegistrationRow>[];
      for (final report in reports) {
        for (final item in report.items) {
          rows.add(_BatchArrivalRegistrationRow(report, item));
        }
      }
      _grid.replaceAll(rows);
      // 预填链（都不猜，无历史不预选）：
      //   1. 服务端 last-warehouse = 当前用户上次**成功登记**所用仓（权威）；
      //   2. 本页上次显式选择的仓（账号记忆，登记未完成也记得）兜底。
      // 预填一律黄框提醒核对，用户一动即清标。
      String? warehouseId;
      try {
        final last = await ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .lastArrivalWarehouse();
        final candidate = last?.warehouseId;
        warehouseId =
            WarehouseSelection(
              ref.read(masterNameServiceProvider).warehouseHierarchy,
            ).selectableIds.contains(candidate)
            ? candidate
            : null;
      } catch (_) {
        /* 上次仓拉取失败不阻断，仅不预选 */
      }
      warehouseId ??= () {
        final remembered = ref
            .read(productionFinishedArrivalFillMemoryProvider)
            .warehouseId;
        return WarehouseSelection(
              ref.read(masterNameServiceProvider).warehouseHierarchy,
            ).selectableIds.contains(remembered)
            ? remembered
            : null;
      }();
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _removedLineCount = 0;
        _loading = false;
        _validationError = null;
        _suggestionError = null;
      });
      if (warehouseId?.isNotEmpty == true && _editableRows.isNotEmpty) {
        _applyWarehouseToRows(_editableRows, warehouseId!, autofilled: true);
        await _reloadSuggestions();
      }
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

  /// 把成品仓落到一组行（默认仓切换/批量统一设），并重置未手工改过行的库位。
  void _applyWarehouseToRows(
    List<_BatchArrivalRegistrationRow> rows,
    String warehouseId, {
    bool autofilled = false,
  }) {
    for (final row in rows) {
      row.setWarehouse(warehouseId, autofilled: autofilled);
    }
  }

  /// 按行上出现的每个仓库批量拉一次库位建议（同一仓库的全部行合并成一个请求）。
  Future<void> _reloadSuggestions() async {
    final generation = ++_suggestionGeneration;
    final pending = <String, List<_BatchArrivalRegistrationRow>>{};
    for (final row in _editableRows) {
      final warehouseId = row.warehouseId.value;
      if (warehouseId == null || warehouseId.isEmpty) continue;
      pending.putIfAbsent(warehouseId, () => []).add(row);
    }
    if (pending.isEmpty) {
      for (final row in _editableRows) {
        row.resetSuggestion();
      }
      setState(() => _suggestionsLoading = false);
      return;
    }
    for (final row in _editableRows) {
      row.resetSuggestion();
    }
    setState(() {
      _suggestionsLoading = true;
      _suggestionError = null;
    });
    String? firstError;
    for (final entry in pending.entries) {
      try {
        final reportIds = entry.value
            .map((row) => row.report.reportId)
            .toSet()
            .toList(growable: false);
        final suggestions = await ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .batchPlaceSuggestions(
              reportIds: reportIds,
              warehouseId: entry.key,
            );
        if (!mounted || generation != _suggestionGeneration) return;
        final byReportItemId = {
          for (final suggestion in suggestions)
            suggestion.reportItemId: suggestion,
        };
        for (final row in entry.value) {
          final suggestion = byReportItemId[row.item.reportItemId];
          if (suggestion != null) row.applySuggestion(suggestion);
        }
      } on ApiException catch (error) {
        if (mounted && generation == _suggestionGeneration) {
          firstError ??= error.message;
        }
      } catch (_) {
        if (mounted && generation == _suggestionGeneration) {
          firstError ??= '成品仓默认库位加载失败';
        }
      }
    }
    if (!mounted || generation != _suggestionGeneration) return;
    setState(() {
      _suggestionsLoading = false;
      _suggestionError = firstError;
    });
  }

  /// 一次改动的落值范围（对齐采购批量登记页 `_writeTargets`，2026-09-12）：
  /// **勾选若干行 → 在其中任意一行改仓/写库位 = 批量落到全部选中行**；
  /// 点的行不在选中集里（或压根没勾）就只改这一行。
  List<_BatchArrivalRegistrationRow> _writeTargets(
    _BatchArrivalRegistrationRow row,
  ) {
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 行内/右键批量「设置成品仓」：共享仓库选择面板（主/子级联），返回后落到
  /// 目标行、记住这次选的仓（下次自动带）并刷新库位建议。
  Future<void> _pickWarehouseFor(
    List<_BatchArrivalRegistrationRow> rows,
  ) async {
    final targets = rows.where((row) => !row.registered).toList();
    if (targets.isEmpty) return;
    final names = ref.read(masterNameServiceProvider);
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: names.warehouseHierarchy,
      initialWarehouseId: targets.first.warehouseId.value,
      title: targets.length > 1
          ? '批量设置成品仓（选中 ${targets.length} 行）'
          : '选择成品仓 · ${targets.single.item.goodsName}',
    );
    if (picked == null || !mounted) return;
    _applyWarehouseToRows(targets, picked.id);
    ref
        .read(productionFinishedArrivalFillMemoryProvider.notifier)
        .rememberWarehouse(picked.id);
    if (targets.length > 1) {
      context.appInfo('已把成品仓写到选中的 ${targets.length} 行');
    }
    setState(() {});
    await _reloadSuggestions();
  }

  /// 行内写库位：同样落到 [_writeTargets]——用户边打边能看到整批跟着变，
  /// 与「改一行就是改一批」的心智一致。只改本行时什么都不用做（控件自己持有文本）。
  void _onPlaceChanged(_BatchArrivalRegistrationRow row, String value) {
    final targets = _writeTargets(row);
    if (targets.length > 1) {
      for (final target in targets) {
        if (identical(target, row) || target.registered) continue;
        target.setManualPlace(value);
      }
      setState(() {});
    }
  }

  /// 多选行批量填库位：一次输入应用到全部选中行（同库位场景，如整托同架）。
  Future<void> _batchFillPlace(List<_BatchArrivalRegistrationRow> rows) async {
    final targets = rows.where((row) => !row.registered).toList();
    if (targets.isEmpty) return;
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
        row.setManualPlace(place);
      }
      _validationError = null;
    });
  }

  /// V548 撤回已登记报工（仅品质未处理）：原因弹窗 → 服务端校验 → 重新拉取本页。
  Future<void> _reverseRegistered(
    ProductionFinishedArrivalRegistration report,
  ) async {
    final registrationId = report.registrationId;
    if (registrationId == null || _reversing || _saving || !_canRegister) {
      return;
    }
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
      context.appSuccess('登记已撤回，相关待检任务已取消；报工行重新回到待登记送检');
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

  /// 仅把选择行从这次汇总请求移出；来源报工、fqty、库存和历史均不变。
  /// V469 服务端按行登记，移出行会继续出现在仓库待登记任务中。
  void _removeFromThisRegistration(List<_BatchArrivalRegistrationRow> rows) {
    final removable = rows.where((row) => !row.registered).toList();
    if (_saving || _submitted || !_canRegister || removable.isEmpty) return;
    _grid.removeRows(removable);
    if (!mounted) return;
    setState(() {
      _removedLineCount += removable.length;
      _validationError = null;
    });
    context.appInfo('已从本次汇总登记移出 ${removable.length} 行；这些报工明细仍保持待登记送检');
  }

  String? _rememberPlacesConflict() {
    final grouped = <String, Map<String, List<_BatchArrivalRegistrationRow>>>{};
    for (final row in _editableRows) {
      final place = row.place.text.trim();
      if (place.isEmpty) continue;
      final warehouseId = row.warehouseId.value;
      if (warehouseId == null || warehouseId.isEmpty) continue;
      final key = '$warehouseId|${row.item.goodsId}|${row.item.colorId ?? ''}';
      grouped.putIfAbsent(key, () => {}).putIfAbsent(place, () => []).add(row);
    }
    for (final entry in grouped.entries) {
      if (entry.value.length <= 1) continue;
      final sample = entry.value.values.first.first;
      final candidates = entry.value.entries
          .map((candidate) => '${candidate.key}(${candidate.value.length}行)')
          .join(' / ');
      return '货品 ${sample.item.goodsCode} ${sample.item.goodsName} '
          '在同一仓库同一颜色维度填写了不同库位：$candidates。'
          '请统一库位，或关闭“同时记住”为仅保存本次登记快照。';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || _remembering || !_canRegister || _submitted) return;
    if (_suggestionsLoading) {
      context.appInfo('正在读取成品仓默认库位，请稍候再提交');
      return;
    }
    if (_rememberPlaces && _suggestionError != null) {
      const message = '成品仓默认库位加载失败；请先重试，或关闭“同时记住”后仅保存本次登记';
      setState(() => _validationError = message);
      context.appError(message);
      return;
    }
    final rows = _editableRows;
    if (rows.isEmpty) {
      setState(() => _validationError = '没有待登记的成品明细');
      context.appError('没有待登记的成品明细');
      return;
    }
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final warehouseId = row.warehouseId.value;
      if (warehouseId == null || warehouseId.isEmpty) {
        final message = '第 ${index + 1} 行（${row.report.reportNo}）必须选择成品仓';
        setState(() => _validationError = message);
        context.appError(message);
        return;
      }
      final place = row.place.text.trim();
      if (place.isEmpty || place.length > 100) {
        final message =
            '第 ${index + 1} 行（${row.report.reportNo}）库位号必填且不超过 100 字';
        setState(() => _validationError = message);
        context.appError(message);
        return;
      }
    }
    // 按报工单分组：同一批次中，同一报工的所选行必须同仓。
    final byReport = <String, List<_BatchArrivalRegistrationRow>>{};
    for (final row in rows) {
      byReport.putIfAbsent(row.report.reportId, () => []).add(row);
    }
    for (final entry in byReport.entries) {
      final warehouses = entry.value
          .map((row) => row.warehouseId.value)
          .toSet();
      if (warehouses.length > 1) {
        final message =
            '报工单 ${entry.value.first.report.reportNo} 的明细行选择了不同成品仓；'
            '同一张报工单只能登记到一个仓，请统一';
        setState(() => _validationError = message);
        context.appError(message);
        return;
      }
    }
    if (_rememberPlaces) {
      final conflict = _rememberPlacesConflict();
      if (conflict != null) {
        setState(() => _validationError = conflict);
        context.appError(conflict);
        return;
      }
    }

    final reportIds = byReport.keys.toList()..sort();
    // 2026-09-12：原一整段连排确认文案把弹窗顶得巨长，改「一句结论 + 短要点」，
    // 高度与宽度由 UtenDialog 统一兜（限宽 460 / 限高 60% 屏高 / 超出自滚）。
    final confirmed = await UtenDialog.show(
      context,
      title: '汇总登记并送检（${reportIds.length} 张报工单）',
      confirmLabel: '确认登记并送检',
      content: _confirmPoints(Theme.of(context), const [
        '同一事务逐单登记成品仓与库位，逐行送品质部检查。',
        '同一成品仓的行合并成一张品质检查单；品质放行后再按实物最终点收。',
        '已移出明细仍留在仓库待登记，不产生 FQC 或库存事实。',
        '任一报工状态、权限、品质或并发校验失败，整批回滚。',
      ]),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _saving = true;
      _validationError = null;
    });
    ProductionFinishedBatchRegistrationResult result;
    try {
      result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .saveArrivalRegistrationBatch({
            'idempotencyKey': _idempotencyKey,
            if (_remarkController.text.trim().isNotEmpty)
              'remark': _remarkController.text.trim(),
            'reports': [
              for (final reportId in reportIds)
                {
                  'reportId': reportId,
                  'warehouseId': byReport[reportId]!.first.warehouseId.value,
                  'items': [
                    for (final row in byReport[reportId]!)
                      {
                        'reportItemId': row.item.reportItemId,
                        'place': row.place.text.trim(),
                      },
                  ],
                },
            ],
          });
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
      if (mounted) setState(() => _saving = false);
      return;
    } catch (_) {
      if (mounted) context.appError('汇总登记送检失败，请稍后重试');
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _submitted = true;
      _suggestionsLoading = false;
      _suggestionError = null;
    });
    invalidateWarehouseTaskCounts(ref);
    _suggestionGeneration++;

    if (!_rememberPlaces) {
      context.appSuccess(
        '已汇总登记 ${result.registeredCount} 张报工单的成品仓和库位，'
        '已送品质部检查${_sheetSummary(result)}',
      );
      _leave(changed: true);
      return;
    }
    final registrationIds = result.reports
        .map((report) => report.registrationId?.trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (registrationIds.length != result.reports.length ||
        registrationIds.isEmpty) {
      _rememberFailed('服务器未返回完整登记批次 UUID；登记已完成，请返回任务中心核对');
      return;
    }
    await _rememberRegisteredPlaces(
      registrationIds,
      result.registeredCount,
      sheetSummary: _sheetSummary(result),
    );
  }

  /// 确认弹窗正文：一行一个要点（· 前缀 + 悬挂缩进），与采购批量登记页同款。
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

  /// V547：同仓合并成一张品质检查单；成功提示带单号，便于品质部对单。
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

  Future<void> _rememberRegisteredPlaces(
    List<String> registrationIds,
    int registeredCount, {
    String sheetSummary = '',
  }) async {
    if (_remembering) return;
    setState(() {
      _remembering = true;
      _suggestionError = null;
    });
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .rememberPlacesBatch(registrationIds);
      if (!mounted) return;
      setState(() => _remembering = false);
      final suffix = result.warnings.isEmpty
          ? ''
          : '；${result.warnings.take(3).join('；')}';
      if (result.ambiguous > 0 || result.warnings.isNotEmpty) {
        context.appWarning(
          '汇总登记送检成功；${result.ambiguous} 组默认库位存在歧义，'
          '已记住 ${result.remembered} 组，${result.unchanged} 组未变化$suffix',
          force: true,
        );
      } else {
        context.appSuccess(
          '汇总登记送检成功（$registeredCount 张）；已记住 ${result.remembered} 组'
          '默认库位，${result.unchanged} 组保持不变$sheetSummary',
          force: true,
        );
      }
      _leave(changed: true);
    } on ApiException catch (error) {
      _rememberFailed(error.message);
    } catch (_) {
      _rememberFailed('网络异常，请重试记住默认库位');
    }
  }

  void _rememberFailed(String message) {
    if (!mounted) return;
    setState(() => _remembering = false);
    _suggestionError = null;
    context.appWarning('登记已完成，但默认库位尚未记住：$message', force: true);
    _leave(changed: true);
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
        appBar: const UtenAppBar(title: '批量登记成品仓与库位'),
        body: UtenEmpty.error(
          message: '没有选择待登记的报工单',
          description: '请返回任务中心重新选择任务。',
        ),
      );
    }
    // 建立权限快照订阅；事件处理仍通过 _canRegister 的 read 读取最新值，
    // 授权刷新/撤销则由这里触发整页重建并即时收起写操作。
    if (widget.canRegister == null) {
      ref.watch(isSuperAdminProvider);
      ref.watch(currentPermissionsProvider);
    }
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '批量登记成品仓与库位',
        leading: UtenBackButton(onPressed: () => _leave(changed: _submitted)),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _reports == null
            ? UtenEmpty.error(
                message: _error ?? '没有找到可登记的成品报工任务',
                description: '任务可能已被其他仓库人员处理，请返回任务中心刷新。',
                actionLabel: '重新加载',
                onAction: _load,
              )
            : UtenContentContainer(
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    children: [
                      _buildBanner(theme),
                      const SizedBox(height: UtenSpacing.s12),
                      _buildHeaderCard(theme),
                      const SizedBox(height: UtenSpacing.s12),
                      if (_canRegister) ...[
                        _buildRememberSwitch(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (_suggestionsLoading || _suggestionError != null) ...[
                        _buildSuggestionStatus(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (_validationError != null) ...[
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _validationError!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                      ],
                      // 「成品明细 (N)」标题 2026-09-11 撤除（全站同改：明细表上方不再重复报行数）。
                      // 只保留「来自几张报工单」——这是跨单据聚合信息，看表体数不出来。
                      Text(
                        '来自 '
                        '${_grid.rows.map((row) => row.report.reportId).toSet().length}'
                        ' 张报工单',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      UtenEditableGrid<_BatchArrivalRegistrationRow>(
                        key: const Key(
                          'production-finished-arrival-batch-grid',
                        ),
                        controller: _grid,
                        columns: _columns(names),
                        createBlankRow: () =>
                            throw UnsupportedError('明细由所选报工单固定带入'),
                        showAddRow: false,
                        showRowDelete: false,
                        selectable: _canRegister && !_submitted,
                        selectionEnabled:
                            !_saving && !_remembering && !_submitted,
                        canSelectRow: (row) => !row.registered && !_submitted,
                        onRemoveRows: _canRegister && !_submitted
                            ? _removeFromThisRegistration
                            : null,
                        removeRowsActionLabel: '移出本次登记',
                        removeRowsDialogTitle: '移出本次登记',
                        removeRowsConfirmLabel: '确认移出',
                        removeRowsMessageBuilder: (count) =>
                            '确认从本次汇总登记移出选中的 $count 行？'
                            '报工事实不会删除，也不会产生 FQC、入库或库存事实；'
                            '返回任务中心后仍保持待登记送检。',
                        // 2026-09-12 表头上方常驻按钮全撤（用户口径，与采购批量
                        // 登记页一致）：全选走表头复选框，「移出本次登记」搬进行
                        // 右键菜单，批量设仓/填库位改成「勾选多行后在任意一行
                        // 改仓/写库位即整批落值」+ 右键菜单批量动作。
                        showSelectAllToggle: false,
                        showRemoveRowsAction: false,
                        rowMenuExtraBuilder:
                            _canRegister && !_saving && !_submitted
                            ? (context, selected) => [
                                UtenMenuItem(
                                  label: '批量设置成品仓 (${selected.length})',
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
                        footer: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Text(
                            _removedLineCount > 0
                                ? '已移出 $_removedLineCount 行（仅本次）；这些行仍在待登记送检，'
                                      '本次只提交表内剩余行。'
                                : _canRegister
                                ? _rememberPlaces
                                      ? '将按所选成品仓记住默认库位；不改变历史登记和库存事实。'
                                      : '仅保存本次到货库位快照，不更新以后默认建议。'
                                : '当前账号只有查看权限，不能修改仓库或库位。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s24),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _reports == null
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.large,
                      onPressed: _saving || _remembering
                          ? null
                          : () => _leave(changed: _submitted),
                      child: Text(_canRegister ? '取消' : '返回任务'),
                    ),
                    if (_canRegister && !_submitted) ...[
                      const SizedBox(width: UtenSpacing.s12),
                      UtenButton(
                        key: const Key(
                          'production-finished-arrival-batch-submit',
                        ),
                        size: UtenButtonSize.large,
                        icon: Icons.fact_check_outlined,
                        isLoading: _saving,
                        onPressed:
                            _saving || _suggestionsLoading || _grid.isEmpty
                            ? null
                            : _save,
                        onDisabledTap: _suggestionsLoading
                            ? () => context.appInfo('正在读取默认库位，请稍候再提交')
                            : null,
                        child: const Text('登记并送检'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildBanner(ThemeData theme) => Card(
    color: theme.colorScheme.tertiaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warehouse_outlined,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '多张报工单汇总登记（第 1 步：仓库登记到货位置）',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '成品仓、库位号逐行必填；上次登记仓自动预填（黄框待核对）。'
                  '勾选多行后在任意一行改仓/写库位即批量落值，也可右键批量设置。'
                  '提交后每张报工单各生成一份品质送检；品质放行后再进行最终点收。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildHeaderCard(ThemeData theme) {
    final reports = _reports!;
    final registeredReports = reports.where((r) => r.registered).length;
    final receiverName = reports.isNotEmpty ? reports.first.receiverName : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [
            _readOnlyField('报工单数', '${reports.length} 张'),
            _readOnlyField(
              '登记进度',
              registeredReports > 0
                  ? '$registeredReports 张已登记（只读），'
                        '${reports.length - registeredReports} 张待登记'
                  : '全部待登记',
            ),
            _readOnlyField(
              '报工日期',
              ChinaDateTime.formatDate(
                reports
                    .map((r) => r.reportDate)
                    .reduce((a, b) => a.isBefore(b) ? a : b),
              ),
            ),
            _readOnlyField('收货人', receiverName ?? '—'),
            TextFormField(
              key: const Key('production-finished-arrival-batch-remark'),
              errorBuilder: utenTextFieldErrorBuilder,
              controller: _remarkController,
              enabled: _canRegister && !_saving && !_submitted,
              maxLength: 500,
              decoration: const UtenInputDecoration(
                InputDecoration(
                  labelText: '备注',
                  hintText: '选填；随本批送检登记留痕',
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRememberSwitch(ThemeData theme) {
    return Card(
      child: SwitchListTile(
        key: const Key('production-finished-arrival-batch-remember-places'),
        value: _rememberPlaces,
        onChanged: _saving || _remembering || _submitted
            ? null
            : (value) => setState(() {
                _rememberPlaces = value;
                _validationError = null;
              }),
        title: const Text('同时记住为该成品仓默认库位'),
        subtitle: const Text('默认开启，可随时取消；只影响以后登记建议，不修改历史登记或库存。'),
        secondary: Icon(
          Icons.bookmark_add_outlined,
          color: theme.colorScheme.primary,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s4,
        ),
      ),
    );
  }

  Widget _buildSuggestionStatus(ThemeData theme) {
    final loading = _suggestionsLoading;
    return Card(
      color: loading
          ? theme.colorScheme.secondaryContainer
          : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.error_outline_rounded,
                color: theme.colorScheme.onErrorContainer,
              ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                loading
                    ? '正在读取成品仓默认库位，完成前暂不能提交。'
                    : '库位建议加载失败：$_suggestionError',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: loading
                      ? theme.colorScheme.onSecondaryContainer
                      : theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            if (!loading) ...[
              const SizedBox(width: UtenSpacing.s8),
              UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _reloadSuggestions,
                child: const Text('重试'),
              ),
            ],
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

  /// 表头筛选桶标签：空白/主档未解析的「—」不建桶（返回 null → 计入「未填」），
  /// 避免出现空串桶或一堆「—」桶。
  String? _bucketOrNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == '—') return null;
    return trimmed;
  }

  List<EditableGridColumn<_BatchArrivalRegistrationRow>> _columns(
    MasterNameService names,
  ) => [
    // 2026-09-11 全站表头快速筛选补齐：批量登记一次可拉进几十张报工单的上百
    // 行，报工单/货品/颜色/单位/成品仓是最常用的收敛口径（视图级过滤，不动
    // 行数据与勾选；空值不建桶）。
    EditableGridColumn(
      key: 'reportNo',
      label: '报工单',
      width: 150,
      filterValueOf: (row) => _bucketOrNull(row.report.reportNo),
      textOf: (row) => row.report.reportNo,
      cellBuilder: (context, row) => Text(row.report.reportNo),
    ),
    EditableGridColumn(
      key: 'goodsCode',
      label: '物料编码',
      width: 120,
      textOf: (row) => row.item.goodsCode,
      cellBuilder: (context, row) => Text(row.item.goodsCode),
    ),
    EditableGridColumn(
      key: 'goodsName',
      label: '货品名称',
      width: 200,
      filterValueOf: (row) => _bucketOrNull(row.item.goodsName),
      textOf: (row) => row.item.goodsName,
      cellBuilder: (context, row) => Text(row.item.goodsName),
    ),
    EditableGridColumn(
      key: 'color',
      label: '颜色',
      width: 90,
      filterValueOf: (row) =>
          _bucketOrNull(row.item.colorName ?? names.color(row.item.colorId)),
      textOf: (row) => row.item.colorName ?? names.color(row.item.colorId),
      cellBuilder: (context, row) =>
          Text(row.item.colorName ?? names.color(row.item.colorId)),
    ),
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 70,
      filterValueOf: (row) =>
          _bucketOrNull(row.item.unitName ?? names.unit(row.item.unitId)),
      textOf: (row) => row.item.unitName ?? names.unit(row.item.unitId),
      cellBuilder: (context, row) =>
          Text(row.item.unitName ?? names.unit(row.item.unitId)),
    ),
    EditableGridColumn(
      key: 'qty',
      label: '报工数量',
      width: 100,
      numeric: true,
      textOf: (row) => _quantity(row.item.reportedQty),
      cellBuilder: (context, row) =>
          Text(_quantity(row.item.reportedQty), textAlign: TextAlign.right),
    ),
    EditableGridColumn(
      key: 'warehouse',
      label: '成品仓',
      width: 160,
      required: _canRegister && !_submitted,
      filterValueOf: (row) => row.warehouseId.value == null
          ? null
          : _bucketOrNull(names.warehouse(row.warehouseId.value!)),
      textOf: (row) => row.warehouseId.value == null
          ? ''
          : names.warehouse(row.warehouseId.value!),
      listenableOf: (row) => row.warehouseId,
      cellBuilder: (context, row) => _buildWarehouseCell(context, row, names),
    ),
    EditableGridColumn(
      key: 'place',
      label: '库位号',
      width: 230,
      required: _canRegister && !_submitted,
      // 通用说明收进列头 ⓘ（2026-09-12 全站口径）：格内不再逐行挂 ⓘ 图标
      //（把输入框挤窄），行级只剩黄框（预填待核对）与红框（必填为空）两种状态。
      headerInfo:
          '必填，不超过 100 字。选择成品仓后按「该仓默认 → 最近登记：'
          '同仓同货品 → 货品主档通用建议」自动匹配；黄框 = 已带入默认值，'
          '请核对本次实物存放位置，可直接修改。',
      textOf: (row) => row.place.text,
      listenableOf: (row) => row.place,
      cellBuilder: (context, row) => _buildPlaceCell(context, row),
    ),
  ];

  /// 成品仓格：与采购批量登记页「入库仓库」格同款——不自带 border/contentPadding/
  /// 小字/双行，圆角、内边距、字号吃 UtenEditableGrid 行级主题（与库位号格等高）；
  /// 未选红框（必填）、预填黄框；勾选多行时点击改仓 = 整批落值。
  /// 已登记（只读）行：显示登记仓 + 检查单号，品质未处理时可撤回登记。
  Widget _buildWarehouseCell(
    BuildContext context,
    _BatchArrivalRegistrationRow row,
    MasterNameService names,
  ) {
    final theme = Theme.of(context);
    final warehouseId = row.warehouseId.value;
    final name = warehouseId == null ? null : names.warehouse(warehouseId);
    final enabled = _canRegister && !_saving && !_submitted && !row.registered;
    if (row.registered) {
      final report = row.report;
      return Row(
        children: [
          Expanded(
            child: Text(
              '${name ?? report.warehouseName ?? '—'}'
              '${report.sheetNo == null ? '' : ' · ${report.sheetNo}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
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
                onPressed: _reversing || _saving
                    ? null
                    : () => _reverseRegistered(report),
              ),
            ),
        ],
      );
    }
    return InkWell(
      onTap: enabled ? () => _pickWarehouseFor(_writeTargets(row)) : null,
      borderRadius: BorderRadius.circular(UtenRadius.control),
      child: InputDecorator(
        decoration: applyAutofillHint(
          UtenInputDecoration(
            InputDecoration(
              isDense: true,
              enabledBorder: name == null && enabled
                  ? requiredEmptyBorder(theme)
                  : null,
            ),
            info: row.warehouseAutofilled ? '已带入上次登记成品仓，请核对本次实际存放仓库' : null,
          ),
          theme,
          autofilled:
              !row.registered && name != null && row.warehouseAutofilled,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name ?? '必选 · 点击选择',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: name == null && enabled
                    ? theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      )
                    : null,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceCell(
    BuildContext context,
    _BatchArrivalRegistrationRow row,
  ) {
    return ValueListenableBuilder<_BatchPlaceSource>(
      valueListenable: row.placeSource,
      builder: (context, source, _) {
        final warehouseSelected = row.warehouseId.value?.isNotEmpty == true;
        final matching = warehouseSelected && _suggestionsLoading;
        final editable =
            _canRegister &&
            !_saving &&
            !_submitted &&
            !row.registered &&
            warehouseSelected &&
            !matching;
        final field = Semantics(
          textField: true,
          label: '${row.item.goodsName} 库位号，${source.label}',
          child: TextField(
            key: ValueKey(
              'production-finished-arrival-batch-place-${row.item.reportItemId}',
            ),
            controller: row.place,
            enabled: editable,
            inputFormatters: [LengthLimitingTextInputFormatter(100)],
            decoration: applyAutofillHint(
              UtenInputDecoration(
                InputDecoration(
                  isDense: true,
                  hintText: !warehouseSelected
                      ? '请先选择成品仓'
                      : matching
                      ? '正在匹配默认库位'
                      : '必填',
                ),
              ),
              Theme.of(context),
              autofilled:
                  editable &&
                  source.isLearned &&
                  row.place.text.trim().isNotEmpty,
            ),
            // 勾选多行时改本行 = 批量写到全部选中行；只改本行时同步无事可做。
            onChanged: editable
                ? (value) {
                    _onPlaceChanged(row, value);
                    if (_validationError != null) {
                      setState(() => _validationError = null);
                    }
                  }
                : null,
          ),
        );
        if (!editable) return field;
        return RequiredCellFrame(
          listenable: row.place,
          isEmpty: () => row.place.text.trim().isEmpty,
          child: field,
        );
      },
    );
  }

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class _BatchArrivalRegistrationRow extends EditableGridRow {
  _BatchArrivalRegistrationRow(this.report, this.item)
    : registered = report.registered,
      place = TextEditingController(
        text: item.place?.trim().isNotEmpty == true
            ? item.place
            : item.placeHint ?? '',
      ),
      warehouseId = ValueNotifier<String?>(report.warehouseId),
      placeSource = ValueNotifier<_BatchPlaceSource>(
        report.registered || item.place?.trim().isNotEmpty == true
            ? _BatchPlaceSource.snapshot
            : item.placeHint?.trim().isNotEmpty == true
            ? _BatchPlaceSource.goodsMaster
            : _BatchPlaceSource.none,
      ) {
    warehouseAutofilled = !registered && report.warehouseId?.isNotEmpty == true;
    _lastPlaceText = place.text;
    place.addListener(_handlePlaceChanged);
  }

  final ProductionFinishedArrivalRegistration report;
  final ProductionFinishedArrivalRegistrationItem item;
  final bool registered;
  final TextEditingController place;
  final ValueNotifier<String?> warehouseId;
  bool warehouseAutofilled = false;
  final ValueNotifier<_BatchPlaceSource> placeSource;
  bool _applyingSuggestion = false;
  late String _lastPlaceText;

  void _handlePlaceChanged() {
    final textChanged = place.text != _lastPlaceText;
    _lastPlaceText = place.text;
    if (!textChanged) return;
    if (_applyingSuggestion || placeSource.value == _BatchPlaceSource.manual) {
      return;
    }
    placeSource.value = _BatchPlaceSource.manual;
  }

  /// 行级改仓：清掉未手工改过行的库位（等新仓的建议）。
  void setWarehouse(String? value, {bool autofilled = false}) {
    if (registered) return;
    warehouseAutofilled = autofilled && value?.isNotEmpty == true;
    if (warehouseId.value == value) return;
    warehouseId.value = value;
    resetSuggestion(clear: value == null);
  }

  void applySuggestion(ProductionFinishedPlaceSuggestion suggestion) {
    if (registered || placeSource.value == _BatchPlaceSource.manual) return;
    final candidate = suggestion.place?.trim() ?? '';
    if (candidate.isEmpty) {
      resetSuggestion();
      return;
    }
    _applyingSuggestion = true;
    place.value = TextEditingValue(
      text: candidate,
      selection: TextSelection.collapsed(offset: candidate.length),
    );
    _applyingSuggestion = false;
    placeSource.value = switch (suggestion.source) {
      ProductionFinishedPlaceSuggestionSource.warehousePreference =>
        _BatchPlaceSource.warehousePreference,
      ProductionFinishedPlaceSuggestionSource.registrationHistory =>
        _BatchPlaceSource.registrationHistory,
      ProductionFinishedPlaceSuggestionSource.goodsMaster =>
        _BatchPlaceSource.goodsMaster,
      ProductionFinishedPlaceSuggestionSource.none => _BatchPlaceSource.none,
    };
  }

  /// 批量统一填写：记为手工输入，后续建议不再覆盖。
  void setManualPlace(String value) {
    if (registered) return;
    _applyingSuggestion = true;
    place.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _applyingSuggestion = false;
    _lastPlaceText = value;
    placeSource.value = _BatchPlaceSource.manual;
  }

  /// 回到货品主档建议（换仓/重新匹配时未手工改过行的初值）。
  void resetSuggestion({bool clear = false}) {
    if (registered || placeSource.value == _BatchPlaceSource.manual) return;
    final fallback = clear ? '' : item.placeHint?.trim() ?? '';
    _applyingSuggestion = true;
    place.value = TextEditingValue(
      text: fallback,
      selection: TextSelection.collapsed(offset: fallback.length),
    );
    _applyingSuggestion = false;
    placeSource.value = fallback.isEmpty
        ? _BatchPlaceSource.none
        : _BatchPlaceSource.goodsMaster;
  }

  @override
  void dispose() {
    place.removeListener(_handlePlaceChanged);
    place.dispose();
    warehouseId.dispose();
    placeSource.dispose();
    super.dispose();
  }
}

enum _BatchPlaceSource {
  snapshot,
  warehousePreference,
  registrationHistory,
  goodsMaster,
  none,
  manual;

  bool get isLearned =>
      this == warehousePreference ||
      this == registrationHistory ||
      this == goodsMaster;

  String get label => switch (this) {
    snapshot => '本次登记快照',
    warehousePreference => '该仓默认',
    registrationHistory => '最近登记：同仓同货品',
    goodsMaster => '货品主档通用建议',
    none => '暂无默认',
    manual => '手工输入',
  };
}
