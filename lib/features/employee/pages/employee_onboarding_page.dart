// 入职办理页（真实后端）：5 步向导 → 后端原子建 employee+敏感+薪资+合同+轨迹+紧急联系人+
// 教育经历+账号。工号提交时自动生成(UT 前缀)；登录账号 = 手机号；初始密码 = 证件号后六位，
// 不足六位时系统随机生成(只显示一次、限时有效、首登强制改)。身份证号仍严格校验并说出具体哪里不对。
// 向导骨架与离职办理/工资条生成同款：Material Stepper + controlsBuilder 隐藏内置按钮 +
// onStepTapped 仅允许回退 + 右下悬浮组(上一步 secondary / 下一步 primary / 末步 danger)，
// 草稿随存步骤号。必填只保留建档最小集(姓名/证件/手机/部门)；用工形式、员工状态、入职日期
// 均有默认值(正式/试用/今天)，性别与出生日期按身份证号自动带出；教育背景与紧急联系人可整步跳过。
// 字段标签全页统一 Material 浮动式（标签在框内边框上，与下拉/日期/各选择器同款），
// 不用 UtenInput 的框外标签，避免同一网格行里框顶不齐。
// 文档：docs/03-页面/入职流程页.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../components/cards/uten_card.dart';
import '../../../core/input/china_input_formatters.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/security/input_validators.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/id_card_utils.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_values.dart';
import '../../../shared/drafts/people_form_draft_values.dart';
import '../../department/models/position.dart';
import '../../department/widgets/uten_position_entry_picker.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/employee_api_models.dart';
import '../models/employee_id_types.dart';
import '../repositories/employee_picker_candidates.dart';
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

class _EmployeeOnboardingPageState extends ConsumerState<EmployeeOnboardingPage>
    with FormDraftMixin<EmployeeOnboardingPage> {
  static const _stepCount = 5;

  bool _canOnboardWith(Set<String> permissions) =>
      permissions.contains(Perm.employeeCreate) &&
      permissions.contains(Perm.employeePiiEdit);
  bool _canEditCompensationWith(Set<String> permissions) =>
      permissions.contains(Perm.employeeCompensationEdit);
  @override
  bool get formDraftBusy => _submitting;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.employeeOnboarding.spec(
    title: '员工入职',
    route: '/employee/onboarding',
  );
  Map<String, TextEditingController> get _draftFields => {
    'name': _name,
    'idNumber': _idNumber,
    'phone': _phone,
    'email': _email,
    'ethnicity': _ethnicity,
    'politicalStatus': _politicalStatus,
    'maritalStatus': _maritalStatus,
    'workLocation': _workLocation,
    'seatNo': _seatNo,
    'attendanceGroup': _attendanceGroup,
    'officePhone': _officePhone,
    'hujiAddress': _hujiAddress,
    'residenceAddress': _residenceAddress,
    'baseSalary': _baseSalary,
    'bankAccount': _bankAccount,
    'bankBranch': _bankBranch,
  };
  @override
  Iterable<Listenable> get formDraftListenables => [
    ..._draftFields.values,
    for (final e in _educations) ...[e.school, e.major],
    for (final c in _contacts) ...[c.name, c.phone],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'fields': draftTextValues(_draftFields),
    'step': _step,
    'hireDate': _hireDate?.toIso8601String(),
    'confirmedDate': _confirmedDate?.toIso8601String(),
    'birthDate': _birthDate?.toIso8601String(),
    'idType': _idType,
    'gender': _gender,
    'employmentType': _employmentType,
    'status': _status,
    'departmentId': _departmentId,
    'departments': draftDepartments(_departmentSelection),
    'position': _position.position == null
        ? null
        : {
            'id': _position.position!.id,
            'code': _position.position!.code,
            'name': _position.position!.name,
            'level': _position.position!.level,
          },
    'customPosition': _position.customName,
    'supervisor': draftEmployees({
      for (final item in [_supervisor].whereType<UtenEmployeePickerItem>())
        item.id: item,
    }),
    'educations': [
      for (final e in _educations)
        {
          'school': e.school.text,
          'major': e.major.text,
          'degree': ?e.degree,
          'startDate': e.startDate?.toIso8601String(),
          'endDate': e.endDate?.toIso8601String(),
        },
    ],
    'contacts': [
      for (final c in _contacts)
        {
          'name': c.name.text,
          'phone': c.phone.text,
          'relationship': ?c.relationship,
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!_canOnboardWith(ref.read(currentPermissionsProvider))) {
      throw StateError('您没有恢复入职信息的权限');
    }
    restoreDraftTextValues(_draftFields, draftMap(data['fields']));
    if (!_canEditCompensationWith(ref.read(currentPermissionsProvider))) {
      _baseSalary.clear();
    }
    _step = ((data['step'] as int?) ?? 0).clamp(0, _stepCount - 1);
    _hireDate = DateTime.tryParse(data['hireDate'] as String? ?? '');
    _confirmedDate = DateTime.tryParse(data['confirmedDate'] as String? ?? '');
    _birthDate = DateTime.tryParse(data['birthDate'] as String? ?? '');
    _idType = data['idType'] as String? ?? employeeIdTypeIdCard;
    _gender = data['gender'] as String?;
    _employmentType = data['employmentType'] as String? ?? 'regular';
    _status = data['status'] as String? ?? 'probation';
    _departmentId = data['departmentId'] as String?;
    _departmentSelection = restoreDraftDepartments(data['departments']);
    _position = data['position'] != null
        ? PositionEntryValue.existing(
            Position.fromJson(draftMap(data['position'])),
          )
        : PositionEntryValue.custom(data['customPosition'] as String?);
    final supervisors = <String, UtenEmployeePickerItem>{};
    restoreDraftEmployees(supervisors, data['supervisor']);
    _supervisor = supervisors.values.firstOrNull;
    _educations = [
      for (final raw in draftMaps(data['educations']))
        _EducationEntry(
          school: (raw['school'] as String?) ?? '',
          major: (raw['major'] as String?) ?? '',
          degree: raw['degree'] as String?,
          startDate: DateTime.tryParse(raw['startDate'] as String? ?? ''),
          endDate: DateTime.tryParse(raw['endDate'] as String? ?? ''),
        ),
    ];
    _contacts = [
      for (final raw in draftMaps(data['contacts']))
        _EmergencyContactEntry(
          name: (raw['name'] as String?) ?? '',
          phone: (raw['phone'] as String?) ?? '',
          relationship: raw['relationship'] as String?,
        ),
    ];
  }

  // 每步一个 Form：_next 只校验当前步(与离职向导同款)；UtenDateField 非 FormField，
  // 日期必填经 errorMessage(_showStepErrors) 与提交兜底收口。
  final _stepFormKeys = List.generate(
    _stepCount,
    (_) => GlobalKey<FormState>(),
  );
  final _name = TextEditingController();
  final _idNumber = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _ethnicity = TextEditingController();
  final _politicalStatus = TextEditingController();
  final _maritalStatus = TextEditingController();
  final _workLocation = TextEditingController();
  final _seatNo = TextEditingController();
  final _attendanceGroup = TextEditingController();
  final _officePhone = TextEditingController();
  final _hujiAddress = TextEditingController();
  final _residenceAddress = TextEditingController();
  final _baseSalary = TextEditingController();
  final _bankAccount = TextEditingController();
  final _bankBranch = TextEditingController();

  /// 岗位只有在弹层点击确认后才更新；已有岗位保留 id，自定义岗位保留名称。
  PositionEntryValue _position = const PositionEntryValue.empty();

  // Backend option codes are unchanged; labels come from l10n at build time.
  // 证件类型代码表与修改证件弹窗共用 employee_id_types.dart。
  static const _employmentTypeCodes = [
    'regular',
    'dispatch',
    'intern',
    'outsource',
  ];
  static const _statusCodes = ['active', 'probation', 'onLeave'];
  static const _degreeCodes = ['博士', '硕士', '本科', '大专', '中专', '高中', '初中', '其他'];
  static const _relationshipCodes = [
    '配偶',
    '父母',
    '子女',
    '兄弟姐妹',
    '亲属',
    '朋友',
    '同事',
    '其他',
  ];

  int _step = 0;
  // 与离职向导同款：仅在校验失败后置真，让非 FormField 字段(日期/下拉)描红提示。
  bool _showStepErrors = false;
  DateTime? _hireDate;
  // ADR-021：用工状态=正式（active）时转正日期必填；默认带入入职日期可改
  DateTime? _confirmedDate;
  DateTime? _birthDate;
  String _idType = employeeIdTypeIdCard;
  String? _gender;
  // 默认「试用」：新员工通常先试用再转正(转正后无法退回试用)，默认正式会强迫
  // 立即填转正日期，且选错方向不可逆；转正在员工详情一键办理。
  String _employmentType = 'regular';
  String _status = 'probation';
  String? _departmentId;
  List<DeptSelection> _departmentSelection = const [];
  UtenEmployeePickerItem? _supervisor;
  List<_EducationEntry> _educations = const [];
  List<_EmergencyContactEntry> _contacts = const [];
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
    // 入职日期默认今天(服务端拒绝未来日期，前端选择器同样以今天封顶)。
    _hireDate = ChinaDateTime.today();
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _idNumber,
      _phone,
      _email,
      _ethnicity,
      _politicalStatus,
      _maritalStatus,
      _workLocation,
      _seatNo,
      _attendanceGroup,
      _officePhone,
      _hujiAddress,
      _residenceAddress,
      _baseSalary,
      _bankAccount,
      _bankBranch,
    ]) {
      c.dispose();
    }
    for (final e in _educations) {
      e.dispose();
    }
    for (final c in _contacts) {
      c.dispose();
    }
    super.dispose();
  }

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

  String _degreeLabel(AppLocalizations l10n, String code) => switch (code) {
    '博士' => l10n.employeeOnboardDegreeDoctor,
    '硕士' => l10n.employeeOnboardDegreeMaster,
    '本科' => l10n.employeeOnboardDegreeBachelor,
    '大专' => l10n.employeeOnboardDegreeCollege,
    '中专' => l10n.employeeOnboardDegreeSecondary,
    '高中' => l10n.employeeOnboardDegreeHighSchool,
    '初中' => l10n.employeeOnboardDegreeMiddleSchool,
    '其他' => l10n.employeeOnboardDegreeOther,
    _ => code,
  };

  String _relationshipLabel(AppLocalizations l10n, String code) =>
      switch (code) {
        '配偶' => l10n.employeeOnboardRelSpouse,
        '父母' => l10n.employeeOnboardRelParent,
        '子女' => l10n.employeeOnboardRelChild,
        '兄弟姐妹' => l10n.employeeOnboardRelSibling,
        '亲属' => l10n.employeeOnboardRelRelative,
        '朋友' => l10n.employeeOnboardRelFriend,
        '同事' => l10n.employeeOnboardRelColleague,
        '其他' => l10n.employeeOnboardRelOther,
        _ => code,
      };

  // ---------------------------------------------------------------------
  // 身份证联动：性别/出生日期按证件号自动带出(服务端对身份证一律以证件号为准)。
  // ---------------------------------------------------------------------

  bool get _identityLocked => _idType == employeeIdTypeIdCard;

  void _refreshIdentityDerived() {
    if (!_identityLocked) return;
    final id = _idNumber.text.trim();
    if (IdCardUtils.problemOf(id) != null) return;
    final birth = IdCardUtils.birthDate(id);
    final gender = IdCardUtils.gender(id);
    if (birth != _birthDate || gender != _gender) {
      setState(() {
        _birthDate = birth;
        _gender = gender;
      });
    }
  }

  // ---------------------------------------------------------------------
  // 步进与校验
  // ---------------------------------------------------------------------

  Future<void> _next() async {
    final l10n = AppLocalizations.of(context);
    final formValid = _stepFormKeys[_step].currentState?.validate() ?? false;
    var manualValid = true;
    if (_step == 1) {
      if (_hireDate == null) manualValid = false;
      if (_status == 'active' && _confirmedDate == null) manualValid = false;
      if (_status == 'active' &&
          _confirmedDate != null &&
          _hireDate != null &&
          _confirmedDate!.isBefore(_hireDate!)) {
        context.appError(l10n.employeeOnboardConfirmDateBeforeHire);
        manualValid = false;
      }
    }
    if (_step == 2) {
      for (var i = 0; i < _educations.length; i++) {
        final e = _educations[i];
        if (e.hasContent && e.degree == null) manualValid = false;
        if (e.startDate != null &&
            e.endDate != null &&
            e.endDate!.isBefore(e.startDate!)) {
          context.appError(l10n.employeeOnboardEduDateOrder);
          manualValid = false;
          break;
        }
      }
    }
    if (!formValid || !manualValid) {
      if (_step == 0 && !formValid) {
        // 身份证号不对时把具体原因(哪一位/长度)再明确提示一次：表单内只显示在字段提示里。
        final idProblem = _idType == employeeIdTypeIdCard
            ? IdCardUtils.problemOf(_idNumber.text)
            : null;
        if (idProblem != null) context.appError(idProblem);
      }
      setState(() => _showStepErrors = true);
      return;
    }
    if (_step < _stepCount - 1) {
      setState(() {
        _showStepErrors = false;
        _step++;
      });
      return;
    }
    await _submit();
  }

  Future<void> _backOrClose() async {
    if (_step > 0) {
      setState(() => _step--);
      return;
    }
    if (!await confirmFormDraftExit() || !mounted) return;
    context.pop();
  }

  Future<void> _submit() async {
    final permissions = ref.read(currentPermissionsProvider);
    if (!_canOnboardWith(permissions)) {
      context.appError(
        AppLocalizations.of(context).employeeOnboardNoPermission,
      );
      return;
    }
    final l10n = AppLocalizations.of(context);
    // 兜底复核当前已挂载的各步表单与日期(正常路径在 _next 已分步校验)。
    for (final key in _stepFormKeys) {
      if (key.currentState != null && !key.currentState!.validate()) {
        return;
      }
    }
    if (_hireDate == null || (_status == 'active' && _confirmedDate == null)) {
      setState(() => _showStepErrors = true);
      return;
    }
    setState(() => _submitting = true);
    try {
      await saveFormDraftNow();
      final profile = <String, dynamic>{
        'fullName': _name.text.trim(),
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        'phone': _phone.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
        if (_gender != null) 'gender': _gender,
        if (_birthDate != null)
          'birthDate': ChinaDateTime.formatDate(_birthDate!),
        if (_ethnicity.text.trim().isNotEmpty)
          'ethnicity': _ethnicity.text.trim(),
        if (_politicalStatus.text.trim().isNotEmpty)
          'politicalStatus': _politicalStatus.text.trim(),
        if (_maritalStatus.text.trim().isNotEmpty)
          'maritalStatus': _maritalStatus.text.trim(),
        if (_hujiAddress.text.trim().isNotEmpty)
          'hujiAddress': _hujiAddress.text.trim(),
        if (_residenceAddress.text.trim().isNotEmpty)
          'residenceAddress': _residenceAddress.text.trim(),
      };
      final employment = <String, dynamic>{
        'departmentId': _departmentId,
        if (_position.position != null) 'positionId': _position.position!.id,
        if (_position.position == null &&
            (_position.customName?.trim().isNotEmpty ?? false))
          'positionName': _position.customName!.trim(),
        if (_supervisor != null) 'supervisorId': _supervisor!.id,
        'hireDate': ChinaDateTime.formatDate(_hireDate!),
        'employmentType': _employmentType,
        'status': _status,
        // ADR-021：正式入职必须登记转正日期（后端 fail closed 复核）
        if (_status == 'active')
          'confirmedAt': ChinaDateTime.formatDate(_confirmedDate!),
        if (_workLocation.text.trim().isNotEmpty)
          'workLocation': _workLocation.text.trim(),
        if (_seatNo.text.trim().isNotEmpty) 'seatNo': _seatNo.text.trim(),
        if (_attendanceGroup.text.trim().isNotEmpty)
          'attendanceGroup': _attendanceGroup.text.trim(),
        if (_officePhone.text.trim().isNotEmpty)
          'officePhone': _officePhone.text.trim(),
      };
      Map<String, dynamic>? compensation;
      final canEditCompensation = _canEditCompensationWith(permissions);
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
      final educations = [
        for (final e in _educations)
          if (e.hasContent)
            {
              'school': e.school.text.trim(),
              if (e.degree != null) 'degree': e.degree,
              if (e.major.text.trim().isNotEmpty) 'major': e.major.text.trim(),
              if (e.startDate != null)
                'startDate': ChinaDateTime.formatDate(e.startDate!),
              if (e.endDate != null)
                'endDate': ChinaDateTime.formatDate(e.endDate!),
            },
      ];
      final emergencyContacts = [
        for (final c in _contacts)
          if (c.hasContent)
            {
              'name': c.name.text.trim(),
              'phone': c.phone.text.trim(),
              if (c.relationship != null) 'relationship': c.relationship,
            },
      ];
      final onboardingResult = await runFormDraftSubmission(
        () => ref
            .read(employeeRepositoryProvider)
            .create(
              EmployeeOnboardingInput(
                profile: profile,
                employment: employment,
                compensation: compensation,
                educations: educations,
                emergencyContacts: emergencyContacts,
              ),
            ),
      );
      await completeFormDraft();
      if (!mounted) return;
      // 一次性凭据弹窗前必须先撤遮罩：遮罩是 root Overlay 的裸图层, Navigator 每次重排
      // 都把它重新抬到最顶, 而这个弹窗 barrierDismissible=false 且 PopScope 挡掉返回键,
      // 唯一出口「我已安全保存」被遮罩吃掉点击; 遮罩又要等这行 await 返回才撤 —— 互相
      // 等待会把页面彻底卡死, 临时密码再也拿不出来(员工却已经建好了)。
      setState(() => _submitting = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await showEmployeeCredentialDialog(context, onboardingResult);
      if (!mounted) return;
      context.appSuccess(l10n.employeeOnboardSuccess);
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e, fallback: l10n.employeeOnboardSubmitFailed);
    } catch (error) {
      if (!mounted) return;
      context.appError(
        describeSubmitError(error, fallback: l10n.employeeOnboardSubmitFailed),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ---------------------------------------------------------------------
  // 页面骨架
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return withFormDraft(_buildEditor(context));
  }

  Widget _buildEditor(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canOnboard = _canOnboardWith(permissions);
    final canEditCompensation = _canEditCompensationWith(permissions);
    return PopScope<void>(
      canPop: !_submitting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_backOrClose());
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.employeeOnboardTitle,
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _submitting ? null : _backOrClose,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        // 2026-09-14 UI 统一口径：向导操作走右下悬浮组（上一步 secondary /
        // 下一步 primary / 末步提交 danger），Stepper 内滚底部让位。
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: UtenFloatingActionGroup(
          children: [
            if (_step > 0)
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.large,
                onPressed: _submitting ? null : _backOrClose,
                child: Text(l10n.employeeOnboardPrevious),
              ),
            UtenButton(
              key: const ValueKey('employee-onboarding-next'),
              type: _step == _stepCount - 1
                  ? UtenButtonType.danger
                  : UtenButtonType.primary,
              size: UtenButtonSize.large,
              icon: _step == _stepCount - 1 ? Icons.how_to_reg_outlined : null,
              isLoading: _submitting,
              onPressed: _submitting ? null : _next,
              child: Text(
                _step == _stepCount - 1
                    ? l10n.employeeOnboardSubmit
                    : l10n.employeeOnboardNext,
              ),
            ),
          ],
        ),
        body: !canOnboard
            ? UtenEmpty(
                icon: Icons.lock_outline_rounded,
                message: l10n.employeeOnboardNoPermissionEmpty,
              )
            : UtenContentContainer.narrow(
                child: Column(
                  children: [
                    // 提交建档网络段的全屏加载遮罩（root Overlay 传送门，不占布局；
                    // 一次性凭据弹窗展示前已在 _submit 里撤下）。
                    if (_submitting)
                      UtenBusyOverlay(
                        title: l10n.employeeOnboardTitle,
                        description: l10n.employeeOnboardSubmitting,
                      ),
                    Expanded(
                      // 底部让位右下悬浮操作组：Stepper 内滚的末尾内容可完整滚到按钮上方。
                      child: Padding(
                        padding: const EdgeInsets.only(
                          bottom:
                              UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: Stepper(
                          currentStep: _step,
                          controlsBuilder: (_, _) => const SizedBox.shrink(),
                          onStepTapped: (step) {
                            if (step < _step) setState(() => _step = step);
                          },
                          steps: _steps(l10n, canEditCompensation),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  List<Step> _steps(AppLocalizations l10n, bool canEditCompensation) => [
    Step(
      title: Text('1. ${l10n.employeeOnboardStepBasic}'),
      isActive: _step >= 0,
      state: _step > 0 ? StepState.complete : StepState.indexed,
      content: _basicStep(l10n),
    ),
    Step(
      title: Text('2. ${l10n.employeeOnboardStepWork}'),
      isActive: _step >= 1,
      state: _step > 1 ? StepState.complete : StepState.indexed,
      content: _workStep(l10n),
    ),
    Step(
      title: Text('3. ${l10n.employeeOnboardStepEducation}'),
      isActive: _step >= 2,
      state: _step > 2 ? StepState.complete : StepState.indexed,
      content: _educationStep(l10n),
    ),
    Step(
      title: Text('4. ${l10n.employeeOnboardStepEmergency}'),
      isActive: _step >= 3,
      state: _step > 3 ? StepState.complete : StepState.indexed,
      content: _emergencyStep(l10n),
    ),
    Step(
      title: Text('5. ${l10n.employeeOnboardStepOther}'),
      isActive: _step >= 4,
      content: _otherStep(l10n, canEditCompensation),
    ),
  ];

  // ---------------------------------------------------------------------
  // 第 1 步：基本信息
  // ---------------------------------------------------------------------

  Widget _basicStep(AppLocalizations l10n) => Form(
    key: _stepFormKeys[0],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _noteBanner(l10n.employeeOnboardCodeAutoNote),
        const SizedBox(height: UtenSpacing.s12),
        UtenFormGrid(
          children: [
            _text(
              _name,
              l10n.employeeFieldName,
              l10n.employeeOnboardHintName,
              required: true,
              validator: (v) => _req(l10n, v, l10n.employeeFieldName),
              autofillHints: const [AutofillHints.name],
            ),
            UtenDropdownField(
              label: l10n.employeeFieldIdType,
              required: true,
              value: _idType,
              allowClear: false,
              searchable: false,
              items: [
                for (final c in employeeIdTypeCodes)
                  UtenDropdownItem(
                    value: c,
                    label: employeeIdTypeLabel(l10n, c),
                  ),
              ],
              onChanged: (v) {
                setState(() => _idType = v ?? _idType);
                _refreshIdentityDerived();
              },
            ),
            _text(
              _idNumber,
              l10n.employeeFieldIdNumber,
              l10n.employeeOnboardHintIdNumber,
              required: true,
              // 身份证给出具体哪里不对(长度/第几位/校验码)，与后端同一句话。
              validator: (v) => _idType == employeeIdTypeIdCard
                  ? IdCardUtils.problemOf(v)
                  : _req(l10n, v, l10n.employeeFieldIdNumber),
              inputFormatters: _idType == employeeIdTypeIdCard
                  ? ChinaInputFormatters.residentId
                  : null,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => _refreshIdentityDerived(),
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
            UtenDropdownField(
              label: l10n.employeeFieldGender,
              value: _gender,
              // 身份证：按证件号自动带出且服务端以证件号为准，锁死只读。
              enabled: !_identityLocked,
              allowClear: !_identityLocked,
              searchable: false,
              info: _identityLocked
                  ? l10n.employeeOnboardIdentityDerived
                  : null,
              items: [
                UtenDropdownItem(value: 'male', label: l10n.genderMale),
                UtenDropdownItem(value: 'female', label: l10n.genderFemale),
              ],
              onChanged: (v) => setState(() => _gender = v),
            ),
            UtenDateField(
              label: l10n.employeeFieldBirthDate,
              value: _birthDate,
              enabled: !_identityLocked,
              autofilled: _identityLocked && _birthDate != null,
              info: _identityLocked
                  ? l10n.employeeOnboardIdentityDerived
                  : null,
              firstDate: DateTime(1900),
              lastDate: ChinaDateTime.today(),
              onChanged: (d) => setState(() => _birthDate = d),
            ),
            _text(
              _ethnicity,
              l10n.employeeFieldEthnicity,
              l10n.employeeOnboardEmailOptional,
            ),
            _text(
              _politicalStatus,
              l10n.employeeFieldPoliticalStatus,
              l10n.employeeOnboardEmailOptional,
            ),
            _text(
              _maritalStatus,
              l10n.employeeFieldMaritalStatus,
              l10n.employeeOnboardEmailOptional,
            ),
          ],
        ),
      ],
    ),
  );

  // ---------------------------------------------------------------------
  // 第 2 步：工作信息
  // ---------------------------------------------------------------------

  Widget _workStep(AppLocalizations l10n) => Form(
    key: _stepFormKeys[1],
    child: UtenFormGrid(
      children: [
        UtenDepartmentPicker(
          mode: UtenDepartmentPickerMode.single,
          label: '${l10n.employeeFieldDepartment}*',
          initialSelection: _departmentSelection,
          expandOnRowTap: true,
          onChanged: (sel) {
            final nextDepartmentId = sel.isEmpty ? null : sel.first.id;
            final departmentChanged = nextDepartmentId != _departmentId;
            setState(() {
              _departmentId = nextDepartmentId;
              _departmentSelection = List.unmodifiable(sel);
              if (departmentChanged) {
                _position = const PositionEntryValue.empty();
              }
            });
          },
          validator: (sel) =>
              sel.isEmpty ? l10n.employeeOnboardPickDepartment : null,
        ),
        UtenPositionEntryPicker(
          departmentId: _departmentId,
          value: _position,
          label: l10n.employeeFieldPosition,
          onChanged: (value) => setState(() => _position = value),
        ),
        UtenEmployeePicker(
          key: ValueKey('onboarding-supervisor-${_supervisor?.id ?? 'none'}'),
          label: l10n.employeeFieldSupervisor,
          hint: l10n.employeeOnboardSupervisorHint,
          sheetTitle: l10n.employeeOnboardSupervisorSheet,
          initial: _supervisor,
          allowClear: true,
          loader: _supervisorCandidates,
          onChanged: (value) => setState(() => _supervisor = value),
        ),
        UtenDateField(
          label: l10n.employeeFieldHireDate,
          required: true,
          value: _hireDate,
          // 服务端拒绝未来入职日期；前端选择器同样以今天封顶(默认今天)。
          firstDate: DateTime(1990),
          lastDate: ChinaDateTime.today(),
          errorMessage: _showStepErrors && _hireDate == null
              ? l10n.employeeOnboardPickHireDate
              : null,
          onChanged: (d) {
            setState(() {
              _hireDate = d;
              // 正式员工转正日期默认=入职日期（可改）；试用员工不涉及
              if (_status == 'active' && _confirmedDate == null) {
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
              UtenDropdownItem(value: c, label: _employmentTypeLabel(l10n, c)),
          ],
          onChanged: (v) =>
              setState(() => _employmentType = v ?? _employmentType),
        ),
        UtenDropdownField(
          key: const ValueKey('onboarding-status'),
          label: l10n.employeeFieldStatus,
          required: true,
          value: _status,
          allowClear: false,
          searchable: false,
          items: [
            for (final c in _statusCodes)
              UtenDropdownItem(value: c, label: _statusLabel(l10n, c)),
          ],
          onChanged: (v) => setState(() {
            _status = v ?? _status;
            // 切到正式时转正日期默认=入职日期(可改)；试用由合同试用期派生。
            if (_status == 'active' &&
                _confirmedDate == null &&
                _hireDate != null) {
              _confirmedDate = _hireDate;
            }
          }),
        ),
        // ADR-021：正式（active）入职必须填写转正日期；试用由合同试用期派生
        if (_status == 'active')
          UtenDateField(
            label: l10n.employeeFieldConfirmedDate,
            required: true,
            info: l10n.employeeOnboardConfirmDateInfo,
            value: _confirmedDate,
            firstDate: DateTime(1990),
            lastDate: ChinaDateTime.today(),
            errorMessage:
                _showStepErrors && _status == 'active' && _confirmedDate == null
                ? l10n.employeeOnboardConfirmDateRequired
                : null,
            onChanged: (d) => setState(() => _confirmedDate = d),
          ),
        _text(
          _workLocation,
          l10n.employeeFieldWorkLocation,
          l10n.employeeOnboardEmailOptional,
        ),
        _text(
          _seatNo,
          l10n.employeeFieldSeatNo,
          l10n.employeeOnboardEmailOptional,
        ),
        _text(
          _attendanceGroup,
          l10n.employeeOnboardAttendanceGroup,
          l10n.employeeOnboardEmailOptional,
        ),
        _text(
          _officePhone,
          l10n.employeeFieldOfficePhone,
          l10n.employeeOnboardEmailOptional,
          keyboardType: TextInputType.phone,
        ),
      ],
    ),
  );

  /// 直属上级候选：无关键字时收敛到所选部门子树，有关键字时全公司搜。
  Future<List<UtenEmployeePickerItem>> _supervisorCandidates(
    String? keyword,
  ) async {
    final scoped = keyword == null || keyword.trim().isEmpty;
    final res = await ref
        .read(employeeRepositoryProvider)
        .listPickerCandidates(
          size: 30,
          search: keyword,
          departmentId: scoped ? _departmentId : null,
          includeSubtree: true,
        );
    return [
      for (final e in res)
        UtenEmployeePickerItem(
          id: e.id,
          name: e.fullName,
          employeeCode: e.code,
          departmentId: e.departmentId,
          departmentName: e.departmentName,
        ),
    ];
  }

  // ---------------------------------------------------------------------
  // 第 3 步：教育背景（可选，逐条增删）
  // ---------------------------------------------------------------------

  Widget _educationStep(AppLocalizations l10n) => Form(
    key: _stepFormKeys[2],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.employeeOnboardEduHint),
        const SizedBox(height: UtenSpacing.s12),
        for (var i = 0; i < _educations.length; i++)
          _educationEntryCard(l10n, i),
        Align(
          alignment: Alignment.centerLeft,
          child: UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.add_rounded,
            onPressed: () => setState(
              () => _educations = [..._educations, _EducationEntry()],
            ),
            child: Text(l10n.employeeOnboardAddEducation),
          ),
        ),
      ],
    ),
  );

  Widget _educationEntryCard(AppLocalizations l10n, int index) {
    final e = _educations[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: UtenCard(
        key: ValueKey('onboarding-education-entry-$index'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.school_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    l10n.employeeOnboardEducationEntry(index + 1),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.employeeOnboardDeleteEntry,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _removeEducation(index),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenFormGrid(
              children: [
                _text(
                  e.school,
                  l10n.employeeOnboardSchool,
                  l10n.employeeOnboardEmailOptional,
                  required: true,
                  validator: (v) =>
                      e.degree != null && (v == null || v.trim().isEmpty)
                      ? l10n.employeeOnboardFieldRequired(
                          l10n.employeeOnboardSchool,
                        )
                      : null,
                ),
                UtenDropdownField(
                  key: ValueKey('onboarding-degree-$index'),
                  label: l10n.employeeOnboardDegree,
                  value: e.degree,
                  searchable: false,
                  items: [
                    for (final c in _degreeCodes)
                      UtenDropdownItem(value: c, label: _degreeLabel(l10n, c)),
                  ],
                  errorMessage:
                      _showStepErrors && e.hasContent && e.degree == null
                      ? l10n.employeeOnboardPickDegree
                      : null,
                  onChanged: (v) => setState(() => e.degree = v),
                ),
                _text(
                  e.major,
                  l10n.employeeOnboardMajor,
                  l10n.employeeOnboardEmailOptional,
                ),
                UtenDateField(
                  label: l10n.employeeOnboardEduStart,
                  value: e.startDate,
                  firstDate: DateTime(1950),
                  lastDate: ChinaDateTime.today(),
                  onChanged: (d) => setState(() => e.startDate = d),
                ),
                UtenDateField(
                  label: l10n.employeeOnboardEduEnd,
                  value: e.endDate,
                  firstDate: DateTime(1950),
                  lastDate: ChinaDateTime.today(),
                  errorMessage:
                      _showStepErrors &&
                          e.startDate != null &&
                          e.endDate != null &&
                          e.endDate!.isBefore(e.startDate!)
                      ? l10n.employeeOnboardEduDateOrder
                      : null,
                  onChanged: (d) => setState(() => e.endDate = d),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _removeEducation(int index) {
    setState(() {
      final removed = _educations[index];
      _educations = [..._educations]..removeAt(index);
      removed.dispose();
    });
  }

  // ---------------------------------------------------------------------
  // 第 4 步：紧急联系人（可选，逐条增删）
  // ---------------------------------------------------------------------

  Widget _emergencyStep(AppLocalizations l10n) => Form(
    key: _stepFormKeys[3],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.employeeOnboardContactHint),
        const SizedBox(height: UtenSpacing.s12),
        for (var i = 0; i < _contacts.length; i++) _contactEntryCard(l10n, i),
        Align(
          alignment: Alignment.centerLeft,
          child: UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.person_add_alt_outlined,
            onPressed: () => setState(
              () => _contacts = [..._contacts, _EmergencyContactEntry()],
            ),
            child: Text(l10n.employeeOnboardAddContact),
          ),
        ),
      ],
    ),
  );

  Widget _contactEntryCard(AppLocalizations l10n, int index) {
    final c = _contacts[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: UtenCard(
        key: ValueKey('onboarding-contact-entry-$index'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.contact_phone_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    l10n.employeeOnboardContactEntry(index + 1),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.employeeOnboardDeleteEntry,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _removeContact(index),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenFormGrid(
              children: [
                _text(
                  c.name,
                  l10n.employeeFieldName,
                  l10n.employeeOnboardHintName,
                  required: true,
                  validator: (v) =>
                      (c.phone.text.trim().isNotEmpty ||
                              c.relationship != null) &&
                          (v == null || v.trim().isEmpty)
                      ? l10n.employeeOnboardFieldRequired(
                          l10n.employeeFieldName,
                        )
                      : null,
                ),
                _text(
                  c.phone,
                  l10n.employeeFieldPhone,
                  l10n.employeeOnboardHintPhone,
                  required: true,
                  validator: (v) {
                    if (c.name.text.trim().isNotEmpty ||
                        c.relationship != null) {
                      if (v == null || v.trim().isEmpty) {
                        return l10n.employeeOnboardPhoneRequired;
                      }
                      if (InputValidators.phone(v) != null) {
                        return l10n.employeeOnboardPhoneInvalid;
                      }
                    }
                    return null;
                  },
                  keyboardType: TextInputType.phone,
                  inputFormatters: ChinaInputFormatters.phone,
                ),
                UtenDropdownField(
                  key: ValueKey('onboarding-relationship-$index'),
                  label: l10n.employeeOnboardRelationship,
                  value: c.relationship,
                  searchable: false,
                  items: [
                    for (final r in _relationshipCodes)
                      UtenDropdownItem(
                        value: r,
                        label: _relationshipLabel(l10n, r),
                      ),
                  ],
                  onChanged: (v) => setState(() => c.relationship = v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _removeContact(int index) {
    setState(() {
      final removed = _contacts[index];
      _contacts = [..._contacts]..removeAt(index);
      removed.dispose();
    });
  }

  // ---------------------------------------------------------------------
  // 第 5 步：其他信息（地址 + 薪资银行）与提交说明
  // ---------------------------------------------------------------------

  Widget _otherStep(AppLocalizations l10n, bool canEditCompensation) => Form(
    key: _stepFormKeys[4],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _text(
          _hujiAddress,
          l10n.employeeFieldHujiAddress,
          l10n.employeeOnboardEmailOptional,
          maxLines: 2,
        ),
        const SizedBox(height: UtenSpacing.s12),
        _text(
          _residenceAddress,
          l10n.employeeFieldResidenceAddress,
          l10n.employeeOnboardEmailOptional,
          maxLines: 2,
        ),
        const SizedBox(height: UtenSpacing.s24),
        UtenSectionHeader(title: l10n.employeeEditSalary),
        const SizedBox(height: UtenSpacing.s8),
        UtenFormGrid(
          children: [
            if (canEditCompensation)
              _text(
                _baseSalary,
                l10n.employeeFieldBaseSalary,
                l10n.employeeOnboardEmailOptional,
                keyboardType: TextInputType.number,
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
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        _noteBanner(l10n.employeeOnboardNote),
      ],
    ),
  );

  /// 浅底信息条（工号自动生成 / 提交说明），样式沿用原单表单页口径。
  Widget _noteBanner(String text) => Builder(
    builder: (context) {
      final theme = Theme.of(context);
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
            Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          ],
        ),
      );
    },
  );

  /// 通用文本字段：Material 浮动标签（label 在框内边框上），与下拉/日期/选择器同款，
  /// 保证同一网格行里框顶对齐。必填项监听控制器：空值描红边 + 红 *。
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
    int maxLines = 1,
    ValueChanged<String>? onChanged,
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
            // 浮动标签在框内与其它字段同高；多行字段(地址)保持顶部对齐不居中。
          ),
        ),
        validator: validator,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        autofillHints: autofillHints,
        textCapitalization: textCapitalization,
        maxLines: maxLines,
        onChanged: onChanged,
      );
    }
    // 必填：听控制器，为空时描红边 + 红 *（label 由 requiredLabel 追加，调用方勿再带 *）。
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
          maxLines: maxLines,
          onChanged: onChanged,
        );
      },
    );
  }

  String? _req(AppLocalizations l10n, String? v, String label) =>
      (v == null || v.trim().isEmpty)
      ? l10n.employeeOnboardFieldRequired(label)
      : null;
}

/// 一条教育经历（向导第 3 步）：有任一内容即视为待提交条目，学校与学历必填。
class _EducationEntry {
  _EducationEntry({
    String school = '',
    String major = '',
    this.degree,
    this.startDate,
    this.endDate,
  }) {
    this.school.text = school;
    this.major.text = major;
  }

  final school = TextEditingController();
  final major = TextEditingController();
  String? degree;
  DateTime? startDate;
  DateTime? endDate;

  bool get hasContent =>
      school.text.trim().isNotEmpty ||
      major.text.trim().isNotEmpty ||
      degree != null ||
      startDate != null ||
      endDate != null;

  void dispose() {
    school.dispose();
    major.dispose();
  }
}

/// 一条紧急联系人（向导第 4 步）：有任一内容即视为待提交条目，姓名与手机号必填。
class _EmergencyContactEntry {
  _EmergencyContactEntry({
    String name = '',
    String phone = '',
    this.relationship,
  }) {
    this.name.text = name;
    this.phone.text = phone;
  }

  final name = TextEditingController();
  final phone = TextEditingController();
  String? relationship;

  bool get hasContent =>
      name.text.trim().isNotEmpty ||
      phone.text.trim().isNotEmpty ||
      relationship != null;

  void dispose() {
    name.dispose();
    phone.dispose();
  }
}
