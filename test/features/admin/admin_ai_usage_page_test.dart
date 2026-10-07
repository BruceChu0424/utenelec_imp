// AdminAiUsagePage / AdminAiUsagePersonPage 测试(ADR-164):
// 守卫断言、KPI/趋势/人员表渲染、窗口切换重请求、限额编辑(409 冲突/停用二次确认)、
// 无权限空态与人员详情基础渲染。fake 仓储直接喂服务端 wire JSON(顺带覆盖 fromJson)。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/admin/models/ai_usage_dashboard_models.dart';
import 'package:uten_imp/features/admin/pages/admin_ai_usage_page.dart';
import 'package:uten_imp/features/admin/pages/admin_ai_usage_person_page.dart';
import 'package:uten_imp/features/admin/repositories/ai_usage_dashboard_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _zh = lookupAppLocalizations(const Locale('zh'));

const _zhangId = '00000000-0000-4000-8000-000000000001';
const _liId = '00000000-0000-4000-8000-000000000002';
const _goneId = '00000000-0000-4000-8000-000000000003';

/// 服务端 GET /admin/ai/usage-dashboard 的原样形状。
Map<String, dynamic> _dashboardJson({bool withDisabled = true}) => {
  'window': 'day',
  'todayTokens': 123456,
  'dailyTokenBudget': 3000000,
  'todayCalls': 42,
  'activeUsersToday': 2,
  'disabledCount': withDisabled ? 1 : 0,
  'series': [
    {
      'bucket': '2026-10-06',
      'label': '10-06',
      'tokens': 9000,
      'calls': 12,
      'okCalls': 11,
    },
    {
      'bucket': '2026-10-05',
      'label': '10-05',
      'tokens': 8000,
      'calls': 9,
      'okCalls': 9,
    },
    {
      'bucket': '2026-10-04',
      'label': '10-04',
      'tokens': 4000,
      'calls': 5,
      'okCalls': 5,
    },
  ],
  'people': [
    {
      'userId': _zhangId,
      'name': '张三',
      'code': '001',
      'department': '销售部',
      'deleted': false,
      'disabled': false,
      'dailyTokenLimit': null,
      'dailyJobLimit': null,
      'rowVersion': 4,
      'todayTokens': 1000,
      'windowTokens': 15000,
      'windowCalls': 21,
      'lastUsedAt': null,
    },
    if (withDisabled)
      {
        'userId': _liId,
        'name': '李四',
        'code': '002',
        'department': '销售部',
        'deleted': false,
        'disabled': true,
        'dailyTokenLimit': 50000,
        'dailyJobLimit': 60,
        'rowVersion': 7,
        'todayTokens': 60000,
        'windowTokens': 48000,
        'windowCalls': 30,
        'lastUsedAt': null,
      },
  ],
};

/// 服务端 GET /admin/ai/usage-people/{userId} 的原样形状: 用户信息与今日三值
/// (todayTokens/todayCalls/dailyTokenBudget)都平铺在根级, 不嵌 user。
Map<String, dynamic> _personJson({
  bool disabled = false,
  int todayTokens = 1500,
}) => {
  'userId': _zhangId,
  'name': '张三',
  'code': '001',
  'department': '销售部',
  'todayTokens': todayTokens,
  'todayCalls': 9,
  'dailyTokenBudget': 3000000,
  'limits': {
    'userId': _zhangId,
    'disabled': disabled,
    'dailyTokenLimit': 2000,
    'dailyJobLimit': 60,
    'rowVersion': 5,
  },
  'series': [
    {
      'bucket': '2026-10-06',
      'label': '10-06',
      'tokens': 1500,
      'calls': 9,
      'okCalls': 8,
    },
    {
      'bucket': '2026-10-05',
      'label': '10-05',
      'tokens': 700,
      'calls': 4,
      'okCalls': 4,
    },
  ],
  'byPurpose': [
    {'label': '查库存成本', 'calls': 8, 'tokens': 1200},
    {'label': '客户资料识别', 'calls': 1, 'tokens': 300},
  ],
  'byProvider': [
    {'name': 'DeepSeek 正式', 'calls': 9, 'tokens': 1500},
  ],
  'recentUses': [
    {
      'jobId': 'job-1',
      'kind': 'ERP_CHAT',
      'question': '这个月销售额多少',
      'createdAt': '2026-10-06T09:00:00Z',
      'status': 'SUCCEEDED',
      'tokens': 900,
    },
    {
      'jobId': 'job-2',
      'kind': 'ERP_DOCUMENT_ROUTE',
      'question': '',
      'createdAt': '2026-10-05T09:00:00Z',
      'status': 'RUNNING',
      'tokens': 0,
    },
  ],
};

class _Repo implements AiUsageDashboardRepository {
  _Repo({AiUsageDashboard? dashboard, this.personDetail})
    : _dashboard = dashboard ?? AiUsageDashboard.fromJson(_dashboardJson());

  final AiUsageDashboard _dashboard;

  /// null = 人员详情读取按「用户不存在」失败。
  final AiUsagePersonDetail? personDetail;

  /// 非空时 saveLimits 抛它(模拟 409 冲突等)。
  Object? saveError;

  final List<String> dashboardCalls = [];
  final List<String> personCalls = [];
  final List<Map<String, Object?>> saves = [];

  @override
  Future<AiUsageDashboard> dashboard(AiUsageWindow window) async {
    dashboardCalls.add(window.wire);
    return _dashboard;
  }

  @override
  Future<AiUsagePersonDetail> person(
    String userId,
    AiUsageWindow window,
  ) async {
    personCalls.add('$userId:${window.wire}');
    final detail = personDetail;
    if (detail == null) {
      throw ApiException('NOT_FOUND', '', httpStatus: 404);
    }
    return detail;
  }

  @override
  Future<AiUserLimits> saveLimits(
    String userId, {
    required bool disabled,
    int? dailyTokenLimit,
    int? dailyJobLimit,
    required int rowVersion,
  }) async {
    saves.add({
      'userId': userId,
      'disabled': disabled,
      'dailyTokenLimit': dailyTokenLimit,
      'dailyJobLimit': dailyJobLimit,
      'rowVersion': rowVersion,
    });
    final error = saveError;
    if (error != null) throw error;
    return AiUserLimits(
      userId: userId,
      disabled: disabled,
      dailyTokenLimit: dailyTokenLimit,
      dailyJobLimit: dailyJobLimit,
      rowVersion: rowVersion + 1,
    );
  }
}

class _UsageSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'usage-admin',
      code: 'admin',
      name: 'Administrator',
      superAdmin: true,
      permissions: [Perm.authorizationManage],
    ),
  );
}

class _UsageSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  _Repo? repo,
  bool withPermission = true,
  double width = 1400,
  double height = 1500,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        if (repo != null)
          aiUsageDashboardRepositoryProvider.overrideWithValue(repo),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'usage-admin'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://usage.invalid/api'),
        currentPermissionsProvider.overrideWithValue(
          withPermission
              ? const <String>{Perm.authorizationManage}
              : const <String>{},
        ),
        sessionProvider.overrideWith(_UsageSession.new),
        sessionSnapshotProvider.overrideWith(_UsageSnapshot.new),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('routes inherit the system-administration guard', () {
    expect(requiredAnyPermFor(RouteName.adminAiUsage), const [
      Perm.authorizationManage,
    ]);
    expect(requiredAnyPermFor(RouteName.adminAiUsagePersonRoute), const [
      Perm.authorizationManage,
    ]);
    expect(requiredAllPermsFor(RouteName.adminAiUsage), isEmpty);
  });

  testWidgets('a non-authorized admin sees a plain no-access message', (
    tester,
  ) async {
    await _pump(tester, const AdminAiUsagePage(), withPermission: false);
    expect(find.text(_zh.aiSettingsNoAccess), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-usage-window-filter')), findsNothing);
  });

  testWidgets('dashboard renders KPI cards, trend bars and the people table', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, const AdminAiUsagePage(), repo: repo);

    expect(repo.dashboardCalls, ['day']);
    // KPI 四卡: 数值常显 + 预算进度「x / y」双通道。
    expect(find.text('123,456'), findsOneWidget);
    expect(find.text('123,456 / 3,000,000'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-usage-kpi-today-calls')),
        matching: find.text('42'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-usage-kpi-active-users')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-usage-kpi-disabled')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    // 趋势柱顶数值常显。
    expect(find.byKey(const ValueKey('ai-usage-trend')), findsOneWidget);
    expect(find.text('9,000'), findsOneWidget);
    expect(find.text('8,000'), findsOneWidget);
    // 人员表: 姓名/状态徽章三态/跟随全局。
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('李四'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-usage-status-$_zhangId')),
        matching: find.text(_zh.aiUsageStatusNormal),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-usage-status-$_liId')),
        matching: find.text(_zh.aiUsageStatusDisabled),
      ),
      findsOneWidget,
    );
    expect(find.text(_zh.aiUsageLimitFollowGlobal), findsOneWidget);
    expect(find.text('50,000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching the window re-queries the dashboard', (tester) async {
    final repo = _Repo();
    await _pump(tester, const AdminAiUsagePage(), repo: repo);
    expect(repo.dashboardCalls, ['day']);

    await tester.tap(find.text(_zh.aiUsageWindowHour));
    await tester.pumpAndSettle();
    expect(repo.dashboardCalls, ['day', 'hour']);

    await tester.tap(find.text(_zh.aiUsageWindowYearly));
    await tester.pumpAndSettle();
    expect(repo.dashboardCalls, ['day', 'hour', 'year']);
  });

  testWidgets(
    'an all-zero trend series renders floor-height bars without NaN',
    (tester) async {
      // 全零序列峰值是 0: 柱高不能除成 NaN(走最小高), 渲染不抛布局异常即过。
      final json = _dashboardJson();
      for (final point in json['series'] as List<Map<String, dynamic>>) {
        point['tokens'] = 0;
        point['calls'] = 0;
        point['okCalls'] = 0;
      }
      final repo = _Repo(dashboard: AiUsageDashboard.fromJson(json));
      await _pump(tester, const AdminAiUsagePage(), repo: repo);

      expect(find.byKey(const ValueKey('ai-usage-trend')), findsOneWidget);
      expect(find.text('0'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a deleted employee row greys the name and blocks detail and limits',
    (tester) async {
      // 已删除员工: 统计行保留(users 无行, 服务端回退名「已删除员工」+ deleted=true)。
      final json = _dashboardJson();
      (json['people'] as List).add({
        'userId': _goneId,
        'name': '已删除员工',
        'code': '',
        'department': null,
        'deleted': true,
        'disabled': false,
        'dailyTokenLimit': null,
        'dailyJobLimit': null,
        'rowVersion': -1,
        'todayTokens': 0,
        'windowTokens': 300,
        'windowCalls': 2,
        'lastUsedAt': null,
      });
      final repo = _Repo(dashboard: AiUsageDashboard.fromJson(json));
      await _pump(tester, const AdminAiUsagePage(), repo: repo);

      expect(find.text('已删除员工'), findsOneWidget);
      // 「设置限额」按钮禁用。
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('ai-usage-limit-$_goneId')),
      );
      expect(button.onPressed, isNull);
      // 点姓名/行不进人员详情页(不触发路由跳转也不报错)。
      await tester.tap(find.text('已删除员工'));
      await tester.pumpAndSettle();
      expect(repo.personCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'limit editor: a 409 conflict keeps the panel open with the conflict text',
    (tester) async {
      final repo = _Repo()
        ..saveError = ApiException(
          'CONFLICT',
          '配置有变化，请刷新后再保存',
          httpStatus: 409,
        );
      await _pump(tester, const AdminAiUsagePage(), repo: repo);

      await _tap(tester, 'ai-usage-limit-$_zhangId');
      expect(find.byKey(const ValueKey('ai-usage-limit-save')), findsOneWidget);

      await _tap(tester, 'ai-usage-limit-save');
      expect(repo.saves, hasLength(1));
      // 面板留在原地, 就地显示冲突文案(而不是整页报错)。
      expect(find.text(_zh.aiUsageConflict), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-usage-limit-save')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-usage-limit-error')),
        findsOneWidget,
      );
    },
  );

  testWidgets('enabling disable asks for confirmation before saving the flag', (
    tester,
  ) async {
    final repo = _Repo();
    final container = await _pump(tester, const AdminAiUsagePage(), repo: repo);

    await _tap(tester, 'ai-usage-limit-$_zhangId');
    await _tap(tester, 'ai-usage-limit-disabled');
    await _tap(tester, 'ai-usage-limit-save');

    // 危险操作先二次确认; 取消不保存。
    expect(find.text(_zh.aiUsageDisableConfirm), findsOneWidget);
    await tester.tap(find.text(_zh.aiSettingsCancel).last);
    await tester.pumpAndSettle();
    expect(repo.saves, isEmpty);

    // 确认后按停用保存: 带上看板行读到的乐观锁版本号。
    await _tap(tester, 'ai-usage-limit-save');
    await tester.tap(find.text(_zh.aiUsageDisableAction));
    await tester.pumpAndSettle();
    expect(repo.saves, hasLength(1));
    expect(repo.saves.single['disabled'], isTrue);
    expect(repo.saves.single['rowVersion'], 4);
    expect(repo.saves.single['userId'], _zhangId);
    // 保存成功: 面板关闭 + 成功通知 + 页面静默重拉。
    expect(find.byKey(const ValueKey('ai-usage-limit-save')), findsNothing);
    expect(_messages(container), contains(_zh.aiSettingsSaved));
    expect(repo.dashboardCalls, ['day', 'day']);
  });

  testWidgets('saving a plain limit from the editor sends the typed numbers', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, const AdminAiUsagePage(), repo: repo);

    await _tap(tester, 'ai-usage-limit-$_zhangId');
    await _enter(tester, 'ai-usage-limit-tokens', '200000');
    await _enter(tester, 'ai-usage-limit-jobs', '80');
    await _tap(tester, 'ai-usage-limit-save');

    expect(repo.saves, hasLength(1));
    expect(repo.saves.single['dailyTokenLimit'], 200000);
    expect(repo.saves.single['dailyJobLimit'], 80);
    expect(repo.saves.single['disabled'], isFalse);
    // 看板行已带 rowVersion(≥0): 编辑面板直接编辑, 不再先 GET 人员详情补齐。
    expect(repo.personCalls, isEmpty);
    // 没开停用不需要二次确认, 直接保存成功关面板。
    expect(find.text(_zh.aiUsageDisableConfirm), findsNothing);
    expect(find.byKey(const ValueKey('ai-usage-limit-save')), findsNothing);
  });

  testWidgets('person page shows gauge, distributions and recent uses', (
    tester,
  ) async {
    final repo = _Repo(
      personDetail: AiUsagePersonDetail.fromJson(_personJson()),
    );
    await _pump(
      tester,
      const AdminAiUsagePersonPage(userId: _zhangId),
      repo: repo,
    );

    expect(repo.personCalls, ['$_zhangId:day']);
    expect(find.text('张三 · 001'), findsOneWidget);
    // 环形表: 今日 vs 个人限额(x / y 常显), 设了个人限额就不再提示跟随全局。
    expect(find.text('1,500 / 2,000'), findsOneWidget);
    expect(find.text(_zh.aiUsageNoPersonalLimit), findsNothing);
    expect(find.text(_zh.aiUsageStatusNormal), findsOneWidget);
    // 分布卡: label + 数值常显。
    expect(find.text('查库存成本'), findsOneWidget);
    expect(find.text('客户资料识别'), findsOneWidget);
    expect(find.text('DeepSeek 正式'), findsOneWidget);
    expect(find.text('1,200 tokens'), findsOneWidget);
    // 最近使用: 问题/用途/状态; 展开后看得到 tokens 明细。
    expect(find.text('这个月销售额多少'), findsOneWidget);
    expect(find.text(_zh.aiAuditKindDocument), findsOneWidget);
    await tester.tap(find.text('这个月销售额多少'));
    await tester.pumpAndSettle();
    expect(find.text(_zh.aiUsageTokensUnit('900')), findsOneWidget);
    // 未停用: 横幅不出现; 设置限额入口在。
    expect(
      find.byKey(const ValueKey('ai-usage-person-disabled-banner')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('ai-usage-person-set-limits-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled person shows the danger banner', (tester) async {
    final repo = _Repo(
      personDetail: AiUsagePersonDetail.fromJson(_personJson(disabled: true)),
    );
    await _pump(
      tester,
      const AdminAiUsagePersonPage(userId: _zhangId),
      repo: repo,
    );
    expect(
      find.byKey(const ValueKey('ai-usage-person-disabled-banner')),
      findsOneWidget,
    );
    expect(find.text(_zh.aiUsageDisabledBanner), findsOneWidget);
    expect(find.text(_zh.aiUsageStatusDisabled), findsOneWidget);
  });

  testWidgets('the gauge warns once today tokens reach the personal limit', (
    tester,
  ) async {
    // 今日值来自服务端根级 todayTokens(实时日志聚合): 达到个人限额时环形表
    // 常显「x / y」并把状态徽标切到「已超限」(warning)。
    final repo = _Repo(
      personDetail: AiUsagePersonDetail.fromJson(
        _personJson(todayTokens: 2500),
      ),
    );
    await _pump(
      tester,
      const AdminAiUsagePersonPage(userId: _zhangId),
      repo: repo,
    );

    expect(find.text('2,500 / 2,000'), findsOneWidget);
    expect(find.text(_zh.aiUsageStatusOverLimit), findsOneWidget);
    expect(find.text(_zh.aiUsageStatusNormal), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing person explains it instead of an empty page', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(
      tester,
      const AdminAiUsagePersonPage(userId: _zhangId),
      repo: repo,
    );
    expect(find.text(_zh.aiUsagePersonMissing), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-usage-person-window-filter')),
      findsNothing,
    );
  });
}

List<String> _messages(ProviderContainer container) => [
  for (final n in container.read(appNotificationProvider)) n.message,
];

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(TextFormField),
    ),
    text,
  );
  await tester.pumpAndSettle();
}
