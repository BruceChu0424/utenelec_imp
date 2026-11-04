// Real Windows Flutter surface, production ApiClient/repository and loopback HTTP.
// The server is an isolated deterministic fixture; database search semantics are
// independently checked by the migrated PostgreSQL suite.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/pages/admin_permissions_page.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _SearchSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'search-fixture',
      code: 'FIXTURE',
      name: '搜索验证',
      permissions: [Perm.accountSupport],
    ),
  );
}

Map<String, Object?> _row(String id, String name, String code) => {
  'id': id,
  'employeeId': 'employee-$id',
  'employeeName': name,
  'employeeCode': code,
  'employeeStatus': 'active',
  'currentEmployee': true,
  'loginAccount': 'fixture-$code',
  'status': 'active',
  'mustChangePassword': false,
  'remoteAccess': false,
};

Future<void> _visible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.pump(const Duration(milliseconds: 40));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected current search result did not become visible: $finder');
}

Future<void> _requested(
  WidgetTester tester,
  List<String> queries,
  String value, {
  int count = 1,
}) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    if (queries.where((query) => query == value).length >= count) return;
    await tester.pump(const Duration(milliseconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'Expected current search request was not sent: $value; actual queries: $queries',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native permission search keeps single-word and multi-field results current through interruption',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final queries = <String>[];
      final requests = <(String, String)>[];
      var fixtureRevision = 0;
      final handlers = <Future<void>>[];
      server.listen((request) {
        handlers.add(() async {
          requests.add((request.method, request.uri.path));
          final query = request.uri.queryParameters['search'] ?? '';
          queries.add(query);
          if (query == '旧') {
            await Future<void>.delayed(const Duration(milliseconds: 900));
          }
          final rows = switch (query) {
            '张' => [_row('a', '张伟', 'E001'), _row('b', '张敏', 'E002')],
            '张 E001' => [
              _row('a', fixtureRevision == 0 ? '张伟' : '张伟更新', 'E001'),
            ],
            '新' => [_row('new', '新结果员工', 'E003')],
            '旧' => [_row('old', '旧结果员工', 'E004')],
            '不存在' => <Map<String, Object?>>[],
            _ => [_row('initial', '初始员工', 'E000')],
          };
          try {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'items': rows,
                'page': 1,
                'size': 20,
                'total': rows.length,
                'totalPages': rows.isEmpty ? 0 : 1,
              }),
            );
            await request.response.close();
          } on IOException {
            // Cancellation may close the loopback socket before the delayed reply.
          }
        }());
      });
      final dio = Dio(
        BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}/api'),
      );
      final api = ApiClient(dio);
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
        await Future.wait(handlers).timeout(const Duration(seconds: 5));
      });
      final capture = GlobalKey();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            sessionProvider.overrideWith(_SearchSession.new),
            currentPermissionsProvider.overrideWith(
              (ref) => {Perm.accountSupport},
            ),
            isSuperAdminProvider.overrideWith((ref) => false),
            apiClientProvider.overrideWithValue(api),
            adminRepositoryProvider.overrideWithValue(DioAdminRepository(api)),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RepaintBoundary(
              key: capture,
              child: const AdminPermissionsPage(),
            ),
          ),
        ),
      );
      await _visible(tester, find.textContaining('初始员工'));
      final search = find
          .descendant(
            of: find.byType(UtenSearchBar).first,
            matching: find.byType(TextField),
          )
          .first;

      await tester.enterText(search, '张');
      await _visible(tester, find.textContaining('张伟'));
      expect(find.textContaining('张敏'), findsWidgets);
      await tester.enterText(search, '张 E001');
      await _visible(tester, find.textContaining('张伟'));
      // Wait for the debounce/network replacement rather than accepting the old row.
      await _requested(tester, queries, '张 E001');
      await tester.pumpAndSettle();
      expect(find.textContaining('张敏'), findsNothing);

      await tester.enterText(search, '旧');
      await _requested(tester, queries, '旧');
      final oldRequests = queries.where((query) => query == '旧').length;
      await tester.showKeyboard(search);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.showKeyboard(search);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 100));
      expect(queries.where((query) => query == '旧'), hasLength(oldRequests));
      await tester.tap(search);
      await tester.pump();
      await tester.enterText(search, '新');
      await _requested(tester, queries, '新');
      await _visible(tester, find.textContaining('新结果员工'));
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await tester.pump();
      expect(find.textContaining('旧结果员工'), findsNothing);

      for (var index = 0; index < 20; index++) {
        await tester.enterText(search, index.isEven ? '张' : '新');
        await tester.pump(const Duration(milliseconds: 10));
      }
      await _visible(tester, find.textContaining('新结果员工'));
      await tester.enterText(search, '不存在');
      await _visible(tester, find.text('暂无匹配的员工账号'));
      await tester.enterText(search, '张 E001');
      await _visible(tester, find.textContaining('张伟'));
      expect(find.textContaining('张敏'), findsNothing);
      final sameQueryReads = queries.where((query) => query == '张 E001').length;
      fixtureRevision = 1;
      await tester.showKeyboard(search);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _requested(tester, queries, '张 E001', count: sameQueryReads + 1);
      await _visible(tester, find.textContaining('张伟更新'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        queries.where((query) => query == '张 E001'),
        hasLength(sameQueryReads + 1),
      );
      expect(tester.takeException(), isNull);
      expect(requests, isNotEmpty);
      expect(
        requests.every((request) => request == ('GET', '/api/admin/users')),
        isTrue,
      );

      await tester.pumpAndSettle();
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bitmap = await boundary.toImage();
      final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/search-native/permission-search.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      bitmap.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
