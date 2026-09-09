// ProfilePage - 我的页面（v7 — 档案区 Tab 化，对齐员工详情页范式）
// 文档：docs/03-页面/我的页.md
//
// v7 改造（vs v6 八段卡片竖排）：
//   * 档案区改 Tab 分组（基本信息 / 组织与合同 / 联系与车辆 / 任职记录 / 我的文件），
//     与人事端员工详情页同一范式、同一批分组名——「我的档案就是人事看到的我」
//   * 单列断点（compact/medium）：身份卡 + 快捷卡随上滑折叠收起，Tab 栏吸顶，
//     各 Tab 正文内滚（UtenCollapsingHeaderScrollView，同员工详情页）
//   * expanded 双列：左 380 身份组固定自滚 | 右 TabBar 常驻顶栏 + TabBarView 内滚
//   * 「我的车辆与号码」「我的文件」独立页吸收为 Tab（路由下线）；
//     全部数据来自 GET /profile/me（EmployeeDetail 含 vehicles/phones/attachments）
//   * 身份组保留 Hero 卡 + 我的部门 + 我的修改申请（独立管理页）；
//     快捷入口用 goFrom 带 returnTo，返回恒回「我的」而非工作台兜底
//   * 字段维护策略徽章（直接修改 / 需审核 / 人事维护）原样保留；
//     薪酬与银行不因本人对象范围自动展示
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../shared/attachments/employee_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/role.dart';
import '../../../shared/models/user.dart';
import '../../../shared/providers/session_provider.dart';
import '../../department/providers/my_department_providers.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/widgets/employee_status_badge.dart';
import '../field_policy.dart';
import '../models/profile_change_request.dart';
import '../providers/profile_change_providers.dart';
import '../widgets/my_documents_section.dart';
import '../widgets/my_vehicle_phone_cards.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage>
    with SingleTickerProviderStateMixin {
  // 必须在 initState 立即创建：late final 惰性初始化会让 loading/未绑定等
  // 不构建 Tab 的分支把「首次访问」留到 dispose()，在已停用 element 上
  // 注册 ticker 触发断言。
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionProvider);
    final user = session.user;
    final theme = Theme.of(context);

    if (user == null) {
      return _stateScaffold(
        UtenEmpty(
          icon: Icons.person_outline,
          message: l10n.profileSessionUnavailable,
        ),
      );
    }

    final profileAsync = ref.watch(myEmployeeProfileProvider);
    return profileAsync.when(
      loading: () => _stateScaffold(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: UtenSpacing.s16),
            Text(l10n.profileLoadingMessage),
          ],
        ),
      ),
      error: (_, _) => _stateScaffold(
        UtenEmpty.error(
          message: l10n.profileLoadFailed,
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(myEmployeeProfileProvider),
        ),
      ),
      data: (profile) {
        if (profile == null) {
          return _stateScaffold(
            UtenEmpty(
              icon: Icons.person_off_outlined,
              message: l10n.profileUnboundTitle,
              description: l10n.profileUnboundDescription,
            ),
          );
        }

        final bp = context.breakpoint;
        final horizontalPadding = bp.select<double>(
          compact: UtenSpacing.s16,
          medium: UtenSpacing.s24,
          expanded: UtenSpacing.s32,
        );
        // compact 底部悬浮胶囊导航占位；medium+ 为侧栏 Rail，正常留白即可。
        final tabBottomPadding = bp.select<double>(
          compact: 96,
          medium: UtenSpacing.s24,
          expanded: UtenSpacing.s24,
        );
        final identityGroup = _buildIdentityGroup(
          context,
          ref,
          theme,
          l10n,
          user,
          profile,
        );
        final tabBar = _buildTabBar(theme, l10n);
        final tabViews = [
          _basicTab(theme, l10n, profile, tabBottomPadding),
          _orgContractTab(theme, l10n, profile, tabBottomPadding),
          _contactVehicleTab(theme, l10n, profile, tabBottomPadding),
          _historyTab(l10n, profile, tabBottomPadding),
          _documentsTab(profile, tabBottomPadding),
        ];

        return Scaffold(
          // 局部 SelectionArea：个人资料各 Tab 文字可框选复制（准则 §3.4）。
          body: SelectionArea(
            child: SafeArea(
              bottom: false,
              child: switch (bp) {
                // 单列：身份区随上滑折叠，Tab 栏吸顶后正文内滚（同员工详情页）。
                UtenBreakpoint.compact || UtenBreakpoint.medium => Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: _centerIfMedium(
                    bp,
                    child: UtenCollapsingHeaderScrollView(
                      collapsingHeader: Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            identityGroup.hero,
                            const SizedBox(height: UtenSpacing.s12),
                            identityGroup.department,
                            const SizedBox(height: UtenSpacing.s12),
                            identityGroup.shortcut,
                            const SizedBox(height: UtenSpacing.s4),
                          ],
                        ),
                      ),
                      pinnedHeader: _pinnedTabBar(theme, tabBar),
                      pinnedHeaderExtent: tabBar.preferredSize.height,
                      body: TabBarView(controller: _tab, children: tabViews),
                    ),
                  ),
                ),
                // 双列：左身份组固定自滚 | 右 TabBar 常驻 + Tab 内滚。
                UtenBreakpoint.expanded => Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    UtenSpacing.s24,
                    horizontalPadding,
                    0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 380,
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              identityGroup.hero,
                              const SizedBox(height: UtenSpacing.s16),
                              identityGroup.department,
                              const SizedBox(height: UtenSpacing.s12),
                              identityGroup.shortcut,
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s32),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _pinnedTabBar(theme, tabBar),
                                Expanded(
                                  child: TabBarView(
                                    controller: _tab,
                                    children: tabViews,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              },
            ),
          ),
        );
      },
    );
  }

  Widget _stateScaffold(Widget child) => Scaffold(
    body: SafeArea(child: Center(child: child)),
  );

  /// medium 收敛居中 720；compact 顶满。
  Widget _centerIfMedium(UtenBreakpoint bp, {required Widget child}) =>
      bp == UtenBreakpoint.medium
      ? Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: child,
          ),
        )
      : child;

  /// 吸顶/常驻 Tab 栏：补不透明底色，避免正文滚动时从 Tab 间隙透出。
  Widget _pinnedTabBar(ThemeData theme, TabBar tabBar) =>
      Container(color: theme.scaffoldBackgroundColor, child: tabBar);

  TabBar _buildTabBar(ThemeData theme, AppLocalizations l10n) {
    return TabBar(
      controller: _tab,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelStyle: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      tabs: [
        Tab(text: l10n.employeeDetailBasic),
        Tab(text: l10n.profileTabOrgContract),
        Tab(text: l10n.profileTabContactVehicle),
        Tab(text: l10n.profileEmploymentHistoryTitle),
        Tab(text: l10n.profileTabMyDocuments),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 身份组：Hero 卡 + 我的部门 + 我的修改申请
  // ─────────────────────────────────────────────────────────────
  _IdentityGroup _buildIdentityGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    AppLocalizations l10n,
    AppUser user,
    EmployeeProfile profile,
  ) {
    return _IdentityGroup(
      hero: _HeroCard(user: user, profile: profile, theme: theme, l10n: l10n),
      department: const _MyDepartmentShortcut(),
      shortcut: _MyChangesShortcut(l10n: l10n),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Tab 正文：下拉刷新统一重拉本人档案；ListView 无显式 controller，
  // 自动拾取 NestedScrollView 注入的 PrimaryScrollController 参与联动。
  // ─────────────────────────────────────────────────────────────
  Widget _tabBody(List<Widget> sections, double bottomPadding) {
    return RefreshIndicator(
      onRefresh: () => ref.refresh(myEmployeeProfileProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(0, UtenSpacing.s16, 0, bottomPadding),
        children: sections,
      ),
    );
  }

  // Tab 1：基本信息（人口属性 + 地址 + 紧急联系人）
  Widget _basicTab(
    ThemeData theme,
    AppLocalizations l10n,
    EmployeeProfile p,
    double bottomPadding,
  ) {
    final emergencyRows = p.emergencyContacts.isEmpty
        ? <Widget>[
            _profileField(
              label: l10n.employeeDetailEmergency,
              value: l10n.profileValueNotRegistered,
            ),
          ]
        : <Widget>[
            for (var index = 0; index < p.emergencyContacts.length; index++)
              _profileField(
                label:
                    [
                          p.emergencyContacts[index].relationship,
                          p.emergencyContacts[index].name,
                        ]
                        .where((value) => value?.trim().isNotEmpty == true)
                        .join(' · '),
                value: p.emergencyContacts[index].phone,
                kind: index == 0
                    ? FieldPolicyKind.requiresReview
                    : FieldPolicyKind.hrOnly,
                // 紧急联系人三输入在编辑页同卡片相邻，行级铅笔统一定位到姓名输入。
                editField: index == 0
                    ? '${ProfileFieldPolicy.emergencyContactPrefix}0.name'
                    : null,
                showDivider: index < p.emergencyContacts.length - 1,
              ),
          ];

    return _tabBody([
      _section(l10n.employeeDetailBasic, [
        _profileField(label: l10n.employeeFieldCode, value: p.code),
        _profileField(
          label: l10n.employeeFieldName,
          value: p.fullName,
          fieldCode: ProfileFieldPolicy.fullName,
        ),
        _profileField(
          label: l10n.employeeFieldGender,
          value: _genderText(l10n, p.gender),
          fieldCode: ProfileFieldPolicy.gender,
        ),
        _profileField(label: l10n.employeeFieldIdType, value: p.idType),
        _profileField(label: l10n.employeeFieldIdNumber, value: p.idNumber),
        _profileField(
          label: l10n.employeeFieldBirthDate,
          value: p.birthDate,
          fieldCode: ProfileFieldPolicy.birthDate,
        ),
        _profileField(
          label: l10n.employeeFieldEthnicity,
          value: p.ethnicity,
          fieldCode: ProfileFieldPolicy.ethnicity,
        ),
        _profileField(
          label: l10n.employeeFieldPoliticalStatus,
          value: p.politicalStatus,
          fieldCode: ProfileFieldPolicy.politicalStatus,
        ),
        _profileField(
          label: l10n.employeeFieldMaritalStatus,
          value: p.maritalStatus,
          fieldCode: ProfileFieldPolicy.maritalStatus,
          showDivider: false,
        ),
      ]),
      const SizedBox(height: UtenSpacing.s16),
      _section(l10n.profileFieldGroupAddress, [
        _profileField(
          label: l10n.employeeFieldResidenceAddress,
          value: p.residenceAddress,
          fieldCode: ProfileFieldPolicy.residenceAddress,
        ),
        _profileField(
          label: l10n.employeeFieldHujiAddress,
          value: p.hujiAddress,
          fieldCode: ProfileFieldPolicy.hujiAddress,
          showDivider: false,
        ),
      ]),
      const SizedBox(height: UtenSpacing.s16),
      _section(l10n.employeeDetailEmergency, emergencyRows),
    ], bottomPadding);
  }

  // Tab 2：组织与合同（组织信息 + 合同摘要 + 范围脚注）
  Widget _orgContractTab(
    ThemeData theme,
    AppLocalizations l10n,
    EmployeeProfile p,
    double bottomPadding,
  ) {
    return _tabBody([
      _section(l10n.employeeDetailOrg, [
        _profileField(
          label: l10n.employeeFieldDepartment,
          value: p.departmentName,
        ),
        _profileField(label: l10n.employeeFieldPosition, value: p.positionName),
        _profileField(
          label: l10n.employeeFieldSupervisor,
          value: p.supervisorName,
        ),
        _profileField(label: l10n.employeeFieldHireDate, value: p.hireDate),
        _profileField(
          label: l10n.employeeFieldConfirmedDate,
          value: p.confirmedAt,
        ),
        _profileField(
          label: l10n.employeeFieldStatus,
          value: p.status,
          valueWidget: EmployeeStatusBadge(
            status: p.status,
            size: UtenStatusBadgeSize.medium,
          ),
        ),
        _profileField(
          label: l10n.employeeFieldAccountStatus,
          value: _accountStatusText(l10n, p.accountStatus),
        ),
        _profileField(
          label: l10n.employeeFieldEmploymentType,
          value: _employmentTypeText(l10n, p.employmentType),
        ),
        _profileField(
          label: l10n.employeeFieldWorkLocation,
          value: p.workLocation,
          fieldCode: ProfileFieldPolicy.workLocation,
        ),
        _profileField(
          label: l10n.employeeFieldSeatNo,
          value: p.seatNo,
          fieldCode: ProfileFieldPolicy.seatNo,
          showDivider: false,
        ),
      ]),
      const SizedBox(height: UtenSpacing.s16),
      _section(l10n.profileContractSummaryTitle, [
        UtenInfoRow(
          label: l10n.employeeFieldContractType,
          value: _display(l10n, _contractTypeText(l10n, p.contractType)),
          showDivider: false,
        ),
        UtenInfoRow(
          label: l10n.employeeFieldContractPeriod,
          value: p.contractStart == null && p.contractEnd == null
              ? l10n.profileValueNotProvided
              : l10n.employeeContractPeriodValue(
                  _display(l10n, p.contractEnd),
                  _display(l10n, p.contractStart),
                ),
        ),
        UtenInfoRow(
          label: l10n.employeeFieldProbation,
          value: p.probationMonths == null
              ? l10n.profileValueNotProvided
              : l10n.employeeProbationValue(
                  _display(l10n, p.probationEndDate),
                  p.probationMonths!,
                ),
        ),
        UtenInfoRow(
          label: l10n.employeeFieldRenewCount,
          value: p.renewCount == null
              ? l10n.profileValueNotProvided
              : l10n.employeeRenewCountValue(p.renewCount!),
          showDivider: false,
        ),
      ], policy: FieldPolicyKind.hrOnly),
      const SizedBox(height: UtenSpacing.s16),
      _scopeFootnote(theme, l10n),
    ], bottomPadding);
  }

  /// 隐私边界脚注（原独立提示卡降级为小字，不再占整卡）。
  Widget _scopeFootnote(ThemeData theme, AppLocalizations l10n) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.privacy_tip_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            l10n.profileCompensationBoundaryDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  // Tab 3：联系与车辆（联系方式 + 车辆/备用号自助管理）
  Widget _contactVehicleTab(
    ThemeData theme,
    AppLocalizations l10n,
    EmployeeProfile p,
    double bottomPadding,
  ) {
    return _tabBody([
      _section(l10n.profileFieldGroupContact, [
        _profileField(
          label: l10n.employeeFieldPhone,
          value: p.phone,
          fieldCode: ProfileFieldPolicy.phone,
        ),
        _profileField(
          label: l10n.profileAlternatePhoneLabel,
          value: p.phones.isEmpty
              ? l10n.profileValueNotRegistered
              : p.phones
                    .map(
                      (phone) =>
                          '${_display(l10n, phone.phone)}(${_display(l10n, phone.label)})',
                    )
                    .join('、'),
          kind: FieldPolicyKind.directEdit,
        ),
        _profileField(
          label: l10n.employeeFieldOfficePhone,
          value: p.officePhone,
          fieldCode: ProfileFieldPolicy.officePhone,
        ),
        _profileField(
          label: l10n.employeeFieldEmail,
          value: p.email,
          fieldCode: ProfileFieldPolicy.email,
          showDivider: false,
        ),
      ]),
      const SizedBox(height: UtenSpacing.s16),
      MyVehiclesManageCard(vehicles: p.vehicles),
      const SizedBox(height: UtenSpacing.s12),
      MyPhonesManageCard(phones: p.phones),
    ], bottomPadding);
  }

  // Tab 4：任职记录
  Widget _historyTab(
    AppLocalizations l10n,
    EmployeeProfile p,
    double bottomPadding,
  ) {
    return _tabBody([
      _section(
        l10n.profileEmploymentHistoryTitle,
        p.history.isEmpty
            ? [
                UtenInfoRow(
                  label: l10n.profileEmploymentHistoryTitle,
                  value: l10n.profileValueNotRegistered,
                  showDivider: false,
                ),
              ]
            : [
                for (var index = 0; index < p.history.length; index++)
                  UtenInfoRow(
                    label: _historyTitle(l10n, p.history[index]),
                    value: _display(
                      l10n,
                      [p.history[index].eventDate, p.history[index].remark]
                          .where((value) => value?.trim().isNotEmpty == true)
                          .join(' · '),
                    ),
                    showDivider: index < p.history.length - 1,
                  ),
              ],
        policy: FieldPolicyKind.hrOnly,
      ),
    ], bottomPadding);
  }

  // Tab 5：我的文件（只读档案附件）
  Widget _documentsTab(EmployeeProfile p, double bottomPadding) {
    return _tabBody([MyDocumentsSection(profile: p)], bottomPadding);
  }

  Widget _profileField({
    required String label,
    String? value,
    String? fieldCode,
    FieldPolicyKind? kind,
    Widget? valueWidget,
    bool showDivider = true,
    String? editField,
  }) {
    final policyKind =
        kind ?? ProfileFieldPolicy.policyKindOf(fieldCode ?? '__hr_managed__');
    // 铅笔快捷入口：可编辑字段（直改/需审核）默认指向自身 fieldCode；
    // 紧急联系人行等无 fieldCode 的可改行用 editField 显式指定；
    // hrOnly 与备用手机号（Tab 内卡片管理）不出铅笔。
    final effectiveEdit =
        editField ??
        (fieldCode != null && policyKind != FieldPolicyKind.hrOnly
            ? fieldCode
            : null);
    return _ProfileFieldRow(
      label: label.trim().isEmpty ? null : label,
      value: value,
      valueWidget: valueWidget,
      policyKind: policyKind,
      onEdit: effectiveEdit == null
          ? null
          : () => context.go('${RouteName.profileEdit}?field=$effectiveEdit'),
      showDivider: showDivider,
    );
  }

  static String _display(AppLocalizations l10n, String? value) =>
      value == null || value.trim().isEmpty
      ? l10n.profileValueNotProvided
      : value.trim();

  String? _genderText(AppLocalizations l10n, String? gender) =>
      switch (gender) {
        'male' => l10n.genderMale,
        'female' => l10n.genderFemale,
        _ => gender,
      };

  String? _employmentTypeText(AppLocalizations l10n, String? type) =>
      switch (type) {
        'regular' => l10n.employmentTypeRegular,
        'dispatch' => l10n.employmentTypeDispatch,
        'intern' => l10n.employmentTypeIntern,
        'outsource' => l10n.employmentTypeOutsource,
        _ => type,
      };

  String? _contractTypeText(AppLocalizations l10n, String? type) =>
      switch (type) {
        'fixed' => l10n.contractTypeFixed,
        'open' => l10n.contractTypeOpen,
        'task' => l10n.contractTypeTask,
        'intern' => l10n.contractTypeIntern,
        _ => type,
      };

  String _accountStatusText(AppLocalizations l10n, String? status) =>
      switch (status) {
        'active' => l10n.accountStatusActive,
        'locked' => l10n.accountStatusLocked,
        'disabled' => l10n.accountStatusDisabled,
        _ => l10n.accountStatusNone,
      };

  String _historyTitle(AppLocalizations l10n, EmploymentHistoryView history) {
    final event = switch (history.eventType) {
      'onboard' => l10n.historyEventOnboard,
      'transfer' => l10n.historyEventTransfer,
      'confirm' => l10n.historyEventConfirm,
      'resign' => l10n.historyEventResign,
      'rehire' => l10n.historyEventRehire,
      _ => _display(l10n, history.eventType),
    };
    final department = history.toDeptName ?? history.fromDeptName;
    return department?.trim().isNotEmpty == true
        ? '$event · ${department!.trim()}'
        : event;
  }

  Widget _section(String title, List<Widget> rows, {FieldPolicyKind? policy}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(
          title: title,
          subdued: true,
          trailing: policy == null ? null : _PolicyBadge(kind: policy),
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16,
            vertical: UtenSpacing.s4,
          ),
          child: Column(children: rows),
        ),
      ],
    );
  }
}

class _ProfileFieldRow extends StatelessWidget {
  const _ProfileFieldRow({
    required this.label,
    required this.value,
    required this.policyKind,
    this.valueWidget,
    this.onEdit,
    this.showDivider = true,
  });

  final String? label;
  final String? value;
  final FieldPolicyKind policyKind;
  final Widget? valueWidget;
  final VoidCallback? onEdit;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final labelText = Text(
      label ?? l10n.profileValueNotProvided,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final valueContent =
        valueWidget ??
        Text(
          value == null || value!.trim().isEmpty
              ? l10n.profileValueNotProvided
              : value!.trim(),
          textAlign: TextAlign.right,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
    final pencil = onEdit == null
        ? null
        : _EditFieldPencil(kind: policyKind, onTap: onEdit);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 480) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        labelText,
                        _PolicyBadge(kind: policyKind),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: valueContent),
                          if (pencil != null) ...[
                            const SizedBox(width: UtenSpacing.s4),
                            pencil,
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        labelText,
                        const SizedBox(height: UtenSpacing.s4),
                        _PolicyBadge(kind: policyKind),
                      ],
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(child: valueContent),
                          if (pencil != null) ...[
                            const SizedBox(width: UtenSpacing.s4),
                            pencil,
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
      ],
    );
  }
}

/// 字段行尾的「修改」铅笔：直改 = 绿、需审核 = 黄；点击跳编辑页定位该字段。
class _EditFieldPencil extends StatelessWidget {
  const _EditFieldPencil({required this.kind, this.onTap});

  final FieldPolicyKind kind;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = kind == FieldPolicyKind.directEdit
        ? (isDark ? UtenColors.successOnDark : UtenColors.success)
        : (isDark ? UtenColors.warningOnDark : UtenColors.warning);
    return Tooltip(
      message: l10n.profileEditFieldAction,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(UtenRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(Icons.edit_outlined, size: 16, color: color),
        ),
      ),
    );
  }
}

class _PolicyBadge extends StatelessWidget {
  const _PolicyBadge({required this.kind});

  final FieldPolicyKind kind;

  @override
  Widget build(BuildContext context) => UtenStatusBadge(
    label: ProfileFieldPolicy.policyLabel(AppLocalizations.of(context), kind),
    type: switch (kind) {
      FieldPolicyKind.directEdit => UtenStatusBadgeType.success,
      FieldPolicyKind.requiresReview => UtenStatusBadgeType.warning,
      FieldPolicyKind.hrOnly => UtenStatusBadgeType.neutral,
    },
    size: UtenStatusBadgeSize.small,
  );
}

/// 把 Hero 卡 + 快捷入口包成一个结构体，避免 layout 里来回来回传参。
class _IdentityGroup {
  const _IdentityGroup({
    required this.hero,
    required this.department,
    required this.shortcut,
  });
  final Widget hero;
  final Widget department;
  final Widget shortcut;
}

/// 头部身份卡：头像 + 名字 + 角色 chip（一行）+ 部门职位 + 两个 CTA
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.user,
    required this.profile,
    required this.theme,
    required this.l10n,
  });

  /// session 只提供认证角色/超级管理员标记；员工身份文字一律取本人档案 DTO。
  final AppUser user;
  final EmployeeProfile profile;
  final ThemeData theme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    // 大屏略放大头像，建立气场；保持 ≥44pt touch target 友好。
    final avatarSize = context.breakpoint.select<double>(
      compact: 56,
      medium: 60,
      expanded: 64,
    );
    final name = profile.fullName?.trim().isNotEmpty == true
        ? profile.fullName!.trim()
        : l10n.profileValueNotProvided;
    final department = profile.departmentName?.trim().isNotEmpty == true
        ? profile.departmentName!.trim()
        : l10n.profileValueNotProvided;
    final position = profile.positionName?.trim().isNotEmpty == true
        ? profile.positionName!.trim()
        : l10n.profileValueNotProvided;

    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              EmployeeAvatar(
                employeeId: profile.id,
                revision: profile.avatarStorageKey,
                size: avatarSize,
                name: name,
              ),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 名字 + 角色徽章同行：用 Wrap 让长名字能换行时 chip 跟着换
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s4,
                      children: [
                        Text(
                          name,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        ..._buildRoleChips(user, theme),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '$department · $position',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          // CTA：修改我的信息 + 修改密码（全员可见；能改什么由编辑页字段策略定）
          Row(
            children: [
              Expanded(
                child: UtenButton(
                  size: UtenButtonSize.small,
                  icon: Icons.edit_outlined,
                  // go_router 14：从 /profile（ShellRoute 主 Tab）push /profile/edit 会静默失效
                  // （redirect 放行但路由未构造），改用 go；返回靠 AppBar ← 与提交后 pop。
                  onPressed: () => context.go(RouteName.profileEdit),
                  child: Text(l10n.profileChangeEditCta),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_outline_rounded,
                  onPressed: () => context.push(RouteName.changePassword),
                  child: Text(l10n.profileChangePassword),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 把角色渲染成紧贴名字的 chip。
  ///
  /// - superAdmin：实心 teal「ADMIN」徽章，最优先
  /// - 普通角色：≤2 个全展示；>2 显示前 2 +「+N」折叠
  List<Widget> _buildRoleChips(AppUser user, ThemeData theme) {
    final chips = <Widget>[];

    if (user.superAdmin) {
      chips.add(
        _RoleChip(
          label: 'ADMIN',
          icon: Icons.verified_rounded,
          background: UtenColors.teal500,
          foreground: Colors.white,
          theme: theme,
        ),
      );
    }

    const maxNormalRoles = 2;
    final roles = user.roles;
    final showRoles = roles.length > maxNormalRoles
        ? roles.take(maxNormalRoles).toList()
        : roles;
    for (final r in showRoles) {
      chips.add(
        _RoleChip(
          label: r.displayNameZh,
          icon: _iconForRole(r),
          outline: true,
          theme: theme,
        ),
      );
    }
    if (roles.length > maxNormalRoles) {
      chips.add(
        _RoleChip(
          label: '+${roles.length - maxNormalRoles}',
          outline: true,
          theme: theme,
          muted: true,
        ),
      );
    }
    return chips;
  }

  IconData _iconForRole(Role role) {
    switch (role) {
      case Role.admin:
        return Icons.admin_panel_settings_rounded;
      case Role.hr:
        return Icons.badge_rounded;
      case Role.finance:
        return Icons.account_balance_rounded;
      case Role.lab:
        return Icons.science_rounded;
      case Role.production:
        return Icons.factory_rounded;
      case Role.manager:
        return Icons.supervisor_account_rounded;
      case Role.security:
        return Icons.shield_rounded;
      case Role.employee:
        return Icons.person_rounded;
    }
  }
}

/// 角色徽章：支持实心（superAdmin）/ 描边（普通角色）/ 静音（折叠 +N）
class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.label,
    required this.theme,
    this.icon,
    this.background,
    this.foreground,
    this.outline = false,
    this.muted = false,
  });

  final String label;
  final IconData? icon;
  final Color? background;
  final Color? foreground;
  final bool outline;
  final bool muted;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final fg =
        foreground ??
        (muted
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.primary);
    final bg =
        background ??
        (outline ? theme.colorScheme.surfaceContainer : Colors.transparent);

    final borderSide = outline
        ? BorderSide(color: theme.colorScheme.outlineVariant)
        : BorderSide.none;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon != null ? UtenSpacing.s8 : UtenSpacing.s12,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: UtenRadius.smAll,
        border: outline ? Border.fromBorderSide(borderSide) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: UtenSpacing.s4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// 我的部门快捷入口：显示所属分支名 + 跳 /profile/me/department 全页面查看。
class _MyDepartmentShortcut extends ConsumerWidget {
  const _MyDepartmentShortcut();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 取所属大部门分支根名做副标题；加载中/失败/未分配时给中性占位文案。
    final async = ref.watch(myDepartmentTreeProvider);
    final branchName = async.maybeWhen(
      data: (tree) => tree.isEmpty ? null : tree.first.name,
      orElse: () => null,
    );

    return UtenCard(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s4,
        ),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: UtenRadius.lgAll,
          ),
          child: Icon(
            Icons.account_tree_rounded,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        title: Text(
          '我的部门',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          branchName ?? '查看本部门架构与花名册',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        // goFrom 带 ?returnTo=/profile：子页返回键来源感知回「我的」，
        // 不再落入 UtenBackButton 的工作台兜底（主 Tab 前缀子路由 go 不 push）。
        onTap: () => goFrom(context, RouteName.profileMyDepartment),
      ),
    );
  }
}

/// 我的修改申请快捷入口：显示 pending 数 + 跳 /profile/me/changes。
class _MyChangesShortcut extends ConsumerWidget {
  const _MyChangesShortcut({required this.l10n});
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(
      myProfileChangesProvider((status: 'pending', page: 1)),
    );
    final count = async.maybeWhen(data: (page) => page.total, orElse: () => 0);

    return UtenCard(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s4,
        ),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: UtenRadius.lgAll,
          ),
          child: Icon(
            Icons.assignment_outlined,
            size: 18,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          l10n.profileChangeListTitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          count > 0
              ? l10n.profilePendingBadge(count)
              : l10n.profileChangeListEmpty,
          style: TextStyle(
            color: count > 0
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: count > 0 ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        // 同上：goFrom 带 returnTo，返回恒回「我的」。
        onTap: () => goFrom(context, RouteName.profileMyChanges),
      ),
    );
  }
}
