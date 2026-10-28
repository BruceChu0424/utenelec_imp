import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/pages/payment_style_page.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

final _permissions = StateProvider<Set<String>>(
  (_) => {
    Perm.paymentStyleView,
    Perm.paymentStyleEdit,
    Perm.paymentStyleStatus,
    Perm.paymentStyleReorder,
  },
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

String _idOf(Object row) {
  // The page owns a private projection; the assertion only reads its public node identity.
  // ignore: avoid_dynamic_calls
  final node = (row as dynamic).node as PaymentStyleNode;
  return node.id;
}

class _Fixture {
  int extraRows = 0;
  final names = {'root': '办公费用', 'child': '文具费用', 'system': '系统科目'};
  final statuses = {'root': '使用', 'child': '使用', 'system': '使用'};
  final properties = <String, Map<String, dynamic>>{};
  final writes = <RequestOptions>[];
  Completer<void>? batch;

  Map<String, dynamic> row(String id) => {
    'id': id,
    'code': id == 'system'
        ? '041'
        : id == 'root'
        ? 'EXP01'
        : id == 'child'
        ? 'EXP02'
        : 'EXP$id',
    'name': names[id] ?? '额外类别${id.replaceFirst('extra', '')}',
    'category': 'EXPENSE',
    'status': statuses[id] ?? '使用',
    'level': id == 'child' || id.startsWith('extra') ? 1 : 0,
    'sortOrder': 0,
    'path': id == 'child' ? '/EXP01/EXP02/' : '/$id/',
    if (id == 'child') 'parentId': 'root',
    if (id == 'child') 'parentName': names['root'],
    'children': id == 'root'
        ? [
            row('child'),
            for (var index = 0; index < extraRows; index++) row('extra$index'),
          ]
        : <Object>[],
    'childCount': id == 'root' ? 1 : 0,
    'receipt': properties[id]?['receipt'] ?? true,
    'payment': properties[id]?['payment'] ?? false,
    'departmental': properties[id]?['departmental'] ?? false,
  };

  late final api = ApiClient(
    Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            Object data = <String, dynamic>{};
            if (request.method == 'PATCH') {
              writes.add(request);
              final id = request.path.split('/').last;
              final changes = (request.data as Map)['changes'] as Map;
              properties[id] = {
                ...?properties[id],
                ...Map<String, dynamic>.from(changes),
              };
              if (changes.containsKey('name')) {
                names[id] = changes['name'] as String;
              }
            } else if (request.path.endsWith('/batch-status')) {
              writes.add(request);
              if (batch != null) await batch!.future;
              final body = request.data as Map;
              final ids = [
                (body['items'] as List).map(
                  (item) => (item as Map)['id'] as String,
                ),
              ].expand((ids) => ids).toList();
              final results = [
                for (final id in ids)
                  {
                    'id': id,
                    'label': names[id],
                    'ok': id != 'system',
                    if (id == 'system') 'reason': '系统科目必须保持使用',
                  },
              ];
              for (final id in ids.where((id) => id != 'system')) {
                statuses[id] = body['status'] as String;
              }
              data = {
                'succeeded': ids.where((id) => id != 'system').length,
                'failed': ids.where((id) => id == 'system').length,
                'results': results,
              };
            } else if (request.path == '/master/payment-styles/tree') {
              data = request.queryParameters['category'] == 'EXPENSE'
                  ? [row('root'), row('system')]
                  : <Object>[];
            } else if (request.path.startsWith('/master/payment-styles/')) {
              data = row(request.path.split('/').last);
            } else if (request.path == '/master/operation-history') {
              data = {'entries': <Object>[], 'events': <Object>[]};
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      ),
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Fixture fixture, {
  Size size = const Size(1500, 1000),
  bool dark = false,
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'payment-editor'),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        apiClientProvider.overrideWithValue(fixture.api),
        paymentStyleRepositoryProvider.overrideWithValue(
          DioPaymentStyleRepository(fixture.api),
        ),
      ],
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const PaymentStylePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(PaymentStylePage)),
  );
}

Future<void> _edit(
  WidgetTester tester,
  String id,
  String original,
  String value,
) async {
  await tester.tap(find.byKey(ValueKey('inline-activate-$id-name')));
  await tester.pumpAndSettle();
  final input = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.controller?.text == original,
  );
  expect(input, findsOneWidget);
  await tester.enterText(input, value);
  await tester.pump();
}

void main() {
  testWidgets('业务标志沿用共享自定义单元格，提交布尔原值及修改值', (tester) async {
    final fixture = _Fixture();
    await _pump(tester, fixture);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('inline-activate-root-receipt')),
    );
    await tester.pumpAndSettle();
    final checkbox = find.descendant(
      of: find.byKey(const ValueKey('inline-root-receipt')),
      matching: find.byType(Checkbox),
    );
    expect(checkbox, findsOneWidget);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(fixture.writes.single.data, {
      'expected': {'receipt': true},
      'changes': {'receipt': false},
    });
    expect(fixture.properties['root']?['receipt'], isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('157条资料真实每页50条，表头筛选覆盖完整范围且翻页不重复', (tester) async {
    final fixture = _Fixture()..extraRows = 154;
    await _pump(tester, fixture);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    var table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('payment-style-inline-table')),
    );
    expect(table.items, hasLength(50));
    expect(table.unpagedItems, isEmpty);
    expect(table.totalPages, 4);
    expect(table.facets['name'], hasLength(157));
    final firstIds = table.items.map((row) => _idOf(row as Object)).toSet();
    table.onPageChange!(2);
    await tester.pumpAndSettle();
    table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('payment-style-inline-table')),
    );
    expect(table.items, hasLength(50));
    expect(
      table.items.every((row) => !firstIds.contains(_idOf(row as Object))),
      isTrue,
    );
    table.onFilterChanged('search.name', '额外类别153');
    await tester.pumpAndSettle();
    table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('payment-style-inline-table')),
    );
    expect(table.items, hasLength(1));
    expect(_idOf(table.items.single as Object), 'extra153');
    expect(table.totalPages, 1);
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('共享表格编辑两行，用字段CAS保存且编号、层级、状态及系统名称只读', (tester) async {
    final fixture = _Fixture();
    await _pump(tester, fixture);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('payment-style-inline-table')),
      findsOneWidget,
    );
    expect(find.textContaining('不支持删除'), findsNothing);
    expect(
      find.byKey(const ValueKey('inline-activate-root-code')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('inline-activate-root-parent')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('inline-activate-root-status')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('inline-activate-system-name')),
      findsNothing,
    );
    await _edit(tester, 'root', '办公费用', '办公室费用');
    await _edit(tester, 'child', '文具费用', '纸笔费用');
    await tester.tap(find.text('保存 2 行修改'));
    await tester.pumpAndSettle();
    expect(fixture.writes.map((request) => request.path), [
      '/master/inline-edit/payment-styles/root',
      '/master/inline-edit/payment-styles/child',
    ]);
    expect(fixture.writes.first.data, {
      'expected': {'name': '办公费用'},
      'changes': {'name': '办公室费用'},
    });
    expect(fixture.writes.last.data, {
      'expected': {'name': '文具费用'},
      'changes': {'name': '纸笔费用'},
    });
    expect(find.text('保存 0 行修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多选批量停用只发一次请求，取消不写并显示逐条失败', (tester) async {
    final fixture = _Fixture();
    await _pump(tester, fixture);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停用所选'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.writes, isEmpty);
    fixture.batch = Completer<void>();
    await tester.tap(find.text('停用所选'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(fixture.writes, hasLength(1));
    expect(find.byType(UtenBusyOverlay), findsWidgets);
    fixture.batch!.complete();
    await tester.pumpAndSettle();
    expect(fixture.writes.single.path, '/master/payment-styles/batch-status');
    expect(
      ((fixture.writes.single.data as Map)['items'] as List),
      hasLength(3),
    );
    expect(find.text('系统科目必须保持使用'), findsOneWidget);
    expect(fixture.statuses['root'], '禁用');
    expect(fixture.statuses['child'], '禁用');
    expect(fixture.statuses['system'], '使用');
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换范围前保护草稿，取消后仍保留待保存修改', (tester) async {
    final fixture = _Fixture();
    await _pump(tester, fixture);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _edit(tester, 'root', '办公费用', '未保存费用');
    await tester.tap(find.text('所选类别及下级'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('保存 1 行修改'), findsOneWidget);
    expect(fixture.writes, isEmpty);
    await tester.tap(find.text('所选类别及下级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const ValueKey('payment-style-inline-table')),
    );
    expect(table.items, hasLength(2));
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('权限撤回后立即移除编辑表格及旧草稿', (tester) async {
    final fixture = _Fixture();
    final container = await _pump(tester, fixture);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _edit(tester, 'root', '办公费用', '旧权限草稿');
    container.read(_permissions.notifier).state = {Perm.paymentStyleView};
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('payment-style-inline-table')),
      findsNothing,
    );
    expect(find.text('编辑模式'), findsNothing);
    expect(find.text('旧权限草稿'), findsNothing);
    expect(fixture.writes, isEmpty);
  });

  testWidgets('仅启停权限也可多选而不能编辑名称，窄屏深色大字无溢出', (tester) async {
    final fixture = _Fixture();
    final container = await _pump(
      tester,
      fixture,
      size: const Size(420, 900),
      dark: true,
      scale: 1.5,
    );
    container.read(_permissions.notifier).state = {
      Perm.paymentStyleView,
      Perm.paymentStyleStatus,
    };
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('payment-style-inline-table')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('inline-activate-root-name')),
      findsNothing,
    );
    expect(find.text('停用所选'), findsOneWidget);
    expect(find.text('启用所选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
