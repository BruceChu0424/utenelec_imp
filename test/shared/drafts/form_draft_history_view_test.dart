import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_history_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'form_draft_store_test.dart' show MemoryDraftStorage;

final _permissions = StateProvider<Set<String>>(
  (ref) => {Perm.salesOrderView, Perm.salesOrderPriceView},
);
final _server = StateProvider((ref) => 'https://one.example/api');

class _HistoryStorage extends MemoryDraftStorage
    implements FormDraftHistoryStorage {
  int payloadReads = 0;
  final cursors = <String?>[];
  final FormDraftHistoryEntry entry = FormDraftHistoryEntry(
    id: '2',
    draftId: 'draft-1',
    module: BadgeModule.sales,
    route: '/sales/orders/new',
    permission: Perm.salesOrderCreate,
    draftKind: 'salesOrder',
    revision: 'rev',
    recordedAt: DateTime.utc(2026, 10),
    action: FormDraftHistoryAction.deleted,
  );

  @override
  Future<FormDraftHistoryPage> readHistoryPage(
    String prefix, {
    String? before,
    int limit = 30,
  }) async {
    cursors.add(before);
    return FormDraftHistoryPage(
      entries: before == null ? [entry] : [],
      nextCursor: before == null ? '2' : null,
    );
  }

  @override
  Future<FormDraftHistoryRecord?> readHistoryRecord(
    String prefix,
    String id,
  ) async {
    payloadReads++;
    return FormDraftHistoryRecord(
      entry: entry,
      draft: FormDraft(
        id: entry.draftId,
        title: 'PRIVATE TITLE',
        module: entry.module,
        route: entry.route,
        permission: entry.permission,
        draftKind: entry.draftKind,
        updatedAt: entry.recordedAt,
        data: {
          'rows': [
            {
              'goods': {'name': '货品A'},
              'text': {'qty': '12.', 'price': '9527.31'},
            },
          ],
          'attachments': {'bytes': 'PRIVATE_BINARY'},
        },
      ),
    );
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _HistoryStorage storage, {
  double textScale = 1,
}) async {
  final container = ProviderContainer(
    overrides: [
      formDraftStorageProvider.overrideWithValue(storage),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'user-1', readOnly: true),
      ),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(
          body: FormDraftHistoryButton(
            scope: FormDraftCategoryScope(module: BadgeModule.sales),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('本机草稿历史'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'history uses metadata until opened and immediately masks revoked price',
    (tester) async {
      final storage = _HistoryStorage();
      final container = await _mount(tester, storage);
      expect(find.text('已删除'), findsOneWidget);
      expect(storage.payloadReads, 0);
      expect(find.text('PRIVATE TITLE'), findsNothing);
      await tester.tap(find.text('销售订货单'));
      await tester.pumpAndSettle();
      expect(find.text('单价：9527.31'), findsOneWidget);
      expect(find.textContaining('PRIVATE_BINARY'), findsNothing);
      container.read(_permissions.notifier).state = {Perm.salesOrderView};
      await tester.pumpAndSettle();
      expect(find.textContaining('9527.31'), findsNothing);
      expect(find.text('数量：12.'), findsOneWidget);
      container.read(_permissions.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.textContaining('数量：12.'), findsNothing);
      expect(find.text('当前权限不可查看，或历史内容不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('server switch fences an already open history detail', (
    tester,
  ) async {
    final container = await _mount(tester, _HistoryStorage());
    await tester.tap(find.text('销售订货单'));
    await tester.pumpAndSettle();
    container.read(_server.notifier).state = 'https://two.example/api';
    await tester.pumpAndSettle();
    expect(find.textContaining('9527.31'), findsNothing);
    expect(find.text('登录身份已变化，请返回重新查看'), findsOneWidget);
  });

  testWidgets('narrow large text supports bounded cursor navigation and back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _HistoryStorage();
    await _mount(tester, storage, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(storage.cursors.last, '2');
    expect(find.text('第 2 页'), findsOneWidget);
    await tester.tap(find.text('上一页'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 页'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(FormDraftHistoryButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
