// ADR-134 customer detail tab 货品对照: learned customer wording of our goods.
// Fake repository only (server built in parallel); covers rendering, the
// plain empty state, keyword search, paging, delete with confirmation and
// the fail-closed delete capability.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/client_goods_alias.dart';
import 'package:uten_imp/features/basic_data/repositories/client_goods_alias_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/client_goods_alias_tab.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rows show the customer wording, our goods and plain facts', (
    tester,
  ) async {
    final repo = _FakeAliasRepository(
      rows: [
        _alias(
          'alias-1',
          text: 'GZ23/D',
          context: 'Z9 | 白',
          confirm: 3,
          explicit: 1,
          canDelete: true,
        ),
        _alias(
          'alias-2',
          text: 'DOUBLE 3 PIN SOCKET WITH SWITCH',
          kind: ClientGoodsAliasKind.description,
        ),
      ],
    );
    await _pump(tester, repo);

    expect(find.text('客户对货品的叫法'), findsOneWidget);
    expect(find.text('GZ23/D'), findsOneWidget);
    expect(find.text('DOUBLE 3 PIN SOCKET WITH SWITCH'), findsOneWidget);
    expect(find.text('两开多功能三极插座(280235165) · 白色'), findsNWidgets(2));
    expect(find.text('客户型号'), findsOneWidget);
    expect(find.text('客户品名'), findsOneWidget);
    expect(
      find.text('适用于 Z9 | 白 · 已确认 3 次, 其中 1 次是手工选的 · 最近 2026-09-20 · 李销售'),
      findsOneWidget,
    );
    expect(find.text('已确认 1 次 · 最近 2026-09-20 · 李销售'), findsOneWidget);
    // Delete follows the per-row server capability only.
    expect(
      find.byKey(const ValueKey('client-goods-alias-delete-alias-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('client-goods-alias-delete-alias-2')),
      findsNothing,
    );
    expect(find.text('共 2 条'), findsOneWidget);
    expect(repo.listCalls.single, (clientId: 'client-1', page: 1, keyword: ''));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty customer shows the plain learning explanation', (
    tester,
  ) async {
    await _pump(tester, _FakeAliasRepository(rows: const []));

    expect(find.text('还没有货品对照'), findsOneWidget);
    expect(find.text('保存带有文件型号的报价单或订货单后, 这里会自动记住客户的叫法'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('client-goods-alias-pager')),
      findsNothing,
    );
  });

  testWidgets('keyword search reloads page 1 and explains no match', (
    tester,
  ) async {
    final repo = _FakeAliasRepository(
      rows: [_alias('alias-1', text: 'GZ23/D', canDelete: true)],
    );
    await _pump(tester, repo);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('client-goods-alias-search')),
        matching: find.byType(TextField),
      ),
      '  zz99 ',
    );
    // UtenSearchBar debounces input by 300 ms.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(repo.listCalls.last, (
      clientId: 'client-1',
      page: 1,
      keyword: 'zz99',
    ));
    expect(find.text('没有找到相关的对照, 换个关键词试试'), findsOneWidget);
    expect(find.text('GZ23/D'), findsNothing);
  });

  testWidgets('delete asks first, then removes the row and reloads', (
    tester,
  ) async {
    final repo = _FakeAliasRepository(
      rows: [_alias('alias-1', text: 'GZ23/D', canDelete: true)],
    );
    await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('client-goods-alias-delete-alias-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除这条对照'), findsWidgets);
    expect(
      find.textContaining('不再把「GZ23/D」对应到「两开多功能三极插座(280235165) · 白色」'),
      findsOneWidget,
    );

    // Cancel first: nothing is sent.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.deleted, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('client-goods-alias-delete-alias-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(repo.deleted, [(clientId: 'client-1', aliasId: 'alias-1')]);
    expect(repo.listCalls, hasLength(2));
    expect(find.text('GZ23/D'), findsNothing);
    expect(find.text('还没有货品对照'), findsOneWidget);
    expect(_notifications(tester), contains('已删除这条对照'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed delete keeps the row and tells why', (tester) async {
    final repo = _FakeAliasRepository(
      rows: [_alias('alias-1', text: 'GZ23/D', canDelete: true)],
      deleteFailure: ApiException('FORBIDDEN', '该客户对你只读, 不能删除对照'),
    );
    await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('client-goods-alias-delete-alias-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('GZ23/D'), findsOneWidget);
    expect(repo.listCalls, hasLength(1));
    expect(_notifications(tester), contains('该客户对你只读, 不能删除对照'));
  });

  testWidgets('load failure shows the reason and retry works', (tester) async {
    final repo = _FakeAliasRepository(
      rows: [_alias('alias-1', text: 'GZ23/D')],
      listFailures: [ApiException('NETWORK', '网络连接失败, 请检查后重试')],
    );
    await _pump(tester, repo);

    expect(
      find.byKey(const ValueKey('client-goods-alias-error')),
      findsOneWidget,
    );
    expect(find.text('网络连接失败, 请检查后重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('GZ23/D'), findsOneWidget);
    expect(repo.listCalls, hasLength(2));
  });

  testWidgets('the delete network call runs under a busy overlay', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repo = _FakeAliasRepository(
      rows: [_alias('alias-1', text: 'GZ23/D', canDelete: true)],
      deleteGate: gate,
    );
    await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('client-goods-alias-delete-alias-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    // Dialog closes, then the overlay mounts itself on the next frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在删除对照'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在删除对照'), findsNothing);
    expect(repo.deleted, hasLength(1));
  });

  testWidgets('pager moves between server pages', (tester) async {
    final repo = _FakeAliasRepository(
      rows: [for (var i = 1; i <= 45; i++) _alias('alias-$i', text: 'PART-$i')],
    );
    await _pump(tester, repo);
    expect(find.text('PART-1'), findsOneWidget);

    // The pager sits below 20 rows: scroll the lazy list down to it.
    // The list's own Scrollable is the outermost one (text fields add more).
    final list = find
        .descendant(
          of: find.byKey(const ValueKey('client-goods-alias-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    final pager = find.byKey(const ValueKey('client-goods-alias-pager'));
    await tester.scrollUntilVisible(pager, 400, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.text('共 45 条'), findsOneWidget);
    expect(find.text('第 1 / 3 页'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('client-goods-alias-next')));
    await tester.pumpAndSettle();

    expect(repo.listCalls.last.page, 2);
    await tester.scrollUntilVisible(pager, 400, scrollable: list);
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('PART-21'),
      -400,
      scrollable: list,
    );
    expect(find.text('PART-21'), findsOneWidget);
    expect(find.text('PART-1'), findsNothing);
  });
}

ClientGoodsAlias _alias(
  String id, {
  required String text,
  String kind = ClientGoodsAliasKind.partNo,
  String? context,
  int confirm = 1,
  int explicit = 0,
  bool canDelete = false,
}) => ClientGoodsAlias(
  id: id,
  scope: ClientGoodsAliasScope.client,
  aliasKind: kind,
  aliasText: text,
  contextText: context,
  goods: const ClientGoodsAliasGoods(
    id: 'goods-1',
    code: '280235165',
    name: '两开多功能三极插座',
    colorName: '白色',
  ),
  confirmCount: confirm,
  explicitCount: explicit,
  lastConfirmedAt: '2026-09-20T02:30:00Z',
  lastConfirmedByName: '李销售',
  canDelete: canDelete,
);

List<String> _notifications(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ClientGoodsAliasTab)),
).read(appNotificationProvider).map((n) => n.message).toList();

Future<void> _pump(WidgetTester tester, _FakeAliasRepository repo) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        clientGoodsAliasRepositoryProvider.overrideWithValue(repo),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ClientGoodsAliasTab(clientId: 'client-1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeAliasRepository implements ClientGoodsAliasRepository {
  _FakeAliasRepository({
    required List<ClientGoodsAlias> rows,
    this.deleteFailure,
    this.deleteGate,
    List<ApiException> listFailures = const [],
  }) : _rows = [...rows],
       _listFailures = [...listFailures];

  final List<ClientGoodsAlias> _rows;
  final ApiException? deleteFailure;
  final Completer<void>? deleteGate;
  final List<ApiException> _listFailures;
  final listCalls = <({String clientId, int page, String keyword})>[];
  final deleted = <({String clientId, String aliasId})>[];

  @override
  Future<PagedResult<ClientGoodsAlias>> list(
    String clientId, {
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    final kw = keyword?.trim() ?? '';
    listCalls.add((clientId: clientId, page: page, keyword: kw));
    if (_listFailures.isNotEmpty) throw _listFailures.removeAt(0);
    final matched = [
      for (final row in _rows)
        if (kw.isEmpty ||
            row.aliasText.toLowerCase().contains(kw.toLowerCase()))
          row,
    ];
    final start = (page - 1) * size;
    final items = start >= matched.length
        ? const <ClientGoodsAlias>[]
        : matched.sublist(
            start,
            start + size > matched.length ? matched.length : start + size,
          );
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: matched.length,
      totalPages: matched.isEmpty ? 0 : (matched.length + size - 1) ~/ size,
    );
  }

  @override
  Future<void> delete(String clientId, String aliasId) async {
    if (deleteGate != null) await deleteGate!.future;
    if (deleteFailure != null) throw deleteFailure!;
    deleted.add((clientId: clientId, aliasId: aliasId));
    _rows.removeWhere((row) => row.id == aliasId);
  }
}
