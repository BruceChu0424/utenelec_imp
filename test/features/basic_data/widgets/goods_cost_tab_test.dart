import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_cost_sheet.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_cost_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_cost_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Map<String, dynamic> _input() => {
  'goodsId': 'product',
  'name': '80N 内部成本',
  'batchQty': '1000',
  'currencyId': 'cny',
  'exchangeRateToLocal': '1',
  'effectiveDate': '2026-09-29',
  'usageStrategy': 'ACTUAL_FIRST',
  'priceStrategy': 'APPROVED_PURCHASE',
  'lineOverrides': <Object>[],
  'fees': <Object>[],
  'priceColumns': <Object>[],
  'priceCells': <Object>[],
  'extraFields': <String, String>{},
};
Map<String, dynamic> _calculation({String total = '6337.3207'}) => {
  'goodsId': 'product',
  'goodsName': '80N 玻璃开关',
  'currencyName': 'CNY',
  'contentDigest': 'receipt-1',
  'lines': [
    for (final path in ['edge-a', 'edge-b'])
      {
        'id': path,
        'path': path,
        'depth': 0,
        'goodsId': 'same-material',
        'goodsName': '按钮',
        'goodsCode': 'A001',
        'colorName': '白色',
        'unitName': '个',
        'designQty': '2',
        'actualQty': path == 'edge-a' ? '2.123456' : null,
        'adoptedQty': path == 'edge-a' ? '2.123456' : '2',
        'usageBasis': path == 'edge-a' ? 'ACTUAL' : 'DESIGN',
        'usageReason': '已核清生产使用量',
        'sampleCount': 4,
        'batchQty': '2123.456',
        'unitPrice': '0.123456789123456',
        'amount': '262.155059',
        'unitContribution': '0.262155059',
        'included': true,
        'valueState': 'COMPLETE',
        'priceEvidence': {
          'sourceType': 'APPROVED_PURCHASE',
          'sourceNumber': 'PO-001',
        },
        'extraCosts': <String, dynamic>{},
      },
  ],
  'fees': <Object>[],
  'issues': <Object>[],
  'totals': {
    'material': total,
    'process': '0',
    'management': '0',
    'knownTotal': total,
    'unitCost': '6.3373207',
    'valueState': 'COMPLETE',
  },
};

class _Costs extends Fake implements GoodsCostRepository {
  Map<String, dynamic>? saved;
  int previewCalls = 0;
  bool defer = false;
  final pending = <Completer<GoodsCostCalculation>>[];
  GoodsCostSheet sheet({Map<String, dynamic>? input, int version = 3}) =>
      GoodsCostSheet({
        'id': 'sheet-a',
        'sheetNo': 'CB-001',
        'status': 'DRAFT',
        'version': version,
        'input': input ?? _input(),
        'calculation': _calculation(),
        'canEdit': true,
        'canConfirm': true,
        'canExport': true,
      });
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async => [
    {'id': 'sheet-a', 'name': '80N 内部成本', 'status': 'DRAFT', 'version': 3},
  ];
  @override
  Future<GoodsCostSheet> detail(String id) async => sheet();
  @override
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  ) async => [];
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) {
    previewCalls++;
    if (defer) {
      final c = Completer<GoodsCostCalculation>();
      pending.add(c);
      return c.future;
    }
    return Future.value(
      GoodsCostCalculation(_calculation(total: '7777.123456')),
    );
  }

  @override
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  }) async {
    expect(id, 'sheet-a');
    expect(expectedVersion, 3);
    saved = copyCostJson(input);
    return sheet(input: input, version: 4);
  }

  @override
  Future<Map<String, dynamic>> actual(
    String goodsId,
    Map<String, dynamic> filters,
  ) async => {
    'summary': {
      'knownInputCostLocal': '12.123456789123456789',
      'allocatedOutputCostLocal': '10',
      'actualUnitCostLocal': '1',
      'outputQtyBase': '10',
      'fullCostComplete': false,
    },
    'costObjects': <Object>[],
    'inputs': <Object>[],
    'outputs': <Object>[],
    'gaps': <Object>[],
    'filter': filters,
    'contentDigest': 'actual-1',
  };
}

class _ProjectedCosts extends _Costs {
  Map<String, dynamic> initial() => {
    ..._input(),
    'priceColumns': [
      {
        'key': 'inspect',
        'name': '检验费',
        'type': 'PER_QUANTITY',
        'category': 'PROCESS',
        'baseKeys': ['MATERIAL'],
      },
    ],
    'priceCells': [
      {'path': 'edge-a', 'columnKey': 'inspect', 'value': '0.02'},
    ],
  };
  Map<String, dynamic> result(Map<String, dynamic> input) => {
    ..._calculation(),
    'fees': [
      for (final cell in costMaps(input['priceCells']))
        {
          'key': 'COLUMN:inspect:edge-a',
          'name': '检验费',
          'type': 'PER_QUANTITY',
          'category': 'PROCESS',
          'targetPath': 'edge-a',
          'value': cell['value'],
          'quantity': cell['quantity'],
          'baseKeys': ['MATERIAL'],
          'amount': '40',
          'source': 'PRICE_COLUMN',
        },
    ],
  };
  @override
  GoodsCostSheet sheet({Map<String, dynamic>? input, int version = 3}) =>
      GoodsCostSheet({
        ...super.sheet(input: input ?? initial(), version: version).json,
        'calculation': result(input ?? initial()),
      });
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async =>
      GoodsCostCalculation(result(input));
}

/// A self-consistent synthetic fixture for the rendered UI artifact only.
/// It is deliberately labelled as a test example, never company actual usage.
class _RenderCosts extends _Costs {
  @override
  GoodsCostSheet sheet({Map<String, dynamic>? input, int version = 3}) {
    final data = super.sheet(input: input, version: version).json;
    data['sheetNo'] = 'CB-TEST';
    data['input'] = {
      ...costMap(data['input']),
      'name': '模拟测试样例',
      'notes': '数量与价格均为测试值，不代表真实实耗',
      'priceColumns': [
        {
          'key': 'inspect',
          'name': '检验费',
          'type': 'PER_QUANTITY',
          'category': 'PROCESS',
          'baseKeys': ['MATERIAL'],
        },
      ],
      'priceCells': [
        {'path': 'edge-a', 'columnKey': 'inspect', 'value': '0.02'},
      ],
    };
    final calculation = costMap(data['calculation']);
    final rows = costMaps(calculation['lines']);
    rows[0].addAll({
      'goodsId': 'test-a',
      'goodsName': '测试材料 A',
      'goodsCode': 'TEST-A',
      'unitPrice': '0.1',
      'batchQty': '2123.456',
      'amount': '254.81472',
      'materialAmount': '212.3456',
      'feeAmount': '42.46912',
      'extraCosts': {'inspect': '42.46912'},
      'unitContribution': '0.25481472',
    });
    rows[1].addAll({
      'goodsId': 'test-b',
      'goodsName': '测试材料 B',
      'goodsCode': 'TEST-B',
      'unitPrice': '0.1',
      'batchQty': '2000',
      'amount': '200',
      'unitContribution': '0.2',
    });
    calculation['lines'] = rows;
    calculation['fees'] = [
      {
        'key': 'COLUMN:inspect:edge-a',
        'name': '检验费',
        'type': 'PER_QUANTITY',
        'category': 'PROCESS',
        'targetPath': 'edge-a',
        'value': '0.02',
        'amount': '42.46912',
        'unitAmount': '0.04246912',
        'source': 'PRICE_COLUMN',
        'baseKeys': ['MATERIAL'],
      },
    ];
    calculation['totals'] = {
      ...costMap(calculation['totals']),
      'material': '412.3456',
      'process': '42.46912',
      'knownTotal': '454.81472',
      'unitCost': '0.45481472',
    };
    data['calculation'] = calculation;
    return GoodsCostSheet(data);
  }
}

class _ResumeCosts extends _Costs {
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async => [
    {'id': 'new-confirmed', 'status': 'CONFIRMED', 'name': 'newer confirmed'},
  ];
  @override
  Future<GoodsCostSheet> detail(String id) async => id == 'new-confirmed'
      ? GoodsCostSheet({
          ...sheet().json,
          'id': id,
          'status': 'CONFIRMED',
          'canEdit': false,
        })
      : sheet();
}

class _ResolvedCosts extends _Costs {
  Map<String, dynamic>? lastPreview;
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async => [];
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async {
    lastPreview = copyCostJson(input);
    return GoodsCostCalculation({
      ..._calculation(),
      'resolvedInput': {
        ...input,
        'batchQty': '999',
        'lineOverrides': <Object>[],
        'priceCells': <Object>[],
        'priceColumns': [
          {
            'key': 'auto-inspect',
            'name': '模板检验费',
            'type': 'PER_QUANTITY',
            'category': 'PROCESS',
            'baseKeys': ['MATERIAL'],
          },
        ],
        'extraFields': {
          ...costMap(input['extraFields']),
          'costAutoPriceColumnKeys': '["auto-inspect"]',
          'costTemplateVersions': '{"template":1}',
        },
      },
    });
  }
}

class _ImportedPriceCosts extends _Costs {
  Map<String, dynamic> initial() => {
    ..._input(),
    'lineOverrides': [
      {
        'path': 'edge-a',
        'adoptedQty': '2.123456',
        'unitPrice': '400',
        'priceUnitRate': '25',
        'priceExchangeRateToLocal': '1',
        'priceSourceType': 'MANUAL',
        'taxMode': 'AS_RECORDED',
        'reason': 'Imported per-bag price',
      },
    ],
  };
  Map<String, dynamic> result(Map<String, dynamic> input) {
    final result = _calculation();
    final rows = costMaps(result['lines']);
    final override = costMaps(
      input['lineOverrides'],
    ).where((r) => r['path'] == 'edge-a').firstOrNull;
    rows.first['unitName'] = 'kg';
    rows.first['unitPrice'] = (override?['priceUnitRate'] == '1')
        ? (override?['unitPrice'])
        : '16';
    result['lines'] = rows;
    result['currencyName'] = input['currencyId'] == 'usd' ? 'USD' : 'CNY';
    result['fees'] = [
      for (final fee in costMaps(input['fees']))
        {...fee, 'amount': fee['value']},
      for (final cell in costMaps(input['priceCells']))
        {
          'key': 'COLUMN:${cell['columnKey']}:${cell['path']}',
          'targetPath': cell['path'],
          'name': cell['columnKey'],
          'type': cell['columnKey'] == 'pct' ? 'PERCENT' : 'PER_QUANTITY',
          'category': 'PROCESS',
          'baseKeys': ['MATERIAL'],
          'value': cell['value'],
          'quantity': cell['quantity'],
          'amount': cell['value'],
          'source': 'PRICE_COLUMN',
        },
    ];
    return result;
  }

  @override
  GoodsCostSheet sheet({Map<String, dynamic>? input, int version = 3}) =>
      GoodsCostSheet({
        ...super.sheet(input: input ?? initial(), version: version).json,
        'calculation': result(input ?? initial()),
      });
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async =>
      GoodsCostCalculation(result(input));
}

class _CurrencyCosts extends _ImportedPriceCosts {
  bool failConversion = false;
  Map<String, dynamic>? conversionRequest, templateInput;
  @override
  Map<String, dynamic> initial() => {
    ...super.initial(),
    'fees': [
      {
        'key': 'fixed',
        'name': '固定费用',
        'type': 'FIXED_BATCH',
        'category': 'PROCESS',
        'value': '80',
        'quantity': '5',
        'source': 'MANUAL',
        'baseKeys': ['MATERIAL'],
      },
      {
        'key': 'percentage',
        'name': '比例费用',
        'type': 'PERCENT',
        'category': 'MANAGEMENT',
        'value': '12',
        'quantity': '3',
        'source': 'MANUAL',
        'baseKeys': ['MATERIAL'],
      },
    ],
    'priceColumns': [
      {
        'key': 'money',
        'name': '检验费',
        'type': 'PER_QUANTITY',
        'category': 'PROCESS',
        'baseKeys': ['MATERIAL'],
      },
      {
        'key': 'pct',
        'name': '管理比例',
        'type': 'PERCENT',
        'category': 'MANAGEMENT',
        'baseKeys': ['MATERIAL'],
      },
    ],
    'priceCells': [
      {'path': 'edge-a', 'columnKey': 'money', 'value': '40', 'quantity': '2'},
      {'path': 'edge-a', 'columnKey': 'pct', 'value': '12', 'quantity': '3'},
    ],
  };
  @override
  Future<Map<String, dynamic>> convertCurrency(
    Map<String, dynamic> input,
    String? targetCurrencyId,
    String targetExchangeRateToLocal,
  ) async {
    conversionRequest = {
      'input': copyCostJson(input),
      'targetCurrencyId': targetCurrencyId,
      'targetExchangeRateToLocal': targetExchangeRateToLocal,
    };
    if (failConversion) throw StateError('Conversion unavailable');
    final converted = copyCostJson(input)
      ..['currencyId'] = targetCurrencyId
      ..['exchangeRateToLocal'] = targetExchangeRateToLocal;
    final overrides = costMaps(converted['lineOverrides']);
    overrides.first.addAll({
      'unitPrice': '2',
      'priceUnitRate': '1',
      'priceExchangeRateToLocal': targetExchangeRateToLocal,
    });
    converted['lineOverrides'] = overrides;
    converted['fees'] = [
      for (final fee in costMaps(converted['fees']))
        {...fee, 'value': fee['type'] == 'PERCENT' ? fee['value'] : '10'},
    ];
    converted['priceCells'] = [
      for (final cell in costMaps(converted['priceCells']))
        {...cell, 'value': cell['columnKey'] == 'pct' ? cell['value'] : '5'},
    ];
    converted['extraFields'] = {
      ...costMap(converted['extraFields']),
      'costCurrencyConversion': 'CNY 1 to USD 8',
    };
    return {'input': converted, 'calculation': result(converted)};
  }

  @override
  Future<Map<String, dynamic>> saveTemplate(
    Map<String, dynamic> input,
    String idempotencyKey,
  ) async {
    templateInput = copyCostJson(input);
    return {'id': 'saved-template'};
  }
}

class _ForeignTemplateCosts extends _ImportedPriceCosts {
  Map<String, dynamic>? request;
  @override
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  ) async => [
    {
      'id': 'foreign-template',
      'input': {
        'name': '外币模板',
        'currencyId': 'usd',
        'exchangeRateToLocal': '8',
        'fees': [
          {
            'key': 'template-fixed',
            'name': '模板固定费',
            'type': 'FIXED_BATCH',
            'category': 'PROCESS',
            'value': '10',
            'source': 'MANUAL',
            'baseKeys': ['MATERIAL'],
          },
        ],
        'priceColumns': <Object>[],
      },
    },
  ];
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async {
    request = copyCostJson(input);
    final fee = {
      'key': 'template-fixed',
      'name': '模板固定费',
      'type': 'FIXED_BATCH',
      'category': 'PROCESS',
      'value': '80',
      'source': 'TEMPLATE:foreign-template:1',
      'baseKeys': ['MATERIAL'],
    };
    final resolved = {
      ...input,
      'fees': [fee],
    };
    return GoodsCostCalculation({
      ...result(resolved),
      'resolvedInput': resolved,
    });
  }
}

class _ExchangeCurrencies extends Fake implements CurrencyRepository {
  _ExchangeCurrencies({this.hasRate = true});
  final bool hasRate;
  @override
  Future<List<CurrencyListItem>> dict() async => [
    const CurrencyListItem(id: 'cny', name: 'CNY', baseCurrency: true),
    CurrencyListItem(
      id: 'usd',
      name: 'USD',
      exchangeRateText: hasRate ? '8' : null,
    ),
  ];
}

class _ActualEvidenceCosts extends _Costs {
  @override
  Future<Map<String, dynamic>> actual(
    String goodsId,
    Map<String, dynamic> filters,
  ) async => {
    ...await super.actual(goodsId, filters),
    'costObjects': [
      {
        'costObjectId': 'object-evidence',
        'executionNo': 'ZX-TEST',
        'revisionId': 'revision-1',
        'state': 'APPLYING',
        'pending': true,
        'pendingReasons': ['SOURCE_REFRESH_PENDING'],
      },
    ],
    'inputs': [
      {
        'costObjectId': 'object-evidence',
        'revisionId': 'revision-1',
        'inputNodeId': 'input-1',
        'valueRevision': 4,
        'sourceDocType': 'UNKNOWN_LEGACY',
        'sourceDocId': 'legacy-document-identifier',
        'sourceItemId': 'source-item-1',
        'amountBasis': 'MISSING_REVISION_EVIDENCE',
        'knownAmountLocal': null,
        'exactAmountLower': '12.01',
        'exactAmountUpper': '12.02',
        'pending': true,
      },
    ],
    'gaps': [
      {
        'code': 'ORIGINAL_INPUT_IDENTITY_MISSING',
        'costObjectId': 'object-evidence',
        'sourceId': 'input-1',
      },
      {
        'code': 'INPUT_REVISION_EVIDENCE_MISSING',
        'costObjectId': 'object-evidence',
        'sourceId': 'input-1',
      },
    ],
  };
}

class _CostPlatform extends Fake implements PlatformTableRepository {
  @override
  Future<List<PlatformTableCapabilities>> scopes() async => const [
    PlatformTableCapabilities(
      scope: 'view_goods_cost',
      priceVisible: true,
      supportsValues: false,
      facts: [
        PlatformTableFact(key: 'value', name: 'value', priceProtected: true),
        PlatformTableFact(key: 'quantity', name: 'quantity'),
        PlatformTableFact(key: 'amount', name: 'amount', priceProtected: true),
      ],
    ),
  ];
  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async => [];
}

class _Currencies extends Fake implements CurrencyRepository {
  @override
  Future<List<CurrencyListItem>> dict() async => [
    const CurrencyListItem(id: 'cny', name: 'CNY', baseCurrency: true),
  ];
}

Future<void> _pump(
  WidgetTester tester,
  _Costs repo, {
  Size size = const Size(1800, 1200),
  bool costView = true,
  bool costExport = true,
  CurrencyRepository? currencies,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsCostRepositoryProvider.overrideWithValue(repo),
        platformTableRepositoryProvider.overrideWithValue(_CostPlatform()),
        currencyRepositoryProvider.overrideWithValue(
          currencies ?? _Currencies(),
        ),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue({
          if (costView) Perm.goodsCostView,
          Perm.goodsEdit,
          Perm.goodsView,
          Perm.goodsExport,
          Perm.goodsCostEdit,
          Perm.goodsCostConfirm,
          if (costExport) Perm.goodsCostExport,
          Perm.goodsCostTemplate,
        }),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const Scaffold(
          body: RepaintBoundary(
            key: Key('cost-render'),
            child: Material(
              child: GoodsCostTab(
                detail: GoodsDetail(
                  id: 'product',
                  name: '80N 玻璃开关',
                  code: '80N',
                  status: '使用',
                ),
                canEdit: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  test(
    'same goods on distinct BOM paths keeps overrides and exact decimals independent',
    () {
      final input = updateCostOverride(_input(), 'edge-a', {
        'adoptedQty': '0.000007123456',
        'unitPrice': '16.123456789123456789',
      });
      final updated = updateCostOverride(input, 'edge-b', {'adoptedQty': '2'});
      expect(costMaps(updated['lineOverrides']).length, 2);
      expect(
        costMaps(updated['lineOverrides']).first['unitPrice'],
        '16.123456789123456789',
      );
    },
  );
  test(
    'fee missing, zero and not applicable remain different persisted facts',
    () {
      var input = updateCostPriceCell(_input(), 'edge-a', 'inspect', '');
      expect(costMaps(input['priceCells']).single['value'], '');
      input = updateCostPriceCell(input, 'edge-a', 'inspect', '0');
      expect(costMaps(input['priceCells']).single['value'], '0');
      input = updateCostPriceCell(
        input,
        'edge-a',
        'inspect',
        null,
        applicable: false,
      );
      expect(costMaps(input['priceCells']), isEmpty);
    },
  );
  testWidgets(
    'shows cost-only tabs, distinct identity columns and one visible line per material cell',
    (tester) async {
      await _pump(tester, _Costs());
      expect(find.text('成本测算'), findsOneWidget);
      expect(find.text('实际核对'), findsOneWidget);
      expect(find.text('成本版本'), findsOneWidget);
      expect(find.text('报价'), findsNothing);
      expect(find.text('售价'), findsNothing);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>).first,
      );
      expect(
        table.columns.map((c) => c.key),
        containsAll([
          'goodsName',
          'goodsCode',
          'designQty',
          'actualQty',
          'adoptedQty',
          'unitPrice',
          'amount',
        ]),
      );
      expect(find.textContaining('6337.3207'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'saving exact adopted quantity uses cost endpoint and stable occurrence identity',
    (tester) async {
      final repo = _Costs();
      await _pump(tester, repo);
      await tester.enterText(
        find.byKey(const ValueKey('cost-adoptedQty-edge-a')),
        '0.000007123456',
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(costMaps(repo.saved?['lineOverrides']).single['path'], 'edge-a');
      expect(
        costMaps(repo.saved?['lineOverrides']).single['adoptedQty'],
        '0.000007123456',
      );
      expect(repo.saved!.containsKey('cTotal'), isFalse);
      expect(repo.saved!.containsKey('price'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('late recalculation cannot replace a newer user input or total', (
    tester,
  ) async {
    final repo = _Costs();
    await _pump(tester, repo);
    repo.defer = true;
    await tester.enterText(
      find.byKey(const ValueKey('cost-header-batchQty')),
      '101',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(
      find.byKey(const ValueKey('cost-header-batchQty')),
      '102',
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(repo.pending.length, 2);
    repo.pending[1].complete(
      GoodsCostCalculation(_calculation(total: '9999.876543')),
    );
    await tester.pump();
    repo.pending[0].complete(GoodsCostCalculation(_calculation(total: '1111')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('cost-header-batchQty')),
          )
          .controller!
          .text,
      '102',
    );
    expect(find.textContaining('9999.876543'), findsWidgets);
    expect(find.textContaining('1111'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    '375px remains a horizontally scrollable table without overflow',
    (tester) async {
      await _pump(tester, _Costs(), size: const Size(375, 900));
      expect(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('price-only permissions never expose stored cost values', (
    tester,
  ) async {
    await _pump(tester, _Costs(), costView: false);
    expect(find.text('没有成本查看权限'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.textContaining('6337'), findsNothing);
  });
  testWidgets(
    'adding a price column saves only the chosen occurrence and no duplicate fee row',
    (tester) async {
      final repo = _Costs();
      await _pump(tester, repo);
      await tester.ensureVisible(find.byKey(const Key('cost-add-column')));
      await tester.tap(find.byKey(const Key('cost-add-column')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-column-name')), '检验费');
      await tester.tap(find.byKey(const Key('cost-column-create')));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>).first,
      );
      final key = table.columns
          .firstWhere((c) => c.key.startsWith('fee:'))
          .key
          .substring(4);
      await tester.enterText(
        find.byKey(ValueKey('cost-fee-$key-edge-a')),
        '0.02',
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(costMaps(repo.saved?['priceColumns']).single['name'], '检验费');
      expect(costMaps(repo.saved?['priceCells']).single['path'], 'edge-a');
      expect(costMaps(repo.saved?['priceCells']).single['value'], '0.02');
      expect(costMaps(repo.saved?['fees']), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'subcontract loss policy refuses database-rounding input before save',
    (tester) async {
      await _pump(tester, _Costs());
      await tester.ensureVisible(find.text('委外允许损耗'));
      await tester.tap(find.text('委外允许损耗'));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(input, '100.001');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').contains('最多2位小数'),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'actual costs retain decimal evidence and never claim complete total variance',
    (tester) async {
      await _pump(tester, _Costs());
      await tester.tap(find.byKey(const ValueKey('cost-tab-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('12.123456789123456789'), findsWidgets);
      expect(find.text('尚未覆盖全部人工及间接费用'), findsOneWidget);
      expect(find.text('同口径成本差额'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'flat fees edit the same price cell without persisting a second charge',
    (tester) async {
      final repo = _ProjectedCosts();
      await _pump(tester, repo);
      await tester.ensureVisible(find.text('工序与费用'));
      await tester.tap(find.text('工序与费用'));
      await tester.pumpAndSettle();
      final input = find.byKey(
        const ValueKey('cost-fee-row-COLUMN:inspect:edge-a-value'),
      );
      final grid = tester.widget<UtenEditableGrid<GoodsCostFeeRow>>(
        find.byWidgetPredicate((w) => w is UtenEditableGrid<GoodsCostFeeRow>),
      );
      final binding = grid.platformBinding!;
      final row = grid.controller.rows.single;
      expect(binding.scope, 'view_goods_cost');
      expect(binding.recordIdOf(row), isNull);
      expect(binding.factValuesOf!(row)['value'], '0.02');
      expect(binding.factValuesOf!(row)['amount'], '40');
      var resultChanges = 0;
      void changed() => resultChanges++;
      final signal = binding.factListenablesOf!(row).last;
      signal.addListener(changed);
      await tester.enterText(input, '0.03');
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      expect(binding.factValuesOf!(row)['value'], '0.03');
      expect(resultChanges, greaterThan(0));
      signal.removeListener(changed);
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(costMaps(repo.saved?['fees']), isEmpty);
      expect(costMaps(repo.saved?['priceCells']).single['value'], '0.03');
      expect(costMaps(repo.saved?['priceCells']).single['quantity'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cost view permission alone does not expose export actions', (
    tester,
  ) async {
    await _pump(tester, _Costs(), costExport: false);
    expect(find.text('成本测算'), findsOneWidget);
    expect(find.text('下载成本 Excel'), findsNothing);
    expect(find.text('下载成本 PDF'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'automatic template columns appear before saving and resolved input preserves typed quantities',
    (tester) async {
      final repo = _ResolvedCosts();
      await _pump(tester, repo);
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget<MasterDataTableView<Map<String, dynamic>>>(
            find.byType(MasterDataTableView<Map<String, dynamic>>).first,
          );
      expect(table().columns.any((c) => c.key == 'fee:auto-inspect'), isTrue);
      expect(repo.saved, isNull);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-header-batchQty')),
            )
            .controller!
            .text,
        '1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('cost-adoptedQty-edge-a')),
        '0.000007123456',
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-adoptedQty-edge-a')),
            )
            .controller!
            .text,
        '0.000007123456',
      );
      expect(
        costMaps(repo.lastPreview?['lineOverrides']).single['adoptedQty'],
        '0.000007123456',
      );
      expect(
        costMetadataKeys(
          costMap(repo.lastPreview?['extraFields'])['costAutoPriceColumnKeys'],
        ),
        {'auto-inspect'},
      );
      await tester.ensureVisible(find.byKey(const Key('cost-add-column')));
      await tester.tap(find.byKey(const Key('cost-add-column')));
      await tester.pumpAndSettle();
      final reuse = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '搜索已有费用列',
        ),
      );
      reuse.onChanged('auto-inspect');
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('cost-column-name')),
        '本单特殊检验',
      );
      await tester.tap(find.byKey(const Key('cost-column-create')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      expect(
        table().columns.firstWhere((c) => c.key == 'fee:auto-inspect').label,
        '本单特殊检验',
      );
      expect(
        costMetadataKeys(
          costMap(repo.lastPreview?['extraFields'])['costAutoPriceColumnKeys'],
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unified basic-data draft page resumes the cost tab through its goods detail deep link',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final storage = MemoryFormDraftStorage();
      final repo = _ResumeCosts();
      final container = ProviderContainer(
        overrides: [
          goodsCostRepositoryProvider.overrideWithValue(repo),
          currencyRepositoryProvider.overrideWithValue(_Currencies()),
          sharedPreferencesProvider.overrideWithValue(prefs),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'cost-user'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.goodsView,
            Perm.materialCategoryView,
            Perm.goodsCostView,
            Perm.goodsCostEdit,
            Perm.goodsCostExport,
          }),
          apiBaseUrlProvider.overrideWithValue('https://cost-draft.test/api'),
          formDraftStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      final spec = FormDraftCatalog.goodsCost.spec(
        title: '待恢复成本方案',
        route: '/basicinfo/goods/product?tab=cost',
      );
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      await store.save(
        FormDraft(
          id: 'cost-draft',
          title: spec.title,
          module: spec.module,
          route: spec.route,
          permission: spec.permission,
          draftKind: spec.draftKind,
          updatedAt: DateTime.utc(2026, 9, 29),
          data: {
            'goodsId': 'product',
            'sheetId': 'sheet-a',
            'serverVersion': 3,
            'idempotencyKey': 'restored-key',
            'input': {..._input(), 'batchQty': '777'},
          },
        ),
      );
      final router = GoRouter(
        initialLocation: '/form-drafts/basicinfo',
        routes: [
          DraftAwareGoRoute(
            path: '/form-drafts/:categoryId',
            builder: (_, state) =>
                FormDraftsPage(categoryId: state.pathParameters['categoryId']!),
          ),
          DraftAwareGoRoute(
            path: '/basicinfo/goods/:id',
            builder: (_, state) {
              expect(state.uri.queryParameters['tab'], 'cost');
              return Scaffold(
                body: GoodsCostTab(
                  detail: GoodsDetail(
                    id: state.pathParameters['id']!,
                    name: '恢复测试',
                    status: '使用',
                  ),
                  canEdit: false,
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildLightTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('待恢复成本方案'), findsWidgets);
      await tester.tap(find.text('待恢复成本方案').first);
      await tester.pumpAndSettle();
      // Master tables use a double tap to open a record; plain local-draft rows
      // may expose their direct Open action instead of row navigation.
      if (find
          .byKey(const ValueKey('cost-header-batchQty'))
          .evaluate()
          .isEmpty) {
        await tester.tap(find.text('待恢复成本方案').first);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.text('待恢复成本方案').first);
        await tester.pumpAndSettle();
      }
      expect(
        GoRouterState.of(
          tester.element(find.byType(GoodsCostTab)),
        ).uri.queryParameters['draftId'],
        'cost-draft',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-header-batchQty')),
            )
            .controller!
            .text,
        '777',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'imported 400 per 25kg displays normalized 16 and editing 20 uses per-kg price',
    (tester) async {
      final repo = _ImportedPriceCosts();
      await _pump(tester, repo);
      final field = find.byKey(const ValueKey('cost-unitPrice-edge-a'));
      expect(tester.widget<TextFormField>(field).controller!.text, '16');
      await tester.enterText(field, '20');
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      final override = costMaps(repo.saved?['lineOverrides']).single;
      expect(override['unitPrice'], '20');
      expect(override['priceUnitRate'], '1');
      expect(override['priceExchangeRateToLocal'], '1');
      expect(override['taxMode'], 'AS_RECORDED');
      expect(override['adoptedQty'], '2.123456');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'currency conversion adopts server money but preserves quantities and percentage values',
    (tester) async {
      final repo = _CurrencyCosts();
      await _pump(tester, repo, currencies: _ExchangeCurrencies());
      final quantity = tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('cost-header-batchQty')),
          )
          .controller!;
      final price = tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('cost-unitPrice-edge-a')),
          )
          .controller!;
      await tester.tap(find.text('工序与费用'));
      await tester.pumpAndSettle();
      final feeQuantity = tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('cost-fee-row-fixed-quantity')),
          )
          .controller!;
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('cost-fee-row-fixed-quantity')),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('cost-fee-row-percentage-quantity'),
                ),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        isTrue,
      );
      final selector = tester.widget<UtenDropdownField>(
        find.byKey(const Key('cost-currency-selector')),
      );
      selector.onChanged('usd');
      await tester.pumpAndSettle();
      expect(repo.conversionRequest, isNull);
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('cost-currency-selector')),
            )
            .value,
        'cny',
      );
      await tester.tap(find.byKey(const Key('cost-currency-convert-confirm')));
      await tester.pumpAndSettle();
      expect(repo.conversionRequest?['targetExchangeRateToLocal'], '8');
      expect(costMap(repo.conversionRequest?['input'])['currencyId'], 'cny');
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('cost-currency-selector')),
            )
            .value,
        'usd',
      );
      expect(quantity.text, '1000');
      expect(feeQuantity.text, '5');
      expect(price.text, '2');
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-fee-row-fixed-quantity')),
            )
            .controller,
        same(feeQuantity),
      );
      await tester.ensureVisible(find.text('保存为成本模板'));
      await tester.tap(find.text('保存为成本模板'));
      await tester.pumpAndSettle();
      expect(repo.templateInput?['currencyId'], 'usd');
      expect(repo.templateInput?['exchangeRateToLocal'], '8');
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(repo.saved?['currencyId'], 'usd');
      expect(repo.saved?['batchQty'], '1000');
      final fees = {for (final f in costMaps(repo.saved?['fees'])) f['key']: f};
      expect(fees['fixed']!['value'], '10');
      expect(fees['fixed']!['quantity'], '5');
      expect(fees['percentage']!['value'], '12');
      final cells = {
        for (final c in costMaps(repo.saved?['priceCells'])) c['columnKey']: c,
      };
      expect(cells['money']!['value'], '5');
      expect(cells['money']!['quantity'], '2');
      expect(cells['pct']!['value'], '12');
      expect(cells['pct']!['quantity'], '3');
      expect(
        costMap(repo.saved?['extraFields'])['costCurrencyConversion'],
        'CNY 1 to USD 8',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'foreign conversion without a rate cannot submit and failure retains the source currency',
    (tester) async {
      final repo = _CurrencyCosts()..failConversion = true;
      await _pump(
        tester,
        repo,
        currencies: _ExchangeCurrencies(hasRate: false),
      );
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('cost-currency-selector')),
          )
          .onChanged('usd');
      await tester.pumpAndSettle();
      final rate = find.byKey(const Key('cost-convert-target-rate'));
      expect(tester.widget<TextFormField>(rate).controller!.text, isEmpty);
      await tester.tap(find.byKey(const Key('cost-currency-convert-confirm')));
      await tester.pumpAndSettle();
      expect(repo.conversionRequest, isNull);
      await tester.enterText(rate, '8');
      await tester.tap(find.byKey(const Key('cost-currency-convert-confirm')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('cost-currency-selector')),
            )
            .value,
        'cny',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-unitPrice-edge-a')),
            )
            .controller!
            .text,
        '16',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('cost-header-exchangeRateToLocal')),
            )
            .controller!
            .text,
        '1',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'selecting a foreign template does not copy its unconverted money as a manual override',
    (tester) async {
      final repo = _ForeignTemplateCosts();
      await _pump(tester, repo, currencies: _ExchangeCurrencies());
      tester
          .widget<UtenDropdownField>(
            find.byWidgetPredicate(
              (w) => w is UtenDropdownField && w.label == '成本模板',
            ),
          )
          .onChanged('foreign-template');
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      expect(costMaps(repo.request?['fees']), isEmpty);
      await tester.tap(find.text('工序与费用'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-fee-row-template-fixed-value')),
            )
            .controller!
            .text,
        '80',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'actual missing evidence has actionable gaps and copyable source facts without guessed navigation',
    (tester) async {
      await _pump(tester, _ActualEvidenceCosts());
      await tester.tap(find.byKey(const ValueKey('cost-tab-1')));
      await tester.pumpAndSettle();
      expect(find.text('legacy-document-identifier'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('cost-actual-pending')));
      await tester.tap(find.byKey(const Key('cost-actual-pending')));
      await tester.pumpAndSettle();
      expect(find.text('历史物料身份或单位缺失'), findsWidgets);
      expect(find.text('投入来源的修订证据缺失'), findsWidgets);
      expect(find.text('来源数据待刷新'), findsWidgets);
      await tester.tap(find.text('返回').last);
      await tester.pumpAndSettle();
      final source = find.byKey(
        const ValueKey('cost-actual-source-legacy-document-identifier'),
      );
      await tester.ensureVisible(source);
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cost-actual-evidence')), findsOneWidget);
      expect(find.text('12.01'), findsWidgets);
      expect(find.text('12.02'), findsWidgets);
      expect(find.text('legacy-document-identifier'), findsWidgets);
      expect(find.text('当前没有可打开的来源入口，可复制标识交由负责岗位核对。'), findsOneWidget);
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final copy = find.byKey(const ValueKey('cost-actual-copy-sourceDocId'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, 'legacy-document-identifier');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('renders reviewable fixture screenshot', (tester) async {
    await _pump(tester, _RenderCosts(), size: const Size(1680, 1200));
    expect(
      tester.getRect(find.text('单件成本').first).right,
      lessThanOrEqualTo(1680),
    );
    expect(
      tester.getRect(find.text('本批成本').first).right,
      lessThanOrEqualTo(1680),
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey('cost-fee-inspect-edge-a')))
          .right,
      lessThanOrEqualTo(1680),
    );
    expect(find.textContaining('454.81472'), findsWidgets);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('cost-render')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/cost-workspace-widget-preview.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
