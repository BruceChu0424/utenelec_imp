// ProfileEditPage - 员工自助编辑个人信息
// 文档：docs/03-页面/我的页.md（§编辑）
//
// v7.1 分区对齐「我的」页查看 Tab：基本信息 / 地址 / 紧急联系人 / 联系方式 / 组织信息，
// 只列可编辑字段（hrOnly 锁定行已砍——查看页灰徽章已说明，顶部一行策略图例代替）；
// 「我的」页字段铅笔经 /profile/edit?field=xxx 进入时滚动定位并聚焦目标字段。
//
// 三档字段策略：
//   * directEdit      → 提交即生效
//   * requiresReview  → 弹密码框二次确认 → 生成申请，HR 通过后合并
//   * hrOnly          → 员工页只读，提示"请联系人事"（不在本页渲染）
//
// 提交流程：
//   1) 收集所有 dirty 字段（按 FieldPolicyKind 分组）
//   2) 若含 requiresReview 字段 → 弹密码框 → verify-password → 提交
//   3) 后端原子处理（直改立即生效，需审核进 pending 批次）
//   4) 成功通知 → 纯直改回 /profile；含审核跳 /profile/me/changes
//
// 数据复用 myEmployeeProfileProvider（查看页同源，进编辑页不重复拉取）；
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/security/input_validators.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/models/employee_api_models.dart';
import '../field_policy.dart';
import '../models/profile_change_request.dart';
import '../providers/profile_change_providers.dart';
import '../repositories/profile_change_repository.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key, this.initialField});

  /// 从「我的」页字段铅笔进入时定位的目标字段 code
  /// （如 `phone` / `emergencyContact.0.name`）；空 = 整表编辑。
  final String? initialField;

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  static const _fieldOrder = [
    ProfileFieldPolicy.fullName,
    ProfileFieldPolicy.ethnicity,
    ProfileFieldPolicy.politicalStatus,
    ProfileFieldPolicy.maritalStatus,
    ProfileFieldPolicy.phone,
    ProfileFieldPolicy.officePhone,
    ProfileFieldPolicy.email,
    ProfileFieldPolicy.residenceAddress,
    ProfileFieldPolicy.hujiAddress,
    ProfileFieldPolicy.seatNo,
    '${ProfileFieldPolicy.emergencyContactPrefix}0.name',
    '${ProfileFieldPolicy.emergencyContactPrefix}0.phone',
    '${ProfileFieldPolicy.emergencyContactPrefix}0.relationship',
  ];

  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Map<String, GlobalKey> _fieldKeys = {};
  final Map<String, String> _initialValues = {};

  bool _loading = true;
  bool _saving = false;
  bool _unbound = false;
  bool _hasEmergencyContact = false;
  bool _locatedInitialField = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _unbound = false;
    });
    try {
      // 复用查看页同源 provider：从「我的」页进入时命中缓存，零额外请求。
      final p = await ref.read(myEmployeeProfileProvider.future);
      if (!mounted) return;
      if (p == null) {
        setState(() {
          _unbound = true;
          _loading = false;
        });
        return;
      }
      _initControllers(p);
      setState(() => _loading = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).commonError;
        _loading = false;
      });
    }
  }

  void _initControllers(EmployeeProfile p) {
    _initialValues.clear();
    void add(String code, String? value) {
      final initialValue = value ?? '';
      final controller = _ctrls.putIfAbsent(code, TextEditingController.new);
      controller.value = TextEditingValue(text: initialValue);
      _focusNodes.putIfAbsent(code, FocusNode.new);
      _fieldKeys.putIfAbsent(code, GlobalKey.new);
      _initialValues[code] = initialValue;
    }

    add(ProfileFieldPolicy.fullName, p.fullName);
    add(ProfileFieldPolicy.ethnicity, p.ethnicity);
    add(ProfileFieldPolicy.politicalStatus, p.politicalStatus);
    add(ProfileFieldPolicy.maritalStatus, p.maritalStatus);
    add(ProfileFieldPolicy.hujiAddress, p.hujiAddress);
    add(ProfileFieldPolicy.residenceAddress, p.residenceAddress);
    add(ProfileFieldPolicy.phone, p.phone);
    add(ProfileFieldPolicy.officePhone, p.officePhone);
    add(ProfileFieldPolicy.email, p.email);
    add(ProfileFieldPolicy.seatNo, p.seatNo);
    _hasEmergencyContact = p.emergencyContacts.isNotEmpty;
    if (p.emergencyContacts.isNotEmpty) {
      final ec = p.emergencyContacts.first;
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.name', ec.name);
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.phone', ec.phone);
      add(
        '${ProfileFieldPolicy.emergencyContactPrefix}0.relationship',
        ec.relationship,
      );
    } else {
      final emergencyCodes = _ctrls.keys
          .where(
            (code) =>
                code.startsWith(ProfileFieldPolicy.emergencyContactPrefix),
          )
          .toList();
      for (final code in emergencyCodes) {
        _ctrls.remove(code)?.dispose();
        _focusNodes.remove(code)?.dispose();
        _fieldKeys.remove(code);
      }
    }
  }

  /// 查看页铅笔带 ?field= 进入：滚动到目标字段并聚焦（只做一次）。
  /// 由 _buildForm 的 post-frame 回调触发，此时字段已挂载。
  void _locateInitialField() {
    if (_locatedInitialField) return;
    final target = widget.initialField;
    if (target == null) return;
    final fieldKey = _fieldKeys[target];
    final node = _focusNodes[target];
    final fieldContext = fieldKey?.currentContext;
    if (fieldContext == null || node == null) return;
    _locatedInitialField = true;
    Scrollable.ensureVisible(
      fieldContext,
      duration: const Duration(milliseconds: 300),
      alignment: 0.25,
    );
    node.requestFocus();
  }

  /// 找出当前 dirty 字段：值与初始值不同。
  List<ProfileFieldChange> _collectDirty(AppLocalizations l10n) {
    final dirty = <ProfileFieldChange>[];
    for (final def in ProfileFieldPolicy.selfEditableFields) {
      final ctrl = _ctrls[def.code];
      if (ctrl == null) continue;
      final newValue = ctrl.text.trim();
      final oldValue = _initialValues[def.code] ?? '';
      if (newValue == oldValue) continue;
      dirty.add(
        ProfileFieldChange(
          fieldCode: def.code,
          fieldLabel: ProfileFieldPolicy.labelOf(l10n, def.code),
          newValue: newValue,
        ),
      );
    }
    return dirty;
  }

  Future<void> _submit() async {
    // 防连续点击：重入直接返回；_saving 全程覆盖（提交按钮 loading + disabled）
    if (_saving) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final dirty = _collectDirty(l10n);
    if (dirty.isEmpty) {
      context.appInfo(l10n.profileChangeSubmitApplied);
      context.go(RouteName.profile);
      return;
    }
    final hasReview = dirty.any(
      (c) => ProfileFieldPolicy.isRequiresReview(c.fieldCode),
    );

    setState(() => _saving = true);
    try {
      if (hasReview) {
        final pwd = await _askPassword();
        if (pwd == null || pwd.isEmpty) return;
        try {
          await ref.read(profileChangeRepositoryProvider).verifyPassword(pwd);
        } on ApiException catch (e) {
          if (!mounted) return;
          context.appError(_mapVerifyError(e));
          return;
        } catch (_) {
          if (!mounted) return;
          context.appError(l10n.profileChangePasswordWrong);
          return;
        }
      }

      final idem = DateTime.now().microsecondsSinceEpoch.toString();
      await ref
          .read(profileChangeRepositoryProvider)
          .submit(SubmitProfileChangeRequest(changes: dirty, idemKey: idem));
      if (!mounted) return;
      final onlyDirect = dirty.every(
        (c) => ProfileFieldPolicy.isDirectEdit(c.fieldCode),
      );
      // 失效申请列表 + pending 计数，让"我的修改申请"页与 /profile 快捷入口刷新
      ref.invalidate(myProfileChangesProvider);
      if (onlyDirect) {
        // 纯直改：已即时生效，回"我的"页
        context.appSuccess(l10n.profileChangeSubmitApplied);
        context.go(RouteName.profile);
      } else {
        // 含需审核字段：跳"我的修改申请"，看到刚提交的 pending 批次
        context.appSuccess(l10n.profileChangeSubmitSuccess);
        context.go(RouteName.profileMyChanges);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(_mapSubmitError(e));
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.profileChangeSubmitFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _askPassword() {
    return showDialog<String?>(
      context: context,
      builder: (_) => const _ProfilePasswordConfirmationDialog(),
    );
  }

  String _mapVerifyError(ApiException e) {
    final l10n = AppLocalizations.of(context);
    if (e.code == '401' || e.message.contains('密码')) {
      return l10n.profileChangePasswordWrong;
    }
    return e.message;
  }

  String _mapSubmitError(ApiException e) {
    final l10n = AppLocalizations.of(context);
    if (e.code == '409') return l10n.profileChangeConflict;
    if (e.code == '429') return l10n.profileChangeRateLimited;
    return e.message;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.profileChangeEditTitle,
        // go 进入（非 push），栈被替换；返回显式回"我的"页
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.profile),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? UtenEmpty.error(
              message: _error,
              actionLabel: l10n.commonRetry,
              onAction: () {
                ref.invalidate(myEmployeeProfileProvider);
                _load();
              },
            )
          : _unbound
          ? UtenEmpty(
              icon: Icons.person_off_outlined,
              message: l10n.profileUnboundTitle,
              description: l10n.profileUnboundDescription,
            )
          : _buildForm(context, l10n, theme),
      bottomNavigationBar: _loading || _error != null || _unbound
          ? null
          : UtenBottomActionBar(
              child: Row(
                children: [
                  Expanded(
                    child: UtenButton(
                      type: UtenButtonType.ghost,
                      isExpanded: true,
                      onPressed: _saving
                          ? null
                          : () => context.go(RouteName.profile),
                      child: Text(l10n.profileChangeCancel2),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    flex: 2,
                    child: UtenButton(
                      isExpanded: true,
                      isLoading: _saving,
                      onPressed: _saving ? null : _submit,
                      child: Text(l10n.profileChangeConfirm),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    // 铅笔带 ?field= 进入：等字段首帧挂载完成后再定位（仅一次）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _locateInitialField();
    });
    // 表单页全断点窄版收敛（1120），避免宽屏表单被拉得过长
    return UtenContentContainer.narrow(
      child: Form(
        key: _formKey,
        // 仅五个分区全部保持挂载，确保滚出视口的脏字段也参与 Form.validate。
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _policyHint(l10n, theme),
              _pendingHint(l10n, theme),
              const SizedBox(height: UtenSpacing.s16),
              ..._groupSection(l10n.employeeDetailBasic, 'basic'),
              ..._groupSection(l10n.profileFieldGroupAddress, 'address'),
              ..._groupSection(
                l10n.profileFieldGroupEmergency,
                'emergency',
                // 未登记紧急联系人时没有可编辑控制器（HR 补录链路待建），整组只留提示。
                includeFields: _hasEmergencyContact,
                emptyMessage: _hasEmergencyContact
                    ? null
                    : l10n.profileMissingEmergencyContact,
              ),
              ..._groupSection(l10n.profileFieldGroupContact, 'contact'),
              ..._groupSection(
                l10n.profileFieldGroupOrganization,
                'organization',
              ),
              const SizedBox(height: 80), // 底部固定操作栏留白
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部策略图例：代替原先散在表单里的 hrOnly 锁定行（查看页灰徽章已说明，
  /// 编辑页不再重复列只读字段）。
  Widget _policyHint(AppLocalizations l10n, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            l10n.profileEditPolicyHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  /// 待审冲突提示：有 pending 申请时置顶提醒，避免提交撞 409 才发现。
  Widget _pendingHint(AppLocalizations l10n, ThemeData theme) {
    final count = ref
        .watch(myProfileChangesProvider((status: 'pending', page: 1)))
        .maybeWhen(data: (page) => page.total, orElse: () => 0);
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.hourglass_top_rounded,
            size: 18,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              l10n.profileEditPendingConflictHint(count),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 渲染一个分区（标题 + 卡片），返回 [section, 间距] 便于 Column 展开。
  List<Widget> _groupSection(
    String title,
    String group, {
    bool includeFields = true,
    String? emptyMessage,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final fields = includeFields
        ? _fieldsForGroup(group)
        : const <ProfileFieldDef>[];

    final children = <Widget>[];
    for (final field in fields) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: UtenSpacing.s16));
      }
      children.add(_buildField(field, l10n));
    }
    if (emptyMessage != null) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: UtenSpacing.s16));
      }
      children.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                emptyMessage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenSectionHeader(title: title),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
      const SizedBox(height: UtenSpacing.s24),
    ];
  }

  List<ProfileFieldDef> _fieldsForGroup(String group) {
    final fields = ProfileFieldPolicy.selfEditableFields
        .where((field) => field.group == group)
        .toList();
    fields.sort(
      (left, right) => _fieldOrder
          .indexOf(left.code)
          .compareTo(_fieldOrder.indexOf(right.code)),
    );
    return fields;
  }

  Widget _buildField(ProfileFieldDef def, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final ctrl = _ctrls[def.code]!;
    final review = def.kind == FieldPolicyKind.requiresReview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      key: _fieldKeys[def.code],
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _mapL10n(l10n, def.labelKey),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // 字段策略徽章：需审核 = 警告色，直改生效 = 成功色
            UtenStatusBadge(
              label: ProfileFieldPolicy.policyLabel(l10n, def.kind),
              type: review
                  ? UtenStatusBadgeType.warning
                  : UtenStatusBadgeType.success,
              size: UtenStatusBadgeSize.small,
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenInput(
          controller: ctrl,
          focusNode: _focusNodes[def.code],
          keyboardType:
              def.code == ProfileFieldPolicy.phone ||
                  def.code == ProfileFieldPolicy.officePhone
              ? TextInputType.phone
              : def.code == ProfileFieldPolicy.email
              ? TextInputType.emailAddress
              : TextInputType.text,
          validator: _validatorFor(def.code),
          autofillHints: switch (def.code) {
            ProfileFieldPolicy.fullName => const [AutofillHints.name],
            ProfileFieldPolicy.phone => const [AutofillHints.telephoneNumber],
            ProfileFieldPolicy.email => const [AutofillHints.email],
            ProfileFieldPolicy.hujiAddress ||
            ProfileFieldPolicy.residenceAddress => const [
              AutofillHints.fullStreetAddress,
            ],
            _ => null,
          },
        ),
      ],
    );
  }

  String? Function(String?) _validatorFor(String code) {
    return (v) {
      final value = v?.trim() ?? '';
      final emergencyField = code.startsWith(
        ProfileFieldPolicy.emergencyContactPrefix,
      );
      final initiallyPresent = (_initialValues[code] ?? '').trim().isNotEmpty;
      if (value.isEmpty) {
        if (code == ProfileFieldPolicy.fullName ||
            emergencyField && initiallyPresent ||
            code == ProfileFieldPolicy.phone && initiallyPresent) {
          return InputValidators.required(
            value,
            label: ProfileFieldPolicy.labelOf(
              AppLocalizations.of(context),
              code,
            ),
          );
        }
        return null;
      }
      switch (code) {
        case ProfileFieldPolicy.email:
          return InputValidators.email(value);
        case ProfileFieldPolicy.phone:
          return InputValidators.phone(value);
        case ProfileFieldPolicy.officePhone:
          return InputValidators.telephone(value);
      }
      if (code.endsWith('.phone') && emergencyField) {
        return InputValidators.phone(value);
      }
      return null;
    };
  }
}

class _ProfilePasswordConfirmationDialog extends StatefulWidget {
  const _ProfilePasswordConfirmationDialog();

  @override
  State<_ProfilePasswordConfirmationDialog> createState() =>
      _ProfilePasswordConfirmationDialogState();
}

class _ProfilePasswordConfirmationDialogState
    extends State<_ProfilePasswordConfirmationDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.profileChangePasswordLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.profileChangePasswordHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenInput(
            label: l10n.profileChangePasswordLabel,
            isPassword: true,
            controller: _controller,
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.profileChangeCancel2),
        ),
        UtenButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l10n.profileChangeConfirm),
        ),
      ],
    );
  }
}

/// 把 l10n key 映射到 [AppLocalizations] 的 getter；缺值时回退到 key 本身。
String _mapL10n(AppLocalizations l10n, String key) {
  switch (key) {
    case 'profileFieldEthnicity':
      return l10n.profileFieldEthnicity;
    case 'profileFieldPoliticalStatus':
      return l10n.profileFieldPoliticalStatus;
    case 'profileFieldMaritalStatus':
      return l10n.profileFieldMaritalStatus;
    case 'profileFieldResidenceAddress':
      return l10n.profileFieldResidenceAddress;
    case 'profileFieldOfficePhone':
      return l10n.profileFieldOfficePhone;
    case 'profileFieldEmail':
      return l10n.profileFieldEmail;
    case 'profileFieldSeatNo':
      return l10n.profileFieldSeatNo;
    case 'profileChangeFieldFullName':
      return l10n.profileChangeFieldFullName;
    case 'profileFieldHujiAddress':
      return l10n.profileFieldHujiAddress;
    case 'profileFieldPhone':
      return l10n.profileChangeFieldPhone;
    case 'profileChangeFieldEmergencyName':
      return l10n.profileChangeFieldEmergencyName;
    case 'profileChangeFieldEmergencyPhone':
      return l10n.profileChangeFieldEmergencyPhone;
    case 'profileChangeFieldEmergencyRelationship':
      return l10n.profileChangeFieldEmergencyRelationship;
    default:
      return key;
  }
}
