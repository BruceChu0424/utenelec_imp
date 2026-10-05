// 证件号码问题提醒：校验未通过红、缺失/未校验黄；正文原样带服务端具体原因；
// 只有传了修改回调才出「修改证件信息」按钮。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_id_number_issue.dart';
import 'package:uten_imp/features/employee/widgets/employee_identity_issue_notice.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

const _invalid = EmployeeIdNumberIssue(
  kind: EmployeeIdNumberIssueKind.invalid,
  reason: '身份证号应为18位，当前为17位',
);
const _missing = EmployeeIdNumberIssue(
  kind: EmployeeIdNumberIssueKind.missing,
  reason: '档案里没有证件号码',
);
const _unchecked = EmployeeIdNumberIssue(
  kind: EmployeeIdNumberIssueKind.unchecked,
  reason: '证件号码来自历史资料导入，系统还没有完成校验',
);

UtenInlineNotice _notice(WidgetTester tester) =>
    tester.widget<UtenInlineNotice>(
      find.descendant(
        of: find.byKey(const ValueKey('employee-identity-issue-notice')),
        matching: find.byType(UtenInlineNotice),
      ),
    );

void main() {
  test('idNumberIssue 解析：对象才算问题，未知种类忽略', () {
    final parsed = EmployeeIdNumberIssue.fromJson(const {
      'kind': 'invalid',
      'reason': '身份证号第18位只能是数字或X',
    });
    expect(parsed?.kind, EmployeeIdNumberIssueKind.invalid);
    expect(parsed?.reason, '身份证号第18位只能是数字或X');
    expect(parsed?.isError, isTrue);
    expect(
      EmployeeIdNumberIssue.fromJson(const {'kind': 'missing'})?.reason,
      '',
    );
    expect(EmployeeIdNumberIssue.fromJson(null), isNull);
    expect(EmployeeIdNumberIssue.fromJson('invalid'), isNull);
    expect(EmployeeIdNumberIssue.fromJson(const {'kind': 'other'}), isNull);
  });

  testWidgets('校验未通过用红色，正文先写服务端具体原因', (tester) async {
    await tester.pumpWidget(
      _host(
        const EmployeeIdentityIssueNotice(
          issue: _invalid,
          where: EmployeeIdentityNoticeContext.detail,
        ),
      ),
    );

    final notice = _notice(tester);
    expect(notice.level, UtenInlineNoticeLevel.error);
    expect(notice.title, '证件号码校验未通过');
    expect(
      notice.message,
      '具体问题：身份证号应为18位，当前为17位\n'
      '请人事对照员工证件核对后修改。不影响开通和使用登录账号。',
    );
    expect(find.textContaining('身份证号应为18位，当前为17位'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('employee-identity-issue-correct')),
      findsNothing,
      reason: '没传修改回调不显示按钮',
    );
  });

  testWidgets('缺失和未校验用黄色，标题按种类区分', (tester) async {
    for (final (issue, title) in [
      (_missing, '未登记证件号码'),
      (_unchecked, '证件号码尚未校验'),
    ]) {
      await tester.pumpWidget(
        _host(
          EmployeeIdentityIssueNotice(
            issue: issue,
            where: EmployeeIdentityNoticeContext.detail,
          ),
        ),
      );
      final notice = _notice(tester);
      expect(notice.level, UtenInlineNoticeLevel.warning, reason: title);
      expect(notice.title, title);
      expect(notice.message, startsWith('具体问题：${issue.reason}\n'));
    }
  });

  testWidgets('开号确认与凭据弹窗用各自的说明', (tester) async {
    await tester.pumpWidget(
      _host(
        const EmployeeIdentityIssueNotice(
          issue: _invalid,
          where: EmployeeIdentityNoticeContext.provision,
        ),
      ),
    );
    expect(_notice(tester).message, endsWith('可以继续开通，不受影响。人事任务中心会提醒人事核对修改。'));

    await tester.pumpWidget(
      _host(
        const EmployeeIdentityIssueNotice(
          issue: _missing,
          where: EmployeeIdentityNoticeContext.credential,
        ),
      ),
    );
    expect(_notice(tester).message, endsWith('初始密码由系统随机生成，请复制后交给员工。'));
  });

  testWidgets('传了修改回调才出按钮，点击触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        EmployeeIdentityIssueNotice(
          issue: _unchecked,
          where: EmployeeIdentityNoticeContext.detail,
          onCorrect: () => taps++,
        ),
      ),
    );

    final button = find.byKey(
      const ValueKey('employee-identity-issue-correct'),
    );
    expect(button, findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('修改证件信息')),
      findsOneWidget,
    );
    await tester.tap(button);
    expect(taps, 1);
  });
}
