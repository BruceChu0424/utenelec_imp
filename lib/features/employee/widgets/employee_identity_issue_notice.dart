// 证件号码问题提醒：员工详情页顶部常驻、开号确认弹窗、一次性凭据弹窗三处共用。
//
// 证件号码有问题只提醒、不阻塞开号(用户口径 2026-10-05)：校验未通过用红色，
// 缺失或尚未校验用黄色。正文第一句原样显示服务端给出的具体原因(如「身份证号应为
// 18位，当前为17位」)，第二句按场景说明接下来怎么办。不显示号码本身。
import 'package:flutter/material.dart';

import '../../../components/feedback/uten_inline_notice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../models/employee_id_number_issue.dart';

/// 提醒出现的位置：决定说明文字。
enum EmployeeIdentityNoticeContext {
  /// 员工详情页：提醒人事核对修改。
  detail,

  /// 开号确认弹窗：说明可以继续开通。
  provision,

  /// 一次性凭据弹窗：说明初始密码以弹窗显示的为准。
  credential,
}

class EmployeeIdentityIssueNotice extends StatelessWidget {
  const EmployeeIdentityIssueNotice({
    super.key = const ValueKey('employee-identity-issue-notice'),
    required this.issue,
    required this.where,
    this.onCorrect,
  });

  final EmployeeIdNumberIssue issue;
  final EmployeeIdentityNoticeContext where;

  /// 「修改证件信息」按钮回调；null 不显示按钮(无 employee:pii:edit)。
  final VoidCallback? onCorrect;

  /// 红色(校验未通过)还是黄色(缺失 / 尚未校验)。
  static UtenInlineNoticeLevel levelOf(EmployeeIdNumberIssue issue) =>
      issue.isError
      ? UtenInlineNoticeLevel.error
      : UtenInlineNoticeLevel.warning;

  static String titleOf(AppLocalizations l10n, EmployeeIdNumberIssue issue) =>
      switch (issue.kind) {
        EmployeeIdNumberIssueKind.invalid => l10n.employeeIdIssueInvalidTitle,
        EmployeeIdNumberIssueKind.missing => l10n.employeeIdIssueMissingTitle,
        EmployeeIdNumberIssueKind.unchecked =>
          l10n.employeeIdIssueUncheckedTitle,
      };

  static String _hintOf(
    AppLocalizations l10n,
    EmployeeIdNumberIssue issue,
    EmployeeIdentityNoticeContext where,
  ) => switch ((where, issue.kind)) {
    (EmployeeIdentityNoticeContext.detail, EmployeeIdNumberIssueKind.invalid) =>
      l10n.employeeIdIssueDetailInvalid,
    (EmployeeIdentityNoticeContext.detail, EmployeeIdNumberIssueKind.missing) =>
      l10n.employeeIdIssueDetailMissing,
    (
      EmployeeIdentityNoticeContext.detail,
      EmployeeIdNumberIssueKind.unchecked,
    ) =>
      l10n.employeeIdIssueDetailUnchecked,
    (EmployeeIdentityNoticeContext.provision, _) =>
      l10n.employeeIdIssueProvisionHint,
    (
      EmployeeIdentityNoticeContext.credential,
      EmployeeIdNumberIssueKind.invalid,
    ) =>
      l10n.employeeIdIssueCredentialInvalid,
    (
      EmployeeIdentityNoticeContext.credential,
      EmployeeIdNumberIssueKind.missing,
    ) =>
      l10n.employeeIdIssueCredentialMissing,
    (
      EmployeeIdentityNoticeContext.credential,
      EmployeeIdNumberIssueKind.unchecked,
    ) =>
      l10n.employeeIdIssueCredentialUnchecked,
  };

  /// 正文：具体原因(服务端原文) + 换行 + 场景说明。
  static String messageOf(
    AppLocalizations l10n,
    EmployeeIdNumberIssue issue,
    EmployeeIdentityNoticeContext where,
  ) {
    final hint = _hintOf(l10n, issue, where);
    return issue.reason.isEmpty
        ? hint
        : '${l10n.employeeIdIssueReason(issue.reason)}\n$hint';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final correct = onCorrect;
    return UtenInlineNotice(
      level: levelOf(issue),
      title: titleOf(l10n, issue),
      message: messageOf(l10n, issue, where),
      trailing: correct == null
          ? null
          : TextButton.icon(
              key: const ValueKey('employee-identity-issue-correct'),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: Text(l10n.employeeIdentityCorrectAction),
              onPressed: correct,
            ),
    );
  }
}
