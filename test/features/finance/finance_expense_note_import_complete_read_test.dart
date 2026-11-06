import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/features/finance/widgets/finance_expense_analysis_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'all1001 period note imports reach the Chinese tail and restore its direct identity',
    (tester) async {
      final api = _ImportsApi();
      final environment = await _open(tester, api);
      final dropdown = _dropdown(tester);
      expect(dropdown.items, hasLength(1001));
      expect(dropdown.items.last.value, 'import-1000');
      expect(api.queries.map((query) => query['page']), [1, 2]);
      expect(
        api.queries.every(
          (query) =>
              query['period'] == '2026-09' &&
              query['scope'] == 'active' &&
              query['size'] == 1000,
        ),
        isTrue,
      );
      expect(api.queries.last['readSnapshotRevision'], 'a' * 64);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '最近导入批次',
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-dropdown-search-input')),
        '中文末尾1000',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('备注中文末尾1000 未应用'));
      await tester.pumpAndSettle();
      expect(api.restored, ['import-1000']);
      expect(api.queries, hasLength(2));
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '记录范围',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      expect(
        api.queries.skip(2).every((query) => query['scope'] == 'history'),
        isTrue,
      );
      expect(api.queries.map((query) => query['page']), [1, 2, 1, 2]);
      expect(_dropdown(tester).items.last.label, '备注中文末尾1000 已应用');
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );

  testWidgets(
    'a failed tail terminates waiting without a prefix and explicit retry reads the entire scope',
    (tester) async {
      final api = _ImportsApi()..failTail = true;
      final environment = await _open(tester, api);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '最近导入批次',
        ),
        findsNothing,
      );
      expect(api.queries.map((query) => query['page']), [1, 2]);
      final refresh = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '刷新'),
      );
      expect(refresh.onPressed, isNotNull);
      api.failTail = false;
      await tester.tap(find.widgetWithText(UtenButton, '刷新'));
      await tester.pumpAndSettle();
      expect(_dropdown(tester).items, hasLength(1001));
      expect(api.queries.map((query) => query['page']), [1, 2, 1, 2]);
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );

  testWidgets(
    'a denied summary publishes no import candidates and permits an explicit read retry',
    (tester) async {
      final api = _ImportsApi()..denied = true;
      final environment = await _open(tester, api);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '最近导入批次',
        ),
        findsNothing,
      );
      expect(api.queries.map((query) => query['page']), [1]);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '刷新'))
            .onPressed,
        isNotNull,
      );
      api.denied = false;
      await tester.tap(find.widgetWithText(UtenButton, '刷新'));
      await tester.pumpAndSettle();
      expect(_dropdown(tester).items.last.value, 'import-1000');
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );

  testWidgets(
    'a retired authorization scope cannot publish its held tail or replay a note command',
    (tester) async {
      final api = _ImportsApi()..tail = Completer<Map<String, dynamic>>();
      final environment = await _open(tester, api, settle: false);
      expect(api.queries.map((query) => query['page']), [1, 2]);
      final response = api.page(api.queries.last);
      environment.read(readScopeRevisionProvider.notifier).state++;
      await tester.pump();
      expect(find.text('访问范围已变化'), findsOneWidget);
      api.tail!.complete(response);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '最近导入批次',
        ),
        findsNothing,
      );
      expect(find.text('访问范围已变化'), findsOneWidget);
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
}

UtenDropdownField _dropdown(WidgetTester tester) =>
    tester.widget<UtenDropdownField>(
      find.byWidgetPredicate(
        (widget) => widget is UtenDropdownField && widget.label == '最近导入批次',
      ),
    );

Future<ProviderContainer> _open(
  WidgetTester tester,
  _ImportsApi api, {
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final environment = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeReportView,
        Perm.financeViewAll,
        Perm.paymentStyleEdit,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: environment,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showFinanceExpenseAnalysisDialog(
                  context,
                  period: '2026-09',
                  mode: 'note',
                );
              },
              child: const Text('打开备注目录'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开备注目录'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }
  return environment;
}

class _ImportsApi extends ApiClient {
  _ImportsApi() : super(Dio());
  final queries = <Map<String, dynamic>>[],
      posts = <String>[],
      restored = <String>[];
  bool failTail = false, denied = false;
  Completer<Map<String, dynamic>>? tail;
  Map<String, dynamic> page(Map<String, dynamic> query) {
    final number = query['page'] as int,
        size = query['size'] as int,
        start = (number - 1) * size;
    return {
      'items': [
        for (var i = start; i < start + size && i < 1001; i++)
          {
            'importId': 'import-$i',
            'sourceName': i == 1000 ? '备注中文末尾1000' : '备注批次$i',
            'appliedAt': query['scope'] == 'history'
                ? '2026-09-30T00:00:00Z'
                : null,
          },
      ],
      'page': number,
      'size': size,
      'total': 1001,
      'totalPages': 2,
      'scope': query['scope'],
      'readScopeVersion': 'finance-note-owner',
      'readSnapshotRevision': 'a' * 64,
      'readDataVersion': 'b' * 64,
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/expense-analysis/note-imports/summaries') {
      final values = Map<String, dynamic>.of(query!);
      queries.add(values);
      if (denied) {
        throw ApiException(
          'FORBIDDEN',
          '无权读取备注目录',
          httpStatus: 403,
          hasResponseCode: true,
        );
      }
      if (values['page'] == 2) {
        if (failTail) {
          throw ApiException('INTERNAL', '目录尾批暂不可用', httpStatus: 503);
        }
        if (tail != null) return tail!.future;
      }
      return page(values);
    }
    if (path == '/finance/expense-analysis/notes') {
      return {'items': <Map<String, dynamic>>[]};
    }
    if (path.startsWith('/finance/expense-analysis/note-imports/')) {
      final id = path.split('/').last;
      restored.add(id);
      return {
        'importId': id,
        'sourceName': '备注中文末尾1000',
        'rows': <Object>[],
        'issues': <Object>[],
        'applied': false,
      };
    }
    throw StateError('Unexpected read $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add(path);
    throw StateError('No command is allowed during summary reads');
  }
}
