import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/saved_document_fields.dart';

import 'drafts/memory_form_draft_storage.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final module in ['purchase', 'subcontract']) {
    testWidgets(
      '$module total amount survives draft recovery and exact submission',
      (tester) async {
        final storage = _Storage();
        final api = _Api();
        var env = await _pump(tester, module, storage, api);
        await _seed(tester, module);
        final pricing = module == 'purchase'
            ? tester
                  .widget<UtenEditableGrid<PurchaseGridRow>>(
                    find.byType(UtenEditableGrid<PurchaseGridRow>),
                  )
                  .controller[0]
                  .pricing
            : tester
                  .widget<UtenEditableGrid<SubcontractGridRow>>(
                    find.byType(UtenEditableGrid<SubcontractGridRow>),
                  )
                  .controller[0]
                  .pricing;
        pricing.qty.text = '3000';
        pricing.totalAmount.text = '100';
        expect(pricing.totalAmountInput, '100');
        expect(pricing.price.text, '0.0333333333');
        final state = module == 'purchase'
            ? tester.state(find.byType(PurchaseOrderEditPage))
                  as FormDraftMixin<PurchaseOrderEditPage>
            : tester.state(find.byType(SubcontractOrderEditPage))
                  as FormDraftMixin<SubcontractOrderEditPage>;
        await state.saveFormDraftNow();
        final draft = env.container.read(formDraftsProvider).single;
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
        env = await _pump(
          tester,
          module,
          storage,
          api,
          location: draft.resumeLocation,
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(api.creates, 1);
        final line = (api.lastBody!['items'] as List).single as Map;
        expect(line['qty'], '3000');
        expect(line['price'], '0.0333333333');
        expect(line['totalAmountInput'], '100');
        expect(line.containsKey('amountOriginal'), isFalse);
        expect(line.containsKey('amountLocal'), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
      },
    );
    for (final failCheckpoint in [false, true]) {
      testWidgets(
        '$module restored partial order saves; failed local checkpoint=$failCheckpoint',
        (tester) async {
          final storage = _Storage();
          final api = _Api();
          var env = await _pump(tester, module, storage, api);
          await _seed(tester, module);
          final draft = env.container.read(formDraftsProvider).single;
          await tester.pumpWidget(const SizedBox());
          env.router.dispose();
          env.container.dispose();
          env = await _pump(
            tester,
            module,
            storage,
            api,
            location: draft.resumeLocation,
          );
          storage.failCheckpoint = failCheckpoint;
          if (module == 'purchase') {
            tester
                    .widget<UtenEditableGrid<PurchaseGridRow>>(
                      find.byType(UtenEditableGrid<PurchaseGridRow>),
                    )
                    .controller[0]
                    .qty
                    .text =
                '7';
          } else {
            tester
                    .widget<UtenEditableGrid<SubcontractGridRow>>(
                      find.byType(UtenEditableGrid<SubcontractGridRow>),
                    )
                    .controller[0]
                    .qty
                    .text =
                '7';
          }
          await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
          await tester.pumpAndSettle();
          expect(api.creates, 1);
          expect(find.text('created-document'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('pending-attachment-retry-notice')),
            findsNothing,
          );
          expect(env.container.read(formDraftsProvider), isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          env.router.dispose();
          env.container.dispose();
        },
      );
    }
    testWidgets(
      '$module confirmed order recovery navigates without creating again',
      (tester) async {
        final storage = _Storage();
        final api = _Api();
        var env = await _pump(tester, module, storage, api);
        await _seed(tester, module, knownCreated: true);
        final draft = env.container.read(formDraftsProvider).single;
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
        env = await _pump(
          tester,
          module,
          storage,
          api,
          location: draft.resumeLocation,
        );
        expect(
          find.byKey(const ValueKey('pending-attachment-retry-notice')),
          findsNothing,
        );
        expect(
          tester
              .widgetList<SavedDocumentFields>(find.byType(SavedDocumentFields))
              .every((widget) => widget.locked),
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(api.creates, 0);
        expect(find.text('created-document'), findsOneWidget);
        expect(env.container.read(formDraftsProvider), isEmpty);
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
}

Future<void> _seed(
  WidgetTester tester,
  String module, {
  bool knownCreated = false,
}) async {
  final state = module == 'purchase'
      ? tester.state(find.byType(PurchaseOrderEditPage))
            as FormDraftMixin<PurchaseOrderEditPage>
      : tester.state(find.byType(SubcontractOrderEditPage))
            as FormDraftMixin<SubcontractOrderEditPage>;
  Map<String, dynamic> row;
  if (module == 'purchase') {
    final value = PurchaseGridRow()
      ..goods = const GoodsOption(id: 'goods-1', name: '采购料')
      ..supplierId = 'supplier-1'
      ..currencyId = 'cny'
      ..settlementMethodId = 'settlement-1';
    value.price.text = '12';
    value.exchangeRate.text = '1';
    value.taxRate.text = '0';
    row = value.exportDraft();
    value.dispose();
  } else {
    final value = SubcontractGridRow()
      ..goods = const GoodsOption(id: 'goods-1', name: '委外料')
      ..supplierId = 'supplier-1'
      ..currencyId = 'cny'
      ..settlementMethodId = 'settlement-1';
    value.price.text = '12';
    value.exchangeRate.text = '1';
    value.taxRate.text = '0';
    row = value.exportDraft();
    value.dispose();
  }
  await state.restoreFormDraft({
    ...state.captureFormDraft(),
    'rows': [
      {...row, 'selected': !knownCreated},
    ],
    'createdOrders': [
      if (knownCreated) {'id': 'created-order'},
    ],
  });
  await state.saveFormDraftNow();
  await tester.pumpAndSettle();
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  String module,
  _Storage storage,
  _Api api, {
  String? location,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'procurement-user'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.purchaseOrderCreate,
        Perm.purchaseOrderView,
        Perm.subcontractOrderCreate,
        Perm.subcontractOrderView,
      }),
      formDraftStorageProvider.overrideWithValue(storage),
      sharedPreferencesProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      settlementMethodOptionsProvider.overrideWith(
        (ref) async => const [
          ReferenceMethodOption(id: 'settlement-1', code: 'NET30', name: '月结'),
        ],
      ),
    ],
  );
  final router = GoRouter(
    initialLocation: location ?? '/$module/orders/new',
    routes: [
      DraftAwareGoRoute(
        path: '/$module/orders/new',
        builder: (_, state) => module == 'purchase'
            ? PurchaseOrderEditPage(key: state.pageKey)
            : SubcontractOrderEditPage(key: state.pageKey),
      ),
      GoRoute(
        path: '/$module/orders/created-order',
        builder: (_, _) => const Scaffold(body: Text('created-document')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int creates = 0;
  Map<String, dynamic>? lastBody;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'items': <Map<String, dynamic>>[],
    'page': 1,
    'size': 1,
    'total': 0,
    'totalPages': 0,
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/orders/batch')) return const {};
    creates++;
    lastBody = body as Map<String, dynamic>;
    return const {
      'items': [
        {'id': 'created-order', 'items': <Map<String, dynamic>>[]},
      ],
    };
  }
}

class _Storage extends MemoryFormDraftStorage {
  bool failCheckpoint = false;
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) {
    if (failCheckpoint && value != null) {
      final json = jsonDecode(value) as Map<String, dynamic>;
      final data = json['data'];
      if (data is Map &&
          data['createdOrders'] is List &&
          (data['createdOrders'] as List).isNotEmpty) {
        throw StateError('local checkpoint failure');
      }
    }
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}
