import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_material_return_batch_receive_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'main', name: '主仓', isAccountable: false),
    WarehouseDictEntry(
      id: 'leaf',
      name: '实际仓',
      parentId: 'main',
      status: '使用',
      selectableForNew: true,
    ),
  ];
  @override
  String warehouse(String? id) => id == 'leaf' ? '实际仓' : '—';
}

class _Session extends SessionNotifier {
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  @override
  SessionState build() => const SessionState();
}

class _GateStorage extends MemoryFormDraftStorage {
  bool gate = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (gate) {
      gate = false;
      entered.complete();
      await release.future;
    }
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}

class _Repo extends StockDocRepository {
  _Repo() : super(ApiClient(Dio()), StockDocType.wdraw);
  final unreadable = <String>{};
  final missing = <String>{};
  final statuses = <String, int>{};
  final calls = <Map<String, dynamic>>[];
  bool lose = true;
  @override
  Future<StockDocDetail> detail(String id) async {
    if (missing.contains(id)) {
      throw ApiException('NOT_FOUND', '原单已删除', httpStatus: 404);
    }
    if (unreadable.contains(id)) {
      throw ApiException('FORBIDDEN', '原单不可读取', httpStatus: 403);
    }
    return StockDocDetail(
      id: id,
      docType: 'WDRAW',
      billNo: 'RETURN-$id',
      status: statuses[id] ?? 0,
      warehouseId: 'leaf',
      materialReturnMainWarehouseId: 'main',
      productionMaterialReturn: true,
      items: [
        StockDocItem(
          id: 'line-$id',
          goodsId: 'goods-$id',
          qty: 5,
          unitId: 'kg',
        ),
      ],
    );
  }

  @override
  Future<StockDocDetail> confirmMaterialReturn(
    String id, {
    required String warehouseId,
    required String idempotencyKey,
    List<Map<String, dynamic>> lines = const [],
    List<String>? itemIds,
  }) async {
    calls.add({
      'id': id,
      'warehouseId': warehouseId,
      'key': idempotencyKey,
      'itemIds': itemIds,
    });
    if (lose) {
      lose = false;
      throw NetworkTimeoutException();
    }
    statuses[id] = 1;
    return detail(id);
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repo repo,
  MemoryFormDraftStorage storage, {
  String? draftId,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() => tester.view.resetPhysicalSize());
  addTearDown(() => tester.view.resetDevicePixelRatio());
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  const path = '/warehouse/material-returns/batch-receive';
  final router = GoRouter(
    initialLocation: Uri(
      path: path,
      queryParameters: {
        'documentIds': 'a,b',
        'itemIds': 'line-a,line-b',
        'draftId': ?draftId,
      },
    ).toString(),
    routes: [
      GoRoute(
        path: path,
        builder: (_, state) => const WarehouseMaterialReturnBatchReceivePage(
          documentIds: ['a', 'b'],
          selectedItemIds: ['line-a', 'line-b'],
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        fixedBadgeSummaryOverride(),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'warehouse-user'),
        ),
        apiClientProvider.overrideWithValue(repo.api),
        apiBaseUrlProvider.overrideWithValue(
          'https://warehouse-recovery.test/api',
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.stockDocView,
          Perm.stockDocApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(_Names()),
        stockDocRepositoryProvider(StockDocType.wdraw).overrideWithValue(repo),
        formDraftStorageProvider.overrideWithValue(storage),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(WarehouseMaterialReturnBatchReceivePage)),
  );
}

void main() {
  testWidgets(
    'return binds the original intent before its draft write awaits',
    (tester) async {
      final repo = _Repo()..lose = false;
      final storage = _GateStorage();
      final container = await _pump(tester, repo, storage);
      storage.gate = true;
      await tester.tap(find.byKey(const Key('material-return-batch-confirm')));
      await tester.pump();
      expect(storage.entered.isCompleted, isTrue);
      (container.read(sessionProvider.notifier) as _Session).intent++;
      storage.release.complete();
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty);
      expect(
        container.read(authenticatedScopeProvider)?.userId,
        'warehouse-user',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final scenario in [
    (hidden: 'b', late: false, kind: 'forbidden'),
    (hidden: 'b', late: false, kind: 'deleted'),
    (hidden: 'b', late: false, kind: 'cancelled'),
    (hidden: 'a', late: false, kind: 'forbidden'),
    (hidden: 'a', late: true, kind: 'forbidden'),
  ]) {
    final hidden = scenario.hidden;
    testWidgets(
      'return draft resumes only the original pending command when source $hidden is ${scenario.kind} late=${scenario.late}',
      (tester) async {
        final repo = _Repo();
        final storage = MemoryFormDraftStorage();
        var container = await _pump(tester, repo, storage);
        await tester.tap(
          find.byKey(const Key('material-return-batch-confirm')),
        );
        await tester.pumpAndSettle();
        expect(repo.calls, hasLength(1));
        final original = container.read(formDraftsProvider).single;
        final command = Map<String, dynamic>.from(
          original.data['pendingCommand'] as Map,
        );
        expect(original.hasUnknownSubmission, isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        if (scenario.kind == 'deleted') {
          repo.missing.add(hidden);
        } else if (scenario.kind == 'cancelled') {
          repo.statuses[hidden] = 3;
        } else {
          repo.unreadable.add(scenario.late ? 'b' : hidden);
        }
        container = await _pump(tester, repo, storage, draftId: original.id);
        expect(repo.calls, hasLength(1));
        expect(
          find.textContaining('来源 ${scenario.late ? 'b' : hidden}'),
          findsWidgets,
        );
        expect(
          find.text('RETURN-${scenario.late ? 'b' : hidden}'),
          findsNothing,
        );
        final button = tester.widget<UtenButton>(
          find.byKey(const Key('material-return-batch-confirm')),
        );
        if (hidden == 'a') {
          if (scenario.late) {
            expect(button.onPressed, isNotNull);
            repo.unreadable.add('a');
            await tester.tap(
              find.byKey(const Key('material-return-batch-confirm')),
            );
            await tester.pumpAndSettle();
            expect(
              repo.calls,
              hasLength(1),
              reason: 'fresh authority read must fail before any replay POST',
            );
            expect(find.text('RETURN-a'), findsNothing);
          } else {
            expect(button.onPressed, isNull);
          }
          final saved = container.read(formDraftsProvider).single;
          expect(saved.hasUnknownSubmission, isTrue);
          expect(saved.data['pendingCommand'], command);
        } else {
          expect(button.onPressed, isNotNull);
          await tester.tap(
            find.byKey(const Key('material-return-batch-confirm')),
          );
          await tester.pumpAndSettle();
          expect(repo.calls, hasLength(2));
          expect(repo.calls.last, repo.calls.first);
          final saved = container.read(formDraftsProvider).single;
          expect(saved.hasUnknownSubmission, isFalse);
          expect(saved.data['documentIds'], ['a', 'b']);
          expect(
            (saved.data['rows'] as List)
                .whereType<Map<Object?, Object?>>()
                .singleWhere((row) => row['documentId'] == 'b')['done'],
            isFalse,
          );
          expect(repo.calls.map((call) => call['id']), ['a', 'a']);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('fresh return batch remains strict when a source is unreadable', (
    tester,
  ) async {
    final repo = _Repo()..unreadable.add('b');
    await _pump(tester, repo, MemoryFormDraftStorage());
    expect(repo.calls, isEmpty);
    expect(find.text('RETURN-a'), findsNothing);
    expect(find.textContaining('原单不可读取'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
