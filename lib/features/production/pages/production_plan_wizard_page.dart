import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/production_material_analysis.dart';

class ProductionPlanWizardEntry {
  const ProductionPlanWizardEntry({
    required this.product,
    required this.qty,
    required this.billDate,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.workerName,
    this.teamDepartmentId,
  });

  final ProductionMaterialAnalysisProduct product;
  final double qty;
  final DateTime billDate;
  final DateTime? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? workerName;
  final String? teamDepartmentId;
}

/// One self-made product/batch per paper-like page. The page returns drafts;
/// server preview and atomic generation remain owned by the calling analysis
/// workbench.
class ProductionPlanWizardPage extends ConsumerStatefulWidget {
  const ProductionPlanWizardPage({super.key, required this.entries});

  final List<ProductionPlanWizardEntry> entries;

  @override
  ConsumerState<ProductionPlanWizardPage> createState() =>
      _ProductionPlanWizardPageState();
}

class _ProductionPlanWizardPageState
    extends ConsumerState<ProductionPlanWizardPage> {
  late final List<_PlanDraft> _drafts;
  late final List<GlobalKey<FormState>> _formKeys;
  int _index = 0;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _drafts = widget.entries.map(_PlanDraft.fromEntry).toList(growable: false);
    _formKeys = List.generate(_drafts.length, (_) => GlobalKey<FormState>());
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  bool _validateDraft(int index) {
    setState(() => _submitted = true);
    final formValid = _formKeys[index].currentState?.validate() ?? false;
    final draft = _drafts[index];
    return formValid &&
        draft.beginDate != null &&
        draft.endDate != null &&
        !draft.endDate!.isBefore(draft.beginDate!);
  }

  void _previous() {
    if (_index == 0) return;
    setState(() {
      _submitted = false;
      _index--;
    });
  }

  void _saveAndNext() {
    if (!_validateDraft(_index)) return;
    if (_index >= _drafts.length - 1) {
      _showSummary();
      return;
    }
    setState(() {
      _submitted = false;
      _index++;
    });
  }

  void _applyToRemaining() {
    if (!_validateDraft(_index)) return;
    final source = _drafts[_index];
    setState(() {
      for (var i = _index + 1; i < _drafts.length; i++) {
        _drafts[i].copyScheduleFrom(source);
      }
      _submitted = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已应用到剩余 ${_drafts.length - _index - 1} 张计划单')),
    );
  }

  Future<void> _showSummary() async {
    for (var index = 0; index < _drafts.length; index++) {
      if (!_drafts[index].isComplete) {
        setState(() {
          _index = index;
          _submitted = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _formKeys[index].currentState?.validate();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('第 ${index + 1} 张计划单资料未填完整')));
        return;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('确认提交 ${_drafts.length} 张生产计划单'),
        content: SizedBox(
          width: 620,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _drafts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final draft = _drafts[index];
              return ListTile(
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text(draft.productLabel),
                subtitle: Text(
                  '${draft.qtyText} · ${draft.workshopName} · '
                  '${_dateText(draft.beginDate)} 至 ${_dateText(draft.endDate)}',
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('返回修改'),
          ),
          FilledButton.icon(
            key: const Key('production-plan-wizard-submit'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.send_outlined),
            label: const Text('确认并提交审批'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, [for (final draft in _drafts) draft.toInput()]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _drafts[_index];
    return Scaffold(
      appBar: AppBar(
        title: const Text('填写生产计划单'),
        leading: IconButton(
          tooltip: '返回物料分析',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 900;
            final paper = _paper(theme, draft);
            return Column(
              children: [
                LinearProgressIndicator(
                  value: (_index + 1) / _drafts.length,
                  minHeight: 4,
                ),
                Expanded(
                  child: desktop
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 260, child: _stepRail(theme)),
                            const VerticalDivider(width: 1),
                            Expanded(child: paper),
                          ],
                        )
                      : paper,
                ),
                _bottomBar(desktop),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _stepRail(ThemeData theme) => Material(
    color: theme.colorScheme.surfaceContainerLow,
    child: ListView.builder(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      itemCount: _drafts.length,
      itemBuilder: (_, index) {
        final selected = index == _index;
        return Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: InkWell(
            key: ValueKey('production-plan-wizard-step-$index'),
            borderRadius: UtenRadius.mdAll,
            onTap: () => setState(() {
              _submitted = false;
              _index = index;
            }),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.all(UtenSpacing.s8),
              decoration: BoxDecoration(
                color: selected ? UtenColors.deepGreen : null,
                borderRadius: UtenRadius.mdAll,
                border: Border.all(
                  color: selected
                      ? UtenColors.deepGreen
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: selected
                        ? Colors.white
                        : theme.colorScheme.primaryContainer,
                    foregroundColor: selected
                        ? UtenColors.deepGreen
                        : theme.colorScheme.onPrimaryContainer,
                    child: Text('${index + 1}'),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _drafts[index].productLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected ? Colors.white : null,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '第 ${index + 1} / ${_drafts.length} 张',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: selected
                                ? Colors.white70
                                : theme.colorScheme.onSurfaceVariant,
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
      },
    ),
  );

  Widget _paper(ThemeData theme, _PlanDraft draft) => SingleChildScrollView(
    padding: const EdgeInsets.all(UtenSpacing.s16),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 794, minHeight: 700),
        child: Material(
          key: ValueKey('production-plan-paper-${draft.analysisLineId}'),
          color: Colors.white,
          elevation: 3,
          borderRadius: UtenRadius.smAll,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: Theme(
              data: theme.copyWith(
                colorScheme: theme.colorScheme.copyWith(
                  surface: Colors.white,
                  onSurface: const Color(0xFF17231F),
                ),
              ),
              child: Form(
                key: _formKeys[_index],
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '生产计划单',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: const Color(0xFF17231F),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '第 ${_index + 1} / ${_drafts.length} 张 · 一种自制件一个执行批次',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF52605A),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s24),
                    _readOnlyFacts(theme, draft),
                    const SizedBox(height: UtenSpacing.s20),
                    TextFormField(
                      key: ValueKey(
                        'production-plan-wizard-qty-${draft.analysisLineId}',
                      ),
                      controller: draft.qtyController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: '本批计划数量 *',
                        helperText:
                            '最多可安排 ${_qty(draft.entry.product.readyNowQty)}'
                            '${_unitSuffix(draft.entry.product.unitName)}，最终由服务端再次校验',
                      ),
                      validator: (value) {
                        final qty = double.tryParse(value?.trim() ?? '');
                        if (qty == null || !qty.isFinite || qty <= 0) {
                          return '请输入大于 0 的计划数量';
                        }
                        if (qty > draft.entry.product.readyNowQty) {
                          return '不能超过当前可生产数量';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    UtenDepartmentPicker(
                      key: ValueKey(
                        'production-plan-wizard-dept-${draft.departmentId}',
                      ),
                      mode: UtenDepartmentPickerMode.single,
                      label: '生产车间 *',
                      hint: '请选择生产车间（部门）',
                      requireConfirm: true,
                      initialSelection: draft.departmentId == null
                          ? const []
                          : [
                              DeptSelection(
                                id: draft.departmentId!,
                                name: draft.workshopName ?? '',
                                fullPath: '',
                                level: '',
                              ),
                            ],
                      validator: (selection) =>
                          selection.isEmpty ? '请选择生产车间（部门）' : null,
                      onChanged: (selection) {
                        final value = selection.isEmpty
                            ? null
                            : selection.first;
                        setState(() {
                          draft.departmentId = value?.id;
                          draft.workshopName = value?.name;
                        });
                      },
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    UtenEmployeePicker(
                      key: ValueKey(
                        'production-plan-wizard-worker-${draft.workerId}',
                      ),
                      label: '负责人',
                      hint: '请选择负责人',
                      sheetTitle: '选择生产负责人',
                      required: true,
                      initial: draft.workerId == null
                          ? null
                          : UtenEmployeePickerItem(
                              id: draft.workerId!,
                              name: draft.workerName ?? draft.workerId!,
                            ),
                      departmentName: draft.workshopName,
                      loader: (keyword) async {
                        final result = await ref
                            .read(employeeRepositoryProvider)
                            .list(
                              size: 30,
                              search: keyword,
                              departmentId: keyword?.trim().isEmpty ?? true
                                  ? draft.departmentId
                                  : null,
                              includeSubtree: true,
                            );
                        return [
                          for (final employee in result.items)
                            UtenEmployeePickerItem(
                              id: employee.id,
                              name: employee.fullName,
                              departmentName: employee.departmentName,
                            ),
                        ];
                      },
                      validator: (value) => value == null ? '请选择负责人' : null,
                      onChanged: (value) => setState(() {
                        draft.workerId = value?.id;
                        draft.workerName = value?.name;
                      }),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    LayoutBuilder(
                      builder: (_, constraints) {
                        final compact = constraints.maxWidth < 560;
                        final fields = [
                          UtenDateField(
                            key: ValueKey(
                              'production-plan-wizard-begin-${draft.analysisLineId}',
                            ),
                            label: '计划开始 *',
                            value: draft.beginDate,
                            required: true,
                            errorText: _submitted && draft.beginDate == null
                                ? '请选择计划开始日期'
                                : null,
                            onChanged: (value) => setState(() {
                              draft.beginDate = value;
                            }),
                          ),
                          UtenDateField(
                            key: ValueKey(
                              'production-plan-wizard-end-${draft.analysisLineId}',
                            ),
                            label: '计划结束 *',
                            value: draft.endDate,
                            required: true,
                            firstDate: draft.beginDate,
                            errorText: _dateError(draft),
                            onChanged: (value) => setState(() {
                              draft.endDate = value;
                            }),
                          ),
                        ];
                        if (compact) {
                          return Column(
                            children: [
                              fields.first,
                              const SizedBox(height: UtenSpacing.s16),
                              fields.last,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: fields.first),
                            const SizedBox(width: UtenSpacing.s16),
                            Expanded(child: fields.last),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  String? _dateError(_PlanDraft draft) {
    if (!_submitted) return null;
    if (draft.endDate == null) return '请选择计划结束日期';
    if (draft.beginDate != null && draft.endDate!.isBefore(draft.beginDate!)) {
      return '计划结束不能早于计划开始';
    }
    return null;
  }

  Widget _readOnlyFacts(ThemeData theme, _PlanDraft draft) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: const Color(0xFFF3F7F5),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: const Color(0xFFD5E1DB)),
    ),
    child: Wrap(
      spacing: UtenSpacing.s16,
      runSpacing: UtenSpacing.s8,
      children: [
        _paperFact('产品', draft.productLabel),
        _paperFact('编码', draft.entry.product.goodsCode ?? '—'),
        _paperFact('规格', draft.entry.product.spec ?? '—'),
        _paperFact(
          '来源',
          draft.entry.product.sourceType == 'MAKE_COMPONENT'
              ? '自制备料任务'
              : draft.entry.product.orderNo ??
                    draft.entry.product.sourceRef ??
                    '生产需求',
        ),
        _paperFact(
          '当前可生产',
          '${_qty(draft.entry.product.readyNowQty)}'
              '${_unitSuffix(draft.entry.product.unitName)}',
        ),
      ],
    ),
  );

  Widget _paperFact(String label, String value) => SizedBox(
    width: 210,
    child: RichText(
      text: TextSpan(
        style: const TextStyle(color: Color(0xFF17231F), height: 1.5),
        children: [
          TextSpan(
            text: '$label：',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );

  Widget _bottomBar(bool desktop) => Material(
    elevation: 8,
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!desktop)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
                child: Text('第 ${_index + 1} / ${_drafts.length} 张'),
              ),
            UtenButton(
              type: UtenButtonType.ghost,
              icon: Icons.arrow_back_rounded,
              onPressed: _index == 0 ? null : _previous,
              child: const Text('上一张'),
            ),
            if (_index < _drafts.length - 1)
              UtenButton(
                key: const Key('production-plan-wizard-apply-remaining'),
                type: UtenButtonType.tonal,
                icon: Icons.copy_all_outlined,
                onPressed: _applyToRemaining,
                child: const Text('应用到剩余'),
              ),
            UtenButton(
              key: const Key('production-plan-wizard-next'),
              icon: _index == _drafts.length - 1
                  ? Icons.fact_check_outlined
                  : Icons.arrow_forward_rounded,
              onPressed: _saveAndNext,
              child: Text(_index == _drafts.length - 1 ? '汇总确认' : '保存并下一张'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PlanDraft {
  _PlanDraft({
    required this.entry,
    required this.qtyController,
    required this.beginDate,
    required this.endDate,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.workerName,
    this.teamDepartmentId,
  });

  factory _PlanDraft.fromEntry(ProductionPlanWizardEntry entry) => _PlanDraft(
    entry: entry,
    qtyController: TextEditingController(text: _qty(entry.qty)),
    beginDate: entry.billDate,
    endDate: entry.deliveryDate ?? entry.billDate,
    departmentId: entry.departmentId,
    workshopName: entry.workshopName,
    workerId: entry.workerId,
    workerName: entry.workerName,
    teamDepartmentId: entry.teamDepartmentId,
  );

  final ProductionPlanWizardEntry entry;
  final TextEditingController qtyController;
  DateTime? beginDate;
  DateTime? endDate;
  String? departmentId;
  String? workshopName;
  String? workerId;
  String? workerName;
  String? teamDepartmentId;

  String get analysisLineId => entry.product.analysisLineId;
  String get productLabel =>
      entry.product.goodsName ?? entry.product.goodsCode ?? analysisLineId;
  String get qtyText =>
      '${_qty(double.tryParse(qtyController.text))}'
      '${_unitSuffix(entry.product.unitName)}';

  bool get isComplete {
    final qty = double.tryParse(qtyController.text.trim());
    return qty != null &&
        qty.isFinite &&
        qty > 0 &&
        qty <= entry.product.readyNowQty &&
        departmentId?.isNotEmpty == true &&
        workshopName?.trim().isNotEmpty == true &&
        workerId?.isNotEmpty == true &&
        beginDate != null &&
        endDate != null &&
        !endDate!.isBefore(beginDate!);
  }

  void copyScheduleFrom(_PlanDraft source) {
    departmentId = source.departmentId;
    workshopName = source.workshopName;
    workerId = source.workerId;
    workerName = source.workerName;
    teamDepartmentId = source.teamDepartmentId;
    beginDate = source.beginDate;
    endDate = source.endDate;
  }

  MaterialAnalysisPlanItemInput toInput() => MaterialAnalysisPlanItemInput(
    analysisLineId: analysisLineId,
    qty: double.parse(qtyController.text.trim()),
    billDate: _dateText(beginDate),
    deliveryDate: _dateText(endDate),
    departmentId: departmentId,
    workshopName: workshopName,
    workerId: workerId,
    teamDepartmentId: teamDepartmentId,
  );

  void dispose() => qtyController.dispose();
}

String _qty(double? value) {
  if (value == null) return '—';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _unitSuffix(String? unitName) {
  final normalized = unitName?.trim();
  return normalized == null || normalized.isEmpty ? ' 件' : ' $normalized';
}

String _dateText(DateTime? value) => value == null
    ? ''
    : '${value.year.toString().padLeft(4, '0')}-'
          '${value.month.toString().padLeft(2, '0')}-'
          '${value.day.toString().padLeft(2, '0')}';
