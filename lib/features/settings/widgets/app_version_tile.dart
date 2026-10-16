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
        l10n.release253Reset,
        l10n.release253Maintenance,
      ],
      // v2.5.7 与 v2.5.6 同批发布(含并行收尾), 说明共用; 下一个版本再另立条目。
      '2.5.6' || '2.5.7' => [
        l10n.release253Hr,
        l10n.release253Permissions,
        l10n.release253Materials,
        l10n.release253Ai,
        l10n.release253Notices,
        l10n.release253Reset,
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
        l10n.release2518ServerUpdates,
        l10n.release2518Storage,
        l10n.release2518CompanyConnections,
        l10n.release2518LayoutAndTrace,
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
