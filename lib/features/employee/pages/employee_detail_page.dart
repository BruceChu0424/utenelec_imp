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
import '../../../shared/auth/permissions.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';
import '../widgets/employee_status_badge.dart';
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
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.employeeDetailTitle,
        showBackButton: true,
        actions: [
          if (ref.watch(currentPermissionsProvider).contains(Perm.employeeEdit))
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.employeeEditTitle,
              onPressed: () async {
                await context.push('/employee/${widget.employeeId}/edit');
                _load();
              },
            ),
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
                        padding: const EdgeInsets.only(
                          bottom: UtenSpacing.s24,
                        ),
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
                                      subtitle: h.eventDate == null
                                          ? null
                                          : Text(h.eventDate!),
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

  Widget _header(ThemeData theme, AppLocalizations l10n) {
    final p = _p;
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
                Text(
                  p.fullName ?? '',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
      _ => h.eventType ?? '',
    };
    final dept = h.toDeptName ?? h.fromDeptName ?? '';
    return '$type · $dept';
  }
}
