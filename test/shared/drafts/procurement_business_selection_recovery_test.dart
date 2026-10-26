import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_field_codec.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'memory_form_draft_storage.dart';
import '../../helpers/badge_summary_fixture.dart';

class _IdleSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _IdleSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _Sources extends ApiClient {
  _Sources() : super(Dio());
  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async => path.contains('decomposition-preview')
      ? [
          for (var i = 1; i <= 2; i++)
            {
              'sourceDocumentId': 'source',
              'sourceDocumentNo': 'SOURCE',
              'sourceItemId': 'item-$i',
              'goodsId': 'goods-$i',
              'requestedQty': 10,
              'orderedQty': 0,
              'pendingQty': 0,
              'remainingQty': 10,
              'kitQty': 10,
              'orderableQty': 10,
              'unitId': 'unit',
              'unitRate': 1,
            },
        ]
      : [];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('goods/lookup')
      ? [
          for (var i = 1; i <= 2; i++)
            {'id': 'goods-$i', 'code': 'G$i', 'name': 'Goods $i'},
        ]
      : [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'items': <Object?>[], 'total': 0, 'page': 1, 'totalPages': 0};
}

typedef _GridView = ({
  TextEditingController Function(int) qty,
  void Function(int, bool) select,
  bool Function(int) selected,
  int count,
});
_GridView _grid(WidgetTester tester, bool purchase) {
  if (purchase) {
    final c = tester
        .widget<UtenEditableGrid<PurchaseGridRow>>(
          find.byType(UtenEditableGrid<PurchaseGridRow>),
        )
        .controller;
    return (
      qty: (i) => c.rows[i].qty,
      select: (i, v) => c.setSelected([c.rows[i]], v),
      selected: (i) => c.isSelected(c.rows[i]),
      count: c.length,
    );
  }
  final c = tester
      .widget<UtenEditableGrid<SubcontractGridRow>>(
        find.byType(UtenEditableGrid<SubcontractGridRow>),
      )
      .controller;
  return (
    qty: (i) => c.rows[i].qty,
    select: (i, v) => c.setSelected([c.rows[i]], v),
    selected: (i) => c.isSelected(c.rows[i]),
    count: c.length,
  );
}

void main() {
  for (final purchase in [true, false]) {
    testWidgets(
      '${purchase ? 'purchase' : 'subcontract'} selection-only input survives restart and switching two drafts',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final storage = MemoryFormDraftStorage();
        final api = _Sources();
        ProviderContainer? container;
        GoRouter? router;
        Future<void> open([String? location]) async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          router?.dispose();
          container?.dispose();
          final path = purchase
              ? '/purchase/orders/new'
              : '/subcontract/orders/new';
          router = GoRouter(
            initialLocation: location ?? path,
            routes: [
              GoRoute(
                path: path,
                builder: (_, state) => purchase
                    ? PurchaseOrderEditPage(
                        key: ValueKey(state.uri.toString()),
                        sourceRequestItemIds: const ['item-1', 'item-2'],
                      )
                    : SubcontractOrderEditPage(
                        key: ValueKey(state.uri.toString()),
                        applicationItemIds: const ['item-1', 'item-2'],
                      ),
              ),
            ],
          );
          container = ProviderContainer(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              apiBaseUrlProvider.overrideWithValue(
                'https://draft-source.example/api',
              ),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(
                  userId: 'draft-owner',
                  businessDatasetId: 'draft-dataset',
                ),
              ),
              sessionProvider.overrideWith(_IdleSession.new),
              sessionSnapshotProvider.overrideWith(_IdleSnapshot.new),
              fixedBadgeSummaryOverride(),
              sharedPreferencesProvider.overrideWithValue(prefs),
              formDraftStorageProvider.overrideWithValue(storage),
              currentPermissionsProvider.overrideWithValue({
                purchase
                    ? Perm.purchaseOrderCreate
                    : Perm.subcontractOrderCreate,
                purchase ? Perm.purchaseOrderView : Perm.subcontractOrderView,
              }),
            ],
          );
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container!,
              child: MaterialApp.router(
                routerConfig: router!,
                locale: const Locale('zh'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(_grid(tester, purchase).count, 2);
        }

        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          router?.dispose();
          container?.dispose();
        });
        await open();
        var grid = _grid(tester, purchase);
        grid.qty(0).text = '1.2345';
        await tester.pumpAndSettle();
        grid.select(0, false);
        await tester.pumpAndSettle();
        final a = container!.read(formDraftsProvider).single;
        expect(
          draftMaps(a.data['rows']).first['selected'],
          isFalse,
          reason: 'Business selection must be durable before leaving',
        );
        final persisted = draftMap(
          draftMap(jsonDecode(storage.records.values.single))['data'],
        );
        expect(draftMaps(persisted['rows']).first['selected'], isFalse);
        await open();
        grid = _grid(tester, purchase);
        grid.qty(0).text = '2.3456';
        await tester.pumpAndSettle();
        grid.select(1, false);
        await tester.pumpAndSettle();
        final b = container!
            .read(formDraftsProvider)
            .singleWhere((draft) => draft.id != a.id);
        await open(a.resumeLocation);
        grid = _grid(tester, purchase);
        expect(grid.qty(0).text, '1.2345');
        expect(grid.selected(0), isFalse);
        expect(grid.selected(1), isTrue);
        await open(b.resumeLocation);
        grid = _grid(tester, purchase);
        expect(grid.qty(0).text, '2.3456');
        expect(grid.selected(0), isTrue);
        expect(grid.selected(1), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
