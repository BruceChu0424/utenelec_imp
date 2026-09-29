// 称重计数弹窗契约 (ADR-135 §6.2, review/product.md §1.2):
//  1. 单重未学准: 「填入数量」禁用, 录入 >= 10 件同批抽样后放开, 抽样存成 SAMPLE (带到货供应商);
//  2. 到货: 主按钮「只记重量」不改数量; 「按称重改数量」带「影响对账」提示并按件取整;
//  3. 多次称重相加、扣皮重 x 件数;
//  4. 出库反推「需要 N 个 -> 秤上应显示约」, 只回填重量;
//  5. 弹窗从不调用过账接口, 回填由 applyWeighCountResult 写进行控制器。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/widgets/weigh_count_dialog.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  final posts = <(String, Object?)>[];
  final puts = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, body));
    if (path.endsWith('/samples')) {
      return {
        'goodsId': 'g1',
        'resolved': {'key': 'g1|', 'basis': 'LEARNED', 'tier': 'YELLOW'},
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    puts.add((path, body));
    return {};
  }
}

const _learned = WeightParams(
  key: 'g1|sup-A',
  goodsId: 'g1',
  basis: WeightBasis.learned,
  supplierSpecific: true,
  logMean: -6.214979467174846,
  lotPrior: 3.869930380683166e-05,
  df: 15,
  tier: WeightTier.yellow,
  nInliers: 12,
  tolerancePct: 3,
  baseUnitDimension: 'COUNT',
);

const _red = WeightParams(
  key: 'g1|sup-A',
  goodsId: 'g1',
  basis: WeightBasis.learned,
  logMean: -6.2,
  lotPrior: 0.01,
  df: 4,
  tier: WeightTier.red,
  nInliers: 1,
  suggestedSampleSize: 20,
);

class _Harness {
  WeighCountResult? result;
  bool closed = false;
}

Future<(_FakeApi, _Harness)> _open(
  WidgetTester tester,
  WeighCountRequest request, {
  Set<String> permissions = const {Perm.warehouseInboundStockIn},
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _FakeApi();
  final harness = _Harness();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
        weightRepositoryProvider.overrideWithValue(WeightRepository(api)),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              key: const Key('open'),
              onPressed: () async {
                harness.result = await showWeighCountDialog(
                  context,
                  request: request,
                );
                harness.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return (api, harness);
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

UtenButton _button(WidgetTester tester, String key) =>
    tester.widget<UtenButton>(find.byKey(ValueKey(key)));

Future<void> _tapButton(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未学准: 填入数量禁用, 录入 >= 10 件抽样后放开并存 SAMPLE', (tester) async {
    final (api, harness) = await _open(
      tester,
      const WeighCountRequest(
        mode: WeighCountContext.count,
        goodsId: 'g1',
        goodsTitle: '螺丝 M3 黑',
        params: _red,
        supplierId: 'sup-A',
        warehouseId: 'wh-1',
        baseUnitName: '个',
      ),
    );
    expect(find.text('称重计数 · 螺丝 M3 黑'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('weigh-count-red-banner')),
      findsOneWidget,
    );
    expect(find.textContaining('请数 20 个放上秤'), findsOneWidget);

    await _type(tester, 'weigh-count-gross-0', '20');
    expect(_button(tester, 'weigh-count-primary').onPressed, isNull);
    // 「只记重量」始终可用 (重量从不阻断)。
    expect(_button(tester, 'weigh-count-secondary').onPressed, isNotNull);

    // 少于 10 件的抽样不放行。
    await _type(tester, 'weigh-count-sample-qty', '5');
    await _type(tester, 'weigh-count-sample-weight', '10');
    expect(_button(tester, 'weigh-count-primary').onPressed, isNull);

    await _type(tester, 'weigh-count-sample-qty', '20');
    await _type(tester, 'weigh-count-sample-weight', '40');
    expect(find.byKey(const ValueKey('weigh-count-red-banner')), findsNothing);
    expect(_button(tester, 'weigh-count-primary').onPressed, isNotNull);

    await _tapButton(tester, 'weigh-count-primary');

    final result = harness.result!;
    expect(result.netKg, 20);
    expect(result.qtyFromWeight, isTrue);
    // 抽样 2.0 g/个 与宽先验融合后约 10000 个, 按件取整。
    expect(result.qty, closeTo(10000, 60));
    expect(result.qty, result.qty!.roundToDouble());
    expect(result.qtyEstimateNote, startsWith('按称重推算 '));
    expect(result.sample!.saved, isTrue);

    final samplePosts = api.posts
        .where((p) => p.$1 == ApiEndpoints.stockWeightGoodsSamples('g1'))
        .toList();
    expect(samplePosts, hasLength(1));
    final body = samplePosts.single.$2! as Map<String, Object?>;
    expect(body['qty'], 20);
    expect(body['weight'], 40);
    expect(body['weightUnit'], 'G');
    expect(body['supplierId'], 'sup-A');
    expect(body['warehouseId'], 'wh-1');
    expect(body['newRegime'], isFalse);
    expect(body['idempotencyKey'], startsWith('weight-sample-'));
    // 弹窗只写抽样, 从不调用过账接口。
    expect(api.posts.where((p) => !p.$1.startsWith('/stock/weight/')), isEmpty);
  });

  testWidgets('到货: 只记重量不改数量; 按称重改数量带对账提示并取整', (tester) async {
    final (api, harness) = await _open(
      tester,
      const WeighCountRequest(
        mode: WeighCountContext.receipt,
        goodsId: 'g1',
        goodsTitle: '螺丝',
        params: _learned,
        supplierId: 'sup-A',
        baseUnitName: '个',
        currentQty: 10000,
      ),
    );
    expect(find.byKey(const ValueKey('weigh-count-red-banner')), findsNothing);

    await _type(tester, 'weigh-count-gross-0', '19.3');
    expect(find.textContaining('约 9,654个'), findsOneWidget);
    expect(find.textContaining('偏少约346个 (-3.5%)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('weigh-count-fill-warning')),
      findsOneWidget,
    );
    expect(find.textContaining('将按估算数量入账, 影响对账'), findsOneWidget);

    await _tapButton(tester, 'weigh-count-primary');
    expect(harness.result!.netKg, 19.3);
    expect(harness.result!.qty, isNull);
    expect(harness.result!.qtyFromWeight, isFalse);
    expect(api.posts, isEmpty);
  });

  testWidgets('到货按称重改数量: 回填整数数量并打 qtyFromWeight', (tester) async {
    final (_, harness) = await _open(
      tester,
      const WeighCountRequest(
        mode: WeighCountContext.receipt,
        goodsId: 'g1',
        goodsTitle: '螺丝',
        params: _learned,
        baseUnitName: '个',
        currentQty: 10000,
      ),
    );
    await _type(tester, 'weigh-count-gross-0', '19.3');
    await _tapButton(tester, 'weigh-count-secondary');
    expect(harness.result!.qty, 9654);
    expect(harness.result!.qtyBase, 9654);
    expect(harness.result!.qtyFromWeight, isTrue);

    final weight = WeightEntryController();
    final qty = UtenAutofillTextController(autofilled: false);
    addTearDown(weight.dispose);
    addTearDown(qty.dispose);
    applyWeighCountResult(harness.result!, weight: weight, qty: qty);
    expect(weight.kg, 19.3);
    expect(weight.qtyFromWeight, isTrue);
    expect(qty.text, '9654');
    expect(qty.autofilled, isTrue);
    expect(weight.derivedQtyText, '9654');
  });

  testWidgets('多次称重相加, 扣皮重 x 件数; 行单位按 unit_rate 折回', (tester) async {
    final (_, harness) = await _open(
      tester,
      const WeighCountRequest(
        mode: WeighCountContext.count,
        goodsId: 'g1',
        goodsTitle: '螺丝',
        params: _learned,
        baseUnitName: '个',
        lineUnitName: '千个',
        unitRate: 1000,
      ),
    );
    await _type(tester, 'weigh-count-gross-0', '10');
    await _tapButton(tester, 'weigh-count-add-gross');
    await _type(tester, 'weigh-count-gross-1', '10');
    await _tapButton(tester, 'weigh-count-add-gross');
    await _type(tester, 'weigh-count-gross-2', '5300g');
    await _type(tester, 'weigh-count-tare', '1.2');
    // 件数没手改时跟着称重次数走 (3 次 = 3 件)。
    await _type(tester, 'weigh-count-pieces', '3');
    expect(find.text('21.7 kg'), findsOneWidget);

    await _tapButton(tester, 'weigh-count-primary');
    final result = harness.result!;
    expect(result.netKg, 21.7);
    expect(result.grossKg, 25.3);
    expect(result.tareKg, 3.6);
    // 21.7 kg / 2.0 g ≈ 10854 个 = 10.854 千个。
    expect(result.qtyBase, 10854);
    expect(result.qty, 10.854);
  });

  testWidgets('出库反推: 需要 N 个 -> 秤上应显示约; 只回填重量', (tester) async {
    final (_, harness) = await _open(
      tester,
      const WeighCountRequest(
        mode: WeighCountContext.outbound,
        goodsId: 'g1',
        goodsTitle: '螺丝',
        params: _learned,
        baseUnitName: '个',
        currentQty: 10000,
      ),
    );
    await _type(tester, 'weigh-count-tare', '1.2');
    await _type(tester, 'weigh-count-pieces', '1');
    final target = find.byKey(const ValueKey('weigh-count-outbound-target'));
    expect(target, findsOneWidget);
    expect(find.textContaining('需要 10,000个 → 净重约 19.993 kg'), findsOneWidget);
    expect(find.textContaining('秤上应显示约 21.193 kg'), findsOneWidget);

    await _type(tester, 'weigh-count-gross-0', '21.5');
    expect(find.textContaining('比应发多约'), findsOneWidget);

    await _tapButton(tester, 'weigh-count-primary');
    expect(harness.result!.netKg, 20.3);
    expect(harness.result!.qty, isNull);
    expect(harness.result!.qtyFromWeight, isFalse);
  });

  testWidgets('取消返回 null', (tester) async {
    final (api, harness) = await _open(
      tester,
      const WeighCountRequest(
        mode: WeighCountContext.count,
        goodsId: 'g1',
        goodsTitle: '螺丝',
        params: _learned,
      ),
    );
    await _tapButton(tester, 'weigh-count-cancel');
    expect(harness.closed, isTrue);
    expect(harness.result, isNull);
    expect(api.posts, isEmpty);
    expect(WeightPredictor.defaultGamma, 0.02);
  });
}
