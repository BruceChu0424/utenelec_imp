// 称样校准弹窗契约 (ADR-135 §6.2, review/product.md §1.3):
//  1. 实时「本次单重 vs 当前」; 保存 = POST samples (净重按抽样单位, 皮重以千克留痕, 带供应商);
//  2. 与当前单重差异超过 3 倍标准差时提示「差异较大: 换了供应商/批次?」并可勾「新批次」;
//  3. 抽样单位切换记为用户偏好, 请求带对应单位码;
//  4. 没有称样权限时不能保存。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_sample_dialog.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  final posts = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, body));
    return {
      'goodsId': 'g1',
      'resolved': {
        'goodsId': 'g1',
        'basis': 'LEARNED',
        'tier': 'GREEN',
        'unitWeightKg': 0.002005,
      },
      'supplierRows': [
        {'supplierId': 'sup-A', 'supplierName': '甲五金', 'nRef': 3},
      ],
    };
  }
}

const _learned = WeightParams(
  goodsId: 'g1',
  basis: WeightBasis.learned,
  supplierSpecific: true,
  logMean: -6.214979467174846,
  lotPrior: 3.869930380683166e-05,
  df: 15,
  tier: WeightTier.yellow,
  nInliers: 12,
  unitWeightKg: 0.0019992574,
  suggestedSampleSize: 16,
);

class _Harness {
  GoodsWeightDetail? result;
}

Future<(_FakeApi, _Harness, ProviderContainer)> _open(
  WidgetTester tester, {
  Set<String> permissions = const {Perm.stockDocEdit},
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _FakeApi();
  final harness = _Harness();
  final container = ProviderContainer(
    overrides: [
      warehouseWeightUnitsPrefsProvider.overrideWith(
        _MemoryWeightUnitsPrefs.new,
      ),
      weightRepositoryProvider.overrideWithValue(WeightRepository(api)),
      currentPermissionsProvider.overrideWithValue(permissions),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              key: const Key('open'),
              onPressed: () async {
                harness.result = await showWeightSampleDialog(
                  context,
                  goodsId: 'g1',
                  goodsTitle: '螺丝 M3',
                  baseUnitName: '个',
                  supplierId: 'sup-A',
                  supplierName: '甲五金',
                  warehouseId: 'wh-1',
                  params: _learned,
                );
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
  return (api, harness, container);
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

UtenButton _save(WidgetTester tester) =>
    tester.widget<UtenButton>(find.byKey(const ValueKey('weight-sample-save')));

void main() {
  testWidgets('实时对比当前单重, 保存发 SAMPLE 并返回刷新详情', (tester) async {
    final (api, harness, _) = await _open(tester);
    expect(find.text('称样校准 · 螺丝 M3'), findsOneWidget);
    expect(_save(tester).onPressed, isNull);

    await _type(tester, 'weight-sample-qty', '20');
    await _type(tester, 'weight-sample-weight', '40.1');
    expect(find.text('本次单重 2.005 g; 当前 1.999 g (+0.3%)'), findsOneWidget);
    expect(find.byKey(const ValueKey('weight-sample-big-diff')), findsNothing);
    expect(_save(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('weight-sample-save')));
    await tester.pumpAndSettle();

    expect(api.posts, hasLength(1));
    expect(api.posts.single.$1, ApiEndpoints.stockWeightGoodsSamples('g1'));
    final body = api.posts.single.$2! as Map<String, Object?>;
    expect(body['qty'], 20);
    expect(body['weight'], 40.1);
    expect(body['weightUnit'], 'G');
    expect(body['supplierId'], 'sup-A');
    expect(body['warehouseId'], 'wh-1');
    expect(body['newRegime'], isFalse);
    expect(body.containsKey('tareKg'), isFalse);
    expect(harness.result!.resolved!.tier, WeightTier.green);
    expect(harness.result!.supplierRows.single.supplierName, '甲五金');
  });

  testWidgets('差异超过 3 倍标准差: 提示换批并可勾选新批次', (tester) async {
    final (api, _, _) = await _open(tester);
    await _type(tester, 'weight-sample-qty', '20');
    await _type(tester, 'weight-sample-weight', '46.2');

    expect(
      find.byKey(const ValueKey('weight-sample-big-diff')),
      findsOneWidget,
    );
    expect(find.text('差异较大: 换了供应商/批次?'), findsOneWidget);
    final checkbox = find.byKey(const ValueKey('weight-sample-new-regime'));
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('weight-sample-save')));
    await tester.pumpAndSettle();
    final body = api.posts.single.$2! as Map<String, Object?>;
    expect(body['newRegime'], isTrue);
  });

  testWidgets('皮重: 净重按抽样单位回传, 皮重以千克留痕', (tester) async {
    final (api, _, _) = await _open(tester);
    await _type(tester, 'weight-sample-qty', '20');
    await _type(tester, 'weight-sample-weight', '50');
    await _type(tester, 'weight-sample-tare', '10');
    expect(find.textContaining('本次单重 2 g'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('weight-sample-save')));
    await tester.pumpAndSettle();
    final body = api.posts.single.$2! as Map<String, Object?>;
    expect(body['weight'], 40);
    expect(body['weightUnit'], 'G');
    expect(body['tareKg'], 0.01);
  });

  testWidgets('切换抽样单位记为偏好, 请求带单位码', (tester) async {
    final (api, _, container) = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('weight-sample-unit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千克').last);
    await tester.pumpAndSettle();
    expect(
      container.read(warehouseWeightUnitsPrefsProvider).sample,
      WeightUnit.kg,
    );

    await _type(tester, 'weight-sample-qty', '20');
    await _type(tester, 'weight-sample-weight', '0.0401');
    await tester.tap(find.byKey(const ValueKey('weight-sample-save')));
    await tester.pumpAndSettle();
    final body = api.posts.single.$2! as Map<String, Object?>;
    expect(body['weight'], 0.0401);
    expect(body['weightUnit'], 'KG');
  });

  testWidgets('没有称样权限: 提示且不能保存', (tester) async {
    await _open(tester, permissions: const {Perm.stockView});
    expect(find.textContaining('没有称样权限'), findsOneWidget);
    await _type(tester, 'weight-sample-qty', '20');
    await _type(tester, 'weight-sample-weight', '40');
    expect(_save(tester).onPressed, isNull);
    // 服务端没给建议件数时按同一公式兜底 (默认 16)。
    expect(WeightPredictor.suggestedSampleSize(), _learned.suggestedSampleSize);
  });
}
