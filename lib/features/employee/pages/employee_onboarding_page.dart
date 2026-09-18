// 入职办理页（真实后端）：单表单分组提交 → 后端原子建 employee+敏感+薪资+合同+轨迹+账号。
// 工号提交时自动生成（UT 前缀）；登录账号 = 手机号；初始密码 = 身份证后 6 位（首登强制改）。
// 岗位为空起步：可选择部门已有岗位，也可填写新岗位，确认后再回填表单。
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120），分组为 UtenSectionHeader + UtenCard。
// 2026-09-18 UI 统一收口：日期字段改 UtenDateField（与其它编辑页 outlined 同款）、
// 吸底提交按钮改右下悬浮操作组（2026-09-14 全站口径），日期必填校验移到提交时。
// 文档：docs/03-页面/入职流程页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
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
import '../widgets/employee_credential_dialog.dart';

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
  // 日期字段走 UtenDateField：值是 DateTime（提交时格式化），必填校验在 _submit。
  DateTime? _hireDate;
  // ADR-021：用工状态=正式（active）时转正日期必填；默认带入入职日期可改
  DateTime? _confirmedDate;
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
      _baseSalary,
      _bankAccount,
      _bankBranch,
    ]) {
      c.dispose();
    }
    super.dispose();
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
    final l10n = AppLocalizations.of(context);
    // 日期字段是 UtenDateField（非 FormField），必填校验在这里收口。
    if (_hireDate == null) {
      context.appError(l10n.employeeOnboardPickHireDate);
      return;
    }
    // ADR-021：正式入职必须登记转正日期（后端 fail closed 复核）
    if (_status == 'active' && _confirmedDate == null) {
      context.appError('正式入职的员工必须填写转正日期'); // TODO(l10n): 补 arb
      return;
    }
    // 转正日期不得早于入职日期（原日期选择器口径，改 UtenDateField 后由提交校验承担）
    if (_status == 'active' && _confirmedDate!.isBefore(_hireDate!)) {
      context.appError('转正日期不能早于入职日期'); // TODO(l10n): 补 arb
      return;
    }
    setState(() => _submitting = true);
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
        'hireDate': ChinaDateTime.formatDate(_hireDate!),
        'employmentType': _employmentType,
        'status': _status,
        // ADR-021：正式入职必须登记转正日期（后端 fail closed 复核）
        if (_status == 'active')
          'confirmedAt': ChinaDateTime.formatDate(_confirmedDate!),
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
      await showEmployeeCredentialDialog(context, onboardingResult);
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
      // 2026-09-14 UI 统一口径：吸底提交按钮改右下悬浮组，统一 large 尺寸。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: UtenFloatingActionGroup(
        children: [
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.how_to_reg_outlined,
            isLoading: _submitting,
            onPressed: _submitting ? null : _submit,
            child: Text(l10n.employeeOnboardSubmit),
          ),
        ],
      ),
      // 表单页全断点窄版收敛（1120），避免宽屏表单被拉得过长
      body: !canOnboard
          ? const UtenEmpty(
              icon: Icons.lock_outline_rounded,
              message: '无员工入职或敏感信息写入权限', // TODO(l10n): 补 arb
            )
          : UtenContentContainer.narrow(
              child: Stack(
                children: [
                  Form(
                    key: _formKey,
                    child: ListView(
                      // 底部留出右下悬浮操作组的高度。
                      padding: const EdgeInsets.fromLTRB(
                        0,
                        UtenSpacing.s16,
                        0,
                        UtenFloatingActionGroup.scrollClearance,
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
                            l10n.employeeFieldName,
                            l10n.employeeOnboardHintName,
                            required: true,
                            validator: (v) =>
                                _req(l10n, v, l10n.employeeFieldName),
                            autofillHints: const [AutofillHints.name],
                          ),
                          UtenDropdownField(
                            label: l10n.employeeFieldIdType,
                            required: true,
                            value: _idType,
                            allowClear: false,
                            searchable: false,
                            items: [
                              for (final c in _idTypeCodes)
                                UtenDropdownItem(
                                  value: c,
                                  label: _idTypeLabel(l10n, c),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _idType = v ?? _idType),
                          ),
                          _text(
                            _idNumber,
                            l10n.employeeFieldIdNumber,
                            l10n.employeeOnboardHintIdNumber,
                            required: true,
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
                            l10n.employeeFieldPhone,
                            l10n.employeeOnboardHintPhone,
                            required: true,
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
                            autofillHints: const [
                              AutofillHints.telephoneNumber,
                            ],
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
                            onChanged: (value) =>
                                setState(() => _position = value),
                          ),
                          UtenDateField(
                            label: l10n.employeeFieldHireDate,
                            required: true,
                            value: _hireDate,
                            firstDate: DateTime(1990),
                            lastDate: ChinaDateTime.today().add(
                              const Duration(days: 365),
                            ),
                            onChanged: (d) {
                              setState(() {
                                _hireDate = d;
                                // 正式员工转正日期默认=入职日期（可改）；试用员工不涉及
                                if (_status == 'active' &&
                                    _confirmedDate == null) {
                                  _confirmedDate = d;
                                }
                              });
                            },
                          ),
                          UtenDropdownField(
                            label: l10n.employeeFieldEmploymentType,
                            required: true,
                            value: _employmentType,
                            allowClear: false,
                            searchable: false,
                            items: [
                              for (final c in _employmentTypeCodes)
                                UtenDropdownItem(
                                  value: c,
                                  label: _employmentTypeLabel(l10n, c),
                                ),
                            ],
                            onChanged: (v) => setState(
                              () => _employmentType = v ?? _employmentType,
                            ),
                          ),
                          // ADR-021：正式（active）入职必须填写转正日期；试用由合同试用期派生
                          if (_status == 'active')
                            UtenDateField(
                              label: '转正日期',
                              required: true,
                              info: '正式入职必填，默认=入职日期，可按实际修改',
                              value: _confirmedDate,
                              firstDate: DateTime(1990),
                              lastDate: ChinaDateTime.today(),
                              onChanged: (d) =>
                                  setState(() => _confirmedDate = d),
                            ),
                          UtenDropdownField(
                            label: l10n.employeeFieldStatus,
                            required: true,
                            value: _status,
                            allowClear: false,
                            searchable: false,
                            items: [
                              for (final c in _statusCodes)
                                UtenDropdownItem(
                                  value: c,
                                  label: _statusLabel(l10n, c),
                                ),
                            ],
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
                        // 提交按钮在右下悬浮操作组（UtenFloatingActionGroup），
                        // 底部留白已由 ListView padding(scrollClearance) 承担。
                      ],
                    ),
                  ),
                  // 提交建档网络段的全屏加载遮罩（一次性凭据弹窗展示前已撤下）。
                  if (_submitting)
                    UtenBusyOverlay(
                      title: l10n.employeeOnboardTitle,
                      description: '正在创建员工档案与初始账号，请勿重复提交或离开本页。',
                    ),
                ],
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
    bool required = false,
  }) {
    if (!required) {
      return TextFormField(
        errorBuilder: utenTextFieldErrorBuilder,
        controller: c,
        decoration: UtenInputDecoration(
          InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        validator: validator,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        autofillHints: autofillHints,
        textCapitalization: textCapitalization,
      );
    }
    // 必填：听控制器，为空时描红边 + 红 *（label 由本项追加，调用方勿再带 *）。
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final theme = Theme.of(context);
        final empty = c.text.trim().isEmpty;
        return TextFormField(
          errorBuilder: utenTextFieldErrorBuilder,
          controller: c,
          decoration: UtenInputDecoration(
            applyRequiredEmpty(
              InputDecoration(
                label: requiredLabel(
                  label,
                  theme,
                  required: true,
                  base: theme.inputDecorationTheme.labelStyle,
                ),
                hintText: hint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              theme,
              requiredEmpty: empty,
            ),
          ),
          validator: validator,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          autofillHints: autofillHints,
          textCapitalization: textCapitalization,
        );
      },
    );
  }

  String? _req(AppLocalizations l10n, String? v, String label) =>
      (v == null || v.trim().isEmpty)
      ? l10n.employeeOnboardFieldRequired(label)
      : null;
}
