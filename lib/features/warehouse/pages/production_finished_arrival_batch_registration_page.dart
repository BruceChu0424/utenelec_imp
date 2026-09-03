// 多报工单汇总登记成品仓与库位（任务列表多选「批量登记成品仓并送检」落点）。
//
// 交互范式复刻采购订货单明细表：行首选选列 + 「统一设置成品仓(n)」批量动作 +
// 行内可各自改；成品仓选定后逐行批量拉默认库位建议（V431 偏好链，一次请求合并
// 全部行）；页头「默认成品仓」预选当前用户上次登记所用的仓（last-warehouse），
// 切换默认仓 = 批量落到全部未提交行。提交 = 一个事务逐单登记并生成各自的 FQC
// 送检（每单一份 FQC、行级锚定不变，见产成品待点收任务页文档）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
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
  String? _defaultWarehouseId;
  String? _lastWarehouseName;
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
      // 默认仓 = 当前用户上次登记所用仓（无历史不预选，不猜）。
      String? warehouseId;
      String? lastWarehouseName;
      try {
        final last = await ref
            .read(productionFinishedInboundTaskRepositoryProvider)
            .lastArrivalWarehouse();
        warehouseId = last?.warehouseId;
        lastWarehouseName = last?.warehouseName;
      } catch (_) {
        /* 上次仓拉取失败不阻断，仅不预选 */
      }
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _defaultWarehouseId = warehouseId;
        _lastWarehouseName = lastWarehouseName;
        _loading = false;
        _validationError = null;
        _suggestionError = null;
      });
      if (warehouseId?.isNotEmpty == true && _editableRows.isNotEmpty) {
        _applyWarehouseToRows(_editableRows, warehouseId!);
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
    String warehouseId,
  ) {
    for (final row in rows) {
      row.setWarehouse(warehouseId);
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

  Future<void> _onDefaultWarehouseChanged(String? value) async {
    setState(() {
      _defaultWarehouseId = value;
      _validationError = null;
      _suggestionError = null;
    });
    if (value?.isNotEmpty == true) {
      _applyWarehouseToRows(_editableRows, value!);
      await _reloadSuggestions();
    } else {
      _suggestionGeneration++;
      for (final row in _editableRows) {
        row.setWarehouse(null);
      }
      setState(() => _suggestionsLoading = false);
    }
  }

  /// 行内/批量「设置成品仓」：打开仓库选择弹窗，返回后落到目标行并刷新建议。
  Future<void> _pickWarehouseFor(
    List<_BatchArrivalRegistrationRow> rows,
  ) async {
    final names = ref.read(masterNameServiceProvider);
    final current = rows.length == 1
        ? rows.single.warehouseId.value
        : _defaultWarehouseId;
    final picked = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _WarehousePickerDialog(
        entries: names.warehouseEntries,
        currentId: current,
      ),
    );
    if (picked == null || !mounted) return;
    _applyWarehouseToRows(rows, picked.$1);
    setState(() {});
    await _reloadSuggestions();
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
    // 按报工单分组：同一报工的全部行必须同仓（一张登记单一个仓）。
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('汇总登记并送检 ${reportIds.length} 张报工单'),
        content: const Text(
          '将在同一事务逐张报工单登记成品仓与库位并送品质部检查（每单一份 FQC）。'
          '任一报工状态、权限、品质或并发校验失败，整批回滚。'
          '提交后进入品质检查；品质放行后再按实物执行最终点收。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('确认登记并送检'),
          ),
        ],
      ),
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
      context.appSuccess('已汇总登记 ${result.registeredCount} 张报工单的成品仓和库位，已送品质部检查');
      _leave(changed: true);
      return;
    }
    await _rememberRegisteredPlaces(reportIds, result.registeredCount);
  }

  Future<void> _rememberRegisteredPlaces(
    List<String> reportIds,
    int registeredCount,
  ) async {
    if (_remembering) return;
    setState(() {
      _remembering = true;
      _suggestionError = null;
    });
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .rememberPlacesBatch(reportIds);
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
          '默认库位，${result.unchanged} 组保持不变',
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
                      _buildHeaderCard(theme, names),
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
                      Text(
                        '成品明细 (${_grid.length} 行 · ${_reports!.length} 张报工单)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
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
                        selectable: _canRegister,
                        canSelectRow: (row) => !row.registered,
                        selectedOf: (row) => row.selected,
                        onRowSelect: (row, next) =>
                            setState(() => row.selected = next),
                        batchActionsBuilder: _canRegister
                            ? (context, controller) => [
                                Tooltip(
                                  message:
                                      '把所选行的成品仓统一设为同一个仓，'
                                      '并自动匹配默认库位；单行也可点击行内格单独改',
                                  child: UtenButton(
                                    key: const Key(
                                      'production-finished-arrival-batch-set-warehouse',
                                    ),
                                    size: UtenButtonSize.large,
                                    icon: Icons.warehouse_outlined,
                                    onPressed: () {
                                      final rows = controller.rows
                                          .where((row) => row.selected)
                                          .toList(growable: false);
                                      if (rows.isEmpty) {
                                        context.appWarning('请先勾选要统一设置成品仓的行');
                                        return;
                                      }
                                      _pickWarehouseFor(rows);
                                    },
                                    child: Text(
                                      '统一设置成品仓(${controller.rows.where((row) => row.selected).length})',
                                    ),
                                  ),
                                ),
                              ]
                            : null,
                        emptyMessage: '所选报工单没有可登记明细，请返回任务中心刷新',
                        footer: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Text(
                            _canRegister
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
                        onPressed: _saving || _suggestionsLoading
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
                  '默认成品仓按您上次登记自动预选；勾选行可「统一设置成品仓」，'
                  '行内也可单独改库位。提交后每张报工单各生成一份品质送检；'
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
  );

  Widget _buildHeaderCard(ThemeData theme, MasterNameService names) {
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
            UtenDropdownField(
              key: const Key('production-finished-arrival-batch-warehouse'),
              label: '默认成品仓',
              required: true,
              enabled: _canRegister && !_saving && !_submitted,
              value: _defaultWarehouseId,
              items: [
                for (final entry in names.warehouseEntries.entries)
                  UtenDropdownItem(value: entry.key, label: entry.value),
              ],
              helperMessage: _lastWarehouseName == null
                  ? null
                  : '已按您上次登记预选（$_lastWarehouseName）',
              onChanged: _onDefaultWarehouseChanged,
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
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      suffixIcon: const Icon(Icons.lock_outline, size: 16),
    ),
  );

  List<EditableGridColumn<_BatchArrivalRegistrationRow>> _columns(
    MasterNameService names,
  ) => [
    EditableGridColumn(
      key: 'reportNo',
      label: '报工单',
      width: 150,
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
      textOf: (row) => row.item.goodsName,
      cellBuilder: (context, row) => Text(row.item.goodsName),
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
      width: 70,
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
      textOf: (row) => row.place.text,
      listenableOf: (row) => row.place,
      cellBuilder: (context, row) => _buildPlaceCell(context, row),
    ),
  ];

  /// 成品仓格：与订货单「供应商」格同款 outlined 选择格（点击弹选择器）。
  Widget _buildWarehouseCell(
    BuildContext context,
    _BatchArrivalRegistrationRow row,
    MasterNameService names,
  ) {
    final theme = Theme.of(context);
    final warehouseId = row.warehouseId.value;
    final name = warehouseId == null ? null : names.warehouse(warehouseId);
    final enabled = _canRegister && !_saving && !_submitted && !row.registered;
    return InkWell(
      onTap: enabled ? () => _pickWarehouseFor([row]) : null,
      borderRadius: BorderRadius.circular(6),
      child: InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          suffixIcon: Icon(
            name == null ? Icons.search_rounded : Icons.unfold_more_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          suffixIconConstraints: const BoxConstraints(minWidth: 20),
        ),
        child: Text(
          name ?? '点击选择成品仓',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: name != null
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceCell(
    BuildContext context,
    _BatchArrivalRegistrationRow row,
  ) {
    final field = TextField(
      key: ValueKey(
        'production-finished-arrival-batch-place-${row.item.reportItemId}',
      ),
      controller: row.place,
      enabled:
          _canRegister &&
          !_saving &&
          !_submitted &&
          !row.registered &&
          row.warehouseId.value?.isNotEmpty == true &&
          !_suggestionsLoading,
      inputFormatters: [LengthLimitingTextInputFormatter(100)],
      decoration: InputDecoration(
        isDense: true,
        hintText: row.warehouseId.value?.isNotEmpty != true
            ? '请先选择成品仓'
            : _suggestionsLoading
            ? '正在匹配默认库位'
            : '必填',
      ),
      onChanged: (_) {
        if (_validationError != null) setState(() => _validationError = null);
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        const SizedBox(height: UtenSpacing.s4),
        ValueListenableBuilder<_BatchPlaceSource>(
          valueListenable: row.placeSource,
          builder: (context, source, _) {
            final warehouseSelected = row.warehouseId.value?.isNotEmpty == true;
            final matching = warehouseSelected && _suggestionsLoading;
            final statusLabel = row.registered
                ? '已登记快照'
                : !warehouseSelected
                ? '请先选择成品仓'
                : matching
                ? '正在匹配默认库位'
                : source.label;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  source.icon,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s4),
                Expanded(
                  child: Text(
                    statusLabel,
                    maxLines: 2,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
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
    place.addListener(_handlePlaceChanged);
  }

  final ProductionFinishedArrivalRegistration report;
  final ProductionFinishedArrivalRegistrationItem item;
  final bool registered;
  final TextEditingController place;
  final ValueNotifier<String?> warehouseId;
  final ValueNotifier<_BatchPlaceSource> placeSource;
  bool selected = false;
  bool _applyingSuggestion = false;

  void _handlePlaceChanged() {
    if (_applyingSuggestion || placeSource.value == _BatchPlaceSource.manual) {
      return;
    }
    placeSource.value = _BatchPlaceSource.manual;
  }

  /// 行级改仓：清掉未手工改过行的库位（等新仓的建议）。
  void setWarehouse(String? value) {
    if (registered) return;
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

  String get label => switch (this) {
    snapshot => '本次登记快照',
    warehousePreference => '该仓默认',
    registrationHistory => '最近登记：同仓同货品',
    goodsMaster => '货品主档通用建议',
    none => '暂无默认',
    manual => '手工输入',
  };

  IconData get icon => switch (this) {
    snapshot => Icons.lock_outline_rounded,
    warehousePreference => Icons.warehouse_outlined,
    registrationHistory => Icons.history_rounded,
    goodsMaster => Icons.inventory_2_outlined,
    none => Icons.info_outline_rounded,
    manual => Icons.edit_outlined,
  };
}

/// 成品仓选择弹窗：搜索 + 列表（数据源 masterNameService.warehouseEntries）。
class _WarehousePickerDialog extends StatefulWidget {
  const _WarehousePickerDialog({required this.entries, this.currentId});

  final Map<String, String> entries;
  final String? currentId;

  @override
  State<_WarehousePickerDialog> createState() => _WarehousePickerDialogState();
}

class _WarehousePickerDialogState extends State<_WarehousePickerDialog> {
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    final keyword = _keyword.trim().toLowerCase();
    final entries =
        widget.entries.entries
            .where(
              (entry) =>
                  keyword.isEmpty ||
                  entry.value.toLowerCase().contains(keyword) ||
                  entry.key.toLowerCase().contains(keyword),
            )
            .toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    return AlertDialog(
      title: const Text('选择成品仓'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索仓库名称',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setState(() => _keyword = value),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('没有匹配的仓库'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final selected = entry.key == widget.currentId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          title: Text(entry.value),
                          trailing: selected
                              ? const Icon(Icons.check_rounded)
                              : null,
                          onTap: () => Navigator.of(
                            context,
                          ).pop((entry.key, entry.value)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
