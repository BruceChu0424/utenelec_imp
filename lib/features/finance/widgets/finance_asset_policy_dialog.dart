import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/models/payment_style_node.dart';
import '../../basic_data/repositories/payment_style_repository.dart';
import '../models/finance_asset_category_models.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_category_repository.dart';
import 'finance_asset_ui.dart';

Future<bool> showFinanceAssetPolicyDialog(
  BuildContext context, {
  required bool canApprove,
}) async {
  final compact =
      MediaQuery.sizeOf(context).width < UtenBreakpoints.mediumStart;
  final content = FinanceAssetPolicySurface(canApprove: canApprove);
  if (compact) {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          useSafeArea: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(UtenRadius.xxl),
            ),
          ),
          builder: (_) =>
              FractionallySizedBox(heightFactor: 0.96, child: content),
        ) ??
        false;
  }
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Dialog(
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
          child: SizedBox(
            width: 1040,
            height: MediaQuery.sizeOf(context).height * 0.9,
            child: content,
          ),
        ),
      ) ??
      false;
}

class FinanceAssetPolicySurface extends ConsumerStatefulWidget {
  const FinanceAssetPolicySurface({super.key, required this.canApprove});

  final bool canApprove;

  @override
  ConsumerState<FinanceAssetPolicySurface> createState() =>
      _FinanceAssetPolicySurfaceState();
}

class _FinanceAssetPolicySurfaceState
    extends ConsumerState<FinanceAssetPolicySurface> {
  final _requestGuard = LatestRequestGuard();
  final _styleRequestGuard = LatestRequestGuard();
  final _formKey = GlobalKey<FormState>();
  FinanceAssetLedger _ledger = FinanceAssetLedger.fixedAsset;
  List<FinanceAssetCategory> _categories = const [];
  FinanceAssetCategory? _selected;
  bool _loading = true;
  String? _error;
  bool _styleLoading = true;
  String? _styleError;
  List<PaymentStyleNode> _balanceStyles = const [];
  List<PaymentStyleNode> _expenseStyles = const [];
  bool _showStyleErrors = false;
  bool _dirty = false;

  final _code = TextEditingController();
  final _name = TextEditingController();
  final _costAccountId = TextEditingController();
  final _accumulatedAccountId = TextEditingController();
  final _expenseAccountId = TextEditingController();
  final _clearingAccountId = TextEditingController();
  final _method = TextEditingController();
  final _months = TextEditingController();
  final _salvageRate = TextEditingController();
  final _effectiveDate = TextEditingController();
  final _requiredDocuments = TextEditingController();

  late final List<TextEditingController> _controllers = [
    _code,
    _name,
    _costAccountId,
    _accumulatedAccountId,
    _expenseAccountId,
    _clearingAccountId,
    _method,
    _months,
    _salvageRate,
    _effectiveDate,
    _requiredDocuments,
  ];

  @override
  void initState() {
    super.initState();
    for (final controller in _controllers) {
      controller.addListener(_markDirty);
    }
    _load();
    _loadStyles();
  }

  void _markDirty() => _dirty = true;

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..removeListener(_markDirty)
        ..dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final generation = _requestGuard.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(financeAssetCategoryRepositoryProvider)
          .list(_ledger);
      if (!mounted || !_requestGuard.isCurrent(generation)) return;
      setState(() {
        _categories = result;
        _loading = false;
        _selected = null;
      });
      _clearForm();
    } catch (error) {
      if (!mounted || !_requestGuard.isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _error = '会计政策加载失败，请重试';
      });
    }
  }

  List<PaymentStyleNode> _flattenStyles(List<PaymentStyleNode> roots) {
    final result = <PaymentStyleNode>[];
    void visit(PaymentStyleNode node) {
      final status = node.status?.trim().toUpperCase();
      final active = const {'ACTIVE', 'ENABLED', '使用', '启用'}.contains(status);
      if (node.children.isEmpty && active) result.add(node);
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }
    return result;
  }

  Future<void> _loadStyles() async {
    final generation = _styleRequestGuard.begin();
    setState(() {
      _styleLoading = true;
      _styleError = null;
    });
    try {
      final repository = ref.read(paymentStyleRepositoryProvider);
      final balanceRoots = <PaymentStyleNode>[];
      for (final category in const ['ACCOUNT', 'LIABILITY', 'EQUITY']) {
        balanceRoots.addAll(await repository.tree(category: category));
      }
      final expenseRoots = await repository.tree(category: 'EXPENSE');
      if (!mounted || !_styleRequestGuard.isCurrent(generation)) return;
      setState(() {
        _balanceStyles = _flattenStyles(balanceRoots);
        _expenseStyles = _flattenStyles(expenseRoots);
        _styleLoading = false;
      });
    } catch (_) {
      if (!mounted || !_styleRequestGuard.isCurrent(generation)) return;
      setState(() {
        _styleLoading = false;
        _styleError = '会计科目加载失败，请重试';
      });
    }
  }

  void _assign(TextEditingController controller, String value) {
    controller.text = value;
  }

  void _clearForm() {
    for (final controller in _controllers) {
      controller.clear();
    }
    _dirty = false;
  }

  void _populate(FinanceAssetCategory category) {
    _assign(_code, category.code);
    _assign(_name, category.name);
    _assign(_costAccountId, category.costStyleId);
    _assign(_accumulatedAccountId, category.accumulatedStyleId ?? '');
    _assign(_expenseAccountId, category.expenseStyleId);
    _assign(_clearingAccountId, category.clearingStyleId);
    _assign(_method, category.defaultMethod);
    _assign(_months, category.defaultUsefulMonths.toString());
    _assign(_salvageRate, category.defaultResidualRate ?? '');
    _assign(_effectiveDate, category.effectiveFrom ?? '');
    _assign(_requiredDocuments, category.requiredDocumentCodes.join(', '));
    _dirty = false;
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await UtenDialog.show(
      context,
      title: '放弃政策修改？',
      content: const Text('当前会计政策表单有未保存内容。'),
      confirmLabel: '放弃修改',
      danger: true,
    );
    return discard == true;
  }

  Future<void> _switchLedger(FinanceAssetLedger ledger) async {
    if (_ledger == ledger || !await _confirmDiscard()) return;
    setState(() => _ledger = ledger);
    await _load();
  }

  Future<void> _selectCategory(FinanceAssetCategory category) async {
    if (!await _confirmDiscard()) return;
    setState(() => _selected = category);
    _populate(category);
  }

  Future<void> _newCategory() async {
    if (!await _confirmDiscard()) return;
    setState(() => _selected = null);
    _clearForm();
  }

  String? _methodCode(String? value) {
    final requiredError = validateRequired(value, '计提方法代码');
    if (requiredError != null) return requiredError;
    if (!RegExp(r'^[A-Z][A-Z0-9_]{1,39}$').hasMatch(value!.trim())) {
      return '方法代码仅支持大写字母、数字和下划线';
    }
    return null;
  }

  List<String> _documents() {
    return _requiredDocuments.text
        .split(RegExp(r'[,，\n]'))
        .map((item) => item.trim().toUpperCase())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _showStyleErrors = true);
    if (!(_formKey.currentState?.validate() ?? false)) {
      context.appWarning('请先修正会计政策字段');
      return;
    }
    final missingStyles =
        _costAccountId.text.isEmpty ||
        _expenseAccountId.text.isEmpty ||
        _clearingAccountId.text.isEmpty ||
        (_ledger == FinanceAssetLedger.fixedAsset &&
            _accumulatedAccountId.text.isEmpty);
    if (_styleLoading || _styleError != null || missingStyles) {
      context.appWarning(
        _styleError ?? (_styleLoading ? '会计科目仍在加载' : '请选择所有必填会计科目'),
      );
      return;
    }
    final documents = _documents();
    if (documents.isEmpty) {
      context.appWarning('请至少配置一种必备资料代码');
      return;
    }
    final input = FinanceAssetCategoryInput(
      objectType: _ledger,
      code: _code.text,
      name: _name.text,
      costStyleId: _costAccountId.text,
      accumulatedStyleId: _ledger == FinanceAssetLedger.fixedAsset
          ? _accumulatedAccountId.text
          : null,
      expenseStyleId: _expenseAccountId.text,
      clearingStyleId: _clearingAccountId.text,
      defaultMethod: _method.text,
      defaultUsefulMonths: int.parse(_months.text.trim()),
      defaultResidualRate: _ledger == FinanceAssetLedger.fixedAsset
          ? _salvageRate.text
          : null,
      effectiveFrom: _effectiveDate.text,
      requiredDocumentCodes: documents,
      expectedVersion: _selected?.rowVersion,
    );
    try {
      final repository = ref.read(financeAssetCategoryRepositoryProvider);
      if (_selected == null) {
        await repository.create(input);
      } else {
        await repository.update(_selected!.id, input);
      }
      if (!mounted) return;
      _dirty = false;
      context.appSuccess(_selected == null ? '会计政策草稿已创建' : '会计政策已保存');
      await _load();
    } catch (error) {
      if (mounted) {
        context.appApiError(error, fallback: '保存失败，表单内容已保留');
      }
    }
  }

  Future<void> _activate() async {
    final selected = _selected;
    if (selected == null) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '启用会计政策？',
      message: '启用「${selected.name}」后，新资产将按该政策生成账簿计划。',
      confirmLabel: '确认启用',
      actionLabel: '会计政策审核并启用',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref
          .read(financeAssetCategoryRepositoryProvider)
          .activate(selected.id, expectedVersion: selected.rowVersion);
      if (!mounted) return;
      context.appSuccess('会计政策已启用');
      await _load();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '启用失败，请刷新后重试');
    }
  }

  Future<void> _close() async {
    if (!await _confirmDiscard() || !mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Material(
        color: theme.colorScheme.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s20,
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s12,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '资产类别与会计政策',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '所有口径由服务端政策驱动；此处不预设金额门槛或税务优惠。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: '关闭',
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: SegmentedButton<FinanceAssetLedger>(
                segments: const [
                  ButtonSegment(
                    value: FinanceAssetLedger.fixedAsset,
                    label: Text('固定资产'),
                    icon: Icon(Icons.apartment_outlined),
                  ),
                  ButtonSegment(
                    value: FinanceAssetLedger.deferredExpense,
                    label: Text('长期待摊'),
                    icon: Icon(Icons.calendar_month_outlined),
                  ),
                ],
                selected: {_ledger},
                onSelectionChanged: (values) => _switchLedger(values.single),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < UtenBreakpoints.expandedStart) {
                    return Column(
                      children: [
                        SizedBox(height: 180, child: _categoryList(theme)),
                        const Divider(height: 1),
                        Expanded(child: _policyForm(theme)),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      SizedBox(width: 300, child: _categoryList(theme)),
                      const VerticalDivider(width: 1),
                      Expanded(child: _policyForm(theme)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryList(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (widget.canApprove)
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s8),
            child: UtenButton(
              icon: Icons.add_rounded,
              onPressed: _newCategory,
              child: const Text('新建政策'),
            ),
          ),
        Expanded(
          child: _categories.isEmpty
              ? const Center(child: Text('尚未配置该类会计政策'))
              : ListView.separated(
                  padding: const EdgeInsets.all(UtenSpacing.s8),
                  itemCount: _categories.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: UtenSpacing.s8),
                  itemBuilder: (context, index) {
                    final category = _categories[index];
                    final selected = _selected?.id == category.id;
                    return Semantics(
                      button: true,
                      selected: selected,
                      label:
                          '${category.name}，${financeAssetStatusLabel(category.status)}',
                      child: Material(
                        color: selected
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerLow,
                        borderRadius: UtenRadius.lgAll,
                        child: InkWell(
                          borderRadius: UtenRadius.lgAll,
                          onTap: () => _selectCategory(category),
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        category.name,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      Text(
                                        category.code,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                financeAssetStatusBadge(category.status),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _policyForm(ThemeData theme) {
    if (!widget.canApprove && _selected == null) {
      return const Center(child: Text('选择一项政策查看详情'));
    }
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _selected == null ? '新政策草稿' : _selected!.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  if (_styleLoading)
                    const Padding(
                      padding: EdgeInsets.only(bottom: UtenSpacing.s12),
                      child: LinearProgressIndicator(),
                    )
                  else if (_styleError != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: UtenRadius.lgAll,
                      ),
                      child: Row(
                        children: [
                          Expanded(child: Text(_styleError!)),
                          UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: _loadStyles,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  UtenFormGrid(
                    children: [
                      UtenInput(
                        label: '政策代码 *',
                        controller: _code,
                        enabled: widget.canApprove && _selected == null,
                        validator: (value) => validateRequired(value, '政策代码'),
                      ),
                      UtenInput(
                        label: '政策名称 *',
                        controller: _name,
                        enabled: widget.canApprove,
                        validator: (value) =>
                            validateRequiredMaxLength(value, 160, '政策名称'),
                      ),
                      _styleDropdown(
                        '${_ledger == FinanceAssetLedger.fixedAsset ? '资产成本' : '待摊成本'}科目',
                        _costAccountId,
                        _balanceStyles,
                      ),
                      if (_ledger == FinanceAssetLedger.fixedAsset)
                        _styleDropdown(
                          '累计折旧科目',
                          _accumulatedAccountId,
                          _balanceStyles,
                        ),
                      _styleDropdown(
                        '${_ledger == FinanceAssetLedger.fixedAsset ? '折旧' : '摊销'}费用科目',
                        _expenseAccountId,
                        _expenseStyles,
                      ),
                      _styleDropdown(
                        '清理过渡科目',
                        _clearingAccountId,
                        _balanceStyles,
                      ),
                      UtenInput(
                        label: '计提方法代码 *',
                        hint: '按服务端政策字典填写',
                        controller: _method,
                        enabled: widget.canApprove,
                        validator: _methodCode,
                      ),
                      UtenInput(
                        label: '政策月份 *',
                        hint: '1 - 1200',
                        controller: _months,
                        enabled: widget.canApprove,
                        keyboardType: TextInputType.number,
                        validator: validateUsefulMonths,
                      ),
                      if (_ledger == FinanceAssetLedger.fixedAsset)
                        UtenInput(
                          label: '残值率',
                          controller: _salvageRate,
                          enabled: widget.canApprove,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          validator: validateSalvageRate,
                        ),
                      UtenInput(
                        label: '生效日期 *',
                        hint: 'YYYY-MM-DD',
                        controller: _effectiveDate,
                        enabled: widget.canApprove,
                        validator: (value) =>
                            validateFinanceDate(value, required: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  UtenInput(
                    label: '必备资料代码 *',
                    hint: '多个代码用逗号分隔，例如 INVOICE, ACCEPTANCE_REPORT',
                    controller: _requiredDocuments,
                    enabled: widget.canApprove,
                    maxLines: 3,
                    validator: (value) => validateRequired(value, '必备资料代码'),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    _ledger == FinanceAssetLedger.fixedAsset
                        ? '固定资产使用成本、累计折旧、折旧费用、清理过渡四类科目。'
                        : '长期待摊使用待摊成本、摊销费用、清理过渡三类科目，不虚构累计摊销备抵。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.canApprove) ...[
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    if (_selected != null &&
                        _selected!.status.toUpperCase() != 'ACTIVE')
                      UtenActionButton(
                        type: UtenActionButtonType.secondary,
                        onAction: _activate,
                        icon: Icons.verified_outlined,
                        label: const Text('审核并启用'),
                      ),
                    UtenActionButton(
                      key: const Key('finance-asset-policy-save'),
                      onAction: _save,
                      icon: Icons.save_outlined,
                      label: Text(_selected == null ? '创建草稿' : '保存政策'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _styleDropdown(
    String label,
    TextEditingController controller,
    List<PaymentStyleNode> styles,
  ) {
    return UtenDropdownField(
      key: ValueKey('$label-${controller.text}'),
      label: label,
      required: true,
      value: controller.text.isEmpty ? null : controller.text,
      enabled: widget.canApprove && !_styleLoading && _styleError == null,
      searchable: true,
      hintText: _styleLoading ? '科目加载中…' : '请选择会计科目',
      items: [
        for (final style in styles)
          UtenDropdownItem(
            value: style.id,
            label: '${style.code} · ${style.name}',
          ),
      ],
      errorMessage: _showStyleErrors && controller.text.isEmpty
          ? '请选择$label'
          : null,
      onChanged: (value) {
        setState(() {
          controller.text = value ?? '';
          _dirty = true;
        });
      },
    );
  }
}
