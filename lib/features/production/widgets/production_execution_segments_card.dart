import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../department/models/department_node.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/production_execution_planning.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';

/// Confirmed execution segments and their operational state transitions.
///
/// Responsive execution cards expose the legal action for each segment.
/// Only fully-issued dispatched segments offer a 48x48 batch-start checkbox.
class ProductionExecutionSegmentsCard extends ConsumerStatefulWidget {
  const ProductionExecutionSegmentsCard({
    super.key,
    required this.planId,
    required this.canAssign,
    required this.canReleaseDefer,
    required this.canDispatch,
    required this.canStart,
    required this.canReport,
    this.initialSegmentId,
    this.onChanged,
  });

  final String planId;
  final bool canAssign;
  final bool canReleaseDefer;
  final bool canDispatch;
  final bool canStart;
  final bool canReport;
  final String? initialSegmentId;
  final Future<void> Function()? onChanged;

  @override
  ConsumerState<ProductionExecutionSegmentsCard> createState() =>
      _ProductionExecutionSegmentsCardState();
}

class _ProductionExecutionSegmentsCardState
    extends ConsumerState<ProductionExecutionSegmentsCard> {
  List<ProductionExecutionSegmentView>? _segments;
  String? _selectedId;
  String? _handledInitialSegmentId;
  String? _error;
  bool _loading = false;
  bool _busy = false;
  bool _batchStarting = false;
  bool _detailOpening = false;
  final Set<String> _selectedStartIds = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialSegmentId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant ProductionExecutionSegmentsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.planId != widget.planId) {
      _segments = null;
      _error = null;
      _loading = false;
      _selectedId = widget.initialSegmentId;
      _handledInitialSegmentId = null;
      _selectedStartIds.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      return;
    }
    if (oldWidget.initialSegmentId != widget.initialSegmentId) {
      _selectedId = widget.initialSegmentId;
      _handledInitialSegmentId = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openRequestedSegment(),
      );
    }
  }

  Future<void> _load() async {
    if (!mounted || _loading) return;
    final planId = widget.planId;
    setState(() => _loading = true);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .executionSegments(planId);
      if (!mounted || widget.planId != planId) return;
      setState(() {
        _segments = result;
        _error = null;
        final startableIds = result
            .where(_isStartSelectable)
            .map((segment) => segment.id)
            .toSet();
        _selectedStartIds.removeWhere(
          (segmentId) => !startableIds.contains(segmentId),
        );
        if (_selectedId != null &&
            !result.any((segment) => segment.id == _selectedId)) {
          _selectedId = null;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openRequestedSegment(),
      );
    } on ApiException catch (error) {
      if (mounted && widget.planId == planId) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && widget.planId == planId) {
        setState(() => _error = '执行子计划加载失败');
      }
    } finally {
      if (mounted && widget.planId == planId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openRequestedSegment() async {
    if (!mounted) return;
    final requestedId = widget.initialSegmentId;
    if (requestedId == null || requestedId.isEmpty) return;
    if (_handledInitialSegmentId == requestedId) return;
    final segment = _segments
        ?.where((item) => item.id == requestedId)
        .firstOrNull;
    if (segment == null) {
      if (_segments != null) {
        _handledInitialSegmentId = requestedId;
        context.appWarning('未找到指定执行子计划，数据可能已更新', force: true);
      }
      return;
    }
    _handledInitialSegmentId = requestedId;
    setState(() => _selectedId = requestedId);
    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: 0.15,
    );
    if (!mounted) return;
    await _openSegment(segment);
  }

  Future<void> _openSegment(ProductionExecutionSegmentView segment) async {
    if (!mounted || _detailOpening) return;
    if (_busy || _batchStarting) {
      context.appWarning('正在处理，请稍候', force: true);
      return;
    }
    setState(() {
      _selectedId = segment.id;
      _detailOpening = true;
    });
    _SegmentAction? action;
    try {
      action = await _showSegmentDetail(segment);
    } finally {
      if (mounted) {
        setState(() => _detailOpening = false);
      } else {
        _detailOpening = false;
      }
    }
    if (!mounted || action == null) return;
    await _handleSegmentAction(segment, action);
  }

  Future<void> _handleSegmentAction(
    ProductionExecutionSegmentView segment,
    _SegmentAction action,
  ) async {
    if (_batchStarting) {
      context.appWarning('正在批量开工，请稍候', force: true);
      return;
    }
    switch (action) {
      case _SegmentAction.assign:
        await _assign(segment);
        break;
      case _SegmentAction.releaseDefer:
        await _releaseDefer(segment);
        break;
      case _SegmentAction.dispatch:
        await _transition(segment, 'dispatch');
        break;
      case _SegmentAction.start:
        await _transition(segment, 'start');
        break;
      case _SegmentAction.report:
        await _openReport(segment);
        break;
    }
  }

  Future<void> _openReport(ProductionExecutionSegmentView segment) async {
    if (_busy || _batchStarting) {
      context.appWarning('正在处理，请稍候', force: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await context.push(
        Uri(
          path: RoutePath.productionDailyReportNew(),
          queryParameters: {'executionSegmentId': segment.id},
        ).toString(),
      );
      if (!mounted) return;
      await _load();
      await widget.onChanged?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_SegmentAction?> _showSegmentDetail(
    ProductionExecutionSegmentView segment,
  ) {
    final body = _ExecutionSegmentDetail(
      segment: segment,
      canAssign: widget.canAssign,
      canReleaseDefer: widget.canReleaseDefer,
      canDispatch: widget.canDispatch,
      canStart: widget.canStart,
      canReport: widget.canReport,
    );
    if (context.breakpoint.isCompact) {
      return showModalBottomSheet<_SegmentAction>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => FractionallySizedBox(heightFactor: 0.9, child: body),
      );
    }
    return showDialog<_SegmentAction>(
      context: context,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(UtenSpacing.s24),
        child: SizedBox(
          width: 680,
          height: (MediaQuery.sizeOf(dialogContext).height * 0.86)
              .clamp(440.0, 680.0)
              .toDouble(),
          child: body,
        ),
      ),
    );
  }

  Future<void> _assign(ProductionExecutionSegmentView segment) async {
    final workshops = await ref
        .read(productionWorkshopTreeProvider.future)
        .catchError((_) => <DepartmentNode>[]);
    if (!mounted) return;
    String? workshopId = segment.workshopDepartmentId;
    String? teamId = segment.teamDepartmentId;
    UtenEmployeePickerItem? responsible = segment.responsibleEmployeeId == null
        ? null
        : UtenEmployeePickerItem(
            id: segment.responsibleEmployeeId!,
            name: segment.responsibleEmployeeName?.isNotEmpty == true
                ? segment.responsibleEmployeeName!
                : '已选负责人',
          );
    DateTime? begin = DateTime.tryParse(segment.planBeginDate ?? '');
    DateTime? end = DateTime.tryParse(segment.planEndDate ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final workshop = workshops
              .where((item) => item.id == workshopId)
              .firstOrNull;
          final teams = workshop?.children ?? const <DepartmentNode>[];

          Future<void> pickDate(bool isBegin) async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: ctx,
              initialDate: (isBegin ? begin : end) ?? now,
              firstDate: now.subtract(const Duration(days: 365)),
              lastDate: now.add(const Duration(days: 3650)),
            );
            if (picked == null) return;
            setDialogState(() {
              if (isBegin) {
                begin = picked;
                if (end != null && end!.isBefore(picked)) end = picked;
              } else {
                end = picked;
              }
            });
          }

          return AlertDialog(
            title: Text('调整 ${segment.segmentCode}'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: workshopId ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '生产车间'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('待分配')),
                        for (final item in workshops)
                          DropdownMenuItem(
                            value: item.id,
                            child: Text(item.name),
                          ),
                      ],
                      onChanged: (value) => setDialogState(() {
                        workshopId = value == null || value.isEmpty
                            ? null
                            : value;
                        teamId = null;
                        responsible = null;
                      }),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('$workshopId-$teamId-${teams.length}'),
                      initialValue: teamId ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '生产班组'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('待分配')),
                        for (final item in teams)
                          DropdownMenuItem(
                            value: item.id,
                            child: Text(item.name),
                          ),
                      ],
                      onChanged: workshopId == null
                          ? null
                          : (value) => setDialogState(() {
                              teamId = value == null || value.isEmpty
                                  ? null
                                  : value;
                              responsible = null;
                            }),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    UtenEmployeePicker(
                      key: ValueKey(responsible?.id ?? ''),
                      initial: responsible,
                      hint: '选择负责人',
                      loader: (keyword) async {
                        final result = await ref
                            .read(employeeRepositoryProvider)
                            .list(
                              size: 30,
                              search: keyword,
                              statuses: const {'active', 'probation'},
                              departmentId: teamId ?? workshopId,
                              includeSubtree:
                                  teamId != null || workshopId != null,
                            );
                        return [
                          for (final employee in result.items)
                            UtenEmployeePickerItem(
                              id: employee.id,
                              name: employee.fullName,
                              employeeCode: employee.code,
                              departmentName: employee.departmentName,
                            ),
                        ];
                      },
                      onChanged: (value) =>
                          setDialogState(() => responsible = value),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Row(
                      children: [
                        Expanded(
                          child: _dateField(
                            ctx,
                            '计划开工',
                            begin,
                            () => pickDate(true),
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: _dateField(
                            ctx,
                            '计划完工',
                            end,
                            () => pickDate(false),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存分配'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    if (begin != null && end != null && end!.isBefore(begin!)) {
      context.appError('计划完工日期不能早于开工日期');
      return;
    }
    final canonical = [
      segment.id,
      segment.lockVersion,
      workshopId,
      teamId,
      responsible?.id,
      _dateText(begin),
      _dateText(end),
    ].join('|');
    await _runCommand(
      () => ref
          .read(productionPlanRepositoryProvider)
          .assignExecutionSegment(
            widget.planId,
            segment.id,
            expectedVersion: segment.lockVersion,
            idempotencyKey: businessIdempotencyKey(
              'production-segment-assign',
              canonical,
            ),
            workshopDepartmentId: workshopId,
            teamDepartmentId: teamId,
            responsibleEmployeeId: responsible?.id,
            planBeginDate: _dateText(begin),
            planEndDate: _dateText(end),
          ),
      '分配已保存',
    );
  }

  Future<void> _releaseDefer(ProductionExecutionSegmentView segment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除人工暂缓'),
        content: const Text(
          '系统会立即重新检查整套物料：已满足时转为已齐套待派工，'
          '仍有缺口时保持待料并在后续到货后自动转产。确认继续？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认解除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runCommand(
      () => ref
          .read(productionPlanRepositoryProvider)
          .transitionExecutionSegment(
            widget.planId,
            segment.id,
            action: 'release-defer',
            expectedVersion: segment.lockVersion,
            idempotencyKey: businessIdempotencyKey(
              'production-segment-release-defer',
              '${segment.id}|${segment.lockVersion}|${segment.status}',
            ),
          ),
      '已解除人工暂缓并重新检查齐套',
    );
  }

  Future<void> _transition(
    ProductionExecutionSegmentView segment,
    String action,
  ) async {
    final isDispatch = action == 'dispatch';
    final isStart = action == 'start';
    if (isDispatch && !segment.materialReady) {
      context.appError('物料尚未完整齐套，不能派工');
      return;
    }
    if (isDispatch &&
        (segment.workshopDepartmentId == null ||
            segment.responsibleEmployeeId == null)) {
      context.appError('派工前必须指定生产车间和负责人');
      return;
    }
    if (isStart && !segment.materialIssued) {
      context.appError('仓库尚未完成全部生产领料，不能开工');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDispatch ? '确认派工' : '确认开工'),
        content: Text(
          isDispatch
              ? '派工后任务会进入班组待开工列表，物料占用保持不变。'
              : '仓库已完成本执行段全部发料。开工后可分批报工，'
                    '每次报工必须关联这个执行子计划。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isDispatch ? '确认派工' : '确认开工'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runCommand(
      () => ref
          .read(productionPlanRepositoryProvider)
          .transitionExecutionSegment(
            widget.planId,
            segment.id,
            action: action,
            expectedVersion: segment.lockVersion,
            idempotencyKey: businessIdempotencyKey(
              'production-segment-$action',
              '${segment.id}|${segment.lockVersion}|${segment.status}',
            ),
          ),
      isDispatch ? '已派工' : '已开工',
    );
  }

  Future<void> _runCommand(
    Future<ProductionExecutionSegmentView> Function() run,
    String success,
  ) async {
    if (_busy || _batchStarting) return;
    setState(() => _busy = true);
    try {
      final updated = await run();
      if (!mounted) return;
      setState(() {
        _segments = [
          for (final segment
              in _segments ?? const <ProductionExecutionSegmentView>[])
            if (segment.id == updated.id) updated else segment,
        ];
      });
      context.appSuccess(success);
      await widget.onChanged?.call();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
      await _load();
    } catch (_) {
      if (mounted) context.appError('操作失败，请刷新后重试');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isStartSelectable(ProductionExecutionSegmentView segment) =>
      widget.canStart &&
      segment.status == 'DISPATCHED' &&
      segment.materialIssued;

  List<ProductionExecutionSegmentView> get _startableSegments => [
    for (final segment in _segments ?? const <ProductionExecutionSegmentView>[])
      if (_isStartSelectable(segment)) segment,
  ];

  void _toggleStartSelection(
    ProductionExecutionSegmentView segment,
    bool selected,
  ) {
    if (!_isStartSelectable(segment) || _batchStarting) return;
    setState(() {
      if (selected) {
        _selectedStartIds.add(segment.id);
      } else {
        _selectedStartIds.remove(segment.id);
      }
    });
  }

  void _selectAllStartable() {
    if (_batchStarting) return;
    setState(() {
      _selectedStartIds
        ..clear()
        ..addAll(_startableSegments.map((segment) => segment.id));
    });
  }

  void _clearStartSelection() {
    if (_batchStarting || _selectedStartIds.isEmpty) return;
    setState(_selectedStartIds.clear);
  }

  Future<void> _batchStart() async {
    if (_batchStarting || _busy || _selectedStartIds.isEmpty) return;
    final selected = [
      for (final segment
          in _segments ?? const <ProductionExecutionSegmentView>[])
        if (_selectedStartIds.contains(segment.id) &&
            _isStartSelectable(segment))
          segment,
    ];
    if (selected.length != _selectedStartIds.length) {
      setState(() {
        _selectedStartIds
          ..clear()
          ..addAll(selected.map((segment) => segment.id));
      });
      context.appWarning('部分执行子计划状态已更新，请重新确认选择', force: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量开工(${selected.length} 项)'),
        content: const Text(
          '系统会在同一事务中校验全部执行子计划的状态、发料进度和版本。'
          '任一项已变化都会整体失败，不会出现部分开工。确认继续？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('确认批量开工'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _batchStarting = true);
    try {
      final updated = await ref
          .read(productionPlanRepositoryProvider)
          .batchStartExecutionSegments(
            widget.planId,
            items: [
              for (final segment in selected)
                ProductionExecutionBatchStartItem(
                  segmentId: segment.id,
                  expectedVersion: segment.lockVersion,
                  idempotencyKey: businessIdempotencyKey(
                    'production-segment-batch-start',
                    '${segment.id}|${segment.lockVersion}|${segment.status}',
                  ),
                ),
            ],
          );
      if (!mounted) return;
      setState(() {
        _selectedStartIds.clear();
        if (updated.isNotEmpty) {
          final updates = {for (final segment in updated) segment.id: segment};
          _segments = [
            for (final segment
                in _segments ?? const <ProductionExecutionSegmentView>[])
              updates[segment.id] ?? segment,
          ];
        }
      });
      context.appSuccess('已批量开工 ${selected.length} 个执行子计划');
      await _load();
      await widget.onChanged?.call();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
      await _load();
    } catch (_) {
      if (mounted) context.appError('批量开工失败，已刷新最新状态', force: true);
      await _load();
    } finally {
      if (mounted) setState(() => _batchStarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
    final theme = Theme.of(context);
    if (segments == null && _error == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(UtenSpacing.s16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (segments!.isEmpty) {
      return Card(
        key: const Key('production-execution-segments-empty'),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '执行子计划',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '当前尚未形成执行子计划。若计划刚审核，请先刷新；仍为空时请回到“物料分析准备”核对来源，'
                          '或联系系统管理员。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Align(
                alignment: Alignment.centerLeft,
                child: UtenButton(
                  key: const Key('production-execution-segments-empty-refresh'),
                  type: UtenButtonType.tonal,
                  icon: Icons.refresh_rounded,
                  isLoading: _loading,
                  onPressed: _loading || _busy ? null : _load,
                  child: const Text('刷新执行状态'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final ready = segments.where((item) => item.status == 'READY').length;
    final waiting = segments
        .where((item) => item.status == 'WAITING' && item.autoPromoteWhenReady)
        .length;
    final deferred = segments
        .where((item) => item.status == 'WAITING' && !item.autoPromoteWhenReady)
        .length;
    final running = segments
        .where(
          (item) => item.status == 'DISPATCHED' || item.status == 'IN_PROGRESS',
        )
        .length;
    final completed = segments
        .where((item) => item.status == 'COMPLETED')
        .length;
    final startableCount = _startableSegments.length;
    return Card(
      key: const Key('production-execution-segments-card'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '执行子计划',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '待派工/发料 $ready · 待料 $waiting · 人工暂缓 $deferred · '
                        '执行中 $running · 已完成 $completed',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '操作已直接显示在卡片上；点击卡片或“详情”查看完整状态。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新执行状态',
                  onPressed: _busy || _batchStarting || _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (startableCount > 0 || _selectedStartIds.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              _selectionToolbar(theme, startableCount),
            ],
            const SizedBox(height: UtenSpacing.s8),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = UtenSpacing.s12;
                final twoColumns = constraints.maxWidth >= 1040;
                final cardWidth = twoColumns
                    ? (constraints.maxWidth - gap) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final segment in segments)
                      SizedBox(
                        width: cardWidth,
                        child: _segmentCard(theme, segment),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionToolbar(ThemeData theme, int startableCount) {
    final allSelected =
        startableCount > 0 && _selectedStartIds.length == startableCount;
    return Container(
      key: const Key('production-execution-start-selection-toolbar'),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.28),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '已选 ${_selectedStartIds.length} 项 · 可开工 $startableCount 项',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          UtenButton(
            key: const Key('production-execution-select-all-startable'),
            type: UtenButtonType.tonal,
            size: UtenButtonSize.small,
            icon: Icons.select_all_rounded,
            onPressed: allSelected || _batchStarting
                ? null
                : _selectAllStartable,
            child: const Text('全选可开工'),
          ),
          TextButton(
            key: const Key('production-execution-clear-start-selection'),
            onPressed: _selectedStartIds.isEmpty || _batchStarting
                ? null
                : _clearStartSelection,
            child: const Text('清空'),
          ),
          UtenButton(
            key: const Key('production-execution-batch-start'),
            size: UtenButtonSize.small,
            icon: Icons.play_arrow_rounded,
            isLoading: _batchStarting,
            onPressed: _selectedStartIds.isEmpty || _busy || _batchStarting
                ? null
                : _batchStart,
            child: Text('批量开工(${_selectedStartIds.length})'),
          ),
        ],
      ),
    );
  }

  Widget _segmentCard(ThemeData theme, ProductionExecutionSegmentView segment) {
    final selected = _selectedStartIds.contains(segment.id);
    final focused = _selectedId == segment.id;
    final startSelectable = _isStartSelectable(segment);
    final assignment = [
      segment.workshopName,
      segment.teamName,
    ].where((value) => value?.isNotEmpty == true).join(' / ');
    final product = [
      segment.productName,
      segment.productCode,
    ].where((value) => value?.isNotEmpty == true).join(' · ');
    final borderColor = selected || focused
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    final background = selected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.34)
        : _rowColor(theme, segment) ?? theme.colorScheme.surfaceContainerLowest;

    return Semantics(
      container: true,
      selected: selected,
      label: '执行子计划 ${segment.segmentCode}',
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: UtenRadius.mdAll,
          side: BorderSide(color: borderColor, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _busy || _batchStarting ? null : () => _openSegment(segment),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (startSelectable) ...[
                      Semantics(
                        label: '选择 ${segment.segmentCode} 批量开工',
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Checkbox(
                            key: ValueKey(
                              'production-execution-start-select-${segment.id}',
                            ),
                            value: selected,
                            onChanged: _batchStarting
                                ? null
                                : (value) => _toggleStartSelection(
                                    segment,
                                    value ?? false,
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            segment.segmentCode,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            product.isEmpty ? '未命名产品' : product,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    _cardStatusBadge(theme, segment),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s12),
                _segmentMetrics(theme, segment),
                const SizedBox(height: UtenSpacing.s12),
                _cardFact(
                  theme,
                  Icons.verified_outlined,
                  '品质 / 入库',
                  '${_qualityProgressText(segment)} / '
                      '${_finishedInboundProgressText(segment)}',
                ),
                _cardFact(
                  theme,
                  Icons.inventory_2_outlined,
                  '物料',
                  _materialProgressText(segment),
                ),
                _cardFact(
                  theme,
                  Icons.factory_outlined,
                  '车间 / 班组',
                  assignment.isEmpty ? '待分配' : assignment,
                ),
                _cardFact(
                  theme,
                  Icons.badge_outlined,
                  '负责人',
                  segment.responsibleEmployeeName ?? '待分配',
                ),
                _cardFact(
                  theme,
                  Icons.date_range_outlined,
                  '计划开工 / 完工',
                  '${segment.planBeginDate ?? '待排'} / '
                      '${segment.planEndDate ?? '待排'}',
                ),
                const SizedBox(height: UtenSpacing.s8),
                Divider(color: theme.colorScheme.outlineVariant),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  alignment: WrapAlignment.end,
                  children: _segmentCardActions(segment),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardStatusBadge(
    ThemeData theme,
    ProductionExecutionSegmentView segment,
  ) {
    final color = switch (segment.status) {
      'WAITING' => theme.colorScheme.error,
      'READY' || 'COMPLETED' => Colors.green.shade700,
      'DISPATCHED' || 'IN_PROGRESS' => theme.colorScheme.primary,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        _segmentStatusText(segment),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _segmentMetrics(
    ThemeData theme,
    ProductionExecutionSegmentView segment,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = UtenSpacing.s8;
        final columns = constraints.maxWidth >= 420 ? 3 : 2;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            _metricTile(
              theme,
              width: width,
              label: '计划数',
              value: _number(segment.plannedQty),
            ),
            _metricTile(
              theme,
              width: width,
              label: '有效报工',
              value: _number(segment.reportedQty),
              valueColor: segment.reportedQty > 0
                  ? theme.colorScheme.primary
                  : null,
            ),
            _metricTile(
              theme,
              width: width,
              label: '待补',
              value: _number(segment.remainingQty),
              valueColor: segment.remainingQty > 0
                  ? theme.colorScheme.tertiary
                  : Colors.green.shade700,
            ),
          ],
        );
      },
    );
  }

  Widget _metricTile(
    ThemeData theme, {
    required double width,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.78),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardFact(ThemeData theme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  List<Widget> _segmentCardActions(ProductionExecutionSegmentView segment) {
    final commandBusy = _busy || _batchStarting;
    final assigned =
        segment.workshopDepartmentId != null &&
        segment.responsibleEmployeeId != null;
    return [
      if (widget.canAssign &&
          (segment.status == 'READY' || segment.status == 'WAITING'))
        UtenButton(
          key: ValueKey('production-execution-assign-${segment.id}'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.edit_location_alt_outlined,
          onPressed: commandBusy
              ? null
              : () => _handleSegmentAction(segment, _SegmentAction.assign),
          child: const Text('调整分配'),
        ),
      if (widget.canReleaseDefer &&
          segment.status == 'WAITING' &&
          !segment.autoPromoteWhenReady)
        UtenButton(
          key: ValueKey('production-execution-release-${segment.id}'),
          type: UtenButtonType.tonal,
          size: UtenButtonSize.small,
          icon: Icons.play_circle_outline_rounded,
          onPressed: commandBusy
              ? null
              : () =>
                    _handleSegmentAction(segment, _SegmentAction.releaseDefer),
          child: const Text('解除人工暂缓'),
        ),
      if (widget.canDispatch && segment.status == 'READY')
        UtenButton(
          key: ValueKey('production-execution-dispatch-${segment.id}'),
          size: UtenButtonSize.small,
          icon: Icons.assignment_turned_in_outlined,
          onPressed: commandBusy || !segment.materialReady || !assigned
              ? null
              : () => _handleSegmentAction(segment, _SegmentAction.dispatch),
          onDisabledTap: commandBusy
              ? null
              : () => context.appWarning(
                  !segment.materialReady ? '物料尚未完整齐套，不能派工' : '派工前必须指定生产车间和负责人',
                  force: true,
                ),
          child: const Text('派工'),
        ),
      if (widget.canStart && segment.status == 'DISPATCHED')
        UtenButton(
          key: ValueKey('production-execution-start-${segment.id}'),
          size: UtenButtonSize.small,
          icon: Icons.play_arrow_rounded,
          onPressed: commandBusy || !segment.materialIssued
              ? null
              : () => _handleSegmentAction(segment, _SegmentAction.start),
          onDisabledTap: commandBusy
              ? null
              : () => context.appWarning('仓库尚未完成全部生产领料，不能开工', force: true),
          child: const Text('确认开工'),
        ),
      if (widget.canReport && _canReportSegment(segment))
        UtenButton(
          key: ValueKey('production-execution-report-${segment.id}'),
          type: UtenButtonType.tonal,
          size: UtenButtonSize.small,
          icon: Icons.fact_check_outlined,
          onPressed: commandBusy
              ? null
              : () => _handleSegmentAction(segment, _SegmentAction.report),
          child: Text(
            segment.ordinaryRemainingQty > 0
                ? '分批报工'
                : segment.fqcReworkAvailableQty > 0
                ? '返工再检报工'
                : segment.fqcReplacementReadyQty > 0
                ? '补产完工报工'
                : '分批报工',
          ),
        ),
      UtenButton(
        key: ValueKey('production-execution-detail-${segment.id}'),
        type: UtenButtonType.ghost,
        size: UtenButtonSize.small,
        icon: Icons.info_outline_rounded,
        onPressed: commandBusy ? null : () => _openSegment(segment),
        child: const Text('详情'),
      ),
    ];
  }

  Widget _dateField(
    BuildContext context,
    String label,
    DateTime? value,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.date_range_rounded, size: 18),
        ),
        child: Text(_dateText(value) ?? '待排定'),
      ),
    );
  }
}

enum _SegmentAction { assign, releaseDefer, dispatch, start, report }

class _ExecutionSegmentDetail extends StatelessWidget {
  const _ExecutionSegmentDetail({
    required this.segment,
    required this.canAssign,
    required this.canReleaseDefer,
    required this.canDispatch,
    required this.canStart,
    required this.canReport,
  });

  final ProductionExecutionSegmentView segment;
  final bool canAssign;
  final bool canReleaseDefer;
  final bool canDispatch;
  final bool canStart;
  final bool canReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assignment = [
      segment.workshopName,
      segment.teamName,
    ].where((value) => value?.isNotEmpty == true).join(' / ');
    final product = [
      segment.productName,
      segment.productCode,
    ].where((value) => value?.isNotEmpty == true).join(' · ');
    final hasCommandPermission =
        canAssign || canReleaseDefer || canDispatch || canStart || canReport;
    final hasAction =
        (canReleaseDefer &&
            segment.status == 'WAITING' &&
            !segment.autoPromoteWhenReady) ||
        (canAssign &&
            (segment.status == 'READY' || segment.status == 'WAITING')) ||
        (canDispatch && segment.status == 'READY') ||
        (canStart && segment.status == 'DISPATCHED') ||
        (canReport && _canReportSegment(segment));

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '执行子计划详情',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          segment.segmentCode,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _statusBadge(theme, segment),
                  const SizedBox(width: UtenSpacing.s4),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _detailRow(
                      theme,
                      '产品',
                      product.isEmpty ? '未命名产品' : product,
                    ),
                    _detailRow(theme, '计划数量', _number(segment.plannedQty)),
                    _detailRow(theme, '有效报工', _number(segment.reportedQty)),
                    _detailRow(
                      theme,
                      '普通待报',
                      _number(segment.ordinaryRemainingQty),
                    ),
                    _detailRow(
                      theme,
                      '品质判定',
                      _qualityProgressText(segment),
                      valueColor: segment.fqcFailedQty > 0
                          ? theme.colorScheme.error
                          : segment.fqcPendingQty > 0
                          ? theme.colorScheme.tertiary
                          : null,
                    ),
                    _detailRow(
                      theme,
                      '仓库入库',
                      _finishedInboundProgressText(segment),
                      valueColor: segment.finishedInboundPendingQty > 0
                          ? theme.colorScheme.tertiary
                          : segment.inboundQty > 0
                          ? Colors.green.shade700
                          : null,
                    ),
                    _detailRow(
                      theme,
                      '物料齐套',
                      segment.materialReady
                          ? '已齐套 · ${segment.materialKindCount} 种物料'
                          : '待料 · 缺 ${segment.shortageKindCount} 种物料',
                      valueColor: segment.materialReady
                          ? Colors.green.shade700
                          : theme.colorScheme.error,
                    ),
                    _detailRow(
                      theme,
                      '仓库发料',
                      segment.materialIssued
                          ? segment.materialDemandCount == 0
                                ? '零物料任务 · 无需领料'
                                : '已全部发料 · ${segment.fullyIssuedDemandCount}/'
                                      '${segment.materialDemandCount} 项'
                          : '待发料 · ${segment.fullyIssuedDemandCount}/'
                                '${segment.materialDemandCount} 项',
                      valueColor: segment.materialIssued
                          ? Colors.green.shade700
                          : theme.colorScheme.tertiary,
                    ),
                    _detailRow(
                      theme,
                      '车间 / 班组',
                      assignment.isEmpty ? '待分配' : assignment,
                    ),
                    _detailRow(
                      theme,
                      '负责人',
                      segment.responsibleEmployeeName ?? '待分配',
                    ),
                    _detailRow(theme, '计划开工', segment.planBeginDate ?? '待排定'),
                    _detailRow(theme, '计划完工', segment.planEndDate ?? '待排定'),
                    const SizedBox(height: UtenSpacing.s8),
                    if (segment.status == 'WAITING' &&
                        !segment.autoPromoteWhenReady)
                      _notice(
                        theme,
                        '当前为人工暂缓，不会自动转产；解除暂缓后会立即重算齐套，'
                        '未齐套时继续等待后续到货。',
                        theme.colorScheme.tertiary,
                      )
                    else if (segment.status == 'WAITING')
                      _notice(
                        theme,
                        '等待整套物料补齐；当前不会占用零散库存，到货齐套后自动转产。',
                        theme.colorScheme.error,
                      )
                    else if (segment.status == 'DISPATCHED' &&
                        !segment.materialIssued)
                      _notice(
                        theme,
                        '任务已派工，但仓库尚未按领料单完成全部实物发料；发料完成前不能开工。',
                        theme.colorScheme.tertiary,
                      )
                    else if (segment.status == 'READY' &&
                        !segment.materialIssued &&
                        hasCommandPermission)
                      _notice(
                        theme,
                        '整套物料已预留并生成领料单。可先完成车间分配和派工；'
                        '仓库全部实际发料且派工完成后才能确认开工。',
                        theme.colorScheme.tertiary,
                      )
                    else if (segment.status == 'READY' && hasCommandPermission)
                      _notice(
                        theme,
                        '仓库已完成全部发料；请完成车间分配并派工，随后确认开工。',
                        theme.colorScheme.primary,
                      )
                    else if (segment.status == 'IN_PROGRESS' &&
                        !_canReportSegment(segment))
                      _notice(
                        theme,
                        _postReportNextStep(segment),
                        segment.fqcFailedQty > 0
                            ? theme.colorScheme.error
                            : theme.colorScheme.tertiary,
                      )
                    else if (segment.status == 'COMPLETED')
                      _notice(
                        theme,
                        '合格品已足额入库，且该执行段材料已结清。',
                        Colors.green.shade700,
                      )
                    else if (!hasAction)
                      _notice(
                        theme,
                        hasCommandPermission
                            ? '当前状态没有可执行操作。'
                            : '当前账号可查看详情，但没有生产操作权限。',
                        theme.colorScheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '可用操作已显示在执行子计划卡片上。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(
    ThemeData theme,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: valueColor,
                fontWeight: valueColor == null ? null : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(ThemeData theme, String text, Color color) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }

  Widget _statusBadge(ThemeData theme, ProductionExecutionSegmentView segment) {
    final status = segment.status;
    final color = switch (status) {
      'WAITING' => theme.colorScheme.error,
      'READY' || 'COMPLETED' => Colors.green.shade700,
      'DISPATCHED' || 'IN_PROGRESS' => theme.colorScheme.primary,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        _segmentStatusText(segment),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _segmentStatusText(ProductionExecutionSegmentView segment) =>
    segment.status == 'WAITING' && !segment.autoPromoteWhenReady
    ? '人工暂缓'
    : segment.status == 'READY' && !segment.materialIssued
    ? '已齐套·待发料'
    : segment.status == 'DISPATCHED' && !segment.materialIssued
    ? '已派工·待发料'
    : segment.status == 'IN_PROGRESS' && segment.ordinaryRemainingQty > 0
    ? '生产中·可继续报工'
    : segment.status == 'IN_PROGRESS' && segment.fqcReworkAvailableQty > 0
    ? '返工再检·待报工'
    : segment.status == 'IN_PROGRESS' && segment.fqcReplacementReadyQty > 0
    ? '补产物料已发·待报工'
    : segment.status == 'IN_PROGRESS' && segment.fqcReplacementAvailableQty > 0
    ? '补产待齐套/发料'
    : segment.status == 'IN_PROGRESS' && !_canReportSegment(segment)
    ? segment.finishedInboundRejectedQty > 0 &&
              segment.finishedInboundPendingQty > 0
          ? '仓库拒收·待重新交付'
          : segment.finishedInboundRejectedQty > 0
          ? '仓库拒收·待处理'
          : segment.fqcPendingQty > 0
          ? '已报完·待品质'
          : segment.finishedInboundPendingQty > 0
          ? '品质通过·待点收'
          : segment.fqcFailedQty > 0
          ? '品质异常·待处理'
          : '已报完·待入库'
    : _statusText(segment.status);

bool _canReportSegment(ProductionExecutionSegmentView segment) =>
    segment.status == 'IN_PROGRESS' &&
    (segment.ordinaryRemainingQty > 0.000001 ||
        segment.fqcReworkAvailableQty > 0.000001 ||
        segment.fqcReplacementReadyQty > 0.000001);

String _qualityProgressText(ProductionExecutionSegmentView segment) {
  if (segment.reportedQty <= 0 &&
      segment.fqcPendingQty <= 0 &&
      segment.fqcPassedQty <= 0 &&
      segment.fqcFailedQty <= 0) {
    return '尚未报工';
  }
  final parts = <String>[
    if (segment.fqcPendingQty > 0) '待检 ${_number(segment.fqcPendingQty)}',
    if (segment.fqcPassedQty > 0) '通过 ${_number(segment.fqcPassedQty)}',
    if (segment.fqcFailedQty > 0) '不合格 ${_number(segment.fqcFailedQty)}',
    if (segment.fqcReworkAvailableQty > 0)
      '返工再检待报 ${_number(segment.fqcReworkAvailableQty)}',
    if (segment.fqcReplacementReadyQty > 0)
      '补产物料已发待报 ${_number(segment.fqcReplacementReadyQty)}'
    else if (segment.fqcReplacementAvailableQty > 0)
      '报废/拒收补产待齐套 ${_number(segment.fqcReplacementAvailableQty)}',
  ];
  return parts.isEmpty ? '等待品质任务登记' : parts.join(' · ');
}

String _finishedInboundProgressText(ProductionExecutionSegmentView segment) {
  final parts = <String>[
    if (segment.finishedInboundRejectedQty > 0)
      '仓库拒收 ${_number(segment.finishedInboundRejectedQty)}',
    if (segment.finishedInboundPendingQty > 0)
      '待点收 ${_number(segment.finishedInboundPendingQty)}',
    if (segment.inboundQty > 0) '已入库 ${_number(segment.inboundQty)}',
  ];
  return parts.isEmpty ? '尚未形成合格入库' : parts.join(' · ');
}

String _postReportNextStep(ProductionExecutionSegmentView segment) {
  final parts = <String>[
    if (segment.fqcPendingQty > 0) '待品质判定 ${_number(segment.fqcPendingQty)}',
    if (segment.finishedInboundRejectedQty > 0)
      '仓库拒收 ${_number(segment.finishedInboundRejectedQty)}，已保留同源重新交付任务',
    if (segment.finishedInboundPendingQty > 0)
      '待仓库点收 ${_number(segment.finishedInboundPendingQty)}',
    if (segment.inboundQty > 0) '已入库 ${_number(segment.inboundQty)}',
    if (segment.fqcFailedQty > 0)
      '品质不合格 ${_number(segment.fqcFailedQty)}，等待返工/补产处理',
    if (segment.fqcReplacementAvailableQty > 0)
      '补产 ${_number(segment.fqcReplacementAvailableQty)}，'
          '等待重新齐套和发料后才能报工',
  ];
  if (parts.isEmpty) {
    return '本执行段已全部报工，等待品质任务登记或仓库入库状态刷新。';
  }
  return '本执行段已全部报工：${parts.join('；')}。';
}

String _materialProgressText(ProductionExecutionSegmentView segment) {
  if (!segment.materialReady) return '缺 ${segment.shortageKindCount} 种';
  if (segment.materialDemandCount == 0) return '零物料 · 无需发料';
  return segment.materialIssued
      ? '已发料 ${segment.fullyIssuedDemandCount}/${segment.materialDemandCount}'
      : '已预留 · 发料 ${segment.fullyIssuedDemandCount}/'
            '${segment.materialDemandCount}';
}

String _statusText(String status) => switch (status) {
  'WAITING' => '待料',
  'READY' => '已齐套·待派工',
  'DISPATCHED' => '已派工',
  'IN_PROGRESS' => '生产中',
  'COMPLETED' => '已完成',
  'CANCELLED' => '已取消',
  'REVERSED' => '已红冲',
  _ => status,
};

Color? _rowColor(ThemeData theme, ProductionExecutionSegmentView segment) =>
    switch (segment.status) {
      'WAITING' => theme.colorScheme.errorContainer.withValues(alpha: 0.22),
      'READY' => Colors.green.withValues(alpha: 0.06),
      'DISPATCHED' || 'IN_PROGRESS' =>
        theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
      'COMPLETED' => Colors.green.withValues(alpha: 0.11),
      _ => null,
    };

String _number(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(3);

String? _dateText(DateTime? value) {
  if (value == null) return null;
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
