import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_operation_history.dart';
import 'package:uten_imp/features/basic_data/models/party_directory_models.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_operation_history_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_operation_history_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/party_directory_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_operation_history_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Store {
  bool removed = false;
  int reads = 0;
  void read() {
    reads++;
    if (removed) throw ApiException('NOT_FOUND', '资料已撤回');
  }
}

class _Clients extends Fake implements ClientRepository {
  _Clients(this.store);
  final _Store store;
  @override
  Future<ClientDetail> detail(String id) async {
    store.read();
    return const ClientDetail(
      id: 'entity-a',
      name: '客户私有名称',
      status: '使用',
      writable: true,
    );
  }
}

class _Suppliers extends Fake implements SupplierRepository {
  _Suppliers(this.store);
  final _Store store;
  @override
  Future<SupplierDetail> detail(String id) async {
    store.read();
    return const SupplierDetail(id: 'entity-a', name: '供应商私有名称', status: '使用');
  }
}

class _Accounts extends Fake implements AccountRepository {
  _Accounts(this.store);
  final _Store store;
  @override
  Future<AccountDetail> detail(String id) async {
    store.read();
    return const AccountDetail(
      id: 'entity-a',
      name: '账户私有名称',
      status: '使用',
      accountType: 'BANK',
    );
  }
}

class _Directory extends Fake implements PartyDirectoryRepository {
  @override
  Future<List<PartyContactMethod>> contactMethods(String id) async => const [];
  @override
  Future<List<PartyAddress>> addresses(String id) async => const [];
  @override
  Future<List<PartyActivityRecord>> activityRecords(String id) async =>
      const [];
  @override
  Future<int?> creditScore(String id) async => 100;
}

class _Currencies extends Fake implements CurrencyRepository {
  @override
  Future<List<CurrencyListItem>> dict() async => const [
    CurrencyListItem(id: 'cny', name: '人民币', code: 'CNY'),
  ];
}

class _Settlements extends Fake implements ReferenceMethodRepository {
  @override
  Future<List<ReferenceMethodOption>> settlementMethods() async => const [
    ReferenceMethodOption(id: 'cash', code: 'CASH', name: '现结'),
  ];
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _History extends Fake implements GoodsOperationHistoryRepository {
  _History(this.store);
  final _Store store;
  int undos = 0;
  int redos = 0;
  GoodsOperationHistory get value => GoodsOperationHistory(
    entries: [
      GoodsOperationEntry(
        id: 'operation-a',
        operationType: 'MASTER_CREATE',
        label: '新增资料',
        createdAt: '2026-10-20T00:00:00Z',
        state: store.removed ? 'UNDONE' : 'APPLIED',
        version: store.removed ? 2 : 1,
        affectedCount: 1,
        canUndo: !store.removed,
        canRedo: store.removed,
      ),
    ],
  );
  @override
  Future<GoodsOperationHistory> list() async => value;
  @override
  Future<GoodsOperationHistory> undo(
    String id, {
    required int expectedVersion,
  }) async {
    undos++;
    store.removed = true;
    return value;
  }

  @override
  Future<GoodsOperationHistory> redo(
    String id, {
    required int expectedVersion,
  }) async {
    redos++;
    store.removed = false;
    return value;
  }
}

Future<void> _pump(
  WidgetTester tester,
  String entity,
  _Store store,
  _History history, {
  bool writable = true,
}) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefix = {
    'clients': 'client',
    'suppliers': 'supplier',
    'accounts': 'account',
  }[entity]!;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        apiBaseUrlProvider.overrideWithValue('https://company.invalid/api'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'reader'),
        ),
        sessionSnapshotProvider.overrideWith(_Snapshots.new),
        currentPermissionsProvider.overrideWithValue({
          '$prefix:view',
          if (writable) '$prefix:edit',
        }),
        isSuperAdminProvider.overrideWithValue(false),
        clientRepositoryProvider.overrideWithValue(_Clients(store)),
        supplierRepositoryProvider.overrideWithValue(_Suppliers(store)),
        accountRepositoryProvider.overrideWithValue(_Accounts(store)),
        clientDirectoryRepositoryProvider.overrideWithValue(_Directory()),
        supplierDirectoryRepositoryProvider.overrideWithValue(_Directory()),
        currencyRepositoryProvider.overrideWithValue(_Currencies()),
        referenceMethodRepositoryProvider.overrideWithValue(_Settlements()),
        masterOperationHistoryRepositoryProvider(
          entity,
        ).overrideWithValue(history),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: entity == 'accounts'
            ? const AccountDetailPage(accountId: 'entity-a')
            : PartyDetailPage(
                partyType: entity == 'clients' ? 'client' : 'supplier',
                id: 'entity-a',
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _apply(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('master-history-apply')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(UtenAlertDialog),
      matching: find.byType(FilledButton),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(UtenCloseButton).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final entity in ['clients', 'suppliers', 'accounts']) {
    final name = {
      'clients': '客户私有名称',
      'suppliers': '供应商私有名称',
      'accounts': '账户私有名称',
    }[entity]!;
    testWidgets('$entity 详情撤回后清空旧资料，取消撤回重新读取并恢复', (tester) async {
      final store = _Store();
      final history = _History(store);
      await _pump(tester, entity, store, history);
      expect(find.text(name), findsWidgets);
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      await _apply(tester);
      expect(history.undos, 1);
      expect(find.text(name), findsNothing);
      expect(find.text('资料已撤回'), findsOneWidget);
      await tester.tap(find.text('取消撤回'));
      await tester.pumpAndSettle();
      await _apply(tester);
      expect(history.redos, 1);
      expect(store.reads, 3);
      expect(find.text(name), findsWidgets);
      expect(tester.takeException(), isNull);
    });
    testWidgets('$entity 只读账号不显示历史操作', (tester) async {
      final store = _Store();
      await _pump(tester, entity, store, _History(store), writable: false);
      expect(find.text('撤回'), findsNothing);
      expect(find.text('取消撤回'), findsNothing);
    });
  }

  testWidgets('客户就地编辑期间禁用历史，取消后不提交草稿并恢复入口', (tester) async {
    final store = _Store();
    final history = _History(store);
    await _pump(tester, 'clients', store, history);
    await tester.tap(find.byKey(const Key('party-detail-edit')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MasterOperationHistoryActions>(
            find.byType(MasterOperationHistoryActions),
          )
          .enabled,
      isFalse,
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '客户私有名称',
      ),
      '未提交客户名称',
    );
    await tester.tap(find.byKey(const Key('party-detail-cancel')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MasterOperationHistoryActions>(
            find.byType(MasterOperationHistoryActions),
          )
          .enabled,
      isTrue,
    );
    expect(find.text('未提交客户名称'), findsNothing);
    expect(history.undos, 0);
    expect(history.redos, 0);
  });
}
