import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

const _total = 120;

/// Offset-exact open tasks. While [continuation] is set, every batch after the
/// first waits for it and then fails while [failContinuation].
class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://a.test/api')));

  final reads = <(int, int)>[];
  final posts = <String>[];
  Completer<void>? continuation;
  bool failContinuation = true;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/rd-tasks') return const {};
    final page = query?['page'] as int? ?? 1;
    final size = query?['size'] as int? ?? 20;
    reads.add((page, size));
    if ((page - 1) * size > 0 && continuation != null) {
      await continuation!.future;
      if (failContinuation) {
        throw ApiException('SERVICE_UNAVAILABLE', '研发任务读取中断', httpStatus: 503);
      }
    }
    return {
      'items': [
        for (var i = (page - 1) * size; i < page * size && i < _total; i++)
          {
            'id': 'rd-$i',
            'taskNo': 'RD-$i',
            'title': '待完成的工作$i',
            'category': 'BOM',
            'status': 'OPEN',
            'priority': 'NORMAL',
            'rowVersion': 1,
            'allowedActions': ['RESOLVE'],
          },
      ],
      'page': page,
      'size': size,
      'total': _total,
      'totalPages': (_total + size - 1) ~/ size,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    posts.add(path);
    return const {};
  }
}

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets(
    'the floating resolve bar waits for the complete result and never keeps '
    'a withdrawn row of a failed read; the selection returns with the result',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api()..continuation = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'A'),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.rdTaskView,
              Perm.rdTaskResolve,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RdTaskPage(),
          ),
        ),
      );
      for (var frame = 0; frame < 100 && api.reads.length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The first batch is on screen while the read continues. Selecting one
      // of its rows offers no resolve entry yet (the row menu waits as well).
      expect(api.reads, [(1, 50), (2, 50)]);
      await tester.tap(find.text('RD-0'));
      await _frames(tester);
      expect(find.text('标记完成'), findsNothing);
      expect(find.textContaining('已选中 RD-0'), findsNothing);

      // The read fails after its progressive rows were shown: the table takes
      // them down behind its read-failure notice with retry; the bar does not
      // keep the withdrawn row or its write entry.
      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(find.text('RD-0'), findsNothing);
      expect(find.text('数据加载失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('master-table-initial-read-details')),
        findsOneWidget,
      );
      expect(find.text('标记完成'), findsNothing);
      expect(find.textContaining('已选中 RD-0'), findsNothing);

      // A successful retry reads the whole query; the kept selection is shown
      // again on the complete result.
      api
        ..continuation = null
        ..failContinuation = false;
      api.reads.clear();
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      expect(api.reads.first, (1, 50));
      expect(find.text('RD-0'), findsOneWidget);
      expect(find.textContaining('已选中 RD-0'), findsOneWidget);
      expect(find.text('标记完成'), findsOneWidget);
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
