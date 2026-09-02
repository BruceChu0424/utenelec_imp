import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/page_permission_action.dart';
import '../../../shared/auth/page_permission_scope.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/production_material_analysis.dart';
import '../providers/production_department_provider.dart';

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
    this.productNo,
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
  final String? productNo;
}

/// 向导完成后的回传：各批次计划输入 + 是否「生成后立即审核下达」。
/// approveNow 只在有生产计划审核权限时才可能为 true。
class ProductionPlanWizardResult {
  const ProductionPlanWizardResult({
    required this.items,
    required this.approveNow,
  });

  final List<MaterialAnalysisPlanItemInput> items;
  final bool approveNow;
}

/// One self-made product/batch per paper-like page. The page returns drafts;
/// server preview and atomic generation remain owned by the calling analysis
/// workbench.
class ProductionPlanWizardPage extends ConsumerStatefulWidget {
  const ProductionPlanWizardPage({
    super.key,
    required this.entries,
    this.canApprove = false,
  });

  final List<ProductionPlanWizardEntry> entries;

  /// 是否持有生产计划审核权限（production_plan:approve）。
  /// 为 true 时确认对话框提供「生成后立即审核下达」选项。
  final bool canApprove;

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
  bool _approveNow = false;

  @override
  void initState() {
    super.initState();
    _drafts = widget.entries.map(_PlanDraft.fromEntry).toList();
    _formKeys = List.generate(_drafts.length, (_) => GlobalKey<FormState>());
    // 审核权限由调用页和服务端双重门控。持有权限时默认采用现场最常用的
    // “生成并审核下达”，但仍保留汇总二次确认和显式取消勾选。
    _approveNow = widget.canApprove;
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

  void _reorderDrafts(int oldIndex, int newIndex) {
    if (newIndex == oldIndex) return;
    final selected = _drafts[_index];
    setState(() {
      final draft = _drafts.removeAt(oldIndex);
      final formKey = _formKeys.removeAt(oldIndex);
      _drafts.insert(newIndex, draft);
      _formKeys.insert(newIndex, formKey);
      _index = _drafts.indexOf(selected);
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

  Future<void> _applyToRemaining() async {
    if (!_validateDraft(_index)) return;
    final source = _drafts[_index];
    final choice = await showDialog<_BulkApplyChoice>(
      context: context,
      builder: (_) =>
          _BulkApplyDialog(remainingCount: _drafts.length - _index - 1),
    );
    if (choice == null || !mounted) return;
    setState(() {
      for (var i = _index + 1; i < _drafts.length; i++) {
        _drafts[i].copyScheduleFrom(source, choice);
      }
      _submitted = false;
    });
    context.appSuccess('已按所选字段应用到剩余 ${_drafts.length - _index - 1} 张计划单');
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
        context.appWarning('第 ${index + 1} 张计划单资料未填完整');
        return;
      }
    }
    final groupedDrafts = _draftsByWorkshop();
    final missingCount = _drafts
        .where((draft) => draft.departmentId == null)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: Text(
            '确认提交 ${_drafts.length} 张生产计划单 · ${groupedDrafts.length} 个车间组',
          ),
          content: SizedBox(
            // AlertDialog 会对 content 做 intrinsic 测量：宽度必须有界。
            // 用屏幕宽度钳制，大屏不超过 700，中/小屏随窗口收缩。
            width: (MediaQuery.sizeOf(dialogContext).width - 96).clamp(
              280.0,
              700.0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    Chip(label: Text('生产计划 ${_drafts.length} 张')),
                    Chip(label: Text('车间分组 ${groupedDrafts.length} 个')),
                    if (missingCount > 0)
                      Chip(
                        avatar: Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: Theme.of(dialogContext).colorScheme.error,
                        ),
                        label: Text('缺车间 $missingCount 张'),
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final group in groupedDrafts.entries) ...[
                        Container(
                          margin: const EdgeInsets.only(top: UtenSpacing.s8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: UtenSpacing.s12,
                            vertical: UtenSpacing.s8,
                          ),
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .surfaceContainerHigh,
                          child: Text(
                            '${group.key} · ${group.value.length} 张',
                            style: Theme.of(dialogContext).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        for (final draft in group.value)
                          ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              child: Text('${_drafts.indexOf(draft) + 1}'),
                            ),
                            title: Text(draft.productLabel),
                            subtitle: Text(
                              '${draft.productNoText} · ${draft.qtyText} · '
                              '${_dateText(draft.beginDate)} 至 ${_dateText(draft.endDate)}',
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                if (widget.canApprove)
                  CheckboxListTile(
                    key: const Key('production-plan-wizard-approve-now'),
                    value: _approveNow,
                    onChanged: (value) =>
                        setLocal(() => _approveNow = value ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('生成后立即审核下达'),
                    subtitle: const Text(
                      '勾选：计划直接生效，系统同时生成物料提货单(领料单)，'
                      '车间可马上去仓库领料；不勾选：先提交审批，审核下达时再出提货单。',
                    ),
                  ),
                if (_approveNow) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  const UtenReviewerResponsibilityNotice(
                    actionLabel: '生产计划审核下达',
                    description: '确认后将以当前员工记录审核责任，并立即生成正式下达后的关联单据。',
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                ],
                Text(
                  '提交后仍生成独立生产计划；本页只是按车间汇总核对。计划审核并正式下达后，系统才学习未来默认车间。',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
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
              label: Text(_approveNow ? '确认生成并审核下达' : '确认并提交审批'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(
        context,
        ProductionPlanWizardResult(
          items: [for (final draft in _drafts) draft.toInput()],
          approveNow: _approveNow,
        ),
      );
    }
  }

  Map<String, List<_PlanDraft>> _draftsByWorkshop() {
    final result = <String, List<_PlanDraft>>{};
    for (final draft in _drafts) {
      final key = draft.workshopName?.trim().isNotEmpty == true
          ? draft.workshopName!.trim()
          : '未分配车间';
      result.putIfAbsent(key, () => []).add(draft);
    }
    return result;
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
        actions: [
          PagePermissionAction(
            scope: pagePermissionScopeFor('/production/plans/new'),
          ),
        ],
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
    child: ReorderableListView.builder(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      itemCount: _drafts.length,
      buildDefaultDragHandles: false,
      onReorderItem: _reorderDrafts,
      itemBuilder: (_, index) {
        final selected = index == _index;
        return Padding(
          key: ValueKey(
            'production-plan-wizard-draft-${_drafts[index].analysisLineId}',
          ),
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
                  if (_drafts[index].departmentId == null)
                    Tooltip(
                      message: '未维护默认车间，需本次指定',
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: selected
                            ? Colors.white
                            : theme.colorScheme.error,
                      ),
                    ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Tooltip(
                      message: '拖动调整本次提交顺序',
                      child: SizedBox(
                        width: 44,
                        height: 48,
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          size: 20,
                          color: selected
                              ? Colors.white
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
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

  Widget _paper(ThemeData theme, _PlanDraft draft) {
    final workshopTreeState = ref.watch(productionWorkshopTreeProvider);
    final workshopTree = workshopTreeState.valueOrNull ?? const [];
    final workshopIds = {for (final node in workshopTree) node.id};
    return SingleChildScrollView(
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
                    onSurface: UtenColors.docInk,
                  ),
                ),
                child: Form(
                  key: _formKeys[_index],
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '中山市优腾电器有限公司',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: UtenColors.docInk,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '生产计划单',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: UtenColors.docInk,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '第 ${_index + 1} / ${_drafts.length} 张 · 一种自制件一个执行批次 · '
                        '单号审核后由系统生成',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: UtenColors.docInkSoft,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      if (draft.departmentId == null)
                        _missingWorkshopBanner(theme),
                      if (draft.departmentId == null)
                        const SizedBox(height: UtenSpacing.s12),
                      _readOnlyFacts(theme, draft),
                      const SizedBox(height: UtenSpacing.s20),
                      TextFormField(
                        errorBuilder: utenTextFieldErrorBuilder,
                        key: ValueKey(
                          'production-plan-wizard-product-no-${draft.analysisLineId}',
                        ),
                        controller: draft.productNoController,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '产品编号(可选)',
                          helper: UtenFieldMessage.helper('留空由系统按计划单号生成'),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      TextFormField(
                        errorBuilder: utenTextFieldErrorBuilder,
                        key: ValueKey(
                          'production-plan-wizard-qty-${draft.analysisLineId}',
                        ),
                        controller: draft.qtyController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: '本批计划数量 *',
                          helper: UtenFieldMessage.helper(
                            '最多可安排 ${_qty(draft.entry.product.readyNowQty)}'
                            '${_unitSuffix(draft.entry.product.unitName)}，最终由服务端再次校验',
                          ),
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
                      if (workshopTreeState.isLoading)
                        const LinearProgressIndicator(minHeight: 2),
                      if (workshopTreeState.hasError)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s8,
                          ),
                          child: Text(
                            '生产车间目录加载失败，请重试后再提交',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      UtenDepartmentPicker(
                        key: ValueKey(
                          'production-plan-wizard-dept-${draft.departmentId}',
                        ),
                        mode: UtenDepartmentPickerMode.single,
                        label: '生产车间 *',
                        hint: '仅可选择生产部直属车间',
                        enabled:
                            !workshopTreeState.isLoading &&
                            workshopTree.isNotEmpty,
                        treeOverride: workshopTree,
                        selectablePredicate: (node) =>
                            workshopIds.contains(node.id),
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
                        validator: (selection) {
                          if (selection.isEmpty) return '请选择生产车间';
                          if (!workshopIds.contains(selection.first.id)) {
                            return '生产车间必须是生产部直属有效车间';
                          }
                          return null;
                        },
                        onChanged: (selection) {
                          final value = selection.isEmpty
                              ? null
                              : selection.first;
                          setState(() {
                            if (draft.departmentId != value?.id) {
                              draft.workerId = null;
                              draft.workerName = null;
                              draft.teamDepartmentId = null;
                            }
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
                                employeeCode: employee.code,
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
                              errorMessage:
                                  _submitted && draft.beginDate == null
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
                              errorMessage: _dateError(draft),
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
  }

  String? _dateError(_PlanDraft draft) {
    if (!_submitted) return null;
    if (draft.endDate == null) return '请选择计划结束日期';
    if (draft.beginDate != null && draft.endDate!.isBefore(draft.beginDate!)) {
      return '计划结束不能早于计划开始';
    }
    return null;
  }

  /// 缺默认车间提示：尚未学习该组件的未来车间建议。
  Widget _missingWorkshopBanner(ThemeData theme) => Container(
    key: const Key('production-plan-wizard-missing-workshop'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.error.withValues(alpha: 0.08),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.factory_outlined, size: 20, color: theme.colorScheme.error),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            '该组件还没有默认生产车间建议，请本次指定；计划审核并正式下达后系统会学习本次选择，下次自动预填，但不会改写历史计划。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _readOnlyFacts(ThemeData theme, _PlanDraft draft) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: UtenColors.docPaperTint,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: UtenColors.docLine),
    ),
    child: Wrap(
      spacing: UtenSpacing.s16,
      runSpacing: UtenSpacing.s8,
      children: [
        _paperFact('产品', draft.productLabel),
        _paperFact('编码', draft.entry.product.goodsCode ?? '—'),
        _paperFact('规格', draft.entry.product.spec ?? '—'),
        _paperFact('开单日期', _dateText(draft.entry.billDate)),
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
        style: const TextStyle(color: UtenColors.docInk, height: 1.5),
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
    required this.productNoController,
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
    productNoController: TextEditingController(text: entry.productNo ?? ''),
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
  final TextEditingController productNoController;
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
  String get productNoText {
    final value = productNoController.text.trim();
    return value.isEmpty ? '产品编号由系统生成' : '产品编号 $value';
  }

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

  void copyScheduleFrom(_PlanDraft source, _BulkApplyChoice choice) {
    bool canWrite(Object? current) =>
        !choice.onlyBlank || current == null || current == '';
    if (choice.copyDates) {
      if (canWrite(beginDate)) beginDate = source.beginDate;
      if (canWrite(endDate)) endDate = source.endDate;
    }
    if (choice.copyAssignment) {
      final assignmentIsBlank =
          departmentId == null && workerId == null && teamDepartmentId == null;
      // 车间、负责人、班组是一组相互约束的安排，必须整组复制或整组保留，
      // 不能在“只填空白”模式下拼出车间 A + 负责人 B 的混合数据。
      if (!choice.onlyBlank || assignmentIsBlank) {
        departmentId = source.departmentId;
        workshopName = source.workshopName;
        teamDepartmentId = source.teamDepartmentId;
        workerId = source.workerId;
        workerName = source.workerName;
      }
    }
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
    productNo: productNoController.text.trim().isEmpty
        ? null
        : productNoController.text.trim(),
  );

  void dispose() {
    qtyController.dispose();
    productNoController.dispose();
  }
}

class _BulkApplyChoice {
  const _BulkApplyChoice({
    required this.copyDates,
    required this.copyAssignment,
    required this.onlyBlank,
  });

  final bool copyDates;
  final bool copyAssignment;
  final bool onlyBlank;
}

class _BulkApplyDialog extends StatefulWidget {
  const _BulkApplyDialog({required this.remainingCount});

  final int remainingCount;

  @override
  State<_BulkApplyDialog> createState() => _BulkApplyDialogState();
}

class _BulkApplyDialogState extends State<_BulkApplyDialog> {
  bool _copyDates = true;
  bool _copyAssignment = false;
  bool _onlyBlank = true;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('批量应用到后续 ${widget.remainingCount} 张'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('请选择要复制的字段。系统不会再默认把一个产品的车间和负责人覆盖给所有组件。'),
          const SizedBox(height: UtenSpacing.s8),
          CheckboxListTile(
            key: const Key('production-plan-bulk-copy-dates'),
            value: _copyDates,
            onChanged: (value) => setState(() => _copyDates = value == true),
            title: const Text('计划开始/结束日期'),
            contentPadding: EdgeInsets.zero,
          ),
          CheckboxListTile(
            key: const Key('production-plan-bulk-copy-assignment'),
            value: _copyAssignment,
            onChanged: (value) =>
                setState(() => _copyAssignment = value == true),
            title: const Text('生产车间、负责人和班组'),
            subtitle: const Text('仅在这些产品确实共用同一生产安排时勾选；正式下达后会分别学习车间建议。'),
            contentPadding: EdgeInsets.zero,
          ),
          CheckboxListTile(
            key: const Key('production-plan-bulk-only-blank'),
            value: _onlyBlank,
            onChanged: (value) => setState(() => _onlyBlank = value == true),
            title: const Text('只填写空白字段(推荐)'),
            subtitle: const Text('关闭后会覆盖后续计划中已经预填或人工填写的对应字段。'),
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('production-plan-bulk-apply-confirm'),
        onPressed: !_copyDates && !_copyAssignment
            ? null
            : () => Navigator.pop(
                context,
                _BulkApplyChoice(
                  copyDates: _copyDates,
                  copyAssignment: _copyAssignment,
                  onlyBlank: _onlyBlank,
                ),
              ),
        child: const Text('确认应用'),
      ),
    ],
  );
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
