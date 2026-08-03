// 入职办理页（真实后端）：单表单分组提交 → 后端原子建 employee+敏感+薪资+合同+轨迹+账号。
// 工号提交时自动生成（UT 前缀）；登录账号 = 手机号；初始密码 = 身份证后 6 位（首登强制改）。
// 岗位为空起步：可选择部门已有岗位，也可填写新岗位，确认后再回填表单。
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120），分组为 UtenSectionHeader + UtenCard。
// 文档：docs/03-页面/入职流程页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/input/china_input_formatters.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/security/input_validators.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/id_card_utils.dart';
import '../../../shared/auth/permissions.dart';
import '../../department/widgets/uten_position_entry_picker.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';

class EmployeeOnboardingPage extends ConsumerStatefulWidget {
  const EmployeeOnboardingPage({super.key, this.initialDepartmentId});

  /// 由「部门管理 → 添加员工」传入，预填所属部门；其余入口为 null。
  final String? initialDepartmentId;

  @override
  ConsumerState<EmployeeOnboardingPage> createState() =>
      _EmployeeOnboardingPageState();
}

class _EmployeeOnboardingPageState
    extends ConsumerState<EmployeeOnboardingPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _idNumber = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _hireDate = TextEditingController();
  final _baseSalary = TextEditingController();
  final _bankAccount = TextEditingController();
  final _bankBranch = TextEditingController();

  /// 岗位只有在弹层点击确认后才更新；已有岗位保留 id，自定义岗位保留名称。
  PositionEntryValue _position = const PositionEntryValue.empty();

  // Backend option codes are unchanged; labels come from l10n at build time.
  static const _idTypeCodes = ['身份证', '护照', '港澳台通行证', '其他'];
  static const _employmentTypeCodes = [
    'regular',
    'dispatch',
    'intern',
    'outsource',
  ];
  static const _statusCodes = ['active', 'probation', 'onLeave'];

  String _idType = '身份证';
  String _employmentType = 'regular';
  String _status = 'active';
  String? _departmentId;
  List<DeptSelection> _departmentSelection = const [];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final initialDepartmentId = widget.initialDepartmentId?.trim();
    _departmentId = initialDepartmentId?.isEmpty == true
        ? null
        : initialDepartmentId;
    _departmentSelection = _departmentId == null
        ? const []
        : [
            DeptSelection(
              id: _departmentId!,
              name: '',
              fullPath: '',
              level: '',
            ),
          ];
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _idNumber,
      _phone,
      _email,
      _hireDate,
      _baseSalary,
      _bankAccount,
      _bankBranch,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: DateTime(1990),
      lastDate: today.add(const Duration(days: 365)),
    );
    if (d != null) {
      _hireDate.text = DateFormat('yyyy-MM-dd').format(d);
    }
  }

  String _idTypeLabel(AppLocalizations l10n, String code) => switch (code) {
    '身份证' => l10n.idTypeIdCard,
    '护照' => l10n.idTypePassport,
    '港澳台通行证' => l10n.idTypeHmtPermit,
    '其他' => l10n.idTypeOther,
    _ => code,
  };

  String _employmentTypeLabel(AppLocalizations l10n, String code) =>
      switch (code) {
        'regular' => l10n.employmentTypeRegular,
        'dispatch' => l10n.employmentTypeDispatch,
        'intern' => l10n.employmentTypeIntern,
        'outsource' => l10n.employmentTypeOutsource,
        _ => code,
      };

  String _statusLabel(AppLocalizations l10n, String code) => switch (code) {
    'active' => l10n.employeeStatusActive,
    'probation' => l10n.employeeStatusProbation,
    'onLeave' => l10n.employeeStatusOnLeave,
    _ => code,
  };

  Future<void> _submit() async {
    final permissions = ref.read(currentPermissionsProvider);
    if (!permissions.contains(Perm.employeeCreate) ||
        !permissions.contains(Perm.employeePiiEdit)) {
      context.appError('无员工入职或敏感信息写入权限'); // TODO(l10n): 补 arb
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    final l10n = AppLocalizations.of(context);
    try {
      final profile = <String, dynamic>{
        'fullName': _name.text.trim(),
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        'phone': _phone.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
      };
      final employment = <String, dynamic>{
        'departmentId': _departmentId,
        if (_position.position != null) 'positionId': _position.position!.id,
        if (_position.position == null &&
            (_position.customName?.trim().isNotEmpty ?? false))
          'positionName': _position.customName!.trim(),
        'hireDate': _hireDate.text.trim().isEmpty
            ? ChinaDateTime.formatDate(ChinaDateTime.today())
            : _hireDate.text.trim(),
        'employmentType': _employmentType,
        'status': _status,
      };
      Map<String, dynamic>? compensation;
      final canEditCompensation = permissions.contains(
        Perm.employeeCompensationEdit,
      );
      if ((canEditCompensation && _baseSalary.text.trim().isNotEmpty) ||
          _bankAccount.text.trim().isNotEmpty ||
          _bankBranch.text.trim().isNotEmpty) {
        compensation = {
          if (canEditCompensation && _baseSalary.text.trim().isNotEmpty)
            'baseSalary': _baseSalary.text.trim(),
          if (_bankAccount.text.trim().isNotEmpty)
            'bankAccount': _bankAccount.text.trim(),
          if (_bankBranch.text.trim().isNotEmpty)
            'bankBranch': _bankBranch.text.trim(),
        };
      }
      final onboardingResult = await ref
          .read(employeeRepositoryProvider)
          .create(
            EmployeeOnboardingInput(
              profile: profile,
              employment: employment,
              compensation: compensation,
            ),
          );
      if (!mounted) return;
      await _showOnboardingCredential(onboardingResult);
      if (!mounted) return;
      context.appSuccess(l10n.employeeOnboardSuccess);
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e, fallback: l10n.employeeOnboardSubmitFailed);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.employeeOnboardSubmitFailed);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showOnboardingCredential(EmployeeOnboardingResult result) {
    final l10n = AppLocalizations.of(context);
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.key_rounded),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(child: Text(l10n.employeeOnboardCredentialTitle)),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.employeeOnboardCredentialWarning),
                const SizedBox(height: UtenSpacing.s16),
                Text(
                  l10n.employeeFieldCode,
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                SelectableText(result.employee.code),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  l10n.employeeOnboardAccountLabel,
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                SelectableText(result.loginAccount),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  l10n.employeeOnboardTemporaryPasswordLabel,
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                const SizedBox(height: UtenSpacing.s4),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    result.temporaryPassword,
                    textAlign: TextAlign.center,
                    style: Theme.of(dialogContext).textTheme.titleLarge
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                  ),
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: result.temporaryPassword),
                );
                if (dialogContext.mounted) {
                  dialogContext.appSuccess(
                    l10n.employeeOnboardTemporaryPasswordCopied,
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: Text(l10n.employeeOnboardCopyTemporaryPassword),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.employeeOnboardCredentialSaved),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canOnboard =
        permissions.contains(Perm.employeeCreate) &&
        permissions.contains(Perm.employeePiiEdit);
    final canEditCompensation = permissions.contains(
      Perm.employeeCompensationEdit,
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.employeeOnboardTitle,
        showBackButton: true,
      ),
      // 表单页全断点窄版收敛（1120），避免宽屏表单被拉得过长
      body: !canOnboard
          ? const UtenEmpty(
              icon: Icons.lock_outline_rounded,
              message: '无员工入职或敏感信息写入权限', // TODO(l10n): 补 arb
            )
          : UtenContentContainer.narrow(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _group(l10n.employeeOnboardGroupProfile, [
                      Builder(
                        builder: (noteCtx) {
                          final theme = Theme.of(noteCtx);
                          return Container(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                              borderRadius: UtenRadius.lgAll,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: UtenSpacing.s8),
                                Expanded(
                                  child: Text(
                                    l10n.employeeOnboardCodeAutoNote,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      _text(
                        _name,
                        '${l10n.employeeFieldName}*',
                        l10n.employeeOnboardHintName,
                        validator: (v) => _req(l10n, v, l10n.employeeFieldName),
                        autofillHints: const [AutofillHints.name],
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _idType,
                        decoration: InputDecoration(
                          labelText: '${l10n.employeeFieldIdType}*',
                        ),
                        items: _idTypeCodes
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(_idTypeLabel(l10n, c)),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _idType = v ?? _idType),
                      ),
                      _text(
                        _idNumber,
                        '${l10n.employeeFieldIdNumber}*',
                        l10n.employeeOnboardHintIdNumber,
                        validator: (v) =>
                            _idType == '身份证' && !IdCardUtils.isValid(v)
                            ? l10n.employeeOnboardIdNumberInvalid
                            : _req(l10n, v, l10n.employeeFieldIdNumber),
                        inputFormatters: _idType == '身份证'
                            ? ChinaInputFormatters.residentId
                            : null,
                        textCapitalization: TextCapitalization.characters,
                      ),
                      _text(
                        _phone,
                        '${l10n.employeeFieldPhone}*',
                        l10n.employeeOnboardHintPhone,
                        validator: (v) {
                          final error = InputValidators.phone(v);
                          return error == null
                              ? null
                              : (v == null || v.trim().isEmpty)
                              ? l10n.employeeOnboardPhoneRequired
                              : l10n.employeeOnboardPhoneInvalid;
                        },
                        keyboardType: TextInputType.phone,
                        inputFormatters: ChinaInputFormatters.phone,
                        autofillHints: const [AutofillHints.telephoneNumber],
                      ),
                      _text(
                        _email,
                        l10n.employeeFieldEmail,
                        l10n.employeeOnboardEmailOptional,
                        validator: InputValidators.email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                      ),
                    ]),
                    _group(l10n.employeeOnboardGroupOrg, [
                      UtenDepartmentPicker(
                        mode: UtenDepartmentPickerMode.single,
                        label: '${l10n.employeeFieldDepartment}*',
                        initialSelection: _departmentSelection,
                        requireConfirm: true,
                        expandOnRowTap: true,
                        onChanged: (sel) {
                          final nextDepartmentId = sel.isEmpty
                              ? null
                              : sel.first.id;
                          final departmentChanged =
                              nextDepartmentId != _departmentId;
                          setState(() {
                            _departmentId = nextDepartmentId;
                            _departmentSelection = List.unmodifiable(sel);
                            if (departmentChanged) {
                              _position = const PositionEntryValue.empty();
                            }
                          });
                        },
                        validator: (sel) => sel.isEmpty
                            ? l10n.employeeOnboardPickDepartment
                            : null,
                      ),
                      UtenPositionEntryPicker(
                        departmentId: _departmentId,
                        value: _position,
                        label: l10n.employeeFieldPosition,
                        onChanged: (value) => setState(() => _position = value),
                      ),
                      GestureDetector(
                        onTap: _pickDate,
                        child: AbsorbPointer(
                          child: _text(
                            _hireDate,
                            '${l10n.employeeFieldHireDate}*',
                            l10n.employeeOnboardHireDateHint,
                            validator: (v) => (v == null || v.isEmpty)
                                ? l10n.employeeOnboardPickHireDate
                                : null,
                          ),
                        ),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _employmentType,
                        decoration: InputDecoration(
                          labelText: '${l10n.employeeFieldEmploymentType}*',
                        ),
                        items: _employmentTypeCodes
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(_employmentTypeLabel(l10n, c)),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(
                          () => _employmentType = v ?? _employmentType,
                        ),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _status,
                        decoration: InputDecoration(
                          labelText: '${l10n.employeeFieldStatus}*',
                        ),
                        items: _statusCodes
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(_statusLabel(l10n, c)),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _status = v ?? _status),
                      ),
                    ]),
                    _group(l10n.employeeOnboardGroupPay, [
                      if (canEditCompensation)
                        _text(
                          _baseSalary,
                          l10n.employeeFieldBaseSalary,
                          l10n.employeeOnboardEmailOptional,
                        ),
                      _text(
                        _bankBranch,
                        l10n.employeeFieldBankBranch,
                        l10n.employeeOnboardEmailOptional,
                      ),
                      _text(
                        _bankAccount,
                        l10n.employeeFieldBankAccount,
                        l10n.employeeOnboardEmailOptional,
                      ),
                    ]),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s12,
                      ),
                      child: Builder(
                        builder: (context) {
                          final theme = Theme.of(context);
                          return Container(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                              borderRadius: UtenRadius.lgAll,
                            ),
                            child: Text(
                              l10n.employeeOnboardNote,
                              style: theme.textTheme.bodySmall,
                            ),
                          );
                        },
                      ),
                    ),
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.employeeOnboardSubmit),
                    ),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
            ),
    );
  }

  /// 分组：UtenSectionHeader（卡外标题）+ UtenCard（字段），字段间距 12、区块间距 24。
  Widget _group(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(title: title),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i < children.length - 1)
                    const SizedBox(height: UtenSpacing.s12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _text(
    TextEditingController c,
    String label,
    String hint, {
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    Iterable<String>? autofillHints,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return TextFormField(
      controller: c,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      validator: validator,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      autofillHints: autofillHints,
      textCapitalization: textCapitalization,
    );
  }

  String? _req(AppLocalizations l10n, String? v, String label) =>
      (v == null || v.trim().isEmpty)
      ? l10n.employeeOnboardFieldRequired(label)
      : null;
}
