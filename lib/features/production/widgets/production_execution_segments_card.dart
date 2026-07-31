import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../department/models/department_node.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/production_execution_planning.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';

/// Confirmed execution segments and their operational state transitions.
///
/// A row is selected before acting, which keeps the shared
/// [MasterDataTableView] read-only while assignment and transitions remain
/// explicit, version-checked commands.
class ProductionExecutionSegmentsCard extends ConsumerStatefulWidget {
  const ProductionExecutionSegmentsCard({
    super.key,
    required this.planId,
    required this.canEdit,
    required this.canReport,
    this.onChanged,
  });

  final String planId;
  final bool canEdit;
  final bool canReport;
  final Future<void> Function()? onChanged;

  @override
  ConsumerState<ProductionExecutionSegmentsCard> createState() =>
      _ProductionExecutionSegmentsCardState();
}

class _ProductionExecutionSegmentsCardState
    extends ConsumerState<ProductionExecutionSegmentsCard> {
  List<ProductionExecutionSegmentView>? _segments;
  String? _selectedId;
  String? _error;
  bool _busy = false;

  ProductionExecutionSegmentView? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    return _segments?.where((segment) => segment.id == id).firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .executionSegments(widget.planId);
      if (!mounted) return;
      setState(() {
        _segments = result;
        _error = null;
        if (_selectedId != null &&
            !result.any((segment) => segment.id == _selectedId)) {
          _selectedId = null;
        }
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '执行子计划加载失败');
    }
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
                          : (value) => setDialogState(
                              () => teamId = value == null || value.isEmpty
                                  ? null
                                  : value,
                            ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    UtenEmployeePicker(
                      key: ValueKey(responsible?.id ?? ''),
                      initial: responsible,
                      hint: '选择负责人',
                      loader: (keyword) async {
                        final result = await ref
                            .read(employeeRepositoryProvider)
                            .list(size: 30, search: keyword);
                        return [
                          for (final employee in result.items)
                            UtenEmployeePickerItem(
                              id: employee.id,
                              name: employee.fullName,
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

  Future<void> _transition(
    ProductionExecutionSegmentView segment,
    String action,
  ) async {
    final isDispatch = action == 'dispatch';
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDispatch ? '确认派工' : '确认开工'),
        content: Text(
          isDispatch
              ? '派工后任务会进入班组待开工列表，物料占用保持不变。'
              : '开工后即可分批报工；每次报工必须关联这个执行子计划。',
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
    if (_busy) return;
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

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (segments!.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final selected = _selected;
    final ready = segments.where((item) => item.status == 'READY').length;
    final waiting = segments.where((item) => item.status == 'WAITING').length;
    final running = segments
        .where(
          (item) => item.status == 'DISPATCHED' || item.status == 'IN_PROGRESS',
        )
        .length;
    final completed = segments
        .where((item) => item.status == 'COMPLETED')
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
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
                        '可开工 $ready · 待料 $waiting · 执行中 $running · 已完成 $completed',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新执行状态',
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            MasterDataTableView<ProductionExecutionSegmentView>(
              embedded: true,
              columns: [
                MasterColumnDef(
                  key: 'segmentCode',
                  label: '子计划编号',
                  width: 135,
                  value: (item) => item.segmentCode,
                ),
                MasterColumnDef(
                  key: 'product',
                  label: '产品',
                  width: 190,
                  value: (item) =>
                      item.productName ?? item.productCode ?? '未命名产品',
                ),
                MasterColumnDef(
                  key: 'status',
                  label: '状态',
                  width: 95,
                  value: (item) => _statusText(item.status),
                ),
                MasterColumnDef(
                  key: 'planned',
                  label: '计划数',
                  width: 82,
                  type: 'number',
                  value: (item) => _number(item.plannedQty),
                ),
                MasterColumnDef(
                  key: 'reported',
                  label: '已报 / 剩余',
                  width: 105,
                  type: 'number',
                  value: (item) =>
                      '${_number(item.reportedQty)} / ${_number(item.remainingQty)}',
                ),
                MasterColumnDef(
                  key: 'material',
                  label: '物料',
                  width: 120,
                  value: (item) => item.materialReady
                      ? '齐套 ${item.materialKindCount} 种'
                      : '缺 ${item.shortageKindCount} 种',
                ),
                MasterColumnDef(
                  key: 'workshop',
                  label: '车间 / 班组',
                  width: 160,
                  value: (item) => [
                    item.workshopName,
                    item.teamName,
                  ].where((value) => value?.isNotEmpty == true).join(' / '),
                ),
                MasterColumnDef(
                  key: 'responsible',
                  label: '负责人',
                  width: 105,
                  value: (item) => item.responsibleEmployeeName ?? '待分配',
                ),
                MasterColumnDef(
                  key: 'dates',
                  label: '开工 / 完工',
                  width: 190,
                  value: (item) =>
                      '${item.planBeginDate ?? '待排'} / ${item.planEndDate ?? '待排'}',
                ),
              ],
              items: segments,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              onRowTap: (item) => setState(() => _selectedId = item.id),
              rowColor: (item) => _rowColor(theme, item),
              emptyMessage: '暂无执行子计划',
            ),
            if (selected != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              _selectedActions(theme, selected),
            ],
          ],
        ),
      ),
    );
  }

  Widget _selectedActions(
    ThemeData theme,
    ProductionExecutionSegmentView segment,
  ) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${segment.segmentCode} · ${_statusText(segment.status)}',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (widget.canEdit &&
              (segment.status == 'READY' || segment.status == 'WAITING'))
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _assign(segment),
              icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
              label: const Text('调整分配'),
            ),
          if (widget.canEdit && segment.status == 'READY')
            UtenButton(
              icon: Icons.assignment_turned_in_outlined,
              isLoading: _busy,
              onPressed: () => _transition(segment, 'dispatch'),
              child: const Text('派工'),
            ),
          if (widget.canEdit && segment.status == 'DISPATCHED')
            UtenButton(
              icon: Icons.play_arrow_rounded,
              isLoading: _busy,
              onPressed: () => _transition(segment, 'start'),
              child: const Text('确认开工'),
            ),
          if (widget.canReport && segment.status == 'IN_PROGRESS')
            UtenButton(
              icon: Icons.fact_check_outlined,
              onPressed: () => context.push(
                Uri(
                  path: RoutePath.productionDailyReportNew(),
                  queryParameters: {'executionSegmentId': segment.id},
                ).toString(),
              ),
              child: const Text('分批报工'),
            ),
          if (segment.status == 'WAITING')
            Text(
              '等待整套物料补齐；当前不会占用零散库存。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (segment.status == 'COMPLETED')
            Text(
              '合格品已足额入库，且该执行段材料已结清。',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
            ),
        ],
      ),
    );
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

String _statusText(String status) => switch (status) {
  'WAITING' => '待料',
  'READY' => '可开工',
  'DISPATCHED' => '已派工',
  'IN_PROGRESS' => '生产中',
  'COMPLETED' => '已完成',
  'CANCELED' => '已取消',
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
