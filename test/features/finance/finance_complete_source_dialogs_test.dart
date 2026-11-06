import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/finance_auxiliary_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_material_context_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_open_item_classification_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_procurement_confirmation_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_statement_document_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/uten_test_actions.dart';

const _exact = '98765432101234567890.123456789';
const _scope = <String, dynamic>{
  'templateKey': 'supplierStatement',
  'partyRole': 'SUPPLIER',
  'partyId': 'supplier-original',
  'currencyId': 'currency-original',
  'dateFrom': '2026-10-01',
  'dateTo': '2026-10-31',
};

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Finder _table(String key) => find.byWidgetPredicate(
  (widget) =>
      widget is MasterDataTableView<Map<String, dynamic>> &&
      widget.tableKey == key,
);

MasterDataTableView<Map<String, dynamic>> _value(
  WidgetTester tester,
  String key,
) => tester.widget<MasterDataTableView<Map<String, dynamic>>>(_table(key));

Future<void> _mount(
  WidgetTester tester,
  _Api api,
  void Function(BuildContext) open, {
  bool held = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await setUtenTestSurfaceSize(tester, const Size(1400, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue(
          'https://finance-local.invalid/api',
        ),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'original-finance-reader'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.supplierSettlementConfirm,
          Perm.financePostExecute,
        }),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context),
              child: const Text('打开完整来源'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开完整来源'));
  if (held) {
    for (var frame = 0; frame < 35 && api.reads.length < 2; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> _tail(
  WidgetTester tester,
  _Api api,
  String tableKey,
  String label,
) async {
  final table = _table(tableKey);
  await tester.ensureVisible(table);
  await tester.pumpAndSettle();
  final state = tester
      .stateList<ScrollableState>(
        find.descendant(of: table, matching: find.byType(Scrollable)),
      )
      .where((state) => state.position.axis == Axis.vertical)
      .reduce(
        (left, right) =>
            left.position.maxScrollExtent > right.position.maxScrollExtent
            ? left
            : right,
      );
  final before = api.reads.length;
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pumpAndSettle();
  expect(
    find.descendant(of: table, matching: find.text(label)),
    findsOneWidget,
  );
  state.position.jumpTo(0);
  await tester.pumpAndSettle();
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pumpAndSettle();
  expect(api.reads, hasLength(before));
}

void main() {
  for (final material in [false, true]) {
    testWidgets(
      'accepted directory denial rejects its retired row callback: material=$material',
      (tester) async {
        final api = _Api();
        Map<String, dynamic>? selected;
        await _mount(tester, api, (context) async {
          selected = material
              ? await showFinanceMaterialContextPicker(context)
              : await showFinanceAuxiliaryPicker(context);
        });
        final key = material
            ? 'finance.material-context.picker.v1'
            : 'finance.auxiliary.directory.v1';
        final previous = _value(tester, key);
        final row = previous.items.last;
        expect(previous.items, hasLength(251));
        expect(previous.canOpenRow!(row), isTrue);
        api.denyDirectory = true;
        previous.onRetry!();
        await tester.pumpAndSettle();
        final current = _value(tester, key);
        expect(current.items, isEmpty);
        expect(current.error, '当前目录无权限');
        expect(current.canOpenRow!(row), isFalse);
        // A queued event must validate against the State's current accepted
        // rows, even if it still holds the earlier widget callback and DTO.
        previous.onRowTap!(row);
        await tester.pumpAndSettle();
        expect(selected, isNull);
        expect(_table(key), findsOneWidget);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'all 251 auxiliary source identities load before local tail scroll',
    (tester) async {
      final api = _Api();
      Map<String, dynamic>? selected;
      await _mount(tester, api, (context) async {
        selected = await showFinanceAuxiliaryPicker(
          context,
          accountCode: '1122-original',
          role: 'CUSTOMER',
        );
      });
      const key = 'finance.auxiliary.directory.v1';
      expect(_value(tester, key).items, hasLength(251));
      expect(api.reads.map((r) => r.$2['page']), ['1', '2', '3']);
      expect(
        api.reads.every((r) => r.$2['accountCode'] == '1122-original'),
        isTrue,
      );
      expect(api.reads.every((r) => r.$2['role'] == 'CUSTOMER'), isTrue);
      await _tail(tester, api, key, '原项目250');
      final last = find.text('原项目250');
      await tester.tap(last);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(selected?['id'], 'aux-250');
      expect(selected?['sourceCode'], '原项目250');
      expect(selected?['version'], 37);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all 251 approved material contexts preserve original currency and source precision',
    (tester) async {
      final api = _Api();
      Map<String, dynamic>? selected;
      await _mount(tester, api, (context) async {
        selected = await showFinanceMaterialContextPicker(context);
      });
      const key = 'finance.material-context.picker.v1';
      final table = _value(tester, key);
      expect(table.items, hasLength(251));
      expect(table.canOpenRow!(table.items.first), isFalse);
      await _tail(tester, api, key, '原往来250');
      final last = find.text('原往来250');
      await tester.tap(last);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(selected?['id'], 'material-250');
      expect(selected?['actualCurrencyId'], 'actual-usd-original');
      expect(selected?['accountingCurrencyId'], 'book-cny-original');
      expect(selected?['amountExact'], _exact);
      expect(selected?['version'], 37);
      expect(api.reads, hasLength(3));
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'all 251 open-item sources keep ledger UUIDs and original direction',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, (context) {
        unawaited(
          showFinanceOpenItemClassificationDialog(
            context,
            partyId: 'customer-original',
            currencyId: 'currency-original',
            receivable: true,
          ),
        );
      });
      const key = 'finance.open-item.classification.sources';
      expect(_value(tester, key).items, hasLength(251));
      expect(_value(tester, key).items.last['ledgerId'], 'ledger-250');
      expect(api.reads.every((r) => r.$2['direction'] == 'AR'), isTrue);
      expect(
        api.reads.every((r) => r.$2['partyId'] == 'customer-original'),
        isTrue,
      );
      await _tail(tester, api, key, '来源单250');
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'source detail completes all 251 cash references and all 251 offset ends independently',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, (context) {
        unawaited(
          showFinanceOpenItemClassificationDialog(
            context,
            ledgerId: 'ledger-original',
          ),
        );
      });
      const cash = 'finance.open-item.classification.payments';
      const offsets = 'finance.open-item.classification.offsets';
      expect(_value(tester, cash).items, hasLength(251));
      expect(_value(tester, cash).items.last['paymentLineId'], 'cash-250');
      expect(_value(tester, offsets).items, hasLength(251));
      expect(_value(tester, offsets).items.last['offsetId'], 'offset-250');
      final references = api.reads.where((r) => r.$1.endsWith('/references'));
      expect(
        references
            .where((r) => r.$2['kind'] == 'cash')
            .map((r) => r.$2['page']),
        ['1', '2', '3'],
      );
      expect(
        references
            .where((r) => r.$2['kind'] == 'offsets')
            .map((r) => r.$2['page']),
        ['1', '2', '3'],
      );
      await _tail(tester, api, cash, '收付款250');
      await _tail(tester, api, offsets, 'offset-250');
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'all 251 procurement candidates and history keep their original supplier and currency',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, (context) {
        unawaited(
          showFinanceProcurementConfirmationDialog(
            context,
            supplierId: 'supplier-original',
            currencyId: 'currency-original',
          ),
        );
      });
      const pending = 'finance.procurement-confirmation.PENDING';
      expect(_value(tester, pending).items, hasLength(251));
      expect(
        _value(tester, pending).items.last['sourceFingerprint'],
        'original-fingerprint-250',
      );
      expect(_value(tester, pending).items.last['amountOriginal'], _exact);
      await _tail(tester, api, pending, '采购来源250');
      tester
          .widget<UtenDropdownField>(find.byType(UtenDropdownField).first)
          .onChanged('HISTORY');
      await tester.pumpAndSettle();
      const history = 'finance.procurement-confirmation.HISTORY';
      expect(_value(tester, history).items, hasLength(251));
      expect(
        api.reads.every(
          (r) =>
              r.$2['supplierId'] == 'supplier-original' &&
              r.$2['currencyId'] == 'currency-original',
        ),
        isTrue,
      );
      expect(
        api.reads.take(3).every((r) => r.$2['status'] == 'PENDING'),
        isTrue,
      );
      expect(
        api.reads.skip(3).every((r) => !r.$2.containsKey('status')),
        isTrue,
      );
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'all 251 statement originals and each profile kind preserve exact query scopes',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, (context) {
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const FinanceStatementDocumentDialog(scope: _scope),
          ),
        );
      });
      expect(
        _value(tester, 'finance-statement-documents-REVIEWS').items,
        hasLength(251),
      );
      expect(api.reads, hasLength(3));
      expect(api.reads.every((r) => r.$1.endsWith('/reviews/query')), isTrue);
      expect(api.readBodies, everyElement(_scope));
      for (final kind in ['OWN', 'COUNTERPART', 'CONTEXT']) {
        tester
            .widget<UtenDropdownField>(find.byType(UtenDropdownField).first)
            .onChanged(kind);
        await tester.pumpAndSettle();
        expect(
          _value(tester, 'finance-statement-documents-$kind').items,
          hasLength(251),
        );
        final query = api.reads.last.$2;
        expect(
          query['templateKey'],
          kind == 'CONTEXT' ? 'supplierStatement' : 'ALL',
        );
        expect(query['currencyId'], 'currency-original');
        expect(query['partyId'], kind == 'OWN' ? isNull : 'supplier-original');
        expect(query['kind'], kind);
      }
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'all 251 immutable original-table rows preserve document metadata totals and local scroll',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, (context) {
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const FinanceStatementDocumentDialog(scope: _scope),
          ),
        );
      });
      final directory = _value(tester, 'finance-statement-documents-REVIEWS');
      directory.onRowTap!(directory.items.last);
      await tester.pumpAndSettle();
      const key = 'finance-statement-original-supplierStatement';
      final table = _value(tester, key);
      expect(table.items, hasLength(251));
      expect(table.items.last['amountExact'], _exact);
      expect(
        table.idOf!(table.items.first),
        isNot(table.idOf!(table.items.last)),
      );
      expect(find.textContaining('sha-review-250'), findsWidgets);
      expect(find.textContaining('保留完整原件页头'), findsOneWidget);
      await _tail(tester, api, key, '原件行250');
      expect(
        api.reads.where(
          (read) => read.$1.endsWith('/reviews/review-250/summary'),
        ),
        hasLength(1),
      );
      final original = api.reads.where((r) => r.$1.endsWith('/original-table'));
      expect(original.map((r) => r.$2['page']), [1, 2, 3]);
      expect(original.every((r) => r.$2['size'] == 100), isTrue);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'failed material tail publishes no partial set and explicit retry restarts at one',
    (tester) async {
      final api = _Api()..failSecond = true;
      await _mount(tester, api, (context) {
        unawaited(showFinanceMaterialContextPicker(context));
      });
      const key = 'finance.material-context.picker.v1';
      expect(_value(tester, key).items, isEmpty);
      expect(api.reads.map((r) => r.$2['page']), [1, 2]);
      api.failSecond = false;
      _value(tester, key).onRetry!();
      await tester.pumpAndSettle();
      expect(_value(tester, key).items, hasLength(251));
      expect(api.reads.map((r) => r.$2['page']), [1, 2, 1, 2, 3]);
    },
  );

  testWidgets(
    'held material tail retires on opaque cover and returns through one fresh full read',
    (tester) async {
      final api = _Api()..second = Completer<Map<String, dynamic>>();
      await _mount(tester, api, (context) {
        unawaited(showFinanceMaterialContextPicker(context));
      }, held: true);
      expect(api.reads, hasLength(2));
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      final covering = navigator.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('覆盖页'))),
      );
      await tester.pumpAndSettle();
      final old = api.page('/finance/material-statements', 2, 100);
      final pending = api.second!;
      api.second = null;
      api.version = 2;
      pending.complete(old);
      await tester.pumpAndSettle();
      expect(api.reads, hasLength(2));
      navigator.pop();
      await covering;
      await tester.pumpAndSettle();
      final table = _value(tester, 'finance.material-context.picker.v1');
      expect(table.items, hasLength(251));
      expect(table.items.every((row) => row['version'] == 38), isTrue);
      expect(api.reads.map((r) => r.$2['page']), [1, 2, 1, 2, 3]);
      expect(api.writes, isEmpty);
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <(String, Map<String, dynamic>)>[];
  final readBodies = <Object?>[];
  final writes = <String>[];
  bool failSecond = false;
  bool denyDirectory = false;
  int version = 1;
  Completer<Map<String, dynamic>>? second;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final parameters = Map<String, dynamic>.from(query ?? {});
    reads.add((path, parameters));
    if (denyDirectory &&
        const {
          '/finance/auxiliary-items',
          '/finance/material-statements',
        }.contains(path)) {
      throw ApiException('FORBIDDEN', '当前目录无权限', httpStatus: 403);
    }
    if (path == '/finance/open-item-classifications/sources/ledger-original') {
      return {
        'ledgerId': 'ledger-original',
        'direction': 'AP',
        'revision': 17,
        'sourceVerified': true,
        'effectiveFrom': '2026-10-01',
        'amountOriginalExact': _exact,
        'amountLocalExact': '0.0001',
        'parts': <Object>[],
        'payments': <Object>[],
        'offsets': <Object>[],
      };
    }
    if (path.endsWith('/reviews/review-250') ||
        path.endsWith('/reviews/review-250/summary')) {
      return {
        'id': 'review-250',
        'status': 'SUBMITTED',
        'document_sha256': 'sha-review-250',
        'submitted_name': '原提交人',
      };
    }
    final number = int.parse('${parameters['page'] ?? 1}');
    final size = int.parse('${parameters['size'] ?? 100}');
    if (number == 2 && path == '/finance/material-statements') {
      if (failSecond) {
        throw ApiException('TEMPORARY', '后批暂不可读', httpStatus: 503);
      }
      if (second != null) return second!.future;
    }
    return page(path, number, size, kind: parameters['kind']?.toString());
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path.endsWith('/reviews/query')) {
      final parameters = Map<String, dynamic>.from(query ?? {});
      reads.add((path, parameters));
      readBodies.add(body);
      return page(path, parameters['page'] as int, parameters['size'] as int);
    }
    writes.add(path);
    throw StateError(
      'These fixtures authorize read-only selection, not mutations',
    );
  }

  Map<String, dynamic> page(String path, int number, int size, {String? kind}) {
    final rows = <Map<String, dynamic>>[
      for (var i = (number - 1) * size; i < number * size && i < 251; i++)
        switch (path) {
          '/finance/auxiliary-items' => {
            'id': 'aux-$i',
            'sourceCode': '原项目$i',
            'sourceName': '原名称$i',
            'role': 'CUSTOMER',
            'status': 'ACTIVE',
            'version': 36 + version,
          },
          '/finance/material-statements' => {
            'id': 'material-$i',
            'state': i == 0 ? 'DRAFT' : 'APPROVED',
            'auxiliaryName': '原往来$i',
            'productNameCaption': '原产品$i',
            'actualCurrencyId': 'actual-usd-original',
            'accountingCurrencyId': 'book-cny-original',
            'partyId': 'party-$i',
            'partyRole': 'SUPPLIER',
            'amountExact': _exact,
            'version': 36 + version,
          },
          '/finance/open-item-classifications' => {
            'ledgerId': 'ledger-$i',
            'billNo': '来源单$i',
            'currencyId': 'currency-original',
          },
          '/finance/open-item-classifications/sources/ledger-original/references' =>
            kind == 'cash'
                ? {
                    'paymentLineId': 'cash-$i',
                    'billNo': '收付款$i',
                    'classificationId': null,
                  }
                : {
                    'offsetId': 'offset-$i',
                    'sourceLedgerId': 'ledger-original',
                    'targetLedgerId': 'other-$i',
                    'classificationId': null,
                  },
          '/finance/procurement-payable-recognitions/candidates' => {
            'id': 'candidate-$i',
            'billNo': '采购来源$i',
            'supplierId': 'supplier-original',
            'currencyId': 'currency-original',
            'sourceFingerprint': 'original-fingerprint-$i',
            'amountOriginal': _exact,
            'amountLocal': '0.0001',
          },
          '/finance/procurement-payable-recognitions' => {
            'id': 'recognition-$i',
            'status': 'APPROVED',
            'fileName': '确认件$i',
          },
          '/finance/statement-documents/reviews/query' => {
            'id': 'review-$i',
            'status': 'SUBMITTED',
            'document_sha256': 'sha-review-$i',
          },
          '/finance/statement-documents/profiles' => {
            'id': 'profile-$kind-$i',
            'revision': 251 - i,
            'status': 'APPROVED',
          },
          '/finance/statement-documents/reviews/review-250/original-table' => {
            'caption': '原件行$i',
            'amountExact': _exact,
            'amount': _exact,
          },
          _ => throw StateError('Unexpected fixture read: $path'),
        },
    ];
    return {
      path.endsWith('/original-table') ? 'rows' : 'items': rows,
      'page': number,
      'size': size,
      'total': 251,
      'totalPages': (251 / size).ceil(),
      if (path.endsWith('/original-table')) ...{
        'columns': [
          {'key': 'caption', 'label': '原件行'},
          {'key': 'amount', 'label': '原金额', 'type': 'money'},
        ],
        'documentMetadata': {
          'reviewId': 'review-250',
          'documentSha256': 'sha-review-250',
          'headerLines': [
            {'label': '页头', 'value': '保留完整原件页头'},
          ],
          'footerLines': <Object>[],
        },
        'totals': <Object>[],
      },
    };
  }
}
