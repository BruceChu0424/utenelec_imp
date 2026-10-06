import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_action.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/inventory_cost_posting_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Future<void> _open(
  WidgetTester tester,
  _Api api, {
  bool canPost = false,
  double width = 1280,
  StateProvider<Set<String>>? grants,
  DateTime? from,
  DateTime? to,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWith(
          (ref) => grants != null
              ? ref.watch(grants)
              : {
                  Perm.financeReportView,
                  Perm.goodsCostView,
                  if (canPost) Perm.financePostExecute,
                },
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: InventoryCostPostingDialog(
            from: from ?? DateTime(2026, 9),
            to: to ?? DateTime(2026, 9, 29),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'same business day normalizes mixed inputs and picker values without weakening range guard',
    (tester) async {
      final api = _Api();
      await _open(
        tester,
        api,
        from: DateTime(2026, 10),
        to: DateTime.utc(2026, 10),
      );
      int reads() =>
          api.reads.where((path) => path.endsWith('/postings')).length;
      expect(reads(), 1);
      var fields = tester
          .widgetList<UtenDateField>(find.byType(UtenDateField))
          .toList();
      expect(fields.first.value!.isUtc, isTrue);
      expect(fields.last.value!.isUtc, isTrue);
      fields.first.onChanged(DateTime(2026, 10));
      await tester.pumpAndSettle();
      expect(reads(), 2);
      fields = tester
          .widgetList<UtenDateField>(find.byType(UtenDateField))
          .toList();
      expect(fields.first.value!.isUtc, isTrue);
      fields.first.onChanged(DateTime(2026, 10, 2));
      await tester.pumpAndSettle();
      expect(reads(), 2);
      expect(find.text('来源开始日期不能晚于结束日期'), findsWidgets);
    },
  );
  testWidgets(
    'permission revoked during confirmation cannot post inventory cost',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {
          Perm.financeReportView,
          Perm.goodsCostView,
          Perm.financePostExecute,
        },
      );
      final api = _Api();
      await _open(tester, api, grants: grants);
      await tester.tap(find.byKey(const ValueKey('inventory-cost-post')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(InventoryCostPostingDialog)),
      );
      container.read(grants.notifier).state = {
        Perm.financeReportView,
        Perm.goodsCostView,
      };
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('inventory-cost-confirm')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.byKey(const ValueKey('inventory-cost-post')), findsNothing);
    },
  );

  testWidgets(
    'revoking cost visibility masks an already loaded financial dialog',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {
          Perm.financeReportView,
          Perm.goodsCostView,
          Perm.financePostExecute,
        },
      );
      final api = _Api();
      await _open(tester, api, grants: grants);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(InventoryCostPostingDialog)),
      );
      container.read(grants.notifier).state = {
        Perm.financeReportView,
        Perm.financePostExecute,
      };
      await tester.pumpAndSettle();
      expect(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('inventory-cost-post')), findsNothing);
      expect(api.writes, isEmpty);
    },
  );
  testWidgets(
    'disabled strategy cannot close a period even with zero pending postings',
    (tester) async {
      final api = _Api()
        ..enabled = false
        ..status = 'POSTED';
      await _open(tester, api, canPost: true);
      final close = tester.widget<UtenButton>(
        find.byKey(const ValueKey('inventory-cost-close-period')),
      );
      expect(close.onPressed, isNull);
      expect(api.writes, isEmpty);
    },
  );
  testWidgets(
    'read only open makes no financial writes and keeps exact amount text',
    (tester) async {
      final api = _Api()..status = 'LEGACY_VOUCHER_RECONCILIATION_REQUIRED';
      await _open(tester, api);
      expect(api.writes, isEmpty);
      expect(
        api.reads.where(
          (path) => path.endsWith('/policy') || path.endsWith('/periods'),
        ),
        isEmpty,
      );
      expect(find.byKey(const ValueKey('inventory-cost-policy')), findsNothing);
      expect(find.text('历史凭证待对账'), findsWidgets);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      final amount = table.columns.singleWhere(
        (column) => column.key == 'amountLocal',
      );
      expect(amount.value(table.items.single), '9007199254740993.0000007');
      expect(
        amount.exactValueOf!(table.items.single),
        '9007199254740993.0000007',
      );
    },
  );

  testWidgets(
    'activation requires evidence and concrete confirmation before writing',
    (tester) async {
      final api = _Api()
        ..enabled = false
        ..status = 'DISABLED_PENDING_RECONCILIATION';
      await _open(tester, api, canPost: true);
      expect(api.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('inventory-cost-policy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(
        tester
            .state<FormFieldState<String>>(find.byType(TextFormField))
            .hasError,
        isTrue,
      );
      await tester.enterText(find.byType(TextFormField), '已核对本期原价值和历史凭证差额');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.text('确认启用实际成本过账'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inventory-cost-confirm')));
      await tester.pumpAndSettle();
      expect(api.writes.single.$1, '$inventoryCostPostingEndpoint/policy');
      expect(api.writes.single.$2, containsPair('enabled', true));
      expect(api.writes.single.$2, containsPair('expectedVersion', 7));
    },
  );

  testWidgets(
    'posting cancellation writes nothing and confirmation posts selected period once',
    (tester) async {
      final api = _Api();
      await _open(tester, api, canPost: true);
      await tester.tap(find.byKey(const ValueKey('inventory-cost-post')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.textContaining('入账期间: 2026-09'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('inventory-cost-post')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inventory-cost-confirm')));
      await tester.pumpAndSettle();
      expect(
        api.writes.single.$1,
        '$inventoryCostPostingEndpoint/periods/2026-09/post',
      );
      expect(find.text('已入账'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('inventory-cost-close-period')),
      );
      await tester.pumpAndSettle();
      expect(api.writes.length, 1);
      await tester.enterText(find.byType(TextField), '本期已完整核对');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(
        api.writes.last.$1,
        '$inventoryCostPostingEndpoint/periods/2026-09/close',
      );
      expect(api.writes.last.$2['expectedVersion'], 0);
    },
  );

  testWidgets(
    'target period choice preserves source identity and waits for confirmation',
    (tester) async {
      final api = _Api()..status = 'TARGET_PERIOD_REQUIRED';
      await _open(tester, api, canPost: true);
      final assign = find.widgetWithText(UtenTableCellAction, '指定入账期间');
      await tester.tap(assign);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-10').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '后补成本核定本期入账');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.textContaining('posting-1'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('inventory-cost-confirm')));
      await tester.pumpAndSettle();
      expect(
        api.writes.single.$1,
        '$inventoryCostPostingEndpoint/postings/posting-1/period',
      );
      expect(api.writes.single.$2['targetPeriod'], '2026-10');
    },
  );

  testWidgets('narrow table keeps single line cells and no initial mutation', (
    tester,
  ) async {
    final api = _Api()..status = 'TARGET_PERIOD_REQUIRED';
    await _open(tester, api, canPost: true, width: 360);
    expect(tester.takeException(), isNull);
    expect(api.writes, isEmpty);
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      find.byType(MasterDataTableView<Map<String, dynamic>>),
    );
    for (final column in table.columns.where(
      (column) => column.key != 'choosePeriod',
    )) {
      final cell =
          column.cellBuilder!(
                tester.element(find.byType(InventoryCostPostingDialog)),
                table.items.single,
              )
              as Tooltip;
      final text = cell.child! as Text;
      expect(text.maxLines, 1);
      expect(text.softWrap, isFalse);
    }
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <String>[];
  final writes = <(String, Map<String, dynamic>)>[];
  bool enabled = true;
  String status = 'READY';
  Map<String, dynamic> get row => {
    'postingId': 'posting-1',
    'amountLocal': '9007199254740993.0000007',
    'businessDate': '2026-09-10',
    'sourcePeriod': '2026-09',
    'targetPeriod': '2026-09',
    'sourceDocType': 'COST_ADJUST',
    'sourceDocId': 'document-1',
    'valueRevision': 2,
    'postingStatus': status,
    'voucherId': status == 'POSTED' ? 'voucher-1' : null,
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    return path.endsWith('/policy')
        ? {
            'enabled': enabled,
            'effectiveFrom': '2026-09-01',
            'reconciliationReference': '',
            'version': 7,
          }
        : {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path.endsWith('/postings')) return [row];
    if (path.endsWith('/periods')) {
      return [
        {
          'period': '2026-09',
          'status': 'OPEN',
          'version': 0,
          'pendingCount': status == 'POSTED' ? 0 : 1,
        },
        {
          'period': '2026-10',
          'status': 'OPEN',
          'version': 0,
          'pendingCount': 0,
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final map = Map<String, dynamic>.from(body! as Map);
    writes.add((path, map));
    enabled = map['enabled'] == true;
    status = 'READY';
    return {...map, 'version': 8};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add((path, Map<String, dynamic>.from(body! as Map)));
    status = 'POSTED';
    return {'period': '2026-09', 'newVoucherCount': 1};
  }
}
