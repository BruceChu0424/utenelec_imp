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
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../models/production_finished_inbound_task.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

/// 生产报工审核后的仓库到货登记。
///
/// 本页只登记本次成品实际存放的仓库与逐行库位；数量来自已审核报工，只读。
/// 保存后进入品质检查，品质放行后再由仓库执行最终点收。
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
  final String _idempotencyKey = const Uuid().v4();

  ProductionFinishedArrivalRegistration? _detail;
  String? _warehouseId;
  String? _error;
  String? _validationError;
  bool _loading = false;
  bool _saving = false;
  bool _remembering = false;
  bool _rememberPlaces = true;
  bool _suggestionsLoading = false;
  bool _registrationCompletedThisSession = false;
  int _removedLineCount = 0;
  int _suggestionGeneration = 0;
  String? _suggestionError;
  String? _rememberError;

  bool get _hasRegisterPermission {
    final override = widget.canRegister;
    if (override != null) return override;
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);
  }

  bool get _canRegister =>
      _hasRegisterPermission && !(_detail?.registered ?? false);

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
      final detail = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .arrivalRegistration(widget.reportId);
      if (!mounted) return;
      _grid.replaceAll([
        for (final item in detail.items)
          _FinishedArrivalRegistrationGridRow(item),
      ]);
      if (detail.warehouseId?.isNotEmpty != true) {
        _clearAutomaticPlaceSuggestions();
      }
      setState(() {
        _detail = detail;
        _warehouseId = detail.warehouseId;
        _removedLineCount = 0;
        _loading = false;
        _validationError = null;
        _suggestionError = null;
        _rememberError = null;
      });
      final warehouseId = detail.warehouseId;
      if (!detail.registered && warehouseId?.isNotEmpty == true) {
        await _loadPlaceSuggestions(warehouseId!);
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

  Future<void> _loadPlaceSuggestions(String warehouseId) async {
    final generation = ++_suggestionGeneration;
    _resetAutomaticPlaceSuggestions();
    setState(() {
      _suggestionsLoading = true;
      _suggestionError = null;
    });
    try {
      final suggestions = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .placeSuggestions(widget.reportId, warehouseId: warehouseId);
      if (!mounted ||
          generation != _suggestionGeneration ||
          _warehouseId != warehouseId) {
        return;
      }
      _resetAutomaticPlaceSuggestions();
      final byReportItemId = {
        for (final suggestion in suggestions)
          suggestion.reportItemId: suggestion,
      };
      for (final row in _grid.rows) {
        final suggestion = byReportItemId[row.item.reportItemId];
        if (suggestion != null) row.applySuggestion(suggestion);
      }
      setState(() => _suggestionsLoading = false);
    } on ApiException catch (error) {
      if (!mounted ||
          generation != _suggestionGeneration ||
          _warehouseId != warehouseId) {
        return;
      }
      setState(() {
        _suggestionsLoading = false;
        _suggestionError = error.message;
      });
    } catch (_) {
      if (!mounted ||
          generation != _suggestionGeneration ||
          _warehouseId != warehouseId) {
        return;
      }
      setState(() {
        _suggestionsLoading = false;
        _suggestionError = '成品仓默认库位加载失败';
      });
    }
  }

  void _resetAutomaticPlaceSuggestions() {
    for (final row in _grid.rows) {
      row.resetAutomaticSuggestion();
    }
  }

  void _clearAutomaticPlaceSuggestions() {
    for (final row in _grid.rows) {
      row.clearAutomaticSuggestion();
    }
  }

  /// 本页删除是“暂不纳入本批送检”，不删除已审核报工明细。
  /// V469 后服务端只登记提交的 UUID；移出行保持仓库待登记且不产生 FQC/库存事实。
  void _removeFromThisRegistration(
    List<_FinishedArrivalRegistrationGridRow> rows,
  ) {
    if (_saving || !_canRegister || rows.isEmpty) return;
    _grid.removeRows(rows);
    if (!mounted) return;
    setState(() {
      _removedLineCount += rows.length;
      _validationError = null;
    });
    context.appInfo('已从本批送检移出 ${rows.length} 行；报工事实未删除，仍留在待登记送检');
  }

  void _resetPlacesForWarehouseChange({required bool warehouseSelected}) {
    for (final row in _grid.rows) {
      row.resetForWarehouseChange(warehouseSelected: warehouseSelected);
    }
  }

  String? _rememberPlacesConflict() {
    final grouped = <String, Map<String, List<int>>>{};
    for (var index = 0; index < _grid.rows.length; index++) {
      final row = _grid.rows[index];
      final place = row.place.text.trim();
      if (place.isEmpty) continue;
      final key = '${row.item.goodsId}|${row.item.colorId ?? ''}';
      grouped
          .putIfAbsent(key, () => <String, List<int>>{})
          .putIfAbsent(place, () => <int>[])
          .add(row.item.lineNo > 0 ? row.item.lineNo : index + 1);
    }
    for (final entry in grouped.entries) {
      if (entry.value.length <= 1) continue;
      final firstRow = _grid.rows.firstWhere(
        (row) => '${row.item.goodsId}|${row.item.colorId ?? ''}' == entry.key,
      );
      final candidates = entry.value.entries
          .map(
            (candidate) => '${candidate.key}(第${candidate.value.join('、')}行)',
          )
          .join(' / ');
      return '货品 ${firstRow.item.goodsCode} ${firstRow.item.goodsName} '
          '在同一颜色维度填写了不同库位：$candidates。'
          '请统一库位，或关闭“同时记住”为仅保存本次登记快照。';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || _remembering || !_canRegister) return;
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
    final warehouseId = _warehouseId;
    if (warehouseId == null || warehouseId.isEmpty) {
      setState(() => _validationError = '请选择实际存放的成品仓库');
      context.appError('请选择实际存放的成品仓库');
      return;
    }
    if (_grid.rows.isEmpty) {
      setState(() => _validationError = '该报工单没有可登记的成品明细');
      context.appError('该报工单没有可登记的成品明细');
      return;
    }
    for (var index = 0; index < _grid.rows.length; index++) {
      final place = _grid.rows[index].place.text.trim();
      if (place.isEmpty) {
        final message = '第 ${index + 1} 行必须填写库位号';
        setState(() => _validationError = message);
        context.appError(message);
        return;
      }
      if (place.length > 100) {
        final message = '第 ${index + 1} 行库位号不能超过 100 个字符';
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

    final body = <String, dynamic>{
      'idempotencyKey': _idempotencyKey,
      'warehouseId': warehouseId,
      'items': [
        for (final row in _grid.rows)
          {
            'reportItemId': row.item.reportItemId,
            'place': row.place.text.trim(),
          },
      ],
    };
    setState(() {
      _saving = true;
      _validationError = null;
    });
    late final ProductionFinishedArrivalRegistration detail;
    try {
      detail = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .saveArrivalRegistration(widget.reportId, body);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
      if (mounted) setState(() => _saving = false);
      return;
    } catch (_) {
      if (mounted) context.appError('登记送检失败，请稍后重试');
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (!mounted) return;

    _suggestionGeneration++;
    _grid.replaceAll([
      for (final item in detail.items)
        _FinishedArrivalRegistrationGridRow(item),
    ]);
    setState(() {
      _detail = detail;
      _warehouseId = detail.warehouseId;
      _saving = false;
      _suggestionsLoading = false;
      _suggestionError = null;
      _validationError = null;
      _registrationCompletedThisSession = true;
    });
    invalidateWarehouseTaskCounts(ref);

    if (!_rememberPlaces) {
      context.appSuccess('成品仓和库位已登记，已送品质部检查');
      _leave(changed: true);
      return;
    }
    await _rememberRegisteredPlaces();
  }

  Future<void> _rememberRegisteredPlaces() async {
    if (_remembering) return;
    setState(() {
      _remembering = true;
      _rememberError = null;
    });
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .rememberPlaces(
            widget.reportId,
            registrationId: _detail?.registrationId,
          );
      if (!mounted) return;
      setState(() => _remembering = false);
      final suffix = result.warnings.isEmpty
          ? ''
          : '；${result.warnings.join('；')}';
      if (result.ambiguous > 0 || result.warnings.isNotEmpty) {
        context.appWarning(
          '登记已完成；${result.ambiguous} 组默认库位存在歧义，'
          '已记住 ${result.remembered} 组，${result.unchanged} 组未变化$suffix',
          force: true,
        );
      } else {
        context.appSuccess(
          '登记送检成功；已记住 ${result.remembered} 组默认库位，'
          '${result.unchanged} 组保持不变',
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

  @override
  Widget build(BuildContext context) {
    if (widget.canRegister == null) {
      ref.watch(isSuperAdminProvider);
      ref.watch(currentPermissionsProvider);
    }
    final theme = Theme.of(context);
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
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _detail == null
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
                      _buildStageBanner(theme),
                      const SizedBox(height: UtenSpacing.s12),
                      _buildHeaderCard(theme, names),
                      const SizedBox(height: UtenSpacing.s12),
                      if (_canRegister) ...[
                        _buildRememberPlacesSwitch(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (_suggestionsLoading || _suggestionError != null) ...[
                        _buildSuggestionStatus(theme),
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
                      LayoutBuilder(
                        builder: (context, constraints) =>
                            constraints.maxWidth < 840
                            ? Padding(
                                padding: const EdgeInsets.only(
                                  bottom: UtenSpacing.s8,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.swipe_rounded,
                                      size: 18,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: UtenSpacing.s8),
                                    Expanded(
                                      child: Text(
                                        '表格可左右滑动；可勾选或右键/长按明细移出本批送检。'
                                        '报工数量只读，库位来源会在输入框下方标明。',
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
                              )
                            : const SizedBox.shrink(),
                      ),
                      Text(
                        '成品明细 (${_grid.length})',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      UtenEditableGrid<_FinishedArrivalRegistrationGridRow>(
                        key: const Key(
                          'production-finished-arrival-registration-grid',
                        ),
                        controller: _grid,
                        columns: _columns(names),
                        createBlankRow: () =>
                            throw UnsupportedError('成品到货登记明细由已审核报工固定带入'),
                        showAddRow: false,
                        showRowDelete: false,
                        selectable: _canRegister,
                        selectionEnabled: !_saving && !_remembering,
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
                        emptyMessage: '该报工单没有可登记明细，请返回任务中心刷新',
                        footer: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Text(
                            _removedLineCount > 0
                                ? '已移出 $_removedLineCount 行（仅本批）；未选行仍在待登记送检，'
                                      '本次只提交表内剩余行。'
                                : _canRegister
                                ? _rememberPlaces
                                      ? '将按所选成品仓记住默认库位；不改变历史登记和库存事实。'
                                      : '仅保存本次到货库位快照，不更新以后默认建议。'
                                : _detail!.registered
                                ? '该到货登记已提交，仓库和库位仅供核对。'
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
      bottomNavigationBar: _detail == null
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
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
                          : () => _leave(
                              changed: _registrationCompletedThisSession,
                            ),
                      child: Text(_canRegister ? '取消' : '返回任务'),
                    ),
                    if (_canRegister) ...[
                      const SizedBox(width: UtenSpacing.s12),
                      UtenButton(
                        key: const Key('production-finished-arrival-submit'),
                        size: UtenButtonSize.large,
                        icon: Icons.fact_check_outlined,
                        isLoading: _saving,
                        onPressed:
                            _saving || _suggestionsLoading || _grid.isEmpty
                            ? null
                            : _save,
                        onDisabledTap: _suggestionsLoading
                            ? () => context.appInfo('正在读取该成品仓默认库位，请稍候再提交')
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
              if (!loading && _warehouseId?.isNotEmpty == true) ...[
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  key: const Key(
                    'production-finished-arrival-retry-suggestions',
                  ),
                  type: UtenButtonType.tonal,
                  onPressed: () =>
                      unawaited(_loadPlaceSuggestions(_warehouseId!)),
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
    label: '成品入库第一步，共两步。仓库登记成品仓和库位后送品质部检查。',
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
                    '选择实际成品仓并逐行填写库位。提交后进入品质检查；品质放行后再进行最终点收。',
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
            UtenDropdownField(
              key: const Key('production-finished-arrival-warehouse'),
              label: '实际成品仓',
              required: true,
              allowClear: false,
              enabled: _canRegister && !_saving,
              value: _warehouseId,
              // V476：主/子层级（父仓置灰分组，实收落具体仓）；
              // 孤儿仓值（仓库已删但单据仍引用）仍回显名称。
              items: [
                ...warehouseHierarchyItems(names.warehouseHierarchy),
                if (_warehouseId != null &&
                    !names.warehouseEntries.containsKey(_warehouseId))
                  UtenDropdownItem(
                    value: _warehouseId!,
                    label: detail.warehouseName ?? _warehouseId!,
                  ),
              ],
              errorMessage: _validationError != null && _warehouseId == null
                  ? '请选择实际存放的成品仓库'
                  : null,
              onChanged: (value) {
                final warehouseChanged = _warehouseId != value;
                setState(() {
                  _warehouseId = value;
                  _validationError = null;
                  _suggestionError = null;
                });
                if (warehouseChanged) {
                  _resetPlacesForWarehouseChange(
                    warehouseSelected: value?.isNotEmpty == true,
                  );
                }
                if (value?.isNotEmpty == true) {
                  unawaited(_loadPlaceSuggestions(value!));
                } else {
                  _suggestionGeneration++;
                  _clearAutomaticPlaceSuggestions();
                  setState(() => _suggestionsLoading = false);
                }
              },
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
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      suffixIcon: const Icon(Icons.lock_outline, size: 16),
    ),
  );

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
    EditableGridColumn(
      key: 'goodsCode',
      label: '物料编码',
      width: 130,
      textOf: (row) => row.item.goodsCode,
      cellBuilder: (context, row) => Text(row.item.goodsCode),
    ),
    EditableGridColumn(
      key: 'goodsName',
      label: '货品名称',
      width: 220,
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
    EditableGridColumn(
      key: 'place',
      label: '库位号',
      width: 220,
      required: _canRegister && _warehouseId?.isNotEmpty == true,
      textOf: (row) => row.place.text,
      listenableOf: (row) => row.place,
      cellBuilder: (context, row) {
        final field = Semantics(
          textField: true,
          label: '${row.item.goodsName} 库位号',
          child: TextField(
            key: ValueKey(
              'production-finished-arrival-place-${row.item.reportItemId}',
            ),
            controller: row.place,
            enabled:
                _canRegister &&
                !_saving &&
                _warehouseId?.isNotEmpty == true &&
                !_suggestionsLoading,
            inputFormatters: [LengthLimitingTextInputFormatter(100)],
            decoration: InputDecoration(
              isDense: true,
              hintText: _warehouseId?.isNotEmpty != true
                  ? '请先选择成品仓'
                  : _suggestionsLoading
                  ? '正在匹配默认库位'
                  : row.item.placeHint?.trim().isNotEmpty == true
                  ? row.item.placeHint
                  : '必填',
            ),
            onChanged: (_) {
              if (_validationError != null) {
                setState(() => _validationError = null);
              }
            },
          ),
        );
        final fieldWithSource = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            field,
            const SizedBox(height: UtenSpacing.s4),
            ValueListenableBuilder<_FinishedArrivalPlaceSource>(
              valueListenable: row.placeSource,
              builder: (context, source, _) {
                final warehouseSelected = _warehouseId?.isNotEmpty == true;
                final matching = warehouseSelected && _suggestionsLoading;
                final statusLabel = !warehouseSelected
                    ? '请先选择成品仓'
                    : matching
                    ? '正在匹配默认库位'
                    : source.label;
                final statusIcon = !warehouseSelected
                    ? Icons.warehouse_outlined
                    : matching
                    ? Icons.sync_rounded
                    : source.icon;
                final manual =
                    warehouseSelected &&
                    !matching &&
                    source == _FinishedArrivalPlaceSource.manual;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      statusIcon,
                      size: 16,
                      color: manual
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        statusLabel,
                        key: ValueKey(
                          'production-finished-arrival-place-source-'
                          '${row.item.reportItemId}',
                        ),
                        maxLines: 2,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: manual
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        );
        if (!_canRegister ||
            _warehouseId?.isNotEmpty != true ||
            _suggestionsLoading) {
          return fieldWithSource;
        }
        return RequiredCellFrame(
          listenable: row.place,
          isEmpty: () => row.place.text.trim().isEmpty,
          child: fieldWithSource,
        );
      },
    ),
  ];

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class _FinishedArrivalRegistrationGridRow extends EditableGridRow {
  _FinishedArrivalRegistrationGridRow(this.item)
    : place = TextEditingController(
        text: item.place?.trim().isNotEmpty == true
            ? item.place
            : item.placeHint ?? '',
      ),
      placeSource = ValueNotifier<_FinishedArrivalPlaceSource>(
        item.place?.trim().isNotEmpty == true
            ? _FinishedArrivalPlaceSource.registrationSnapshot
            : item.placeHint?.trim().isNotEmpty == true
            ? _FinishedArrivalPlaceSource.goodsMaster
            : _FinishedArrivalPlaceSource.none,
      ) {
    place.addListener(_handlePlaceChanged);
  }

  final ProductionFinishedArrivalRegistrationItem item;
  final TextEditingController place;
  final ValueNotifier<_FinishedArrivalPlaceSource> placeSource;
  bool _applyingSuggestion = false;

  void _handlePlaceChanged() {
    if (_applyingSuggestion ||
        placeSource.value == _FinishedArrivalPlaceSource.manual) {
      return;
    }
    placeSource.value = _FinishedArrivalPlaceSource.manual;
  }

  void applySuggestion(ProductionFinishedPlaceSuggestion suggestion) {
    if (item.place?.trim().isNotEmpty == true ||
        placeSource.value == _FinishedArrivalPlaceSource.manual) {
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
    if (item.place?.trim().isNotEmpty == true ||
        placeSource.value == _FinishedArrivalPlaceSource.manual) {
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

  void resetForWarehouseChange({required bool warehouseSelected}) {
    if (item.place?.trim().isNotEmpty == true) return;
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

  void clearAutomaticSuggestion() {
    if (item.place?.trim().isNotEmpty == true ||
        placeSource.value == _FinishedArrivalPlaceSource.manual) {
      return;
    }
    _applyingSuggestion = true;
    place.value = TextEditingValue.empty;
    _applyingSuggestion = false;
    placeSource.value = _FinishedArrivalPlaceSource.none;
  }

  @override
  void dispose() {
    place.removeListener(_handlePlaceChanged);
    place.dispose();
    placeSource.dispose();
    super.dispose();
  }
}

enum _FinishedArrivalPlaceSource {
  registrationSnapshot,
  warehousePreference,
  registrationHistory,
  goodsMaster,
  none,
  manual;

  String get label => switch (this) {
    registrationSnapshot => '本次登记快照',
    warehousePreference => '该仓默认',
    registrationHistory => '最近登记：同仓同货品',
    goodsMaster => '货品主档通用建议',
    none => '暂无默认',
    manual => '手工输入',
  };

  IconData get icon => switch (this) {
    registrationSnapshot => Icons.lock_outline_rounded,
    warehousePreference => Icons.warehouse_outlined,
    registrationHistory => Icons.history_rounded,
    goodsMaster => Icons.inventory_2_outlined,
    none => Icons.info_outline_rounded,
    manual => Icons.edit_outlined,
  };
}
