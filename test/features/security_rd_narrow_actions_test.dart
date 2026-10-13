import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/features/security/pages/security_scan_page.dart';
import 'package:uten_imp/features/security/pages/visitor_check_result_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final commands = <(String, Map<String, dynamic>?)>[];
  bool blocked = false;
  final row = <String, dynamic>{
    'id': 'rd-long',
    'taskNo': 'RD-20261013-000001',
    'title': '确认长名称试产样品完整结构以及来源数据',
    'category': 'BOM',
    'status': 'OPEN',
    'priority': 'NORMAL',
    'rowVersion': 7,
    'allowedActions': ['RESOLVE'],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/rd-tasks'
      ? {
          'items': [row],
          'page': 1,
          'totalPages': 1,
          'total': 1,
          'size': 20,
        }
      : {};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    commands.add((path, body is Map<String, dynamic> ? body : null));
    if (path == '/security/verify') {
      return {
        'valid': false,
        'color': 'red',
        'reason': blocked ? 'blocked' : 'rejected',
        'visitorId': 'visitor-1',
      };
    }
    if (path == '/security/blacklist/visitor-1') blocked = true;
    return row;
  }
}

Widget _app(
  Widget home,
  _Api api,
  SharedPreferences preferences, {
  double textScale = 2,
}) => ProviderScope(
  overrides: [
    apiClientProvider.overrideWithValue(api),
    sharedPreferencesProvider.overrideWithValue(preferences),
    currentPermissionsProvider.overrideWithValue({
      Perm.rdTaskResolve,
      Perm.visitorBlacklist,
    }),
    isSuperAdminProvider.overrideWithValue(false),
    fixedBadgeSummaryOverride(badgeSummaryFixture()),
  ],
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final suffix in ['method', 'event', 'deviceOrientation']) {
      messenger.setMockMethodCallHandler(
        MethodChannel('dev.steenbakker.mobile_scanner/scanner/$suffix'),
        (call) async {
          if (call.method == 'state') return 1;
          return null;
        },
      );
    }
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final suffix in ['method', 'event', 'deviceOrientation']) {
      messenger.setMockMethodCallHandler(
        MethodChannel('dev.steenbakker.mobile_scanner/scanner/$suffix'),
        null,
      );
    }
  });

  testWidgets('160逻辑画布大字保安输入可填写并只核验实际六位通行码', (tester) async {
    await tester.binding.setSurfaceSize(const Size(160, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preferences = await SharedPreferences.getInstance();
    final api = _Api();
    await tester.pumpWidget(_app(const SecurityScanPage(), api, preferences));
    await tester.pumpAndSettle();
    final input = find.byType(TextFormField);
    expect(tester.getSize(input).width, greaterThan(70));
    await tester.enterText(input, '012345');
    await tester.ensureVisible(find.text('确认'));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(api.commands.where((c) => c.$1 == '/security/verify').single.$2, {
      'passcode': '012345',
    });
    expect(find.byType(VisitorCheckResultPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('160逻辑画布长研发任务可滚看全文并完成同一UUID/version一次', (tester) async {
    await tester.binding.setSurfaceSize(const Size(160, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preferences = await SharedPreferences.getInstance();
    final api = _Api();
    await tester.pumpWidget(_app(const RdTaskPage(), api, preferences));
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<RdTaskRow>>(
      find.byType(MasterDataTableView<RdTaskRow>),
    );
    table.onSelectionChanged!(table.items.single);
    await tester.pumpAndSettle();
    final summary = find.text('已选中 ${api.row['taskNo']} · ${api.row['title']}');
    expect(tester.widget<Text>(summary).maxLines, isNull);
    await tester.ensureVisible(find.text('标记完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记完成'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认完成'));
    await tester.tap(find.text('确认完成'));
    await tester.pumpAndSettle();
    expect(
      api.commands.where((c) => c.$1 == '/rd-tasks/rd-long/resolve').single.$2,
      {'expectedVersion': 7},
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final confirm in [true, false]) {
    testWidgets('保安拉黑${confirm ? '确认' : '取消'}控制器存活到退出并在pop冻结原因', (
      tester,
    ) async {
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      await tester.pumpWidget(
        _app(
          const VisitorCheckResultPage(passcode: '123456'),
          api,
          preferences,
          textScale: 1,
        ),
      );
      await tester.pumpAndSettle();
      final label = AppLocalizations.of(
        tester.element(find.byType(VisitorCheckResultPage)),
      ).securityBlacklistAction;
      final background = find.text(label);
      final buttonPoint = tester.getCenter(background);
      await tester.tap(background);
      await tester.pumpAndSettle();
      final field = find.byType(TextFormField);
      final controller = tester.widget<TextFormField>(field).controller!;
      await tester.enterText(field, '原确认原因');
      final dialog = find.byType(AlertDialog).last;
      final route = ModalRoute.of(tester.element(dialog))!;
      var completed = false;
      route.completed.then((_) => completed = true);
      await tester.tap(
        find
            .descendant(of: dialog, matching: find.text(confirm ? label : '取消'))
            .last,
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(completed, isFalse);
      void listener() {}
      expect(() => controller.addListener(listener), returnsNormally);
      controller.removeListener(listener);
      controller.text = '退场晚到输入';
      await tester.tapAt(buttonPoint);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(api.commands.where((c) => c.$1.contains('/blacklist/')), isEmpty);
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(() => controller.addListener(listener), throwsFlutterError);
      final commands = api.commands.where((c) => c.$1.contains('/blacklist/'));
      expect(commands.length, confirm ? 1 : 0);
      if (confirm) expect(commands.single.$2, {'reason': '原确认原因'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
