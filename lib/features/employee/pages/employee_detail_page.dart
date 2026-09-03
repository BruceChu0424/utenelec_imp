// 员工详情页（v2 重构，ADR-021 §六）：大厂 People 范式——
// 头部身份卡 + 常用操作外显（编辑/调岗/登记转正/办理离职，次要在 ⋯），
// 内容 Tab 分组（概览 / 组织与合同 / 联系与车辆 / 薪酬 / 任职记录），
// 联系与车辆 Tab 内置：更换手机号（同步登录账号）、备用手机号与车辆管理。
// 敏感字段由后端按权限点脱敏后返回；全断点 UtenContentContainer.narrow。
// 文档：docs/03-页面/员工详情页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/attachments/attachment.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../models/employee_api_models.dart';
import '../models/work_years.dart';
import '../repositories/employee_repository.dart';
import '../widgets/contract_attachments_dialog.dart';
import '../widgets/employee_account_provision_flow.dart';
import '../widgets/employee_status_badge.dart';
import '../widgets/employee_leadership_badge.dart';
import '../widgets/employee_transfer_dialog.dart';
import '../widgets/profile_change_pending_section.dart';
import '../widgets/employee_contact_edit_dialog.dart';

class EmployeeDetailPage extends ConsumerStatefulWidget {
  const EmployeeDetailPage({super.key, required this.employeeId});

  final String employeeId;

  @override
  ConsumerState<EmployeeDetailPage> createState() => _EmployeeDetailPageState();
}

class _EmployeeDetailPageState extends ConsumerState<EmployeeDetailPage>
    with SingleTickerProviderStateMixin {
  EmployeeProfile? _profile;
  bool _loading = true;
  String? _error;
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 6, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
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

  EmployeeProfile get _p => _profile!;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final canManageAuthorization =
        ref.watch(isSuperAdminProvider) &&
        perms.contains(Perm.authorizationManage);

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.employeeDetailTitle,
        showBackButton: true,
        actions: [
          if (canManageAuthorization && _profile != null)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: _profile!.accountStatus == null
                  ? l10n.employeeAccountNotProvisionedTooltip
                  : l10n.employeePermissionSettingsTooltip,
              onPressed: _openPermissionSettings,
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
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
          // Builder 推迟 _tabBar 构建：其内部经 _p 强制解包 _profile，
          // 仅资料加载完成后才可调用。
          : Builder(
              builder: (context) {
                final tabBar = _tabBar(theme, l10n);
                return UtenContentContainer.narrow(
                  // 「顶部折叠 + Tab 吸顶 + 内容内滚」：身份卡、变更审批、
                  // 到期横幅随上滑收起腾出空间，Tab 栏顶到上沿后吸顶，
                  // 各 Tab 正文内滚（_scrollTab 的竖向 ListView 无显式
                  // controller，自动拾取 NestedScrollView 注入的
                  // PrimaryScrollController 参与联动）。
                  child: UtenCollapsingHeaderScrollView(
                    collapsingHeader: Column(
                      children: [
                        const SizedBox(height: UtenSpacing.s12),
                        _header(theme, l10n),
                        ProfileChangePendingSection(
                          employeeId: widget.employeeId,
                        ),
                        ..._expiryBanners(theme, l10n),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                    ),
                    pinnedHeader: tabBar,
                    pinnedHeaderExtent: tabBar.preferredSize.height,
                    body: TabBarView(
                      controller: _tab,
                      children: [
                        _overviewTab(l10n),
                        _orgContractTab(l10n),
                        _contactVehicleTab(l10n),
                        _compensationTab(l10n),
                        _historyTab(l10n),
                        _documentsTab(l10n),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  // 返回类型保持 TabBar：调用方需要 preferredSize 计算吸顶高度。
  TabBar _tabBar(ThemeData theme, AppLocalizations l10n) {
    final showComp =
        _p.contractType != null ||
        _p.baseSalary != null ||
        _p.bankAccount != null;
    return TabBar(
      controller: _tab,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelStyle: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      tabs: [
        const Tab(text: '概览'),
        const Tab(text: '组织与合同'),
        const Tab(text: '联系与车辆'),
        Tab(text: showComp ? '薪酬' : '薪酬 🔒'),
        const Tab(text: '任职记录'),
        const Tab(text: '档案文件'),
      ],
    );
  }

  // ============================================================
  // Tab 6：档案文件（合同/证件/学历/照片/其他）—— 接通用附件系统
  // 通用层分别使用 attachment:view/download/upload/delete；
  // 对象层 view=本人或 employee:pii:view，上传/删除=employee:edit，
  // 设为头像仅 employee:avatar_edit，不因头像权限获得合同附件删除能力。
  // ============================================================
  Widget _documentsTab(AppLocalizations l10n) {
    final p = _profile;
    if (p == null) {
      return _scrollTab(const [Center(child: CircularProgressIndicator())]);
    }
    final perms = ref.watch(currentPermissionsProvider);
    final canView =
        perms.contains(Perm.attachmentView) &&
        perms.contains(Perm.employeePiiView);
    final ownerCanManageFiles = perms.contains(Perm.employeeEdit);
    final canUploadFiles =
        ownerCanManageFiles && perms.contains(Perm.attachmentUpload);
    if (!canView) {
      return const Center(
        child: UtenEmpty(
          icon: Icons.folder_off_outlined,
          message: '无档案文件查看权限',
          description: '档案文件属员工敏感信息(证件/合同扫描件)，需人事敏感信息查看权限(employee:pii:view)。',
        ),
      );
    }
    return _scrollTab([
      AttachmentSection(
        ownerType: 'EMPLOYEE',
        ownerId: p.id,
        attachments: p.attachments,
        ownerCanUpload: ownerCanManageFiles,
        ownerCanDelete: ownerCanManageFiles,
        onChanged: _load,
        title: '档案文件',
        emptyHint: canUploadFiles
            ? '暂无档案文件，点击上传合同 / 证件 / 照片(PDF 或图片)'
            : '暂无档案文件',
        categories: const ['合同', '身份证件', '学历证书', '照片', '其他'],
        onSetAvatar: perms.contains(Perm.employeeAvatarEdit)
            ? (Attachment attachment) => _onSetAvatar(attachment.id)
            : null,
      ),
    ]);
  }

  Future<void> _onSetAvatar(String attachmentId) async {
    try {
      await ref
          .read(employeeRepositoryProvider)
          .setAvatar(widget.employeeId, attachmentId);
      if (!mounted) return;
      context.appSuccess('已设为头像');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Widget _scrollTab(List<Widget> children) {
    return RefreshIndicator(
      onRefresh: _load,
      // 正文可框选复制：外层 UtenContentContainer.narrow 已默认包局部 SelectionArea
      // （准则 §3.4），此处无需再包。
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        children: children,
      ),
    );
  }

  // ============================================================
  // 头部身份卡 + 外显操作
  // ============================================================
  Widget _header(ThemeData theme, AppLocalizations l10n) {
    final p = _p;
    final leadershipLabel = employeeLeadershipLabel(
      departmentManager: p.departmentManager,
      positionLevel: p.positionLevel,
      leaderRank: p.leaderRank,
    );
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                child: Text(
                  (p.fullName ?? '?').characters.first,
                  style: theme.textTheme.titleLarge,
                ),
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
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        EmployeeStatusBadge(status: p.status),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${p.code} · ${p.departmentName ?? ''} · ${p.positionName ?? ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '入职 ${p.hireDate ?? '—'} · 工龄 ${workYearsText(l10n, p.hireDate)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_primaryActions(l10n).isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s12),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: _primaryActions(l10n),
            ),
          ],
        ],
      ),
    );
  }

  /// 常用操作外显（按权限 + 状态）：编辑 / 调岗 / 登记转正 / 办理离职。
  List<Widget> _primaryActions(AppLocalizations l10n) {
    final p = _p;
    final perms = ref.watch(currentPermissionsProvider);
    final resigned = p.status == 'resigned';
    final actions = <Widget>[];

    if (perms.contains(Perm.employeeEdit)) {
      actions.add(
        FilledButton.tonalIcon(
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text(l10n.employeeEditTitle),
          onPressed: () async {
            await context.push('/employee/${widget.employeeId}/edit');
            _load();
          },
        ),
      );
    }
    if (!resigned && perms.contains(Perm.employeeTransfer)) {
      actions.add(
        FilledButton.tonalIcon(
          icon: const Icon(Icons.swap_horiz_rounded, size: 18),
          label: Text(l10n.employeeActionTransfer),
          onPressed: _onTransfer,
        ),
      );
    }
    if (p.status == 'probation' && perms.contains(Perm.employeeConfirm)) {
      actions.add(
        FilledButton.icon(
          icon: const Icon(Icons.how_to_reg_outlined, size: 18),
          label: Text(l10n.employeeActionConfirm),
          onPressed: _onConfirm,
        ),
      );
    }
    if (!resigned && perms.contains(Perm.employeeOffboard)) {
      actions.add(
        FilledButton.tonalIcon(
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: Text(l10n.employeeActionOffboard),
          onPressed: _onOffboard,
        ),
      );
    }
    if (resigned && perms.contains(Perm.employeeRehire)) {
      actions.add(
        FilledButton.icon(
          icon: const Icon(Icons.assignment_return_outlined, size: 18),
          label: Text(l10n.employeeActionRehire),
          onPressed: _onRehire,
        ),
      );
    }
    // 账号支持（account:support，独立于 employee:edit）：开通 / 锁定 / 解锁。
    if (perms.contains(Perm.accountSupport)) {
      if (p.accountStatus == null && !resigned) {
        actions.add(
          FilledButton.tonalIcon(
            icon: const Icon(Icons.person_add_outlined, size: 18),
            label: Text(l10n.employeeActionProvision),
            onPressed: _onProvisionAccount,
          ),
        );
      } else if (p.accountStatus == 'active') {
        actions.add(
          FilledButton.tonalIcon(
            icon: const Icon(Icons.lock_outline_rounded, size: 18),
            label: Text(l10n.employeeActionLockAccount),
            onPressed: _onLockAccount,
          ),
        );
      } else if (p.accountStatus == 'locked') {
        actions.add(
          FilledButton.tonalIcon(
            icon: const Icon(Icons.lock_open_outlined, size: 18),
            label: Text(l10n.employeeActionUnlockAccount),
            onPressed: _onUnlockAccount,
          ),
        );
      }
    }
    return actions;
  }

  // 注：禁止删除员工——⋯ 菜单与"归档删除"入口已下线。员工离职走「办理离职」流程，
  // status='resigned' 永久留存，可在花名册"离职"筛选查看。

  // ============================================================
  // Tab 1：概览（人口属性 + 关键用工信息）
  // ============================================================
  Widget _overviewTab(AppLocalizations l10n) {
    return _scrollTab([
      _section(l10n.employeeDetailBasic, [
        UtenInfoRow(
          label: l10n.employeeFieldCode,
          value: _p.code,
          showDivider: false,
        ),
        UtenInfoRow(label: l10n.employeeFieldName, value: _p.fullName),
        UtenInfoRow(
          label: l10n.employeeFieldGender,
          value: _genderText(l10n, _p.gender),
        ),
        UtenInfoRow(label: l10n.employeeFieldIdType, value: _p.idType),
        UtenInfoRow(label: l10n.employeeFieldIdNumber, value: _p.idNumber),
        UtenInfoRow(label: l10n.employeeFieldBirthDate, value: _p.birthDate),
        UtenInfoRow(label: l10n.employeeFieldEthnicity, value: _p.ethnicity),
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
      _section('户籍与住址', [
        UtenInfoRow(
          label: l10n.employeeFieldHujiAddress,
          value: _p.hujiAddress,
          showDivider: false,
        ),
        UtenInfoRow(
          label: l10n.employeeFieldResidenceAddress,
          value: _p.residenceAddress,
          showDivider: false,
        ),
      ]),
    ]);
  }

  // ============================================================
  // Tab 2：组织与合同
  // ============================================================
  Widget _orgContractTab(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return _scrollTab([
      _section(l10n.employeeDetailOrg, [
        UtenInfoRow(
          label: l10n.employeeFieldDepartment,
          value: _p.departmentName,
          showDivider: false,
        ),
        UtenInfoRow(label: l10n.employeeFieldPosition, value: _p.positionName),
        UtenInfoRow(
          label: l10n.employeeFieldSupervisor,
          value: _p.supervisorName,
        ),
        UtenInfoRow(label: l10n.employeeFieldHireDate, value: _p.hireDate),
        UtenInfoRow(
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
      if (_p.contractType != null)
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
            showDivider: false,
          ),
        ]),
      if (_p.contracts.isNotEmpty) _contractsTimeline(l10n),
    ]);
  }

  /// 合同时间线：每份合同卡 + 到期色标（30 天黄、已到期红）；HR 可续签。
  /// 每份合同可单独挂附件（ownerType=EMPLOYEE_CONTRACT，存合同扫描件）。
  Widget _contractsTimeline(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final canEdit =
        perms.contains(Perm.employeeContractRenew) && _p.status != 'resigned';
    // 合同附件=PII 级扫描件：与档案文件 Tab 同口径（attachment:view + employee:pii:view）
    final canViewAttachments =
        perms.contains(Perm.attachmentView) &&
        perms.contains(Perm.employeePiiView);
    final ownerCanManageAttachments = perms.contains(Perm.employeeEdit);
    final items = <Widget>[];
    for (final c in _p.contracts) {
      final Color badgeColor;
      final String badgeText;
      if (c.ended) {
        badgeColor = theme.colorScheme.error;
        badgeText = '已到期';
      } else if (c.expiring) {
        badgeColor = Colors.orange.shade700;
        badgeText = '${c.daysToExpiry} 天后到期';
      } else if (c.daysToExpiry != null) {
        badgeColor = theme.colorScheme.primary;
        badgeText = '剩 ${c.daysToExpiry} 天';
      } else {
        badgeColor = theme.colorScheme.onSurfaceVariant;
        badgeText = '无固定期限';
      }
      items.add(
        UtenCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _contractTypeText(l10n, c.contractType),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badgeText,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: badgeColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '第 ${c.signOrder} 份',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  c.endDate == null
                      ? '${c.startDate ?? '—'} 起 · 无固定期限'
                      : '${c.startDate ?? '—'} ~ ${c.endDate}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (canViewAttachments)
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => showContractAttachmentsDialog(
                          context,
                          contractId: c.id,
                          title:
                              '${_contractTypeText(l10n, c.contractType)} · 第 ${c.signOrder} 份合同',
                          ownerCanManage: ownerCanManageAttachments,
                        ),
                        icon: const Icon(Icons.attach_file_rounded, size: 16),
                        label: const Text('合同附件'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UtenSectionHeader(title: '合同时间线', subdued: true),
        const SizedBox(height: UtenSpacing.s8),
        ...items,
        if (canEdit)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showRenewContractDialog(l10n),
                icon: const Icon(Icons.post_add, size: 18),
                label: const Text('续签 / 补录合同'),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showRenewContractDialog(AppLocalizations l10n) async {
    final formKey = GlobalKey<FormState>();
    String contractType = 'fixed';
    String? startDate;
    String? endDate;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('续签 / 补录合同'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: contractType,
                  decoration: const InputDecoration(labelText: '合同类型'),
                  items: const [
                    DropdownMenuItem(value: 'fixed', child: Text('固定期限')),
                    DropdownMenuItem(value: 'open', child: Text('无固定期限')),
                    DropdownMenuItem(value: 'task', child: Text('任务期限')),
                    DropdownMenuItem(value: 'intern', child: Text('实习')),
                  ],
                  onChanged: (v) => setState(() => contractType = v ?? 'fixed'),
                ),
                // 简化：开始/结束用文本输入（YYYY-MM-DD）；生产可换日期选择器。
                TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  decoration: const InputDecoration(
                    labelText: '开始日期',
                    hintText: 'YYYY-MM-DD(留空=今天)',
                  ),
                  onChanged: (v) =>
                      startDate = v.trim().isEmpty ? null : v.trim(),
                ),
                TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  decoration: const InputDecoration(
                    labelText: '结束日期',
                    hintText: 'YYYY-MM-DD(无固定期限留空)',
                  ),
                  onChanged: (v) =>
                      endDate = v.trim().isEmpty ? null : v.trim(),
                ),
              ],
            ),
          ),
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
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(employeeRepositoryProvider).renewContract(
        widget.employeeId,
        {
          'contractType': contractType,
          'startDate': ?startDate,
          'endDate': ?endDate,
        },
      );
      if (!mounted) return;
      context.appSuccess('合同已保存');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  // ============================================================
  // Tab 3：联系与车辆（更换手机号 / 备用手机号 / 车辆管理）
  // ============================================================
  Widget _contactVehicleTab(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final canEdit = perms.contains(Perm.employeeEdit);
    final canPiiEdit = perms.contains(Perm.employeePiiEdit);
    return _scrollTab([
      _section('联系方式', [
        UtenInfoRow(
          label: l10n.employeeFieldPhone,
          value: null,
          showDivider: false,
          valueWidget: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  _p.phone ?? '—',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (canPiiEdit)
                TextButton.icon(
                  icon: const Icon(Icons.sim_card_outlined, size: 16),
                  label: const Text('更换手机号'),
                  onPressed: _onChangePhone,
                ),
            ],
          ),
        ),
        UtenInfoRow(
          label: l10n.employeeFieldOfficePhone,
          value: _p.officePhone,
        ),
        UtenInfoRow(label: l10n.employeeFieldEmail, value: _p.email),
        // 备用手机号（ADR-021）
        for (var i = 0; i < _p.phones.length; i++)
          UtenInfoRow(
            label: '备用 · ${_p.phones[i].label ?? '手机'}',
            value: _p.phones[i].phone,
            showDivider: i == _p.phones.length - 1 && !canPiiEdit,
          ),
        // 备用手机号属联系方式 PII，写权限与主手机一致（employee:pii:edit）
        if (canPiiEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add_call, size: 16),
              label: const Text('管理备用手机号'),
              onPressed: () => _editPhones(),
            ),
          ),
      ]),
      // 车辆信息（ADR-021：按车牌找人）
      Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '车辆信息',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (canEdit)
                  TextButton.icon(
                    icon: const Icon(Icons.directions_car_outlined, size: 16),
                    label: const Text('管理车辆'),
                    onPressed: () => _editVehicles(),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenCard(
              child: _p.vehicles.isEmpty
                  ? Text(
                      '未登记车辆',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < _p.vehicles.length; i++)
                          _vehicleRow(theme, _p.vehicles[i], i),
                      ],
                    ),
            ),
          ],
        ),
      ),
      if (_p.emergencyContacts.isNotEmpty)
        _section(l10n.employeeDetailEmergency, [
          for (final c in _p.emergencyContacts)
            UtenInfoRow(
              label: '${c.relationship ?? ''} ${c.name ?? ''}',
              value: c.phone,
              showDivider: c != _p.emergencyContacts.last,
            ),
        ]),
    ]);
  }

  Widget _vehicleRow(ThemeData theme, EmployeeVehicleView v, int index) {
    final detail = [
      ?v.vehicleType,
      ?v.brandModel,
      ?v.color,
      ?v.remark,
    ].join(' · ');
    return Column(
      children: [
        if (index > 0) const Divider(height: 16),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: UtenRadius.smAll,
                border: Border.all(color: theme.colorScheme.primary),
              ),
              child: Text(
                v.plateNo ?? '',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onPrimaryContainer,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                detail.isEmpty ? '—' : detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // Tab 4：薪酬（按权限点可见）
  // ============================================================
  Widget _compensationTab(AppLocalizations l10n) {
    final hasAny =
        _p.baseSalary != null ||
        _p.bankAccount != null ||
        _p.socialInsuranceLocation != null;
    if (!hasAny) {
      return const Center(
        child: UtenEmpty(
          icon: Icons.lock_outline_rounded,
          message: '无薪酬查看权限或未登记薪酬信息',
        ),
      );
    }
    return _scrollTab([
      _section('薪酬信息', [
        UtenInfoRow(
          label: l10n.employeeFieldBaseSalary,
          value: _p.baseSalary,
          showDivider: false,
        ),
        UtenInfoRow(label: l10n.employeeFieldPerfSalary, value: _p.perfSalary),
        UtenInfoRow(
          label: l10n.employeeFieldSocialBase,
          value: _p.socialInsuranceBase,
        ),
        UtenInfoRow(
          label: l10n.employeeFieldHousingBase,
          value: _p.housingFundBase,
        ),
        UtenInfoRow(label: l10n.employeeFieldBankBranch, value: _p.bankBranch),
        UtenInfoRow(
          label: l10n.employeeFieldBankAccount,
          value: _p.bankAccount,
          showDivider: false,
        ),
      ]),
    ]);
  }

  // ============================================================
  // Tab 5：任职记录（含转正事件）
  // ============================================================
  Widget _historyTab(AppLocalizations l10n) {
    if (_p.history.isEmpty) {
      return const Center(
        child: UtenEmpty(icon: Icons.history_rounded, message: '暂无任职记录'),
      );
    }
    return _scrollTab([
      _section(l10n.employeeDetailHistory, [
        for (final h in _p.history)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_historyIcon(h.eventType), size: 20),
            title: Text(_historyTitle(l10n, h)),
            subtitle: Text(
              [
                if (h.eventDate != null) h.eventDate!,
                if (h.remark != null && h.remark!.isNotEmpty) h.remark!,
              ].join(' · '),
            ),
          ),
      ]),
    ]);
  }

  IconData _historyIcon(String? type) => switch (type) {
    'onboard' => Icons.login_rounded,
    'transfer' => Icons.swap_horiz_rounded,
    'confirm' => Icons.how_to_reg_outlined,
    'resign' => Icons.logout_rounded,
    'rehire' => Icons.assignment_return_outlined,
    _ => Icons.history_rounded,
  };

  // ============================================================
  // 操作
  // ============================================================
  Future<void> _onTransfer() async {
    final ok = await showEmployeeTransferDialog(
      context,
      employeeId: widget.employeeId,
      currentDepartmentId: _p.departmentId,
    );
    if (ok) _load();
  }

  Future<void> _onChangePhone() async {
    final newPhone = await showEmployeeChangePhoneDialog(context, _p.phone);
    if (newPhone == null || !mounted) return;
    try {
      await ref
          .read(employeeRepositoryProvider)
          .changePhone(widget.employeeId, newPhone);
      if (!mounted) return;
      context.appSuccess('手机号已更换，登录账号已同步为新手机号，该员工需重新登录');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _editVehicles() async {
    final ok = await showEmployeeVehiclesDialog(context, _p.vehicles);
    if (ok == null || !mounted) return;
    try {
      await ref.read(employeeRepositoryProvider).update(widget.employeeId, {
        'vehicles': ok,
      });
      if (!mounted) return;
      context.appSuccess('车辆信息已更新');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _editPhones() async {
    final ok = await showEmployeePhonesDialog(context, _p.phones);
    if (ok == null || !mounted) return;
    try {
      await ref.read(employeeRepositoryProvider).update(widget.employeeId, {
        'phones': ok,
      });
      if (!mounted) return;
      context.appSuccess('备用手机号已更新');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _openPermissionSettings() async {
    final profile = _profile;
    if (profile == null) return;
    final l10n = AppLocalizations.of(context);
    if (profile.accountStatus == null) {
      if (profile.status == 'resigned') {
        context.appError(l10n.employeeResignedCannotProvision);
        return;
      }
      if (!ref.read(currentPermissionsProvider).contains(Perm.accountSupport)) {
        context.appError(l10n.employeeAccountNotProvisionedContactSupport);
        return;
      }
      final result = await showProvisionSelectedEmployeeAccountFlow(
        context,
        ref: ref,
        employeeId: widget.employeeId,
        employeeName: profile.fullName ?? '未命名员工',
        employeeCode: profile.code,
        hasAccount: false,
      );
      if (result == null || !mounted) return;
      setState(() => _profile = result.employee);
    }
    if (!mounted) return;
    final target = Uri(
      path: RouteName.adminPermissions,
      queryParameters: {'employeeId': widget.employeeId},
    );
    context.push(target.toString());
  }

  /// 给批量导入等「未开通账号」的存量员工补开登录账号。
  Future<void> _onProvisionAccount() async {
    final profile = _profile;
    if (profile == null ||
        profile.accountStatus != null ||
        profile.status == 'resigned') {
      return;
    }
    final result = await showProvisionSelectedEmployeeAccountFlow(
      context,
      ref: ref,
      employeeId: widget.employeeId,
      employeeName: profile.fullName ?? '未命名员工',
      employeeCode: profile.code,
      hasAccount: false,
    );
    if (result == null || !mounted) return;
    setState(() => _profile = result.employee);
    await _load();
  }

  Future<void> _onLockAccount() => _toggleAccountLock(lock: true);

  Future<void> _onUnlockAccount() => _toggleAccountLock(lock: false);

  /// 锁定 / 解锁登录账号（account:support）。二次确认后调端点，成功刷新档案。
  Future<void> _toggleAccountLock({required bool lock}) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          lock
              ? l10n.employeeActionLockAccount
              : l10n.employeeActionUnlockAccount,
        ),
        content: Text(
          lock ? '锁定后该员工将无法登录，所有会话立即失效，是否继续？' : '解锁后该员工可正常登录，是否继续？',
        ),
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
      final repo = ref.read(employeeRepositoryProvider);
      if (lock) {
        await repo.lockAccount(widget.employeeId);
      } else {
        await repo.unlockAccount(widget.employeeId);
      }
      if (!mounted) return;
      context.appSuccess(
        lock
            ? l10n.employeeLockAccountSuccess
            : l10n.employeeUnlockAccountSuccess,
      );
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
    final today = ChinaDateTime.today();
    DateTime selected = today;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(l10n.employeeConfirmTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.employeeConfirmBody),
              const SizedBox(height: UtenSpacing.s12),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(_fmtDate(selected)),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: selected,
                    firstDate: DateTime(2000),
                    lastDate: today,
                    locale: const Locale('zh'),
                  );
                  if (picked != null) setState(() => selected = picked);
                },
              ),
            ],
          ),
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
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(employeeRepositoryProvider)
          .confirm(widget.employeeId, confirmedDate: _fmtDate(selected));
      if (!mounted) return;
      context.appSuccess(l10n.employeeConfirmSuccess);
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';

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

  // ============================================================
  // 通用小部件
  // ============================================================

  /// 分组：标题（卡外）+ UtenCard（键值行），区块间距 24。
  Widget _section(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
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

  String _contractTypeText(AppLocalizations l10n, String? t) => switch (t) {
    'fixed' => l10n.contractTypeFixed,
    'open' => l10n.contractTypeOpen,
    'task' => l10n.contractTypeTask,
    'intern' => l10n.contractTypeIntern,
    _ => (t == null || t.trim().isEmpty) ? '—' : t,
  };

  String _historyTitle(AppLocalizations l10n, EmploymentHistoryView h) {
    final type = switch (h.eventType) {
      'onboard' => l10n.historyEventOnboard,
      'transfer' => l10n.historyEventTransfer,
      'confirm' => '转正',
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
