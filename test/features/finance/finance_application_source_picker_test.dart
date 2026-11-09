import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/features/finance/pages/finance_applications_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

void main() {
  testWidgets(
    'all supplier sources complete before publication and first-to-last scrolling has no reads',
    (tester) async {
      final api = _Api();
      await _mount(tester, api);
      expect(api.calls.map((c) => (c['page'], c['size'])), [(1, 50), (2, 100)]);
      expect(_table(tester).items, hasLength(125));
      expect(_table(tester).items.last['id'], 'source-124');
      expect(find.textContaining('结果超过100条'), findsNothing);
      final scroll = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .where(
            (s) =>
                axisDirectionToAxis(s.position.axisDirection) ==
                    Axis.vertical &&
                s.position.maxScrollExtent > 0,
          )
          .first;
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      scroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'travel source UUIDs retain their separate immutable source kinds across all pages',
    (tester) async {
      final api = _Api(travel: true);
      await _mount(tester, api, kind: 'TRAVEL_APPLICATION');
      final rows = _table(tester).items;
      expect(rows, hasLength(250));
      expect(rows.map((r) => r['id']).toSet(), hasLength(125));
      expect(
        rows.map((r) => '${r['sourceKind']}|${r['id']}').toSet(),
        hasLength(250),
      );
      final choose = _table(tester).onRowTap!;
      choose(rows.last);
      choose(rows.last);
      await tester.pumpAndSettle();
      expect(api.selected?['sourceKind'], 'FINANCE_APPLICATION');
      expect(api.selected?['id'], 'source-124');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a failed later source page never publishes a truncated directory and explicit retry starts at one',
    (tester) async {
      final api = _Api()..failSecond = true;
      await _mount(tester, api);
      expect(_table(tester).items, isEmpty);
      expect(_table(tester).error, isNotNull);
      expect(api.calls.map((c) => c['page']), [1, 2]);
      _table(tester).onRetry!();
      await tester.pumpAndSettle();
      expect(api.calls.map((c) => c['page']), [1, 2, 1, 2]);
      expect(_table(tester).items, hasLength(125));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a captured source choice cannot return after a different complete search replaces its rows',
    (tester) async {
      final api = _Api();
      await _mount(tester, api);
      final old = _table(tester);
      final row = old.items.last;
      final input = find.descendant(
        of: find.byType(UtenSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, '新');
      old.onRowTap!(row);
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(_table(tester).items.single['id'], 'new');
      old.onRowTap!(row);
      await tester.pump();
      expect(api.selected, isNull);
      expect(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
        findsOneWidget,
      );
      final current = _table(tester);
      current.onRowTap!(current.items.single);
      await tester.pumpAndSettle();
      expect(api.selected?['id'], 'new');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'raw source input retires an older continuation and completed same-word Enter refreshes again',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _Api()..secondGate = gate;
      await _mount(tester, api, settle: false);
      for (var frame = 0; frame < 100 && api.calls.length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(api.calls, hasLength(2));
      final oldOwner = api.owners.last;
      final input = find.descendant(
        of: find.byType(UtenSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, '新');
      await tester.pump();
      expect(oldOwner?.call(), false);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(_table(tester).items.single['id'], 'new');
      gate.complete(api.response(2));
      await tester.pumpAndSettle();
      expect(_table(tester).items.single['id'], 'new');
      final reads = api.calls.length;
      await tester.tap(input);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(reads + 1));
      expect(find.text('OLD-RESPONSE'), findsNothing);
      expect(find.byType(UtenCloseButton), findsOneWidget);
      await tester.tap(find.byType(UtenCloseButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reader replacement removes the busy overlay and rejects the old complete-source continuation',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _Api()..secondGate = gate;
      final epoch = _SourceEpoch();
      await _mount(tester, api, settle: false, epoch: epoch);
      for (var frame = 0; frame < 100 && api.calls.length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(api.calls.map((call) => call['page']), [1, 2]);
      expect(find.text('正在读取申请来源'), findsOneWidget);
      // 第二批未回时表内是已校验的首批增长前缀（不可选），不是空表。
      expect(_table(tester).items, hasLength(100));
      final oldOwner = api.owners.last;
      epoch.advance();
      await tester.pumpAndSettle();
      expect(oldOwner?.call(), false);
      expect(find.text('正在读取申请来源'), findsNothing);
      expect(_table(tester).isLoading, isFalse);
      final oldResponse = api.response(2);
      final oldItem =
          (oldResponse['items'] as List).first as Map<String, dynamic>;
      oldItem['code'] = 'OLD-RESPONSE';
      gate.complete(oldResponse);
      await tester.pumpAndSettle();
      expect(find.text('OLD-RESPONSE'), findsNothing);
      expect(_table(tester).items, isEmpty);
      expect(api.selected, isNull);
      expect(api.calls.map((call) => call['page']), [1, 2]);
      expect(find.byType(UtenCloseButton), findsOneWidget);
      await tester.tap(find.byType(UtenCloseButton));
      await tester.pumpAndSettle();
      expect(find.text('打开来源'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _SourceEpoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}

MasterDataTableView<Map<String, dynamic>> _table(WidgetTester t) =>
    t.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
Future<void> _mount(
  WidgetTester tester,
  _Api api, {
  String kind = 'SUPPLIER',
  bool settle = true,
  _SourceEpoch? epoch,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1300, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (epoch != null) exportContextEpochProvider.overrideWith(() => epoch),
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://source.fixture/api'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'source-reader', epoch: 1),
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeApplicationApply,
        }),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                api.selected = await pickFinanceApplicationSource(
                  context,
                  kind: kind,
                );
              },
              child: const Text('打开来源'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开来源'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _Api extends ApiClient {
  _Api({this.travel = false}) : super(Dio());
  final bool travel;
  bool failSecond = false;
  Completer<Map<String, dynamic>>? secondGate;
  final calls = <Map<String, dynamic>>[];
  final owners = <bool Function()?>[];
  Map<String, dynamic>? selected;
  Map<String, dynamic> response(int page, {String search = ''}) {
    final all = search.isNotEmpty
        ? [
            {'id': 'new', 'code': '新来源', 'name': '新来源'},
          ]
        : [
            for (var i = 0; i < 125; i++)
              for (final kind
                  in travel
                      ? ['BUSINESS_APPLICATION', 'FINANCE_APPLICATION']
                      : ['SUPPLIER'])
                {
                  'id': 'source-$i',
                  'code': 'SRC-$i',
                  'name': '来源$i',
                  if (travel) 'sourceKind': kind,
                },
          ];
    return {
      'items': all.skip((page - 1) * 100).take(100).toList(),
      'page': page,
      'size': 100,
      'total': all.length,
      'totalPages': (all.length + 99) ~/ 100,
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expectSync(path, '/finance/applications/sources/page');
    calls.add({...?query});
    owners.add(PagedReadIntent.currentRead);
    final page = query!['page'] as int;
    final search = query['search']?.toString() ?? '';
    if (page == 2 && search.isEmpty && failSecond) {
      failSecond = false;
      throw StateError('source interruption');
    }
    if (page == 2 && search.isEmpty && secondGate != null) {
      return secondGate!.future;
    }
    return response(page, search: search);
  }
}
