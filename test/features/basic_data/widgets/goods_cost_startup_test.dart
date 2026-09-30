import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_cost_sheet.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_cost_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_cost_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _StartupCosts extends Fake implements GoodsCostRepository {
  bool confirmed = false;
  int previews = 0, saves = 0;
  GoodsCostCalculation get result => GoodsCostCalculation({
    'lines': <Object>[],
    'fees': <Object>[],
    'issues': <Object>[],
    'totals': {'valueState': 'COMPLETE', 'knownTotal': '10', 'unitCost': '2'},
  });
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async => [
    {'id': 'sheet'},
  ];
  @override
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  ) async => [];
  @override
  Future<GoodsCostSheet> detail(String id) async => GoodsCostSheet({
    'id': 'sheet',
    'version': 7,
    'sheetNo': 'CB0001',
    'status': confirmed ? 'CONFIRMED' : 'DRAFT',
    'canEdit': !confirmed,
    'canConfirm': false,
    'canExport': false,
    'input': {
      'goodsId': 'goods',
      'name': '成本单',
      'batchQty': '5',
      'exchangeRateToLocal': '1',
    },
    'calculation': result.json,
  });
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async {
    previews++;
    return result;
  }

  @override
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  }) async {
    saves++;
    expect(id, 'sheet');
    expect(expectedVersion, 7);
    throw ApiException('VALIDATION_ERROR', '测算数量必须大于零');
  }
}

class _StartupCurrencies extends Fake implements CurrencyRepository {
  @override
  Future<List<CurrencyListItem>> dict() async => [];
}

Future<void> _pump(WidgetTester tester, _StartupCosts costs) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsCostRepositoryProvider.overrideWithValue(costs),
        currencyRepositoryProvider.overrideWithValue(_StartupCurrencies()),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(null),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsCostView,
          Perm.goodsCostEdit,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GoodsCostTab(
            detail: GoodsDetail(id: 'goods', name: '货品'),
            canEdit: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'startup confirmed cost is read-only without recomputing historical evidence',
    (tester) async {
      final costs = _StartupCosts()..confirmed = true;
      await _pump(tester, costs);
      expect(costs.previews, 0);
      expect(find.byKey(const Key('cost-save')), findsNothing);
      final input = find.descendant(
        of: find.byKey(const ValueKey('cost-header-batchQty')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(input).readOnly, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cost save validation retains entered quantity and reports the server reason',
    (tester) async {
      final costs = _StartupCosts();
      await _pump(tester, costs);
      await tester.enterText(
        find.byKey(const ValueKey('cost-header-batchQty')),
        '-1',
      );
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(costs.saves, 1);
      expect(find.text('测算数量必须大于零'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-header-batchQty')),
            )
            .controller!
            .text,
        '-1',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
