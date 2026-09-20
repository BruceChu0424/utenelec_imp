import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../models/production_finished_inbound_task.dart';
import '../providers/production_finished_arrival_fill_memory.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';
import '../widgets/arrival_registration_reversal_dialog.dart';
import '../widgets/batch_place_fill_dialog.dart';

/// 批量校验提示：把同一类违规的**全部**行汇总成一句话。
///
/// 条目多时只列前 8 条再折成「等 N 行」——刷屏的提示和只报第一行一样没法用。
/// [unit] 供货品这类非行维度的汇总复用同一句式。
String _rowIssueMessage(
  List<String> rowLabels,
  String issue, {
  required String action,
  String unit = '行',
}) {
  const shownMax = 8;
  final shown = rowLabels.take(shownMax).join('、');
  final more = rowLabels.length > shownMax ? '等 ${rowLabels.length} $unit' : '';
  return '以下 ${rowLabels.length} $unit$issue，$action：$shown$more';
}

/// 生产报工审核后的仓库到货登记（「登记成品」）。
///
/// 2026-09-12 对齐采购到货登记（批量页同日同改）：表头不再有「默认成品仓」下拉与
/// 「统一设置成品仓 / 统一填写库位」按钮——成品仓、库位号行级必填（空时红框），
/// **勾选多行后在其中任意一行改仓/写库位 = 批量落到全部选中行**，右键选中集可
/// 「批量设置成品仓 / 批量设置库位号」；行级预填优先级 = 货品主档默认仓 >
/// 上次登记仓（服务端 last-warehouse）> 本页上次显式选择（账号记忆），均为黄框
/// 待核对。提交按行仓分组，一个仓一个登记批次（V469 一批一仓），每个批次同事务
/// 形成一张品质检查单（V547）；部分仓失败停在本页，已成功仓不重复提交。
/// 已登记批次在品质未处理前可「撤回登记」（V548），报工行回到待登记。
/// 数量来自已审核报工，只读；本页不写库存、不增加 iqty。
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
    extends ConsumerState<ProductionFinishedArrivalRegistrationPage> {
  final _grid =
      UtenEditableGridController<_FinishedArrivalRegistrationGridRow>();
  final _scrollController = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);
  // 登记备注（V542）：随每个登记批次提交并留痕。
  final _remarkController = TextEditingController();
  // 页面级幂等键；按仓提交时派生 `页面键:仓库UUID`，重试不重复登记已成功仓。
  final String _idempotencyKey = const Uuid().v4();

  ProductionFinishedArrivalRegistration? _detail;
  String? _error;
  String? _validationError;
  bool _loading = false;
  bool _saving = false;
  bool _remembering = false;
  bool _reversing = false;
  bool _rememberPlaces = true;
  bool _suggestionsLoading = false;
  bool _registrationCompletedThisSession = false;
  int _removedLineCount = 0;
  int _suggestionGeneration = 0;
  String? _suggestionError;
  String? _rememberError;

  /// 本会话已成功登记的仓 → 登记结果（部分失败重试时跳过）。
  final Map<String, ProductionFinishedArrivalRegistration> _registrations = {};
  final Set<String> _rememberedRegistrationIds = <String>{};

  bool get _hasRegisterPermission {
    final override = widget.canRegister;
    if (override != null) return override;
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);
  }

  bool get _canRegister =>
      _hasRegisterPermission && !(_detail?.registered ?? false);

  /// 先入库后质检(V597)：底部两个按钮二选一——「先入库后质检」= 登记的同时承诺
  /// 「品质合格按本次登记的成品仓 + 库位自动点收入库」，仓库不再点第二次(实收恒等于
  /// 报工量)；「登记并送检」= 原流程。按钮只对持有独立权限的账号显示，服务端同样兜底。
  bool _stockInBeforeInspection = false;

  bool get _canStockInBeforeInspection {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionFinishedInBeforeInspection);
  }

  List<_FinishedArrivalRegistrationGridRow> get _editableRows =>
      _grid.rows.where((row) => !row.registered).toList(growable: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
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
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final repo = ref.read(productionFinishedInboundTaskRepositoryProvider);
      final detail = await repo.arrivalRegistration(widget.reportId);
      if (!mounted) return;
      final selection = WarehouseSelection(
        ref.read(masterNameServiceProvider).warehouseHierarchy,
      );
      // 页面级默认仓预填链（都不猜，无历史不预选）：
      //   1. 服务端 last-warehouse = 上次**成功登记**所用仓（权威）；
      //   2. 本页上次显式选择的仓（账号记忆，登记未完成也记得）兜底。
      String? defaultWarehouseId;
      if (!detail.registered) {
        final last = await repo.lastArrivalWarehouse();
        if (!mounted) return;
        final candidate = last?.warehouseId;
        defaultWarehouseId = selection.selectableIds.contains(candidate)
            ? candidate
            : null;
        defaultWarehouseId ??= () {
          final remembered = ref
              .read(productionFinishedArrivalFillMemoryProvider)
              .warehouseId;
          return selection.selectableIds.contains(remembered)
              ? remembered
              : null;
        }();
      }
      _grid.replaceAll([
        for (final item in detail.items)
          _FinishedArrivalRegistrationGridRow(
            item,
            registered: detail.registered,
          ),
      ]);
      // 进页默认全选（2026-09-18，与到货登记页同款）：勾选=本次要登记送检的行，
      // 右下两个提交按钮只认勾选行；默认全选让「进来直接提交」行为不变。
      _grid.setSelected(
        _grid.rows.where((row) => !row.registered).toList(growable: false),
        true,
      );
      if (detail.registered) {
        for (final row in _grid.rows) {
          row.warehouseId.value = detail.warehouseId;
        }
      } else {
        for (final row in _grid.rows) {
          // 行级预填优先级：货品主档默认仓 > 页面默认仓；均为黄框待核对。
          final rowLast = row.item.lastWarehouseId;
          if (rowLast != null && selection.selectableIds.contains(rowLast)) {
            row.setWarehouse(
              rowLast,
              source: _FinishedArrivalWarehouseSource.goodsMaster,
            );
          } else if (defaultWarehouseId != null) {
            row.setWarehouse(
              defaultWarehouseId,
              source: _FinishedArrivalWarehouseSource.pageDefault,
            );
          }
        }
      }
      setState(() {
        _detail = detail;
        _registrations.clear();
        _rememberedRegistrationIds.clear();
        _removedLineCount = 0;
        _loading = false;
        _validationError = null;
        _suggestionError = null;
        _rememberError = null;
      });
      if (!detail.registered) {
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
        _error = '成品到货登记信息加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 按行上出现的每个仓库拉一次库位建议（同仓行合并一个请求）。
  /// 请求版本门禁：换仓/重试后旧响应作废；迟到响应只落到仍属该仓且未手工改过的行。
  Future<void> _reloadSuggestions() async {
    final generation = ++_suggestionGeneration;
    final pending = <String, List<_FinishedArrivalRegistrationGridRow>>{};
    for (final row in _editableRows) {
      final warehouseId = row.warehouseId.value;
      if (warehouseId == null || warehouseId.isEmpty) continue;
      pending.putIfAbsent(warehouseId, () => []).add(row);
    }
    for (final row in _editableRows) {
      // 未选仓的行不解析任何建议（含货品主档 fallback）；选仓后才回到建议链。
      if (row.warehouseId.value?.isNotEmpty == true) {
        row.resetAutomaticSuggestion();
      } else {
        row.clearAutomaticSuggestion();
      }
    }
    if (pending.isEmpty) {
      setState(() {
        _suggestionsLoading = false;
        _suggestionError = null;
      });
      return;
    }
    setState(() {
      _suggestionsLoading = true;
      _suggestionError = null;
    });
    String? firstError;
    for (final entry in pending.entries) {
      try {
        final suggestions = await ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .placeSuggestions(widget.reportId, warehouseId: entry.key);
        if (!mounted || generation != _suggestionGeneration) return;
        final byReportItemId = {
          for (final suggestion in suggestions)
            suggestion.reportItemId: suggestion,
        };
        for (final row in entry.value) {
          if (row.warehouseId.value != entry.key) continue;
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

  /// 本页删除是“暂不纳入本批送检”，不删除已审核报工明细。
  /// V469 后服务端只登记提交的 UUID；移出行保持仓库待登记且不产生 FQC/库存事实。
  void _removeFromThisRegistration(
    List<_FinishedArrivalRegistrationGridRow> rows,
  ) {
    final removable = rows.where((row) => !row.registered).toList();
    if (_saving || !_canRegister || removable.isEmpty) return;
    _grid.removeRows(removable);
    if (!mounted) return;
    setState(() {
      _removedLineCount += removable.length;
      _validationError = null;
    });
    context.appInfo('已从本批送检移出 ${removable.length} 行；报工事实未删除，仍留在待登记送检');
  }

  /// 一次改动的落值范围（对齐采购登记页，2026-09-12）：**勾选若干行 → 在其中
  /// 任意一行改仓/写库位 = 批量落到全部选中行**；点的行不在选中集里（或压根
  /// 没勾）就只改这一行。
  List<_FinishedArrivalRegistrationGridRow> _writeTargets(
    _FinishedArrivalRegistrationGridRow row,
  ) {
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 行内/右键批量「设置成品仓」：共享仓库选择面板，返回后落到目标行、记住这次
  /// 选的仓（下次自动带）并刷新库位建议。
  Future<void> _pickWarehouseFor(
    List<_FinishedArrivalRegistrationGridRow> rows,
  ) async {
    if (rows.isEmpty) return;
    final names = ref.read(masterNameServiceProvider);
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: names.warehouseHierarchy,
      initialWarehouseId: rows.first.warehouseId.value,
      title: rows.length > 1
          ? '批量设置成品仓（选中 ${rows.length} 行）'
          : '选择成品仓 · ${rows.single.item.goodsName}',
    );
    if (picked == null || !mounted) return;
    for (final row in rows) {
      row.setWarehouse(
        picked.id,
        source: _FinishedArrivalWarehouseSource.manual,
      );
    }
    ref
        .read(productionFinishedArrivalFillMemoryProvider.notifier)
        .rememberWarehouse(picked.id);
    if (rows.length > 1) {
      context.appInfo('已把成品仓写到选中的 ${rows.length} 行');
    }
    setState(() => _validationError = null);
    await _reloadSuggestions();
  }

  /// 行内写库位：落到 [_writeTargets]——勾选多行时改本行，整批逐字符跟着变。
  /// 只改本行时什么都不用做（控件自己持有文本）。
  void _onPlaceChanged(_FinishedArrivalRegistrationGridRow row, String value) {
    final targets = _writeTargets(row);
    if (targets.length > 1) {
      for (final target in targets) {
        if (identical(target, row) || target.registered) continue;
        target.setManualPlace(value);
      }
      setState(() {});
    }
  }

  /// [scope] = 本次要提交的勾选行（2026-09-18）：「同时记住」只核对要登记的行，
  /// 未勾选行不进本次提交，其库位不应拦提交。
  String? _rememberPlacesConflict([
    Set<_FinishedArrivalRegistrationGridRow>? scope,
  ]) {
    final grouped =
        <String, Map<String, List<_FinishedArrivalRegistrationGridRow>>>{};
    for (final row in _editableRows) {
      if (scope != null && !scope.contains(row)) continue;
      final place = row.place.text.trim();
      if (place.isEmpty) continue;
      final warehouseId = row.warehouseId.value;
      if (warehouseId == null || warehouseId.isEmpty) continue;
      final key = '$warehouseId|${row.item.goodsId}|${row.item.colorId ?? ''}';
      grouped.putIfAbsent(key, () => {}).putIfAbsent(place, () => []).add(row);
    }
    // 冲突货品全部列出：只报第一个的话，用户统一完再提交才看到下一个。
    final conflicts = <String>[];
    for (final entry in grouped.entries) {
      if (entry.value.length <= 1) continue;
      final sample = entry.value.values.first.first;
      final candidates = entry.value.entries
          .map(
            (candidate) =>
                '${candidate.key}(第${candidate.value.map(_rowLabel).join('、')}行)',
          )
          .join(' / ');
      conflicts.add(
        '${sample.item.goodsCode} ${sample.item.goodsName}：$candidates',
      );
    }
    if (conflicts.isEmpty) return null;
    return _rowIssueMessage(
      conflicts,
      '在同一成品仓同一颜色维度填写了不同库位',
      action: '请统一库位，或关闭“同时记住”为仅保存本次登记快照',
      unit: '个货品',
    );
  }

  String _rowLabel(_FinishedArrivalRegistrationGridRow row) {
    final index = _grid.rows.indexOf(row);
    return row.item.lineNo > 0 ? '${row.item.lineNo}' : '${index + 1}';
  }

  /// [preStock] 为真 = 「先入库后质检」按钮，否则 = 「登记并送检」按钮。
  Future<void> _save({required bool preStock}) async {
    if (_saving || _remembering || !_canRegister) return;
    final wantPreStock = preStock && _canStockInBeforeInspection;
    if (_stockInBeforeInspection != wantPreStock) {
      setState(() => _stockInBeforeInspection = wantPreStock);
    }
    if (_suggestionsLoading) {
      context.appInfo('正在读取该成品仓默认库位，请稍候再提交');
      return;
    }
    if (_rememberPlaces && _suggestionError != null) {
      const message = '成品仓默认库位加载失败；请先重试，或关闭“同时记住”后仅保存本次登记';
      setState(() => _validationError = message);
      context.appError(message);
      return;
    }
    // 勾选=本次要登记送检的行（2026-09-18，与批量登记页同款）：右下两个提交
    // 按钮没勾行时已置灰，这里再兜一层；未勾选行不进校验与提交。
    final rows = _grid.selectedRows
        .where((row) => !row.registered)
        .toList(growable: false);
    if (rows.isEmpty) {
      setState(() => _validationError = '请先勾选要登记送检的明细行（未勾选的行本次不登记）');
      context.appError('请先勾选要登记送检的明细行（未勾选的行本次不登记）');
      return;
    }
    final submitted = rows.toSet();
    final excludedCount = _editableRows.length - rows.length;
    // 有可登记行却未勾选：提交前明确告知去向，防「取消勾选=静默不登记」。
    if (excludedCount > 0) {
      final confirmed = await UtenDialog.show(
        context,
        title: '有 $excludedCount 行明细未勾选',
        confirmLabel: '只登记勾选行',
        content: Text(
          '本次只登记勾选的 ${rows.length} 行；未勾选的 $excludedCount 行不登记、'
          '不产生 FQC 与库存事实，仍留在待登记送检，可稍后办理。',
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (rows.every((row) => row.warehouseId.value?.isNotEmpty != true)) {
      setState(() => _validationError = '请选择实际存放的成品仓库');
      context.appError('请选择实际存放的成品仓库');
      return;
    }
    // 明细整表扫完再报：原先首个违规就 return，多行缺仓/缺库位时用户补一行提交一次，
    // 观感像「怎么老是报错」。判定条件不变，只把问题按类别各汇总成一条。
    final missingWarehouse = <String>[];
    final missingPlace = <String>[];
    final placeTooLong = <String>[];
    for (final row in rows) {
      final label = '第 ${_rowLabel(row)} 行（${row.item.goodsName}）';
      if (row.warehouseId.value?.isNotEmpty != true) {
        missingWarehouse.add(label);
      }
      final place = row.place.text.trim();
      if (place.isEmpty) {
        missingPlace.add(label);
      } else if (place.length > 100) {
        placeTooLong.add(label);
      }
    }
    final rowIssues = <String>[
      if (missingWarehouse.isNotEmpty)
        _rowIssueMessage(missingWarehouse, '未选择成品仓', action: '请补齐后再提交'),
      if (missingPlace.isNotEmpty)
        _rowIssueMessage(missingPlace, '未填写库位号', action: '请补齐后再提交'),
      if (placeTooLong.isNotEmpty)
        _rowIssueMessage(placeTooLong, '的库位号超过 100 个字符', action: '请改短后再提交'),
    ];
    if (_rememberPlaces) {
      final conflict = _rememberPlacesConflict(submitted);
      if (conflict != null) rowIssues.add(conflict);
    }
    if (rowIssues.isNotEmpty) {
      // 不同类别分行列出，混成一句会让人看不清到底要改哪几处。
      final message = rowIssues.join('\n');
      setState(() => _validationError = message);
      context.appError(message);
      return;
    }

    // 按行仓分组：一个仓一个登记批次 + 一张品质检查单（V469 一批一仓，V547 一仓一单）。
    final byWarehouse = <String, List<_FinishedArrivalRegistrationGridRow>>{};
    for (final row in rows) {
      byWarehouse.putIfAbsent(row.warehouseId.value!, () => []).add(row);
    }
    final remark = _remarkController.text.trim();
    setState(() {
      _saving = true;
      _validationError = null;
    });
    final repo = ref.read(productionFinishedInboundTaskRepositoryProvider);
    for (final entry in byWarehouse.entries) {
      if (_registrations.containsKey(entry.key)) continue;
      final body = <String, dynamic>{
        // 幂等键含选择：同一页改用另一个按钮重提交是另一个请求，不是重放。
        'idempotencyKey': _stockInBeforeInspection
            ? '$_idempotencyKey:${entry.key}:prestock'
            : '$_idempotencyKey:${entry.key}',
        'warehouseId': entry.key,
        if (remark.isNotEmpty) 'remark': remark,
        if (_stockInBeforeInspection) 'stockInBeforeInspection': true,
        'items': [
          for (final row in entry.value)
            {
              'reportItemId': row.item.reportItemId,
              'place': row.place.text.trim(),
            },
        ],
      };
      try {
        final registered = await repo.saveArrivalRegistration(
          widget.reportId,
          body,
        );
        if (!mounted) return;
        _registrations[entry.key] = registered;
        for (final row in entry.value) {
          row.lockRegistered();
        }
        setState(() {});
      } on ApiException catch (error) {
        _registrationFailed(entry.key, error.message);
        return;
      } catch (_) {
        _registrationFailed(entry.key, '登记送检失败，请稍后重试');
        return;
      }
    }
    if (!mounted) return;

    _suggestionGeneration++;
    final last = _registrations.values.last;
    setState(() {
      _detail = last;
      _saving = false;
      _suggestionsLoading = false;
      _suggestionError = null;
      _validationError = null;
      _registrationCompletedThisSession = true;
    });
    invalidateWarehouseTaskCounts(ref);

    if (!_rememberPlaces) {
      context.appSuccess(_registeredSummary());
      _leave(changed: true);
      return;
    }
    await _rememberRegisteredPlaces();
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
      '已按 ${_registrations.length} 个仓库登记送检；仓库「$label」登记失败：$message。'
      '可直接重试，已成功部分不会重复登记',
    );
  }

  String _registeredSummary() {
    final sheets = _registrations.values
        .map((registration) => registration.sheetNo)
        .whereType<String>()
        .where((sheetNo) => sheetNo.isNotEmpty)
        .toList(growable: false);
    final sheetText = sheets.isEmpty ? '' : '，品质检查单 ${sheets.join('、')}';
    final tail = _stockInBeforeInspection ? '；品质合格后系统按本次库位自动入库，无需再点收' : '';
    return _registrations.length == 1
        ? '成品仓和库位已登记，已送品质部检查$sheetText$tail'
        : '已按 ${_registrations.length} 个成品仓分别登记并送检$sheetText$tail';
  }

  Future<void> _rememberRegisteredPlaces() async {
    if (_remembering) return;
    setState(() {
      _remembering = true;
      _rememberError = null;
    });
    var remembered = 0;
    var unchanged = 0;
    var ambiguous = 0;
    final warnings = <String>[];
    try {
      final repo = ref.read(productionFinishedInboundTaskRepositoryProvider);
      for (final registration in _registrations.values) {
        final registrationId = registration.registrationId;
        if (registrationId == null ||
            _rememberedRegistrationIds.contains(registrationId)) {
          continue;
        }
        final result = await repo.rememberPlaces(
          widget.reportId,
          registrationId: registrationId,
        );
        _rememberedRegistrationIds.add(registrationId);
        remembered += result.remembered;
        unchanged += result.unchanged;
        ambiguous += result.ambiguous;
        warnings.addAll(result.warnings);
      }
      if (!mounted) return;
      setState(() => _remembering = false);
      final suffix = warnings.isEmpty ? '' : '；${warnings.join('；')}';
      if (ambiguous > 0 || warnings.isNotEmpty) {
        context.appWarning(
          '登记已完成；$ambiguous 组默认库位存在歧义，'
          '已记住 $remembered 组，$unchanged 组未变化$suffix',
          force: true,
        );
      } else {
        context.appSuccess(
          '${_registeredSummary()}；已记住 $remembered 组默认库位，'
          '$unchanged 组保持不变',
          force: true,
        );
      }
      _leave(changed: true);
    } on ApiException catch (error) {
      _rememberPlacesFailed(error.message);
    } catch (_) {
      _rememberPlacesFailed('网络异常，请重试记住默认库位');
    }
  }

  void _rememberPlacesFailed(String message) {
    if (!mounted) return;
    setState(() {
      _remembering = false;
      _rememberError = message;
    });
    context.appWarning('登记已完成，但默认库位尚未记住：$message', force: true);
  }

  /// V548 撤回登记（仅品质未处理）：原因弹窗 → 服务端校验每条 FQC 仍待检 → 报工行回到待登记。
  Future<void> _reverseBatch(ProductionFinishedRegistrationBatch batch) async {
    if (_reversing || _saving || !_hasRegisterPermission) return;
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

  String? _warehouseLabel(String? warehouseId) {
    if (warehouseId == null || warehouseId.isEmpty) return null;
    final names = ref.read(masterNameServiceProvider);
    final full = warehouseFullLabel(names.warehouseHierarchy, warehouseId);
    if (full != null) return full;
    final resolved = names.warehouse(warehouseId);
    if (resolved.isNotEmpty && resolved != warehouseId) return resolved;
    return _detail?.warehouseId == warehouseId ? _detail?.warehouseName : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.canRegister == null) {
      ref.watch(isSuperAdminProvider);
      ref.watch(currentPermissionsProvider);
    }
    final theme = Theme.of(context);
    // 「先入库后质检」按钮随权限快照实时显隐(独立权限点)。
    final canPreStock =
        ref.watch(isSuperAdminProvider) ||
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.productionFinishedInBeforeInspection);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '登记成品仓与库位',
        leading: UtenBackButton(onPressed: _leave),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('production-finished-arrival-refresh'),
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading,
              onPressed:
                  _loading ||
                      _saving ||
                      _remembering ||
                      _reversing ||
                      (_registrationCompletedThisSession &&
                          _rememberError != null)
                  ? null
                  : _load,
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
                : UtenGridPageScrollbar(
                    pinned: _gridPinned,
                    controller: _scrollController,
                    // 滚动条贴屏幕右缘（2026-09-15）：包装在内容容器之外，右缘窄条
                    // 恒在屏幕最右，不随限宽容器/列宽漂移。
                    child: UtenContentContainer(
                      child: ListView(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        children: [
                          _buildStageBanner(theme),
                          const SizedBox(height: UtenSpacing.s12),
                          _buildHeaderCard(theme, names),
                          const SizedBox(height: UtenSpacing.s12),
                          if (_detail!.batches.isNotEmpty) ...[
                            _buildBatchesCard(theme),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
                          if (_canRegister) ...[
                            // 登记交互控件（默认仓/记忆开关/建议状态/备注）聚拢在工具区，
                            // 一屏完成（2026-09-09 对照采购入库）；行级仓与批量动作在表格内。
                            _buildRegistrationToolbar(theme),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
                          if (_rememberError != null) ...[
                            _buildRememberFailure(theme),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
                          if (_validationError != null) ...[
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _validationError!,
                                key: const Key(
                                  'production-finished-arrival-validation-error',
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s8),
                          ],
                          // 2026-09-14：提示常驻（原先只在 <840 窄屏出现）。
                          LayoutBuilder(
                            builder: (context, constraints) => Padding(
                              padding: const EdgeInsets.only(
                                bottom: UtenSpacing.s8,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    size: 18,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: UtenSpacing.s8),
                                  Expanded(
                                    child: Text(
                                      '明细默认全选：右下「先入库后质检 / 登记并送检」只提交勾选的行，'
                                      '未勾选的行不登记、不写库存，仍留在待登记送检（可重新勾回）；'
                                      '也可点行末 ⊖ 把该行移出本批送检（可勾选多行后右键批量移出），'
                                      '报工明细不会删除。'
                                      '${constraints.maxWidth < 840 ? '表格可左右滑动；' : ''}'
                                      '报工数量只读；勾选多行后在任意一行改成品仓/库位即批量落值，'
                                      '也可右键批量设置；库位说明见列头 ⓘ。',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // 「成品明细 (N)」标题行 2026-09-11 撤除（全站同改）。
                          const SizedBox(height: UtenSpacing.s8),
                          UtenEditableGrid<_FinishedArrivalRegistrationGridRow>(
                            key: const Key(
                              'production-finished-arrival-registration-grid',
                            ),
                            controller: _grid,
                            stickyHeaderPinned: _gridPinned,
                            columns: _columns(names),
                            createBlankRow: () =>
                                throw UnsupportedError('成品到货登记明细由已审核报工固定带入'),
                            showAddRow: false,
                            showRowDelete: false,
                            selectable: _canRegister,
                            selectionEnabled: !_saving && !_remembering,
                            canSelectRow: (row) => !row.registered,
                            onRemoveRows: _canRegister
                                ? _removeFromThisRegistration
                                : null,
                            removeRowsActionLabel: '移出本批送检',
                            removeRowsDialogTitle: '移出本批送检',
                            removeRowsConfirmLabel: '确认移出',
                            removeRowsMessageBuilder: (count) =>
                                '确认从本批送检移出选中的 $count 行？'
                                '报工明细不会删除，也不会产生 FQC、入库或库存事实；'
                                '返回任务中心后仍保持待登记送检。',
                            // 2026-09-12 表头上方常驻按钮全撤（与批量登记页、采购
                            // 登记页同日同改）：全选走表头复选框，「移出本批送检」搬
                            // 进行右键菜单，批量设仓/填库位改成「勾选多行后在任意
                            // 一行改仓/写库位即整批落值」+ 右键菜单批量动作。
                            showSelectAllToggle: false,
                            showRemoveRowsAction: false,
                            // 2026-09-14：行末常驻 ⊖（与到货登记页同一口径）——只走
                            // 右键在宽屏等于没有入口，用户判定「不能删除部分产品」。
                            // 已登记行 canSelectRow=false，组件自动只占位不出按钮。
                            showInlineRemoveAction: true,
                            rowMenuExtraBuilder: _canRegister && !_saving
                                ? (context, selected) => [
                                    UtenMenuItem(
                                      label: '批量设置成品仓 (${selected.length})',
                                      icon: Icons.warehouse_outlined,
                                      enabled: selected.isNotEmpty,
                                      onTap: () => _pickWarehouseFor(
                                        selected
                                            .where((row) => !row.registered)
                                            .toList(),
                                      ),
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
                            footer: Padding(
                              padding: const EdgeInsets.all(UtenSpacing.s12),
                              child: Text(
                                _removedLineCount > 0
                                    ? '已移出 $_removedLineCount 行（仅本批）；未选行仍在待登记送检，'
                                          '本次只提交表内剩余行。'
                                    : _canRegister
                                    ? _rememberPlaces
                                          ? '按行仓分组登记：一个成品仓一个登记批次、一张品质检查单；'
                                                '将按所选成品仓记住默认库位，不改变历史登记和库存事实。'
                                          : '按行仓分组登记：一个成品仓一个登记批次、一张品质检查单；'
                                                '仅保存本次到货库位快照，不更新以后默认建议。'
                                    : _detail!.registered
                                    ? '该到货登记已提交，仓库和库位仅供核对。'
                                    : '当前账号只有查看权限，不能修改仓库或库位。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          ListenableBuilder(
                            listenable: _grid,
                            builder: (context, _) => UtenTotalsSummaryBar(
                              key: const Key(
                                'production-finished-arrival-totals',
                              ),
                              density: true,
                              entries: [
                                UtenTotalEntry('成品明细', '${_grid.length} 行'),
                                UtenTotalEntry(
                                  '报工合计',
                                  measurementTotalsText(
                                    _grid.rows.map(
                                      (row) => MeasuredAmount(
                                        value: row.item.reportedQty,
                                        unitId: row.item.unitId,
                                        unitName: row.item.unitName,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(
                            height: UtenFloatingActionGroup.scrollClearance,
                          ),
                        ],
                      ),
                    ),
                  ),
            // 登记/记忆/撤销网络段的全屏加载遮罩（root Overlay 传送门）。
            if (_saving || _remembering || _reversing)
              UtenBusyOverlay(
                title: _saving
                    ? '正在登记成品仓与库位'
                    : _reversing
                    ? '正在撤销本次登记'
                    : '正在记忆库位',
                description: _saving
                    ? '正在按成品仓逐张登记并送检，请勿重复提交或离开本页。'
                    : '请稍候，完成后自动继续。',
              ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      // 提交集=勾选集（2026-09-18）：监听表格选择集，一行都没勾时右下两个提交
      // 按钮置灰（灰态点击说明原因），勾回任意行立即恢复。
      floatingActionButton: _detail == null
          ? null
          : ListenableBuilder(
              listenable: _grid,
              builder: (context, _) => _buildBottomBar(theme, canPreStock),
            ),
    );
  }

  /// 底部：取消 + 先入库后质检 / 登记并送检(两个主动作二选一)。
  /// 2026-09-18 勾选口径：一行都没勾时两个提交按钮置灰，灰态点击说明原因。
  Widget _buildBottomBar(ThemeData theme, bool canPreStock) {
    final hasCheckedLine = _grid.selectedRows.any((row) => !row.registered);
    final VoidCallback? onEmptySelection =
        _saving || _suggestionsLoading || hasCheckedLine
        ? null
        : () => context.appWarning('请先勾选要登记送检的明细行（未勾选的行本次不登记）');
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _saving || _remembering || _reversing
              ? null
              : () => _leave(changed: _registrationCompletedThisSession),
          child: Text(_canRegister ? '取消' : '返回任务'),
        ),
        if (_canRegister) ...[
          // 先入库后质检(V597 / ADR-090 第六节)：与「登记并送检」并排的第二个主动作。
          // 点它 = 登记 + 送检 + 承诺「合格按本次登记的成品仓与库位自动点收」，仓库不再
          // 收到待点收任务；代价是实收恒等于报工量(放弃短收改量)。需独立权限。
          if (canPreStock)
            Tooltip(
              message:
                  '登记的同时承诺：品质合格由系统按本次登记的成品仓与库位自动点收入库，'
                  '仓库不再确认第二次(实收恒等于报工量，放弃短收改量)；不合格仍不动库存',
              child: UtenButton(
                key: const Key('production-finished-arrival-stock-in-first'),
                size: UtenButtonSize.large,
                icon: Icons.shelves,
                isLoading: _saving && _stockInBeforeInspection,
                onPressed:
                    _saving ||
                        _suggestionsLoading ||
                        _grid.isEmpty ||
                        !hasCheckedLine
                    ? null
                    : () => _save(preStock: true),
                onDisabledTap: onEmptySelection,
                child: const Text('先入库后质检'),
              ),
            ),
          UtenButton(
            key: const Key('production-finished-arrival-submit'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.fact_check_outlined,
            isLoading: _saving && !_stockInBeforeInspection,
            onPressed:
                _saving ||
                    _suggestionsLoading ||
                    _grid.isEmpty ||
                    !hasCheckedLine
                ? null
                : () => _save(preStock: false),
            onDisabledTap: _suggestionsLoading
                ? () => context.appInfo('正在读取该成品仓默认库位，请稍候再提交')
                : onEmptySelection,
            child: const Text('登记并送检'),
          ),
        ],
      ],
    );
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

  /// 多选行批量填库位：一次输入应用到全部选中行（同库位场景，如整托同架）。
  Future<void> _batchFillPlace(
    List<_FinishedArrivalRegistrationGridRow> rows,
  ) async {
    if (rows.isEmpty) return;
    final place = await showBatchPlaceFillDialog(
      context,
      rowCount: rows.length,
    );
    if (place == null || !mounted) return;
    if (place.isEmpty) {
      context.appWarning('库位号不能为空');
      return;
    }
    setState(() {
      for (final row in rows) {
        row.setManualPlace(place);
      }
      _validationError = null;
    });
  }

  Widget _buildRememberPlacesSwitch(ThemeData theme) {
    return Card(
      child: SwitchListTile(
        key: const Key('production-finished-arrival-remember-places'),
        value: _rememberPlaces,
        onChanged: _saving || _remembering
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
    return Semantics(
      key: const Key('production-finished-arrival-suggestion-status'),
      container: true,
      liveRegion: true,
      child: Card(
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
                      ? '正在读取该成品仓默认库位，完成前暂不能提交。'
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
                  key: const Key(
                    'production-finished-arrival-retry-suggestions',
                  ),
                  type: UtenButtonType.tonal,
                  onPressed: () => unawaited(_reloadSuggestions()),
                  child: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRememberFailure(ThemeData theme) {
    return Card(
      key: const Key('production-finished-arrival-remember-failure'),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final message = Text(
              '到货登记和送检已成功，但默认库位尚未记住：$_rememberError',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            );
            final retry = UtenButton(
              key: const Key('production-finished-arrival-retry-remember'),
              isLoading: _remembering,
              onPressed: _remembering ? null : _rememberRegisteredPlaces,
              child: const Text('重试记住默认库位'),
            );
            final back = UtenButton(
              key: const Key(
                'production-finished-arrival-return-after-remember-failure',
              ),
              type: UtenButtonType.secondary,
              onPressed: _remembering ? null : () => _leave(changed: true),
              child: const Text('返回任务'),
            );
            if (constraints.maxWidth < 600) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  message,
                  const SizedBox(height: UtenSpacing.s12),
                  retry,
                  const SizedBox(height: UtenSpacing.s8),
                  back,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: message),
                const SizedBox(width: UtenSpacing.s12),
                retry,
                const SizedBox(width: UtenSpacing.s8),
                back,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildStageBanner(ThemeData theme) => Semantics(
    container: true,
    label: '成品入库第一步，共两步。仓库逐行登记成品仓和库位后送品质部检查。',
    child: Card(
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
                    _detail?.registered == true
                        ? '第 1 步已完成：仓库到货位置已登记'
                        : '第 1 步：仓库登记到货位置',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '逐行选择实际成品仓并填写库位；同一成品仓的行合并成一张品质检查单送检。'
                    '品质放行后再进行最终点收。',
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
    ),
  );

  Widget _buildHeaderCard(ThemeData theme, MasterNameService names) {
    final detail = _detail!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [
            _readOnlyField('报工单', detail.reportNo),
            _readOnlyField('报工日期', ChinaDateTime.formatDate(detail.reportDate)),
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
            if (detail.registered) ...[
              _readOnlyField(
                '实际成品仓',
                detail.warehouseName ?? detail.warehouseCode ?? '—',
              ),
              if (detail.sheetNo?.isNotEmpty == true)
                _readOnlyField('品质检查单', detail.sheetNo!),
              if (detail.remark?.isNotEmpty == true)
                _readOnlyField('备注', detail.remark!),
              if (detail.reversedAt != null)
                _readOnlyField(
                  '撤回登记',
                  '${ChinaDateTime.formatDateTime(detail.reversedAt!)}'
                      '${detail.reversalReason == null ? '' : ' · ${detail.reversalReason}'}',
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 同一报工的登记批次（含已撤回历史）；品质未处理的批次可在此撤回登记。
  Widget _buildBatchesCard(ThemeData theme) {
    final batches = _detail!.batches;
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
              '一个成品仓一个登记批次、一张品质检查单；品质尚未处理的批次可撤回登记，'
              '撤回后这些报工行重新回到待登记送检。',
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
                        onPressed: _reversing || _saving
                            ? null
                            : () => _reverseBatch(batch),
                        child: const Text('撤回登记(仅品质未处理)'),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  /// 本批登记工具区：记忆开关 → 建议状态 → 备注（2026-09-12「默认成品仓」下拉
  /// 撤除——成品仓下沉行级，勾选多行批量落值；预填仍按上次登记/账号记忆带出）。
  Widget _buildRegistrationToolbar(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_suggestionsLoading || _suggestionError != null) ...[
              _buildSuggestionStatus(theme),
              const SizedBox(height: UtenSpacing.s8),
            ],
            _buildRememberPlacesSwitch(theme),
            const SizedBox(height: UtenSpacing.s8),
            TextFormField(
              key: const Key('production-finished-arrival-remark'),
              errorBuilder: utenTextFieldErrorBuilder,
              controller: _remarkController,
              enabled: _canRegister && !_saving,
              maxLength: 500,
              decoration: const UtenInputDecoration(
                InputDecoration(
                  labelText: '备注',
                  hintText: '选填；随本批每个登记批次与品质检查单留痕',
                  counterText: '',
                ),
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

  bool get _anyRowWarehouseSelected =>
      _grid.rows.any((row) => row.warehouseId.value?.isNotEmpty == true);

  List<EditableGridColumn<_FinishedArrivalRegistrationGridRow>> _columns(
    MasterNameService names,
  ) => [
    EditableGridColumn(
      key: 'lineNo',
      label: '行号',
      width: 64,
      numeric: true,
      textOf: (row) => row.item.lineNo.toString(),
      cellBuilder: (context, row) =>
          Text(row.item.lineNo.toString(), textAlign: TextAlign.right),
    ),
    // 2026-09-14 全站列序统一（ADR-081 §4.1）：名称 → 编号 → 颜色。
    EditableGridColumn(
      key: 'goodsName',
      label: '货品名称',
      width: 220,
      textOf: (row) => row.item.goodsName,
      cellBuilder: (context, row) => Text(row.item.goodsName),
    ),
    EditableGridColumn(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      textOf: (row) => row.item.goodsCode,
      cellBuilder: (context, row) => Text(row.item.goodsCode),
    ),
    EditableGridColumn(
      key: 'color',
      label: '颜色',
      width: 90,
      textOf: (row) => row.item.colorName ?? names.color(row.item.colorId),
      cellBuilder: (context, row) =>
          Text(row.item.colorName ?? names.color(row.item.colorId)),
    ),
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 80,
      textOf: (row) => row.item.unitName ?? names.unit(row.item.unitId),
      cellBuilder: (context, row) =>
          Text(row.item.unitName ?? names.unit(row.item.unitId)),
    ),
    EditableGridColumn(
      key: 'qty',
      label: '报工数量',
      width: 110,
      numeric: true,
      textOf: (row) => _quantity(row.item.reportedQty),
      cellBuilder: (context, row) =>
          Text(_quantity(row.item.reportedQty), textAlign: TextAlign.right),
    ),
    if (!(_detail?.registered ?? false))
      EditableGridColumn(
        key: 'warehouse',
        label: '实际成品仓',
        width: 180,
        required: _canRegister,
        textOf: (row) => _warehouseLabel(row.warehouseId.value) ?? '',
        listenableOf: (row) => row.warehouseId,
        // 格尾箭头(20) + 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
        chromeWidth:
            UtenEditableGridCellSpec.dropdownChevronWidth +
            UtenEditableGridCellSpec.hintIconWidth,
        cellBuilder: (context, row) => _buildWarehouseCell(context, row),
      ),
    EditableGridColumn(
      key: 'place',
      label: '库位号',
      width: 220,
      required: _canRegister && _anyRowWarehouseSelected,
      // 通用说明收进列头 ⓘ（2026-09-12 全站口径）：格内不再逐行挂 ⓘ 图标
      //（把输入框挤窄），行级只剩黄框（预填待核对）与红框（必填为空）两种状态。
      headerInfo:
          '必填，不超过 100 字。选择成品仓后按「该仓默认 → 最近登记：'
          '同仓同货品 → 货品主档通用建议」自动匹配；黄框 = 已带入默认值，'
          '请核对本次实物存放位置，可直接修改。',
      textOf: (row) => row.place.text,
      listenableOf: (row) => row.place,
      // 预填黄标 ⓘ(44)计入量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
      cellBuilder: (context, row) => _buildPlaceCell(context, row),
    ),
  ];

  /// 成品仓格：outlined 选择格（点击弹共享仓库面板）；未选红框、预填黄框 + 框内来源说明。
  Widget _buildWarehouseCell(
    BuildContext context,
    _FinishedArrivalRegistrationGridRow row,
  ) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: row.warehouseId,
      builder: (context, warehouseId, _) {
        final label = _warehouseLabel(warehouseId);
        final enabled = _canRegister && !_saving && !row.registered;
        final autofilled = label != null && row.warehouseAutofilled;
        return Semantics(
          button: true,
          label: '${row.item.goodsName} 实际成品仓：${label ?? '未选择'}，点击修改',
          child: InkWell(
            key: ValueKey(
              'production-finished-arrival-wh-${row.item.reportItemId}',
            ),
            onTap: enabled
                ? () => _pickWarehouseFor(
                    _writeTargets(row).where((r) => !r.registered).toList(),
                  )
                : null,
            borderRadius: BorderRadius.circular(UtenRadius.control),
            child: InputDecorator(
              decoration: applyAutofillHint(
                UtenInputDecoration(
                  InputDecoration(
                    isDense: true,
                    enabledBorder: label == null && enabled
                        ? requiredEmptyBorder(theme)
                        : null,
                  ),
                  info: row.warehouseSource.info(AppLocalizations.of(context)),
                ),
                theme,
                autofilled: autofilled,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label ?? (enabled ? '必选 · 点击选择' : '—'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: label == null && enabled
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
          ),
        );
      },
    );
  }

  Widget _buildPlaceCell(
    BuildContext context,
    _FinishedArrivalRegistrationGridRow row,
  ) {
    return ValueListenableBuilder<_FinishedArrivalPlaceSource>(
      valueListenable: row.placeSource,
      builder: (context, source, _) {
        final warehouseSelected = row.warehouseId.value?.isNotEmpty == true;
        final matching = warehouseSelected && _suggestionsLoading;
        final learned =
            warehouseSelected &&
            !matching &&
            source.isLearned &&
            row.place.text.trim().isNotEmpty;
        final editable =
            _canRegister &&
            !_saving &&
            !row.registered &&
            warehouseSelected &&
            !matching;
        final field = Semantics(
          textField: true,
          label: '${row.item.goodsName} 库位号，${source.label}',
          child: TextField(
            key: ValueKey(
              'production-finished-arrival-place-${row.item.reportItemId}',
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
              autofilled: learned && !row.registered,
            ),
            // 勾选多行时改本行 = 批量写到全部选中行；只改本行时同步无事可做。
            // 通用说明在列头 ⓘ（2026-09-12 全站口径），格内不再逐行挂图标。
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

class _FinishedArrivalRegistrationGridRow extends EditableGridRow {
  _FinishedArrivalRegistrationGridRow(this.item, {required this.registered})
    : place = TextEditingController(
        text: item.place?.trim().isNotEmpty == true
            ? item.place
            : item.placeHint ?? '',
      ),
      warehouseId = ValueNotifier<String?>(null),
      placeSource = ValueNotifier<_FinishedArrivalPlaceSource>(
        item.place?.trim().isNotEmpty == true
            ? _FinishedArrivalPlaceSource.registrationSnapshot
            : item.placeHint?.trim().isNotEmpty == true
            ? _FinishedArrivalPlaceSource.goodsMaster
            : _FinishedArrivalPlaceSource.none,
      ) {
    _lastPlaceText = place.text;
    place.addListener(_handlePlaceChanged);
  }

  final ProductionFinishedArrivalRegistrationItem item;
  final TextEditingController place;
  final ValueNotifier<String?> warehouseId;
  final ValueNotifier<_FinishedArrivalPlaceSource> placeSource;
  _FinishedArrivalWarehouseSource warehouseSource =
      _FinishedArrivalWarehouseSource.none;
  bool warehouseAutofilled = false;

  /// 已登记（历史快照或本会话已成功提交的仓）：仓与库位只读、不可再选。
  bool registered;
  bool _applyingSuggestion = false;
  late String _lastPlaceText;

  void lockRegistered() => registered = true;

  void _handlePlaceChanged() {
    final textChanged = place.text != _lastPlaceText;
    _lastPlaceText = place.text;
    if (!textChanged) return;
    if (_applyingSuggestion ||
        placeSource.value == _FinishedArrivalPlaceSource.manual) {
      return;
    }
    placeSource.value = _FinishedArrivalPlaceSource.manual;
  }

  /// 行级改仓：换仓即清掉原仓上下文的建议与手工库位，等新仓建议（单张页口径）。
  void setWarehouse(
    String? value, {
    required _FinishedArrivalWarehouseSource source,
    bool markAutofilled = true,
  }) {
    if (registered) return;
    warehouseSource = source;
    warehouseAutofilled =
        markAutofilled && source.isSuggested && value?.isNotEmpty == true;
    if (warehouseId.value == value) return;
    warehouseId.value = value;
    resetForWarehouseChange(warehouseSelected: value?.isNotEmpty == true);
  }

  void setManualPlace(String value) {
    _applyingSuggestion = true;
    place.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _applyingSuggestion = false;
    _lastPlaceText = value;
    placeSource.value = _FinishedArrivalPlaceSource.manual;
  }

  void applySuggestion(ProductionFinishedPlaceSuggestion suggestion) {
    if (registered || placeSource.value == _FinishedArrivalPlaceSource.manual) {
      return;
    }
    final candidate = suggestion.place?.trim() ?? '';
    if (candidate.isEmpty) {
      resetAutomaticSuggestion();
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
        _FinishedArrivalPlaceSource.warehousePreference,
      ProductionFinishedPlaceSuggestionSource.registrationHistory =>
        _FinishedArrivalPlaceSource.registrationHistory,
      ProductionFinishedPlaceSuggestionSource.goodsMaster =>
        _FinishedArrivalPlaceSource.goodsMaster,
      ProductionFinishedPlaceSuggestionSource.none =>
        _FinishedArrivalPlaceSource.none,
    };
  }

  void resetAutomaticSuggestion() {
    if (registered || placeSource.value == _FinishedArrivalPlaceSource.manual) {
      return;
    }
    final fallback = item.placeHint?.trim() ?? '';
    _applyingSuggestion = true;
    place.value = TextEditingValue(
      text: fallback,
      selection: TextSelection.collapsed(offset: fallback.length),
    );
    _applyingSuggestion = false;
    placeSource.value = fallback.isEmpty
        ? _FinishedArrivalPlaceSource.none
        : _FinishedArrivalPlaceSource.goodsMaster;
  }

  void clearAutomaticSuggestion() {
    if (registered || placeSource.value == _FinishedArrivalPlaceSource.manual) {
      return;
    }
    _applyingSuggestion = true;
    place.value = TextEditingValue.empty;
    _applyingSuggestion = false;
    placeSource.value = _FinishedArrivalPlaceSource.none;
  }

  void resetForWarehouseChange({required bool warehouseSelected}) {
    if (registered) return;
    final fallback = warehouseSelected ? item.placeHint?.trim() ?? '' : '';
    _applyingSuggestion = true;
    place.value = TextEditingValue(
      text: fallback,
      selection: TextSelection.collapsed(offset: fallback.length),
    );
    _applyingSuggestion = false;
    placeSource.value = fallback.isEmpty
        ? _FinishedArrivalPlaceSource.none
        : _FinishedArrivalPlaceSource.goodsMaster;
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

enum _FinishedArrivalWarehouseSource {
  none,
  goodsMaster,
  pageDefault,
  manual;

  bool get isSuggested => this == goodsMaster || this == pageDefault;

  String? info(AppLocalizations l10n) => switch (this) {
    goodsMaster => l10n.warehouseGoodsMasterDefaultHint,
    pageDefault => '已带入默认成品仓，请核对本次实际存放仓库',
    manual => null,
    none => null,
  };
}

enum _FinishedArrivalPlaceSource {
  registrationSnapshot,
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
    registrationSnapshot => '本次登记快照',
    warehousePreference => '该仓默认',
    registrationHistory => '最近登记：同仓同货品',
    goodsMaster => '货品主档通用建议',
    none => '暂无默认',
    manual => '手工输入',
  };
}
