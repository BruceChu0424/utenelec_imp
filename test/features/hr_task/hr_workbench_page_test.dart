// HR 工作台「证件核对」：有待核对员工时概览上方红色横幅(人数 + 去处理)；
// 事务入口只给能修改证件的人(超管或 employee:pii:edit)。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/hr_task/models/hr_task_summary.dart';
import 'package:uten_imp/features/hr_task/pages/hr_workbench_page.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_task_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _banner = ValueKey('hr-identity-review-banner');
const _go = ValueKey('hr-identity-review-go');
const _identityEntry = ValueKey('hr-workbench-entry-identity');

class _FakeHrTaskRepository extends Fake implements HrTaskRepository {
  _FakeHrTaskRepository(this.value);

  final HrTaskSummary value;

  @override
  Future<HrTaskSummary> summary() async => value;
}

HrTaskItem _item(String id, String note, {bool claimedByMe = false}) =>
    HrTaskItem(
      employeeId: id,
      code: 'UT-$id',
      name: '员工$id',
      deptName: '生产部',
      date: '2026-03-01',
      days: 218,
      note: note,
      claimedByName: claimedByMe ? '我' : null,
      claimedByMe: claimedByMe,
    );

HrTaskSummary _summary(List<HrTaskItem> identityReview) => HrTaskSummary(
  generatedAt: '2026-10-05T08:00:00+08:00',
  probationMonths: 3,
  confirmToday: const [],
  confirmUpcoming: const [],
  confirmOverdue: const [],
  unconfirmedLegacyCount: 0,
  birthdayToday: const [],
  birthdayUpcoming: const [],
  anniversaryToday: const [],
  newHires: const [],
  identityReview: identityReview,
  badgeCount: identityReview.length,
);

Future<void> _pump(
  WidgetTester tester,
  HrTaskSummary summary, {
  Set<String> permissions = const {Perm.employeeView},
  bool superAdmin = false,
  Size size = const Size(1200, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HrWorkbenchPage()),
      GoRoute(
        path: '/hr/tasks/:type',
        builder: (context, state) =>
            Scaffold(body: Text('task-list:${state.pathParameters['type']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hrTaskRepositoryProvider.overrideWithValue(
          _FakeHrTaskRepository(summary),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(superAdmin),
        formDraftsPageCountProvider.overrideWith((ref, id) => 0),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('有待核对员工时显示红色横幅，去处理进证件核对页', (tester) async {
    await _pump(
      tester,
      _summary([_item('a', '身份证号应为18位，当前为17位'), _item('b', '档案里没有证件号码')]),
      permissions: const {Perm.employeeView, Perm.employeePiiEdit},
    );

    final banner = tester.widget<UtenInlineNotice>(find.byKey(_banner));
    expect(banner.level, UtenInlineNoticeLevel.error);
    expect(banner.title, '有 2 名员工的证件号码待核对');
    expect(find.byKey(_identityEntry), findsOneWidget);
    expect(find.textContaining('2 人证件待核对'), findsOneWidget);

    await tester.tap(find.byKey(_go));
    await tester.pumpAndSettle();
    expect(find.text('task-list:identity'), findsOneWidget);
  });

  testWidgets('没有 pii:edit 不显示证件核对入口；列表为空不显示横幅', (tester) async {
    await _pump(tester, _summary(const []));

    expect(find.byKey(_banner), findsNothing);
    expect(find.byKey(_identityEntry), findsNothing);
    expect(
      find.byKey(const ValueKey('hr-workbench-entry-confirm')),
      findsOneWidget,
      reason: '其他入口照旧',
    );
  });

  testWidgets('我认领的证件核对出现在「我处理中的事项」，带原因和修改入口', (tester) async {
    const reason = '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对';
    await _pump(
      tester,
      _summary([_item('a', reason, claimedByMe: true)]),
      permissions: const {Perm.employeeView, Perm.employeePiiEdit},
      size: const Size(400, 1600),
    );

    expect(find.text('我处理中的事项'), findsOneWidget);
    expect(find.text('证件待核对'), findsOneWidget, reason: '徽标只放短标签');
    expect(find.textContaining(reason), findsOneWidget, reason: '原因单独一行');
    expect(find.text('修改证件信息'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '窄屏不溢出');
  });

  testWidgets('375 宽手机上校验码原因单独一行红字完整显示，不进灰色副标题', (tester) async {
    const reason = '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对';
    const viewSize = Size(375, 1600);
    await _pump(
      tester,
      _summary([_item('a', reason, claimedByMe: true)]),
      permissions: const {Perm.employeeView, Perm.employeePiiEdit},
      size: viewSize,
    );
    expect(tester.takeException(), isNull, reason: '375 宽不溢出');

    final reasonFinder = find.byKey(const ValueKey('hr-task-identity-reason'));
    expect(reasonFinder, findsOneWidget);
    final text = tester.widget<Text>(reasonFinder);
    expect(text.data, reason, reason: '原因原样完整，不拼前后缀');
    expect(text.maxLines, isNull, reason: '不限行数');
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(
      text.style?.color,
      Theme.of(tester.element(reasonFinder)).colorScheme.error,
      reason: '原因红字',
    );

    // 真排版：没有被省略/截断，且整段落在 375 宽屏幕内。
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: reasonFinder, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    final rect = tester.getRect(reasonFinder);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(viewSize.width));
    expect(rect.bottom, lessThanOrEqualTo(viewSize.height));
    expect(
      rect.width,
      greaterThan(viewSize.width / 2),
      reason: '原因占整行宽，不挤在右侧按钮左边的窄条里',
    );

    // 窄屏按钮另起一行(在原因下面)，不和姓名/徽标并排挤占宽度。
    final button = find.text('修改证件信息');
    expect(button, findsOneWidget);
    expect(tester.getTopLeft(button).dy, greaterThan(rect.bottom));
    expect(tester.getRect(button).right, lessThanOrEqualTo(viewSize.width));

    // 灰色副标题不再拼原因：页面上含原因原文的只有这一行。
    expect(find.textContaining(reason), findsOneWidget);
    expect(find.textContaining('UT-a · 生产部 · 2026-03-01'), findsOneWidget);
    expect(find.textContaining('2026-03-01 · 身份证号'), findsNothing);
  });

  testWidgets('宽屏：按钮在姓名右侧同一行，原因在下方整行红字', (tester) async {
    const reason = '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对';
    await _pump(
      tester,
      _summary([_item('a', reason, claimedByMe: true)]),
      permissions: const {Perm.employeeView, Perm.employeePiiEdit},
    );
    expect(tester.takeException(), isNull);

    final name = tester.getRect(find.text('员工a'));
    final button = tester.getRect(find.text('修改证件信息'));
    final reasonRect = tester.getRect(
      find.byKey(const ValueKey('hr-task-identity-reason')),
    );
    expect(button.left, greaterThan(name.right), reason: '按钮在右侧');
    expect(button.top, lessThan(reasonRect.top), reason: '按钮与姓名同一行，原因在下面');
    expect(reasonRect.left, closeTo(name.left, 1), reason: '原因与姓名左对齐、占整行');
  });

  testWidgets('超管看得到证件核对入口', (tester) async {
    await _pump(tester, _summary(const []), superAdmin: true);

    expect(find.byKey(_identityEntry), findsOneWidget);
    expect(find.textContaining('0 人证件待核对'), findsOneWidget);
    expect(find.byKey(_banner), findsNothing);
  });
}
