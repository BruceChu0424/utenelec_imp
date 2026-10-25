import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/constants/app_info.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';

/// Release notes travel with the installed client, never with the latest server.
class AppVersionTile extends StatelessWidget {
  const AppVersionTile({super.key, this.version = AppInfo.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.info_outline, size: 20),
      title: Text(l10n.settingsVersion),
      subtitle: Text(l10n.releaseNotesOpen),
      trailing: Text(version),
      contentPadding: EdgeInsets.zero,
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => _ReleaseNotesDialog(version: version),
      ),
    );
  }
}

class _ReleaseNotesDialog extends StatelessWidget {
  const _ReleaseNotesDialog({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final normalized = version.startsWith('v') ? version.substring(1) : version;
    final notes = switch (normalized) {
      '2.5.3' => [
        l10n.release253Hr,
        l10n.release253Permissions,
        l10n.release253Materials,
        l10n.release253Ai,
        l10n.release253Notices,
        l10n.release253Maintenance,
      ],
      // v2.5.7 与 v2.5.6 同批发布(含并行收尾), 说明共用; 下一个版本再另立条目。
      '2.5.6' || '2.5.7' => [
        l10n.release253Hr,
        l10n.release253Permissions,
        l10n.release253Materials,
        l10n.release253Ai,
        l10n.release253Notices,
        l10n.release253Maintenance,
        l10n.release254QuantityPrecision,
        l10n.release254AiAuthorization,
        l10n.release254SensitiveAuthorization,
        l10n.release254OverLimit,
        l10n.release254PlanningReminders,
        l10n.release254PeoplePicker,
        l10n.release254AccountSupport,
        l10n.release254Dashboard,
        l10n.release254Publishing,
      ],
      '2.5.8' => [
        l10n.release258StatusColors,
        l10n.release258IqcPending,
        l10n.release258StockCount,
        l10n.release258CompactCells,
        l10n.release258LockReason,
      ],
      '2.5.9' => [
        l10n.release259RollbackMerge,
        l10n.release259SubcontractPending,
        l10n.release259InProgressGate,
        l10n.release259NoticeGrouping,
        l10n.release259PopupSettings,
        l10n.release259HrAndProfile,
      ],
      '2.5.10' => [
        l10n.release2510TableAlignment,
        l10n.release2510TransferOpen,
        l10n.release2510BatchReport,
        l10n.release2510FinanceRate,
        l10n.release2510NeedDate,
        l10n.release2510DirectTransfer,
        l10n.release2510SessionIdentity,
        l10n.release2510Misc,
      ],
      '2.5.11' => [
        l10n.release2511DailyReport,
        l10n.release2511Workshop,
        l10n.release2511Batch,
        l10n.release2511Platform,
      ],
      '2.5.17' => [
        l10n.release2517PickerLayout,
        l10n.release2517Lifecycle,
        l10n.release2517Paging,
        l10n.release2517Drafts,
      ],
      '2.5.18' => [
        l10n.release2518ServerUpdates,
        l10n.release2518Storage,
        l10n.release2518CompanyConnections,
        l10n.release2518LayoutAndTrace,
      ],
      '2.5.19' => [
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Fixed database migration startup during server upgrades, while '
                'keeping backups, permission isolation, and health checks.',
          'ko' =>
            '서버 업데이트 중 데이터베이스 마이그레이션이 시작되지 않던 문제를 수정했습니다. '
                '백업, 권한 분리 및 상태 점검 절차는 유지됩니다.',
          _ => '修复服务器升级时迁移程序无法启动的问题，保留备份、权限隔离和健康检查流程。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Fixed account provisioning blocked by a deleted account. '
                'Reopening preserves identity without restoring old personal permissions.',
          'ko' =>
            '삭제된 계정 때문에 새 계정을 개설할 수 없던 문제를 수정했습니다. '
                '기존 식별자는 유지하고 이전 개인 권한은 복원하지 않습니다.',
          _ => '修复已删除账号占位导致员工无法开通的问题，保留历史身份，重新开通不恢复旧个人授权。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Notification cards now wrap full dates and group counts on narrow screens '
                'and with larger text.',
          'ko' => '좁은 화면과 큰 글꼴에서도 알림 카드의 날짜와 묶음 개수가 잘리지 않도록 줄바꿈합니다.',
          _ => '通知卡片在窄屏和大字体下完整换行显示日期及分组数量。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'HR identity review now uses separate employee columns, one read-only '
                'suggestion and manual entry. Employee details share the standard '
                'category control; account actions are visible in headers and AI '
                'use is categorized within permission details.',
          'ko' =>
            '인사 증명서 검토는 직원 정보를 열별로 나누고 하나의 읽기 전용 제안과 수동 입력을 사용합니다. '
                '직원 상세는 공통 분류 구성요소를 사용하며, 계정 작업은 상단에 배치하고 AI 사용 권한은 권한 상세에서 분류합니다.',
          _ => '员工核对信息分列、只读单条建议与手动填写；详情使用统一分类栏，账号操作外显，AI 使用权限归入权限明细分类。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Form fields and table editors now share consistent styles. Cost '
                'budget hierarchies follow assembly components and adapt to '
                'narrow screens and larger text.',
          'ko' =>
            '양식과 표 편집기의 입력 스타일을 통일했습니다. 원가 예산 계층은 조립 구성요소와 '
                '동일하게 표시되며 좁은 화면과 큰 글꼴에도 대응합니다.',
          _ => '统一表单输入与表格编辑样式，成本预算层级对齐组装组件，适配窄屏和大字体。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Category code prefixes are checked as you type across the shared '
                'numbering namespace, then checked again when saving.',
          'ko' =>
            '분류 코드 접두어를 입력할 때 공통 번호 공간의 중복을 확인하고, '
                '저장 시 다시 검증합니다.',
          _ => '分类编号前缀输入时自动检查全系统占用，保存时再次校验，避免重复编号。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Material tracing has a clearer query layout and uses the same '
                'goods selector as sales, while retaining historical goods '
                'and access controls.',
          'ko' =>
            '자재 추적의 조회 영역을 정리하고 판매와 같은 품목 선택창을 사용합니다. '
                '이력 품목과 접근 권한은 유지됩니다.',
          _ => '物料追溯查询重新排版，货品选择与销售一致，支持历史货品并保留访问权限。',
        },
        l10n.release2518ServerUpdates,
        l10n.release2518Storage,
        l10n.release2518CompanyConnections,
        l10n.release2518LayoutAndTrace,
      ],
      '2.5.20' => [
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Search shows one list across categories on the right. Product names, '
                'codes and matching product categories take priority. Multiple '
                'keywords, filters and paging use the same result scope.',
          'ko' =>
            '검색 결과를 오른쪽에 분류에 관계없이 한 목록으로 표시합니다. 품목명, 코드와 '
                '해당 품목 분류를 우선하며 여러 검색어와 필터, 페이지 이동에 같은 조회 범위를 적용합니다.',
          _ => '搜索结果在右侧跨分类统一显示，优先匹配货品名称、编号和对应货品分类；支持多词组合，筛选与翻页保持同一范围。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Related description matches start collapsed and can be expanded below '
                'the main results. Component picking can switch between component '
                'categories and all goods.',
          'ko' =>
            '설명에만 관련된 결과는 기본적으로 접고 필요할 때 주요 결과 아래에 펼칩니다. '
                '구성요소 선택 시 구성요소 분류와 전체 품목 범위를 전환할 수 있습니다.',
          _ => '描述相关结果默认收起，按需展开后排在主要结果下方；添加组件可切换组件分类与全部货品范围。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Use the + beside category search to add a top-level category in goods, '
                'customers, suppliers, moulds and payment methods.',
          'ko' =>
            '품목, 고객, 공급업체, 금형 및 결제 방식에서 분류 검색 옆의 + 버튼으로 '
                '최상위 분류를 추가할 수 있습니다.',
          _ => '货品、客户、供应商、模具及付款方式的分类搜索框旁新增 + 按钮，可直接添加最外层分类。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Input, dropdown and date fields share consistent heights and alignment. '
                'Category trees show names, and category codes remain searchable.',
          'ko' =>
            '입력칸, 선택 목록과 날짜 필드의 높이와 글자 정렬을 통일했습니다. '
                '분류 트리는 이름만 표시하며 분류 코드는 계속 검색할 수 있습니다.',
          _ => '统一表单输入框、下拉和日期控件的高度与文字对齐，分类树只显示名称，编号仍可搜索。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Mould manufacture months can be selected and corrected, and manufacturer '
                'details can be recorded. Mould pickers keep search results and paging in sync.',
          'ko' =>
            '금형 제조 연월을 선택하거나 수정할 수 있으며 제조사 정보를 기록할 수 있습니다. '
                '금형 선택창의 검색과 페이지 이동도 일치하도록 수정했습니다.',
          _ => '模具制造年月可正常选择和修改，新增制造商记录，选择器搜索与分页同步修正。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Employee records load the complete roster and allow hire-date corrections. '
                'Accounts can be found by employee name, staff code or department.',
          'ko' =>
            '직원 기록에서 전체 직원 명단을 불러오고 입사일을 정정할 수 있습니다. '
                '직원 이름, 사번 또는 부서로 계정을 찾을 수 있습니다.',
          _ => '员工档案显示完整人员名单，支持更正入职日期；账号可按姓名、工号和部门查找。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Customer access can be scoped by department or person. Customer and '
                'receivable information remains within authorized access, and task '
                'and permission controls fit narrow screens.',
          'ko' =>
            '고객 조회 범위를 부서나 직원별로 설정할 수 있습니다. 고객 및 미수금 정보는 '
                '부여된 권한 범위에서만 표시되며 작업과 권한 조작부도 좁은 화면에 맞춰 표시됩니다.',
          _ => '客户查看范围可按部门或人员配置，客户及应收信息继续按授权隔离；任务和权限操作在窄屏下完整显示。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Daily-report outputs that can only go to the warehouse show “Send to '
                'warehouse” in the main table. Outputs needing allocation or review '
                'keep their details below, preserving entered materials and quantities.',
          'ko' =>
            '창고로만 보낼 수 있는 생산 실적은 주 표에 ‘창고 입고’로 표시합니다. '
                '배분이나 확인이 필요한 이동 대상은 아래 상세 영역에서 관리하며 '
                '입력한 자재와 수량은 유지됩니다.',
          _ => '报工中只能送仓的产出在主表直接显示“送入仓库”，需要分配或核对的去向保留在下方详情，原用料和数量保持不变。',
        },
        switch (Localizations.localeOf(context).languageCode) {
          'en' =>
            'Attachment actions, including “Add file”, align to the right and wrap '
                'on narrow screens. Files selected before saving remain queued '
                'until the record is saved.',
          'ko' =>
            '‘파일 추가’ 등 첨부 작업을 오른쪽에 정렬하고 좁은 화면에서는 줄바꿈합니다. '
                '저장 전에 선택한 파일은 문서를 저장할 때 업로드됩니다.',
          _ => '附件区的“添加文件”等操作统一靠右，窄屏自动换行；保存前选好的附件在单据保存后上传。',
        },
      ],
      '2.5.23' => [
        l10n.release2523TaskAudience,
        l10n.release2523PermissionTransfer,
        l10n.release2523PickerTables,
        l10n.release2523PlatformSettings,
        l10n.release2523LoginOtp,
        l10n.release2523ServerAlert,
      ],
      '2.5.21' || '2.5.22' => [
        l10n.release2521Permissions,
        l10n.release2521Session,
        l10n.release2521PermissionSettings,
        l10n.release2521ReviewFeedback,
        l10n.release2521ServerUpdates,
        l10n.release2521TableSearchCopy,
        l10n.release2521FieldHints,
        l10n.release2521ReferencePickers,
        l10n.release2521MasterDataImport,
        l10n.release2521PurchaseDocuments,
        l10n.release2521GoodsHistory,
      ],
      _ => <String>[],
    };
    final theme = Theme.of(context);
    return SelectionArea(
      child: UtenAlertDialog(
        scrollable: false,
        title: Text('${l10n.releaseNotesTitle} · $version'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: notes.isEmpty
                  ? [Text(l10n.releaseNotesUnavailable)]
                  : [
                      for (var index = 0; index < notes.length; index++)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s16,
                          ),
                          child: Text(
                            '${index + 1}. ${notes[index]}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                    ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.releaseNotesClose),
          ),
        ],
      ),
    );
  }
}
