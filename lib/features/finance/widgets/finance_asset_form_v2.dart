import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/finance_asset_category_models.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_category_repository.dart';
import '../repositories/finance_asset_workbench_repository.dart';
import 'finance_asset_ui.dart';

Future<bool> showFinanceAssetForm(
  BuildContext context, {
  required FinanceAssetLedger ledger,
  FinanceAssetSummary? existing,
}) async {
  final compact =
      MediaQuery.sizeOf(context).width < UtenBreakpoints.mediumStart;
  final content = FinanceAssetFormSurface(ledger: ledger, existing: existing);
  if (compact) {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          isDismissible: false,
          enableDrag: false,
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(UtenRadius.xxl),
            ),
          ),
          builder: (_) =>
              FractionallySizedBox(heightFactor: 0.95, child: content),
        ) ??
        false;
  }
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Dialog(
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920, maxHeight: 860),
            child: SizedBox(
              width: double.infinity,
              height: MediaQuery.sizeOf(context).height * 0.9,
              child: content,
            ),
          ),
        ),
      ) ??
      false;
}

class FinanceAssetFormSurface extends ConsumerStatefulWidget {
  const FinanceAssetFormSurface({
    super.key,
    required this.ledger,
    this.existing,
  });

  final FinanceAssetLedger ledger;
  final FinanceAssetSummary? existing;

  @override
  ConsumerState<FinanceAssetFormSurface> createState() =>
      _FinanceAssetFormSurfaceState();
}

class _FinanceAssetFormSurfaceState
    extends ConsumerState<FinanceAssetFormSurface> {
  final _formKey = GlobalKey<FormState>();
  final _categoryGuard = LatestRequestGuard();
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _months;
  late final TextEditingController _salvageRate;
  late final TextEditingController _location;
  late final TextEditingController _serialNumber;
  late final TextEditingController _assetTag;
  late final TextEditingController _costCenterCode;
  late final TextEditingController _sourceRef;
  late final TextEditingController _sourceLineRef;
  late final TextEditingController _remark;
  late final List<TextEditingController> _controllers;

  List<FinanceAssetCategory> _categories = const [];
  bool _categoriesLoading = true;
  String? _categoriesError;
  String? _categoryId;
  String? _categoryError;
  String? _departmentId;
  String? _departmentName;
  String? _sourceType;
  String? _custodianId;
  UtenEmployeePickerItem? _custodian;
  DateTime? _acquisitionDate;
  DateTime? _acceptanceDate;
  DateTime? _readyForUseDate;
  DateTime? _benefitStartDate;
  DateTime? _benefitEndDate;
  DateTime? _sourceDocumentDate;
  String? _dateError;
  bool _dirty = false;

  bool get _isNew => widget.existing == null;
  bool get _fixed => widget.ledger == FinanceAssetLedger.fixedAsset;

  @override
  void initState() {
    super.initState();
    final item = widget.existing;
    _name = TextEditingController(text: item?.name ?? '');
    _amount = TextEditingController(
      text: item == null
          ? ''
          : _fixed
          ? item.originalValue
          : item.totalAmount,
    );
    _months = TextEditingController(text: item?.usefulMonths?.toString() ?? '');
    _salvageRate = TextEditingController(text: item?.salvageRate ?? '');
    _location = TextEditingController(text: item?.location ?? '');
    _serialNumber = TextEditingController(text: item?.serialNumber ?? '');
    _assetTag = TextEditingController(text: item?.assetTag ?? '');
    _costCenterCode = TextEditingController(text: item?.costCenterCode ?? '');
    _sourceType = item?.sourceType;
    _sourceRef = TextEditingController(text: item?.sourceRef ?? '');
    _sourceLineRef = TextEditingController(text: item?.sourceLineRef ?? '');
    _remark = TextEditingController(text: item?.remark ?? '');
    _controllers = [
      _name,
      _amount,
      _months,
      _salvageRate,
      _location,
      _serialNumber,
      _assetTag,
      _costCenterCode,
      _sourceRef,
      _sourceLineRef,
      _remark,
    ];
    for (final controller in _controllers) {
      controller.addListener(_markDirty);
    }
    _categoryId = item?.categoryId;
    _departmentId = item?.departmentId;
    _departmentName = item?.departmentName;
    _custodianId = item?.custodianId;
    _acquisitionDate = _parseDate(item?.acquisitionDate);
    _acceptanceDate = _parseDate(item?.acceptanceDate);
    _readyForUseDate = _parseDate(item?.readyForUseDate);
    _benefitStartDate = _parseDate(item?.benefitStartDate);
    _benefitEndDate = _parseDate(item?.benefitEndDate);
    _sourceDocumentDate = _parseDate(item?.sourceDocumentDate);
    _loadCategories();
    _preloadCustodian();
  }

  DateTime? _parseDate(String? value) {
    return value == null || value.isEmpty ? null : DateTime.tryParse(value);
  }

  String? _iso(DateTime? value) {
    if (value == null) return null;
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  String? get _derivedStartPeriod {
    final date = _fixed ? _readyForUseDate : _benefitStartDate;
    if (date == null) return null;
    if (!_fixed) {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}';
    }
    final next = DateTime(date.year, date.month + 1);
    return '${next.year}-${next.month.toString().padLeft(2, '0')}';
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

  Future<void> _loadCategories() async {
    final generation = _categoryGuard.begin();
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    try {
      final categories = await ref
          .read(financeAssetCategoryRepositoryProvider)
          .list(widget.ledger);
      if (!mounted || !_categoryGuard.isCurrent(generation)) return;
      setState(() {
        _categories = categories;
        _categoriesLoading = false;
      });
    } catch (_) {
      if (!mounted || !_categoryGuard.isCurrent(generation)) return;
      setState(() {
        _categoriesLoading = false;
        _categoriesError = '资产分类加载失败';
      });
    }
  }

  Future<void> _preloadCustodian() async {
    final id = _custodianId;
    if (id == null || id.isEmpty) return;
    try {
      final profile = await ref.read(employeeRepositoryProvider).getById(id);
      if (!mounted) return;
      setState(() {
        _custodian = UtenEmployeePickerItem(
          id: profile.id,
          name: profile.fullName ?? '',
          departmentName: profile.departmentName,
        );
      });
    } catch (_) {
      // Existing ID remains preserved even if its display name cannot load.
    }
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final result = await ref
        .read(employeeRepositoryProvider)
        .list(
          size: 30,
          search: keyword,
          departmentId: _departmentId,
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
  }

  Future<void> _requestClose() async {
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final discard = await UtenDialog.show(
      context,
      title: '放弃未保存内容？',
      content: const Text('当前表单已有修改，关闭后不会自动保存。'),
      confirmLabel: '放弃修改',
      danger: true,
    );
    if (!mounted || discard != true) return;
    _dirty = false;
    Navigator.of(context).pop(false);
  }

  bool _validateSelections() {
    var valid = true;
    setState(() {
      _categoryError = null;
      _dateError = null;
      if (_fixed) {
        if (_acquisitionDate == null || _readyForUseDate == null) {
          _dateError = '请选择取得日期和达到预定可使用日期';
          valid = false;
        } else if (_acceptanceDate != null &&
            _acceptanceDate!.isBefore(_acquisitionDate!)) {
          _dateError = '验收日期不能早于取得日期';
          valid = false;
        } else if (_readyForUseDate!.isBefore(_acquisitionDate!)) {
          _dateError = '达到预定可使用日期不能早于取得日期';
          valid = false;
        }
      } else {
        if (_benefitStartDate == null || _benefitEndDate == null) {
          _dateError = '请选择受益开始与结束日期';
          valid = false;
        } else if (_benefitEndDate!.isBefore(_benefitStartDate!)) {
          _dateError = '受益结束日期不能早于开始日期';
          valid = false;
        }
      }
    });
    if (_departmentId == null) valid = false;
    return valid;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final fieldValid = _formKey.currentState?.validate() ?? false;
    final selectionValid = _validateSelections();
    if (!fieldValid || !selectionValid) {
      context.appWarning('请先修正表单中的字段错误');
      return;
    }
    final existing = widget.existing;
    final input = FinanceAssetDraftInput(
      ledger: widget.ledger,
      categoryId: _categoryId,
      name: _name.text,
      amount: _amount.text,
      usefulMonths: int.parse(_months.text.trim()),
      salvageRate: _fixed ? _salvageRate.text : null,
      startPeriod: _derivedStartPeriod,
      acquisitionDate: _fixed ? _iso(_acquisitionDate) : null,
      acceptanceDate: _fixed ? _iso(_acceptanceDate) : null,
      readyForUseDate: _fixed ? _iso(_readyForUseDate) : null,
      serialNumber: _fixed ? _serialNumber.text : null,
      assetTag: _fixed ? _assetTag.text : null,
      costCenterCode: _costCenterCode.text,
      benefitStartDate: _fixed ? null : _iso(_benefitStartDate),
      benefitEndDate: _fixed ? null : _iso(_benefitEndDate),
      departmentId: _departmentId!,
      location: _location.text,
      custodianId: _fixed ? _custodianId : null,
      responsibleEmployeeId: _fixed ? null : _custodianId,
      sourceType: _sourceType,
      sourceId: existing?.sourceId,
      sourceRef: _sourceRef.text,
      sourceLineRef: _sourceLineRef.text,
      sourceDocumentDate: _iso(_sourceDocumentDate),
      remark: _remark.text,
      expectedVersion: existing?.version,
    );
    try {
      final repository = ref.read(financeAssetWorkbenchRepositoryProvider);
      if (_isNew) {
        await repository.createDraft(widget.ledger, input);
      } else {
        await repository.updateDraft(widget.ledger, existing!.id, input);
      }
      if (!mounted) return;
      _dirty = false;
      context.appSuccess(_isNew ? '草稿已创建，编号由系统生成' : '草稿已保存');
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        context.appApiError(error, fallback: '保存失败，表单内容已保留，请检查后重试');
      }
    }
  }

  void _selectCategory(String? id) {
    setState(() {
      _categoryId = id;
      _categoryError = null;
      _dirty = true;
      if (!_isNew || id == null) return;
      final category = _categories.where((item) => item.id == id).firstOrNull;
      if (category == null) return;
      if (_months.text.trim().isEmpty && category.defaultUsefulMonths > 0) {
        _months.text = category.defaultUsefulMonths.toString();
      }
      if (_fixed &&
          _salvageRate.text.trim().isEmpty &&
          category.defaultResidualRate?.isNotEmpty == true) {
        _salvageRate.text = category.defaultResidualRate!;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Material(
        color: theme.colorScheme.surface,
        child: Column(
          children: [
            _header(theme),
            const Divider(height: 1),
            Expanded(
              child: Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    context.breakpoint.isCompact
                        ? UtenSpacing.s16
                        : UtenSpacing.s24,
                    UtenSpacing.s20,
                    context.breakpoint.isCompact
                        ? UtenSpacing.s16
                        : UtenSpacing.s24,
                    UtenSpacing.s32,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _identifierNotice(theme),
                      const SizedBox(height: UtenSpacing.s20),
                      Text(
                        '基础与计量',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      UtenFormGrid(
                        children: [
                          _categoryField(),
                          UtenInput(
                            label: '名称 *',
                            controller: _name,
                            validator: (value) => validateRequired(value, '名称'),
                          ),
                          UtenInput(
                            key: const Key('finance-asset-amount'),
                            label: '${widget.ledger.amountLabel} *',
                            hint: '最多 2 位小数',
                            controller: _amount,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            validator: (value) => validateFinanceAmount(
                              value,
                              label: widget.ledger.amountLabel,
                            ),
                          ),
                          UtenInput(
                            label: '${_fixed ? '使用' : '摊销'}月份 *',
                            hint: '1 - 1200；选择分类后可带入政策值',
                            controller: _months,
                            keyboardType: TextInputType.number,
                            validator: validateUsefulMonths,
                          ),
                          if (_fixed)
                            UtenInput(
                              label: '残值率',
                              hint: '选择分类后可带入政策值',
                              controller: _salvageRate,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              validator: validateSalvageRate,
                            ),
                          if (_fixed)
                            UtenInput(
                              label: '设备序列号',
                              controller: _serialNumber,
                              validator: (value) =>
                                  validateMaxLength(value, 160, '设备序列号'),
                            ),
                          if (_fixed)
                            UtenInput(label: '资产标签', controller: _assetTag),
                          UtenInput(
                            label: '成本中心代码',
                            controller: _costCenterCode,
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s24),
                      Text(
                        _fixed ? '关键日期与启折' : '受益期与摊销计划',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      _dateFields(),
                      if (_dateError != null) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        Text(
                          _dateError!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s12),
                      _startPeriodNotice(theme),
                      const SizedBox(height: UtenSpacing.s24),
                      Text(
                        '归属与来源',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      UtenFormGrid(
                        children: [
                          _departmentField(),
                          UtenEmployeePicker(
                            key: ValueKey(
                              'asset-responsible-${widget.ledger.apiValue}-$_custodianId',
                            ),
                            label: _fixed ? '保管人' : '责任人',
                            hint: _fixed ? '请选择保管人' : '请选择责任人',
                            sheetTitle: _fixed ? '选择资产保管人' : '选择待摊责任人',
                            initial: _custodian,
                            departmentName: _departmentName,
                            loader: _loadEmployees,
                            onChanged: (item) {
                              setState(() {
                                _custodian = item;
                                _custodianId = item?.id;
                                _dirty = true;
                              });
                            },
                          ),
                          UtenInput(
                            label: _fixed ? '存放地点' : '受益地点',
                            controller: _location,
                            validator: (value) =>
                                validateMaxLength(value, 300, '地点'),
                          ),
                          UtenDropdownField(
                            key: ValueKey('asset-source-type-$_sourceType'),
                            label: '来源类型',
                            value: _sourceType,
                            hintText: '请选择来源类型',
                            items: [
                              if (_sourceType != null &&
                                  !const {
                                    'PURCHASE',
                                    'AP',
                                    'CONTRACT',
                                    'MANUAL',
                                    'OTHER',
                                  }.contains(_sourceType))
                                UtenDropdownItem(
                                  value: _sourceType!,
                                  label: '现有类型 · $_sourceType',
                                ),
                              const UtenDropdownItem(
                                value: 'PURCHASE',
                                label: '采购入账',
                              ),
                              const UtenDropdownItem(
                                value: 'AP',
                                label: '应付单据',
                              ),
                              const UtenDropdownItem(
                                value: 'CONTRACT',
                                label: '合同',
                              ),
                              const UtenDropdownItem(
                                value: 'MANUAL',
                                label: '手工录入',
                              ),
                              const UtenDropdownItem(
                                value: 'OTHER',
                                label: '其他来源',
                              ),
                            ],
                            onChanged: (value) => setState(() {
                              _sourceType = value;
                              _dirty = true;
                            }),
                          ),
                          UtenInput(
                            label: '来源单据引用（提交前必填）',
                            hint: '合同号、发票号或业务单据号；草稿阶段可稍后补',
                            controller: _sourceRef,
                          ),
                          UtenInput(
                            label: '来源单据行引用（提交前必填）',
                            hint: '填写稳定行号；头级来源请明确填写 HEADER',
                            controller: _sourceLineRef,
                          ),
                          UtenDateField(
                            label: '来源单据日期',
                            value: _sourceDocumentDate,
                            onChanged: (date) => setState(() {
                              _sourceDocumentDate = date;
                              _dirty = true;
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      UtenInput(label: '备注', controller: _remark, maxLines: 3),
                      const SizedBox(height: UtenSpacing.s24),
                      _documentNotice(theme),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return Padding(
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
                  '${_isNew ? '新建' : '编辑'}${widget.ledger.label}',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (widget.existing != null) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.existing!.code,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      financeAssetStatusBadge(widget.existing!.status),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: '关闭',
            onPressed: _requestClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _identifierNotice(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Row(
        children: [
          Icon(Icons.tag_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              _isNew
                  ? '${widget.ledger.label}编号将在保存后由系统自动生成，避免重号。'
                  : '编号 ${widget.existing!.code} 由系统维护，不可直接修改。',
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryField() {
    if (_categoriesLoading) {
      return const LinearProgressIndicator();
    }
    if (_categoriesError != null) {
      return Row(
        children: [
          Expanded(child: Text(_categoriesError!)),
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _loadCategories,
            child: const Text('重试'),
          ),
        ],
      );
    }
    final selectable = [
      for (final item in _categories)
        if (!_isNew ||
            item.status.toUpperCase() == 'ACTIVE' ||
            item.id == _categoryId)
          item,
    ];
    return UtenDropdownField(
      key: ValueKey('asset-category-$_categoryId'),
      label: '资产分类',
      searchable: true,
      value: _categoryId,
      hintText: selectable.isEmpty ? '暂无可用分类，可先保存不完整草稿' : '请选择资产分类',
      errorText: _categoryError,
      items: [
        for (final item in selectable)
          UtenDropdownItem(
            value: item.id,
            label: '${item.code} · ${item.name}',
          ),
      ],
      onChanged: _selectCategory,
    );
  }

  Widget _departmentField() {
    return UtenDepartmentPicker(
      key: ValueKey('asset-department-$_departmentId'),
      mode: UtenDepartmentPickerMode.single,
      label: '归属部门 *',
      hint: '请选择归属部门',
      initialSelection: _departmentId == null
          ? const []
          : [
              DeptSelection(
                id: _departmentId!,
                name: _departmentName ?? '',
                fullPath: _departmentName ?? '',
                level: 'DEPARTMENT',
              ),
            ],
      validator: (selection) => selection.isEmpty ? '请选择归属部门' : null,
      onChanged: (selection) {
        final department = selection.firstOrNull;
        setState(() {
          _departmentId = department?.id;
          _departmentName = department?.fullPath;
          _dirty = true;
        });
      },
    );
  }

  Widget _dateFields() {
    return UtenFormGrid(
      children: _fixed
          ? [
              UtenDateField(
                label: '取得日期',
                required: true,
                value: _acquisitionDate,
                onChanged: (date) => setState(() {
                  _acquisitionDate = date;
                  _dateError = null;
                  _dirty = true;
                }),
              ),
              UtenDateField(
                label: '验收日期',
                value: _acceptanceDate,
                onChanged: (date) => setState(() {
                  _acceptanceDate = date;
                  _dateError = null;
                  _dirty = true;
                }),
              ),
              UtenDateField(
                label: '达到预定可使用日期',
                required: true,
                value: _readyForUseDate,
                onChanged: (date) => setState(() {
                  _readyForUseDate = date;
                  _dateError = null;
                  _dirty = true;
                }),
              ),
            ]
          : [
              UtenDateField(
                label: '受益开始日期',
                required: true,
                value: _benefitStartDate,
                onChanged: (date) => setState(() {
                  _benefitStartDate = date;
                  _dateError = null;
                  _dirty = true;
                }),
              ),
              UtenDateField(
                label: '受益结束日期',
                required: true,
                value: _benefitEndDate,
                onChanged: (date) => setState(() {
                  _benefitEndDate = date;
                  _dateError = null;
                  _dirty = true;
                }),
              ),
            ],
    );
  }

  Widget _startPeriodNotice(ThemeData theme) {
    final period = _derivedStartPeriod;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.calculate_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              _fixed
                  ? '启折期间：${period ?? '选择达到预定可使用日期后自动计算'}（从次月开始，不可手工修改）'
                  : '摊销计划：${period == null ? '选择受益期后生成' : '自 $period 起，按受益起止日期和政策月份生成'}',
            ),
          ),
        ],
      ),
    );
  }

  Widget _documentNotice(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.description_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s12),
          const Expanded(child: Text('文档引用可记录来源单据和行号。附件服务尚未启用，本页面不提供虚假上传入口。')),
        ],
      ),
    );
  }

  Widget _footer() {
    final compact = context.breakpoint.isCompact;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Flex(
          direction: compact ? Axis.vertical : Axis.horizontal,
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: _requestClose,
              child: const Text('取消'),
            ),
            SizedBox(
              width: compact ? 0 : UtenSpacing.s12,
              height: compact ? UtenSpacing.s8 : 0,
            ),
            UtenActionButton(
              key: const Key('finance-asset-form-save'),
              onAction: _save,
              icon: Icons.save_outlined,
              isExpanded: compact,
              loadingLabel: const Text('保存中…'),
              label: Text(_isNew ? '创建草稿' : '保存草稿'),
            ),
          ],
        ),
      ),
    );
  }
}
