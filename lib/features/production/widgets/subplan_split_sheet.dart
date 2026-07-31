// 「一键生成子计划」编辑抽屉。
//
// MRP 给出候选自制件，用户在 UtenEditableGrid 中逐行校对选择、数量、车间、
// 负责人及计划日期。确认后返回原子 planning-package 请求，由详情页提交。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/models/department_node.dart';
import '../../employee/repositories/employee_repository.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';

/// 打开唯一的「一键生成子计划」编辑抽屉；null 表示取消。
Future<PlanningPackageRequest?> showSubplanSplitSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<MrpRow> selfMadeRows,
  int purchaseShortageCount = 0,
  bool usingLegacyMrp = false,
  String? defaultDepartmentId,
  String? defaultWorkshopName,
  String? defaultWorkerId,
  String? defaultWorkerName,
  String? defaultPlanBeginDate,
  String? defaultPlanEndDate,
}) {
  final sheet = _SplitSheet(
    rows: selfMadeRows,
    purchaseShortageCount: purchaseShortageCount,
    usingLegacyMrp: usingLegacyMrp,
    defaultDepartmentId: defaultDepartmentId,
    defaultWorkshopName: defaultWorkshopName,
    defaultWorkerId: defaultWorkerId,
    defaultWorkerName: defaultWorkerName,
    defaultPlanBeginDate: defaultPlanBeginDate,
    defaultPlanEndDate: defaultPlanEndDate,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<PlanningPackageRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.96,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<PlanningPackageRequest>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: UtenAnim.normal,
    pageBuilder: (ctx, _, _) {
      final viewportWidth = MediaQuery.sizeOf(ctx).width;
      final panelWidth = viewportWidth < 920 ? viewportWidth * 0.92 : 840.0;
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          elevation: 12,
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: sheet,
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: UtenAnim.standard)),
      child: child,
    ),
  );
}

class _SubplanGridRow extends EditableGridRow {
  _SubplanGridRow(
    this.source, {
    required this.onChanged,
    this.departmentId,
    this.workshopName,
    String? workerId,
    String? workerName,
    String? planBeginDate,
    String? planEndDate,
  }) : worker = workerId == null
           ? null
           : UtenEmployeePickerItem(
               id: workerId,
               name: workerName?.isNotEmpty == true ? workerName! : '已选负责人',
             ),
       planBeginDate = DateTime.tryParse(planBeginDate ?? ''),
       planEndDate = DateTime.tryParse(planEndDate ?? ''),
       qty = TextEditingController(
         text: _formatNumber(source.planningShortage),
       ) {
    qty.addListener(onChanged);
  }

  final MrpRow source;
  final VoidCallback onChanged;
  final ValueNotifier<bool> selectedNotifier = ValueNotifier<bool>(true);
  final TextEditingController qty;

  String? departmentId;
  String? workshopName;
  UtenEmployeePickerItem? worker;
  DateTime? planBeginDate;
  DateTime? planEndDate;

  bool get selected => selectedNotifier.value;

  void setSelected(bool value, {bool notify = true}) {
    if (selectedNotifier.value == value) return;
    selectedNotifier.value = value;
    if (notify) onChanged();
  }

  void changed() => onChanged();

  @override
  void dispose() {
    selectedNotifier.dispose();
    qty.dispose();
    super.dispose();
  }

  static String _formatNumber(double? value) {
    if (value == null) return '';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }
}

class _SplitSheet extends ConsumerStatefulWidget {
  const _SplitSheet({
    required this.rows,
    required this.purchaseShortageCount,
    required this.usingLegacyMrp,
    this.defaultDepartmentId,
    this.defaultWorkshopName,
    this.defaultWorkerId,
    this.defaultWorkerName,
    this.defaultPlanBeginDate,
    this.defaultPlanEndDate,
  });

  final List<MrpRow> rows;
  final int purchaseShortageCount;
  final bool usingLegacyMrp;
  final String? defaultDepartmentId;
  final String? defaultWorkshopName;
  final String? defaultWorkerId;
  final String? defaultWorkerName;
  final String? defaultPlanBeginDate;
  final String? defaultPlanEndDate;

  @override
  ConsumerState<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends ConsumerState<_SplitSheet> {
  late final UtenEditableGridController<_SubplanGridRow> _grid;
  bool _generatePurchaseRequest = true;
  bool _dirty = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _generatePurchaseRequest = widget.purchaseShortageCount > 0;
    _grid = UtenEditableGridController(
      initial: [
        for (final row in widget.rows)
          _SubplanGridRow(
            row,
            onChanged: _markDirty,
            departmentId: widget.defaultDepartmentId,
            workshopName: widget.defaultWorkshopName,
            workerId: widget.defaultWorkerId,
            workerName: widget.defaultWorkerName,
            planBeginDate: widget.defaultPlanBeginDate,
            planEndDate: widget.defaultPlanEndDate,
          ),
      ],
    );
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  List<_SubplanGridRow> get _selectedRows =>
      _grid.rows.where((row) => row.selected).toList();

  int get _workshopCount => {
    for (final row in _selectedRows) row.departmentId ?? '_unassigned',
  }.length;

  double get _totalQty => _selectedRows.fold(
    0,
    (sum, row) => sum + (double.tryParse(row.qty.text.trim()) ?? 0),
  );

  Future<void> _requestClose() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('放弃未保存的规划？'),
          content: const Text('你已修改子计划内容，关闭后本次调整不会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续编辑'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃并关闭'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    _finish();
  }

  void _finish([PlanningPackageRequest? result]) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  void _toggleAll(bool selected) {
    for (final row in _grid.rows) {
      row.setSelected(selected, notify: false);
    }
    setState(() => _dirty = true);
  }

  Future<void> _pickDate(_SubplanGridRow row, bool begin) async {
    final now = DateTime.now();
    final current = begin ? row.planBeginDate : row.planEndDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 3650)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (begin) {
        row.planBeginDate = picked;
        if (row.planEndDate != null && row.planEndDate!.isBefore(picked)) {
          row.planEndDate = picked;
        }
      } else {
        row.planEndDate = picked;
      }
      _dirty = true;
    });
  }

  void _confirm() {
    if (widget.usingLegacyMrp) {
      context.appError('MRP 仍是旧口径，缺少安全库存或及时到货数据，不能生成计划');
      return;
    }
    final selected = _selectedRows;
    if (selected.isEmpty) {
      context.appError('请至少勾选一行子计划');
      return;
    }

    final items = <GenerateSubplanLine>[];
    for (final row in selected) {
      final qty = double.tryParse(row.qty.text.trim());
      final maxQty = row.source.planningShortage ?? 0;
      final name = row.source.goodsName ?? row.source.goodsCode ?? '未命名产品';
      if (qty == null || qty <= 0) {
        context.appError('$name 的计划数量必须大于 0');
        return;
      }
      if (maxQty > 0 && qty > maxQty + 1e-6) {
        context.appError('$name 的计划数量不能超过净需求 ${_fmt(maxQty)}');
        return;
      }
      final begin = row.planBeginDate;
      final end = row.planEndDate;
      if (begin != null && end != null && end.isBefore(begin)) {
        context.appError('$name 的完工日期不能早于开工日期');
        return;
      }
      items.add(
        GenerateSubplanLine(
          goodsId: row.source.goodsId,
          colorId: row.source.colorId,
          unitId: row.source.unitId,
          qty: qty,
          departmentId: row.departmentId,
          workshopName: row.workshopName,
          workerId: row.worker?.id,
          workerName: row.worker?.name,
          planBeginDate: _dateText(begin),
          planEndDate: _dateText(end),
        ),
      );
    }

    _finish(
      PlanningPackageRequest(
        items: items,
        generatePurchaseRequest:
            widget.purchaseShortageCount > 0 && _generatePurchaseRequest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workshops = ref.watch(productionWorkshopTreeProvider).valueOrNull;
    final selectedCount = _selectedRows.length;
    return PopScope<PlanningPackageRequest?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _header(theme),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _stats(theme),
                      if (widget.purchaseShortageCount > 0) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        _shortageWarning(theme),
                      ],
                      if (widget.usingLegacyMrp) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        _legacyWarning(theme),
                      ],
                      const SizedBox(height: UtenSpacing.s12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '子计划明细（$selectedCount / ${_grid.length}）',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _toggleAll(true),
                            child: const Text('全选'),
                          ),
                          TextButton(
                            onPressed: () => _toggleAll(false),
                            child: const Text('取消全选'),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      UtenEditableGrid<_SubplanGridRow>(
                        controller: _grid,
                        columns: _columns(workshops),
                        createBlankRow: () =>
                            throw UnsupportedError('子计划只能来自 MRP 候选行'),
                        showAddRow: false,
                        showRowDelete: false,
                        emptyMessage: '没有可生成的自制件子计划',
                      ),
                      if (widget.purchaseShortageCount > 0) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _generatePurchaseRequest,
                          title: const Text('同时生成采购申请'),
                          subtitle: Text(
                            '对 ${widget.purchaseShortageCount} 种外购物料净缺口生成一张采购申请草稿；'
                            '与子计划在同一事务内提交，任一步失败都会整体回滚。',
                          ),
                          onChanged: (value) => setState(() {
                            _generatePurchaseRequest = value ?? false;
                            _dirty = true;
                          }),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              _footer(theme, selectedCount),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '一键生成子计划',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '系统已按 MRP 生成候选行。请校对数量、车间、负责人和日期后再确认。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: _requestClose,
          ),
        ],
      ),
    );
  }

  Widget _stats(ThemeData theme) {
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        _stat(theme, '已选子计划', '${_selectedRows.length}', Icons.account_tree),
        _stat(theme, '计划总量', _fmt(_totalQty), Icons.production_quantity_limits),
        _stat(theme, '分配车间', '$_workshopCount', Icons.factory_outlined),
        _stat(
          theme,
          '外购缺料',
          '${widget.purchaseShortageCount} 种',
          Icons.warning_amber_rounded,
          warning: widget.purchaseShortageCount > 0,
        ),
      ],
    );
  }

  Widget _stat(
    ThemeData theme,
    String label,
    String value,
    IconData icon, {
    bool warning = false,
  }) {
    final color = warning ? theme.colorScheme.error : theme.colorScheme.primary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 190),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                    Text(label, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shortageWarning(ThemeData theme) {
    return _notice(
      theme,
      color: theme.colorScheme.error,
      icon: Icons.warning_amber_rounded,
      text:
          '当前有 ${widget.purchaseShortageCount} 种外购物料在需求日前仍有净缺口。'
          '未勾选采购申请时，子计划仍会生成，但必须等待人工补料后才能开工。',
    );
  }

  Widget _legacyWarning(ThemeData theme) {
    return _notice(
      theme,
      color: theme.colorScheme.tertiary,
      icon: Icons.info_outline_rounded,
      text: '部分 MRP 行来自旧口径，缺少安全库存或及时到货字段。请人工复核后再提交。',
    );
  }

  Widget _notice(
    ThemeData theme, {
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  List<EditableGridColumn<_SubplanGridRow>> _columns(
    List<DepartmentNode>? workshops,
  ) {
    return [
      EditableGridColumn(
        key: 'selected',
        label: '选择',
        width: 64,
        cellBuilder: (_, row) => ValueListenableBuilder<bool>(
          valueListenable: row.selectedNotifier,
          builder: (_, selected, _) => Checkbox(
            value: selected,
            onChanged: (value) => row.setSelected(value ?? false),
          ),
        ),
      ),
      EditableGridColumn(
        key: 'product',
        label: '生产产品',
        width: 230,
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.source.goodsName ?? row.source.goodsCode ?? '未命名产品',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                [
                  row.source.goodsCode,
                  row.source.spec,
                  row.source.statusLabel,
                ].where((value) => value?.isNotEmpty == true).join(' · '),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
      EditableGridColumn(
        key: 'qty',
        label: '计划数量',
        width: 110,
        numeric: true,
        cellBuilder: (_, row) => ValueListenableBuilder<bool>(
          valueListenable: row.selectedNotifier,
          builder: (_, selected, _) => TextField(
            controller: row.qty,
            enabled: selected,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              isDense: true,
              helperText: '≤${_fmt(row.source.planningShortage)}',
            ),
          ),
        ),
      ),
      EditableGridColumn(
        key: 'workshop',
        label: '生产车间',
        width: 190,
        cellBuilder: (_, row) => ValueListenableBuilder<bool>(
          valueListenable: row.selectedNotifier,
          builder: (_, selected, _) => _workshopField(row, workshops, selected),
        ),
      ),
      EditableGridColumn(
        key: 'worker',
        label: '负责人',
        width: 220,
        cellBuilder: (_, row) => ValueListenableBuilder<bool>(
          valueListenable: row.selectedNotifier,
          builder: (_, selected, _) => UtenEmployeePicker(
            key: ValueKey('${row.source.goodsId}_${row.worker?.id ?? ''}'),
            enabled: selected,
            initial: row.worker,
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
            onChanged: (item) {
              row.worker = item;
              row.changed();
            },
          ),
        ),
      ),
      EditableGridColumn(
        key: 'begin',
        label: '计划开工',
        width: 135,
        cellBuilder: (_, row) => ValueListenableBuilder<bool>(
          valueListenable: row.selectedNotifier,
          builder: (_, selected, _) => _dateCell(
            row.planBeginDate,
            enabled: selected,
            onTap: () => _pickDate(row, true),
          ),
        ),
      ),
      EditableGridColumn(
        key: 'end',
        label: '计划完工',
        width: 135,
        cellBuilder: (_, row) => ValueListenableBuilder<bool>(
          valueListenable: row.selectedNotifier,
          builder: (_, selected, _) => _dateCell(
            row.planEndDate,
            enabled: selected,
            onTap: () => _pickDate(row, false),
          ),
        ),
      ),
    ];
  }

  Widget _workshopField(
    _SubplanGridRow row,
    List<DepartmentNode>? workshops,
    bool enabled,
  ) {
    final options = workshops ?? const <DepartmentNode>[];
    final currentMissing =
        row.departmentId != null &&
        !options.any((option) => option.id == row.departmentId);
    return DropdownButtonFormField<String>(
      key: ValueKey(
        '${row.source.goodsId}_${row.departmentId}_${options.length}',
      ),
      initialValue: row.departmentId ?? '',
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        const DropdownMenuItem(value: '', child: Text('未指定车间')),
        if (currentMissing)
          DropdownMenuItem(
            value: row.departmentId!,
            child: Text(row.workshopName ?? '当前车间'),
          ),
        for (final workshop in options)
          DropdownMenuItem(value: workshop.id, child: Text(workshop.name)),
      ],
      onChanged: enabled
          ? (value) {
              setState(() {
                if (value == null || value.isEmpty) {
                  row.departmentId = null;
                  row.workshopName = null;
                } else {
                  row.departmentId = value;
                  row.workshopName = options
                      .where((option) => option.id == value)
                      .map((option) => option.name)
                      .firstOrNull;
                }
                _dirty = true;
              });
            }
          : null,
    );
  }

  Widget _dateCell(
    DateTime? value, {
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: UtenRadius.smAll,
      child: InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          enabled: enabled,
          suffixIcon: const Icon(Icons.date_range_rounded, size: 16),
        ),
        child: Text(
          _dateText(value) ?? '未设置',
          style: TextStyle(
            color: value == null ? theme.colorScheme.onSurfaceVariant : null,
          ),
        ),
      ),
    );
  }

  Widget _footer(ThemeData theme, int selectedCount) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          children: [
            Text(
              '已选 $selectedCount 行 · $_workshopCount 个车间',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _requestClose,
              child: const Text('取消'),
            ),
            UtenButton(
              icon: Icons.account_tree_outlined,
              onPressed: selectedCount == 0 ? null : _confirm,
              child: const Text('确认生成计划'),
            ),
          ],
        ),
      ),
    );
  }

  String? _dateText(DateTime? value) {
    if (value == null) return null;
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  String _fmt(double? value) {
    if (value == null) return '—';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }
}
