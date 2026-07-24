// ProfileEditPage - 员工自助编辑个人信息
// 文档：docs/03-页面/我的页.md（§编辑）
//
// 三档字段策略：
//   * directEdit      → 提交即生效
//   * requiresReview  → 弹密码框二次确认 → 生成申请，HR 通过后合并
//   * hrOnly          → 员工页只读，提示"请联系人事"
//
// 提交流程：
//   1) 收集所有 dirty 字段（按 FieldPolicyKind 分组）
//   2) 若含 requiresReview 字段 → 弹密码框 → verify-password → 提交
//   3) 后端原子处理（直改立即生效，需审核进 pending 批次）
//   4) 成功通知 → 跳回 /profile
//
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/session_provider.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/models/employee_api_models.dart';
import '../field_policy.dart';
import '../models/profile_change_request.dart';
import '../providers/profile_change_providers.dart';
import '../repositories/profile_change_repository.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  final Map<String, TextEditingController> _ctrls = {};

  bool _loading = true;
  bool _saving = false;
  EmployeeProfile? _profile;
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
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionProvider);
      final employeeId = session.user?.employeeId;
      if (employeeId == null || employeeId.isEmpty) {
        throw ApiException('401', '当前账号未绑定员工档案');
      }
      final p = await ref.read(employeeRepositoryProvider).getById(employeeId);
      if (!mounted) return;
      _profile = p;
      _initControllers(p);
      setState(() => _loading = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _initControllers(EmployeeProfile p) {
    _ctrls.clear();
    void add(String code, String? value) {
      _ctrls[code] = TextEditingController(text: value ?? '');
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
    if (p.emergencyContacts.isNotEmpty) {
      final ec = p.emergencyContacts.first;
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.name', ec.name);
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.phone', ec.phone);
      add(
        '${ProfileFieldPolicy.emergencyContactPrefix}0.relationship',
        ec.relationship,
      );
    } else {
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.name', null);
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.phone', null);
      add('${ProfileFieldPolicy.emergencyContactPrefix}0.relationship', null);
    }
  }

  /// 找出当前 dirty 字段：值与初始值不同。
  List<ProfileFieldChange> _collectDirty() {
    final dirty = <ProfileFieldChange>[];
    for (final def in ProfileFieldPolicy.selfEditableFields) {
      final ctrl = _ctrls[def.code];
      if (ctrl == null) continue;
      final newValue = ctrl.text.trim();
      final oldValue = _initialValue(def.code);
      if (newValue == (oldValue ?? '')) continue;
      dirty.add(
        ProfileFieldChange(
          fieldCode: def.code,
          fieldLabel: _labelOf(def.code),
          newValue: newValue,
        ),
      );
    }
    return dirty;
  }

  String? _initialValue(String code) {
    final p = _profile;
    if (p == null) return null;
    return switch (code) {
      ProfileFieldPolicy.fullName => p.fullName,
      ProfileFieldPolicy.ethnicity => p.ethnicity,
      ProfileFieldPolicy.politicalStatus => p.politicalStatus,
      ProfileFieldPolicy.maritalStatus => p.maritalStatus,
      ProfileFieldPolicy.hujiAddress => p.hujiAddress,
      ProfileFieldPolicy.residenceAddress => p.residenceAddress,
      ProfileFieldPolicy.phone => p.phone,
      ProfileFieldPolicy.officePhone => p.officePhone,
      ProfileFieldPolicy.email => p.email,
      ProfileFieldPolicy.seatNo => p.seatNo,
      _ => null,
    };
  }

  String _labelOf(String code) {
    final def = ProfileFieldPolicy.findByCode(code);
    return def?.labelKey ?? code;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final dirty = _collectDirty();
    if (dirty.isEmpty) {
      context.appInfo(l10n.profileChangeSubmitApplied);
      context.pop();
      return;
    }
    final hasReview = dirty.any(
      (c) => ProfileFieldPolicy.isRequiresReview(c.fieldCode),
    );

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

    setState(() => _saving = true);
    try {
      final idem = DateTime.now().microsecondsSinceEpoch.toString();
      await ref
          .read(profileChangeRepositoryProvider)
          .submit(SubmitProfileChangeRequest(changes: dirty, idemKey: idem));
      if (!mounted) return;
      final onlyDirect = dirty.every(
        (c) => ProfileFieldPolicy.isDirectEdit(c.fieldCode),
      );
      if (onlyDirect) {
        context.appSuccess(l10n.profileChangeSubmitApplied);
      } else {
        context.appSuccess(l10n.profileChangeSubmitSuccess);
      }
      // 失效一下 pending 计数，便于 /profile 的"我的修改申请"快捷入口刷新
      ref.invalidate(myProfileChangesProvider);
      context.pop();
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

  Future<String?> _askPassword() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.profileChangePasswordLabel),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.profileChangePasswordHint,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenInput(
              label: l10n.profileChangePasswordLabel,
              isPassword: true,
              controller: ctrl,
            ),
          ],
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(l10n.profileChangeCancel2),
          ),
          UtenButton(
            type: UtenButtonType.primary,
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(l10n.profileChangeConfirm),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
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
      appBar: UtenAppBar(title: l10n.profileChangeEditTitle, showBackButton: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? UtenEmpty.error(
              message: _error,
              actionLabel: l10n.commonRetry,
              onAction: _load,
            )
          : _buildForm(context, l10n, theme),
      bottomNavigationBar: _loading || _error != null
          ? null
          : UtenBottomActionBar(
              child: Row(
                children: [
                  Expanded(
                    child: UtenButton(
                      type: UtenButtonType.ghost,
                      isExpanded: true,
                      onPressed: _saving ? null : () => context.pop(),
                      child: Text(l10n.profileChangeCancel2),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    flex: 2,
                    child: UtenButton(
                      type: UtenButtonType.primary,
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
    final basic = ProfileFieldPolicy.selfEditableFields
        .where((f) => f.kind == FieldPolicyKind.directEdit)
        .toList();
    final review = ProfileFieldPolicy.selfEditableFields
        .where((f) => f.kind == FieldPolicyKind.requiresReview)
        .toList();

    // 表单页全断点窄版收敛（1120），避免宽屏表单被拉得过长
    return UtenContentContainer.narrow(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        children: [
        UtenSectionHeader(title: l10n.profileChangeSectionBasic),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < basic.length; i++) ...[
                _buildField(basic[i], l10n, review: false),
                if (i < basic.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s24),
        UtenSectionHeader(title: l10n.profileChangeSectionReview),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < review.length; i++) ...[
                _buildField(review[i], l10n, review: true),
                if (i < review.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s24),
        UtenSectionHeader(title: l10n.profileChangeEditHrOnlyHint),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          child: Column(
            children: [
              for (final def in ProfileFieldPolicy.hrOnlyFields)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(_mapL10n(l10n, def.labelKey)),
                  subtitle: Text(l10n.profileChangeFieldHrOnly),
                ),
            ],
          ),
        ),
        const SizedBox(height: 80), // 底部固定操作栏留白
        ],
      ),
    );
  }

  Widget _buildField(
    ProfileFieldDef def,
    AppLocalizations l10n, {
    required bool review,
  }) {
    final theme = Theme.of(context);
    final ctrl = _ctrls[def.code] ?? TextEditingController();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
              label: review
                  ? l10n.profileChangeFieldReview
                  : l10n.profileChangeFieldDirect,
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
          keyboardType:
              def.code == ProfileFieldPolicy.phone ||
                  def.code == ProfileFieldPolicy.officePhone
              ? TextInputType.phone
              : def.code == ProfileFieldPolicy.email
              ? TextInputType.emailAddress
              : TextInputType.text,
          validator: _validatorFor(def.code),
        ),
      ],
    );
  }

  String? Function(String?) _validatorFor(String code) {
    return (v) {
      if (v == null) return null;
      final value = v.trim();
      if (value.isEmpty) return null;
      switch (code) {
        case ProfileFieldPolicy.email:
          if (!RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$').hasMatch(value)) {
            return '请输入正确的邮箱';
          }
          break;
        case ProfileFieldPolicy.phone:
        case ProfileFieldPolicy.officePhone:
          if (!RegExp(r'^\d{11}$').hasMatch(value)) {
            return '请输入 11 位手机号';
          }
          break;
      }
      return null;
    };
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
    case 'profileFieldGender':
      return l10n.profileFieldGender;
    case 'profileFieldBirthDate':
      return l10n.profileFieldBirthDate;
    case 'profileFieldWorkLocation':
      return l10n.profileFieldWorkLocation;
    default:
      return key;
  }
}
