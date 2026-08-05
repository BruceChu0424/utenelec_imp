// 员工详情页（真实后端 + 组件库）。敏感字段由后端按当前角色脱敏后返回。
// 分组用 UtenSectionHeader + UtenCard，键值用 UtenInfoRow，状态用 EmployeeStatusBadge，
// 空/错用 UtenEmpty。详情页全断点套 UtenContentContainer.narrow（maxWidth 1120）。
// 文档：docs/03-页面/员工详情页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../models/employee_api_models.dart';
import '../models/work_years.dart';
import '../repositories/employee_repository.dart';
import '../widgets/employee_credential_dialog.dart';
import '../widgets/employee_status_badge.dart';
import '../widgets/employee_leadership_badge.dart';
import '../widgets/employee_transfer_dialog.dart';
import '../widgets/profile_change_pending_section.dart';

class EmployeeDetailPage extends ConsumerStatefulWidget {
  const EmployeeDetailPage({super.key, required this.employeeId});

  final String employeeId;

  @override
  ConsumerState<EmployeeDetailPage> createState() => _EmployeeDetailPageState();
}

class _EmployeeDetailPageState extends ConsumerState<EmployeeDetailPage> {
  EmployeeProfile? _profile;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await ref
          .read(employeeRepositoryProvider)
          .getById(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _profile = p;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).employeeOffboardLoadFailed;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final currentPermissions = ref.watch(currentPermissionsProvider);
    final canManageAuthorization =
        ref.watch(isSuperAdminProvider) &&
        currentPermissions.contains(Perm.authorizationManage);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.employeeDetailTitle,
        showBackButton: true,
        actions: [
          if (canManageAuthorization && _profile != null)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: _profile!.accountStatus == null ? '该员工未开通账号' : '设置员工权限',
              onPressed: () {
                if (_profile!.accountStatus == null) {
                  context.appError('该员工未开通登录账号，暂不能设置权限');
                  return;
                }
                final target = Uri(
                  path: RouteName.adminPermissions,
                  queryParameters: {'employeeId': widget.employeeId},
                );
                context.push(target.toString());
              },
            ),
          if (currentPermissions.contains(Perm.employeeEdit))
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.employeeEditTitle,
              onPressed: () async {
                await context.push('/employee/${widget.employeeId}/edit');
                _load();
              },
            ),
          _buildActionMenu(context, l10n),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? UtenEmpty.error(
              message: _error,
              actionLabel: l10n.commonRetry,
              onAction: _load,
            )
          : RefreshIndicator(
              onRefresh: _load,
              // 详情页全断点窄版收敛（1120），避免宽屏信息行被拉得过长
              child: UtenContentContainer.narrow(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _header(theme, l10n),
                    ProfileChangePendingSection(employeeId: widget.employeeId),
                    ..._expiryBanners(theme, l10n),
                    const SizedBox(height: UtenSpacing.s16),
                    _section(l10n.employeeDetailBasic, [
                      UtenInfoRow(
                        label: l10n.employeeFieldCode,
                        value: _p.code,
                        showDivider: false,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldName,
                        value: _p.fullName,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldGender,
                        value: _genderText(l10n, _p.gender),
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldIdType,
                        value: _p.idType,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldIdNumber,
                        value: _p.idNumber,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldBirthDate,
                        value: _p.birthDate,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldEthnicity,
                        value: _p.ethnicity,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldPoliticalStatus,
                        value: _p.politicalStatus,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldMaritalStatus,
                        value: _p.maritalStatus,
                        showDivider: false,
                      ),
                    ]),
                    _section(l10n.employeeDetailContact, [
                      UtenInfoRow(
                        label: l10n.employeeFieldPhone,
                        value: _p.phone,
                        showDivider: false,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldOfficePhone,
                        value: _p.officePhone,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldEmail,
                        value: _p.email,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldHujiAddress,
                        value: _p.hujiAddress,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldResidenceAddress,
                        value: _p.residenceAddress,
                        showDivider: false,
                      ),
                    ]),
                    _section(l10n.employeeDetailOrg, [
                      UtenInfoRow(
                        label: l10n.employeeFieldDepartment,
                        value: _p.departmentName,
                        showDivider: false,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldPosition,
                        value: _p.positionName,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldSupervisor,
                        value: _p.supervisorName,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldHireDate,
                        value: _p.hireDate,
                      ),
                      UtenInfoRow(
                        // 工龄动态计算：按当前日期得出，随日期自然变化
                        label: l10n.employeeFieldWorkYears,
                        value: workYearsText(l10n, _p.hireDate),
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldConfirmedDate,
                        value: _p.confirmedAt,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldStatus,
                        value: null,
                        valueWidget: EmployeeStatusBadge(
                          status: _p.status,
                          size: UtenStatusBadgeSize.medium,
                        ),
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldAccountStatus,
                        value: null,
                        valueWidget: _accountStatusBadge(theme, l10n),
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldEmploymentType,
                        value: _employmentTypeText(l10n, _p.employmentType),
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldWorkLocation,
                        value: _p.workLocation,
                      ),
                      UtenInfoRow(
                        label: l10n.employeeFieldSeatNo,
                        value: _p.seatNo,
                        showDivider: false,
                      ),
                    ]),
                    if (_p.contractType != null ||
                        _p.baseSalary != null ||
                        _p.bankAccount != null)
                      _section(l10n.employeeDetailContract, [
                        UtenInfoRow(
                          label: l10n.employeeFieldContractType,
                          value: _contractTypeText(l10n, _p.contractType),
                          showDivider: false,
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldContractPeriod,
                          value: _p.contractStart == null
                              ? null
                              : l10n.employeeContractPeriodValue(
                                  _p.contractStart!,
                                  _p.contractEnd ?? '',
                                ),
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldProbation,
                          value: _p.probationMonths == null
                              ? null
                              : l10n.employeeProbationValue(
                                  _p.probationMonths!,
                                  _p.probationEndDate ?? '',
                                ),
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldRenewCount,
                          value: _p.renewCount == null
                              ? null
                              : l10n.employeeRenewCountValue(_p.renewCount!),
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldBaseSalary,
                          value: _p.baseSalary,
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldPerfSalary,
                          value: _p.perfSalary,
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldSocialBase,
                          value: _p.socialInsuranceBase,
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldHousingBase,
                          value: _p.housingFundBase,
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldBankBranch,
                          value: _p.bankBranch,
                        ),
                        UtenInfoRow(
                          label: l10n.employeeFieldBankAccount,
                          value: _p.bankAccount,
                          showDivider: false,
                        ),
                      ]),
                    if (_p.emergencyContacts.isNotEmpty)
                      _section(l10n.employeeDetailEmergency, [
                        for (final c in _p.emergencyContacts)
                          UtenInfoRow(
                            label: '${c.relationship ?? ''} ${c.name ?? ''}',
                            value: c.phone,
                            showDivider: c != _p.emergencyContacts.last,
                          ),
                      ]),
                    if (_p.history.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UtenSectionHeader(
                              title: l10n.employeeDetailHistory,
                              icon: Icons.history_rounded,
                            ),
                            const SizedBox(height: UtenSpacing.s8),
                            UtenCard(
                              child: Column(
                                children: [
                                  for (final h in _p.history)
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: const Icon(
                                        Icons.history_rounded,
                                        size: 20,
                                      ),
                                      title: Text(_historyTitle(l10n, h)),
                                      subtitle: Text(
                                        [
                                          if (h.eventDate != null) h.eventDate!,
                                          if (h.remark != null &&
                                              h.remark!.isNotEmpty)
                                            h.remark!,
                                        ].join(' · '),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
            ),
    );
  }

  EmployeeProfile get _p => _profile!;

  /// 操作菜单：调岗 / 转正 / 办理离职 / 删除档案（按权限点 + 员工状态显隐）。
  Widget _buildActionMenu(BuildContext context, AppLocalizations l10n) {
    final p = _profile;
    if (p == null) return const SizedBox.shrink();
    final perms = ref.watch(currentPermissionsProvider);
    final canEdit = perms.contains(Perm.employeeEdit);
    final canDelete = perms.contains(Perm.employeeDelete);
    // 仅「未开通账号」且具备账号支持权限时，才显示「开通登录账号」。
    final canProvision =
        perms.contains(Perm.accountSupport) && p.accountStatus == null;
    final resigned = p.status == 'resigned';

    final items = <PopupMenuEntry<String>>[
      if (canProvision)
        PopupMenuItem(
          value: 'provision',
          child: Text(l10n.employeeActionProvision),
        ),
      if (canEdit && !resigned)
        PopupMenuItem(
          value: 'transfer',
          child: Text(l10n.employeeActionTransfer),
        ),
      if (canEdit && p.status == 'probation')
        PopupMenuItem(
          value: 'confirm',
          child: Text(l10n.employeeActionConfirm),
        ),
      if (canEdit && !resigned)
        PopupMenuItem(
          value: 'offboard',
          child: Text(l10n.employeeActionOffboard),
        ),
      if (canEdit && resigned)
        PopupMenuItem(value: 'rehire', child: Text(l10n.employeeActionRehire)),
      if (canDelete && resigned)
        PopupMenuItem(value: 'delete', child: Text(l10n.employeeActionDelete)),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded),
      tooltip: l10n.employeeActions,
      itemBuilder: (_) => items,
      onSelected: (v) => switch (v) {
        'provision' => _onProvisionAccount(),
        'transfer' => _onTransfer(),
        'confirm' => _onConfirm(),
        'offboard' => _onOffboard(),
        'rehire' => _onRehire(),
        'delete' => _onDelete(),
        _ => null,
      },
    );
  }

  Future<void> _onTransfer() async {
    final ok = await showEmployeeTransferDialog(
      context,
      employeeId: widget.employeeId,
      currentDepartmentId: _p.departmentId,
    );
    if (ok) _load();
  }

  /// 给批量导入等「未开通账号」的存量员工补开登录账号：账号=手机号，初始密码=身份证后6位。
  Future<void> _onProvisionAccount() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.employeeActionProvision),
        content: Text(l10n.employeeProvisionConfirm),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await ref
          .read(employeeRepositoryProvider)
          .provisionAccount(widget.employeeId);
      if (!mounted) return;
      await showEmployeeCredentialDialog(context, result);
      if (!mounted) return;
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _onOffboard() async {
    await context.push('/employee/${widget.employeeId}/offboarding');
    _load();
  }

  Future<void> _onConfirm() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.employeeConfirmTitle),
        content: Text(l10n.employeeConfirmBody),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(employeeRepositoryProvider).confirm(widget.employeeId);
      if (!mounted) return;
      context.appSuccess(l10n.employeeConfirmSuccess);
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _onRehire() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.employeeRehireTitle),
        content: Text(l10n.employeeRehireBody),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(employeeRepositoryProvider).rehire(widget.employeeId);
      if (!mounted) return;
      context.appSuccess(l10n.employeeRehireSuccess);
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _onDelete() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.employeeDeleteTitle),
        content: Text(l10n.employeeDeleteBody),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(employeeRepositoryProvider).delete(widget.employeeId);
      if (!mounted) return;
      context.appSuccess(l10n.employeeDeleteSuccess);
      context.go('/employee');
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Widget _header(ThemeData theme, AppLocalizations l10n) {
    final p = _p;
    final leadershipLabel = employeeLeadershipLabel(
      departmentManager: p.departmentManager,
      positionLevel: p.positionLevel,
      leaderRank: p.leaderRank,
    );
    return UtenCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            child: Text((p.fullName ?? '?').characters.first),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (leadershipLabel != null)
                      EmployeeLeadershipBadge(
                        departmentManager: p.departmentManager,
                        positionLevel: p.positionLevel,
                        leaderRank: p.leaderRank,
                      ),
                    Text(
                      p.fullName ?? '',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${p.code} · ${p.departmentName ?? ''} · ${p.positionName ?? ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          EmployeeStatusBadge(status: p.status),
        ],
      ),
    );
  }

  /// 分组：UtenSectionHeader（卡外标题）+ UtenCard（键值行），区块间距 24。
  Widget _section(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(title: title),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rows,
            ),
          ),
        ],
      ),
    );
  }

  String? _genderText(AppLocalizations l10n, String? g) => switch (g) {
    'male' => l10n.genderMale,
    'female' => l10n.genderFemale,
    _ => null,
  };

  String? _employmentTypeText(AppLocalizations l10n, String? t) => switch (t) {
    'regular' => l10n.employmentTypeRegular,
    'dispatch' => l10n.employmentTypeDispatch,
    'intern' => l10n.employmentTypeIntern,
    'outsource' => l10n.employmentTypeOutsource,
    _ => null,
  };

  String? _contractTypeText(AppLocalizations l10n, String? t) => switch (t) {
    'fixed' => l10n.contractTypeFixed,
    'open' => l10n.contractTypeOpen,
    'task' => l10n.contractTypeTask,
    'intern' => l10n.contractTypeIntern,
    _ => null,
  };

  String _historyTitle(AppLocalizations l10n, EmploymentHistoryView h) {
    final type = switch (h.eventType) {
      'onboard' => l10n.historyEventOnboard,
      'transfer' => l10n.historyEventTransfer,
      'resign' => l10n.historyEventResign,
      'rehire' => l10n.historyEventRehire,
      _ => h.eventType ?? '',
    };
    final dept = h.toDeptName ?? h.fromDeptName ?? '';
    return '$type · $dept';
  }

  /// 登录账号状态徽章：active=正常 / locked=锁定 / disabled=停用 / null=未开通。
  Widget _accountStatusBadge(ThemeData theme, AppLocalizations l10n) {
    final (label, color) = switch (_p.accountStatus) {
      'active' => (l10n.accountStatusActive, Colors.green.shade700),
      'locked' => (l10n.accountStatusLocked, Colors.orange.shade800),
      'disabled' => (l10n.accountStatusDisabled, theme.colorScheme.error),
      _ => (l10n.accountStatusNone, theme.colorScheme.onSurfaceVariant),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
      ],
    );
  }

  /// 到期预警横幅：试用期/合同 30 天内到期或已过期时醒目提示（离职员工不再提示）。
  List<Widget> _expiryBanners(ThemeData theme, AppLocalizations l10n) {
    if (_p.status == 'resigned') return const [];
    final banners = <Widget>[];
    final today = ChinaDateTime.today();

    String? check(
      String? dateStr,
      String Function(String date, int days) expiring,
      String Function(String date) expired,
    ) {
      if (dateStr == null) return null;
      final d = DateTime.tryParse(dateStr);
      if (d == null) return null;
      final days = DateUtils.dateOnly(d).difference(today).inDays;
      if (days < 0) return expired(dateStr);
      if (days <= 30) return expiring(dateStr, days);
      return null;
    }

    final msgs = <String>[
      if (_p.status == 'probation')
        ?check(
          _p.probationEndDate,
          (date, days) => l10n.employeeProbationExpiring(date, days),
          (date) => l10n.employeeProbationExpired(date),
        ),
      ?check(
        _p.contractEnd,
        (date, days) => l10n.employeeContractExpiring(date, days),
        (date) => l10n.employeeContractExpired(date),
      ),
    ];

    for (final msg in msgs) {
      banners.add(
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s12),
          child: Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.event_busy_rounded,
                  size: 18,
                  color: Colors.orange.shade800,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    msg,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.orange.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return banners;
  }
}
