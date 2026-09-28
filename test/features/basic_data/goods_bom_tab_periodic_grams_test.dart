// 组装信息页签：整批领到车间内料仓的料 (期间边，ADR-131) 按克输入显示。
//
//  1. 数量列对期间边显示「X 克」(基本单位千克时 = 数量 × 1000)，普通行照旧；
//  2. 编辑期间边：输入框叫「单个重量 (克)」，提交带 unitWeightGrams 与换算后的数量，
//     管控阶段 / 计量方式 / 齐套门槛不提交 (只读，由系统固定)；与货品资料单重相差
//     20% 以上标黄提醒；
//  3. 小于 0.1 克或大于 5000 克二次确认，确认后带 confirmUnusualWeight；
//  4. 添加第二种整批领料的料要确认 (双色 / 双料)，确认后带 confirmSecondPeriodicMaterial；
//  5. 页面没问到、服务端回 422 要人确认时，弹框确认后带上确认字段原样重发；
//  6. 组件单位不能按克换算时按基本单位填，只提交 qty。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _pcRow = GoodsBomItem(
  id: 'row-pc',
  componentGoodsId: 'pc',
  componentCode: 'M01',
  componentName: 'PC E-15',
  componentUnitName: '千克',
  qty: 0.0125,
  componentIssueMethod: 'PERIODIC',
  hardGate: false,
);

const _tonRow = GoodsBomItem(
  id: 'row-ton',
  componentGoodsId: 'ton-resin',
  componentCode: 'M09',
  componentName: '吨包树脂',
  componentUnitName: '吨',
  qty: 0.00002,
  componentIssueMethod: 'PERIODIC',
  hardGate: false,
);

const _shellRow = GoodsBomItem(
  id: 'row-shell',
  componentGoodsId: 'shell',
  componentCode: 'K01',
  componentName: '外壳',
  componentUnitName: '个',
  qty: 1,
);

class _FakeBomRepo implements GoodsBomRepository {
  _FakeBomRepo({this.rows = const [_pcRow, _shellRow]});

  final List<GoodsBomItem> rows;
  final updates = <Map<String, dynamic>>[];
  final pastes = <List<Map<String, dynamic>>>[];

  /// 下一次保存先回这个错误 (如 422 要人确认)，回完即清掉。
  Object? updateFailureOnce;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async =>
      goodsId == 'goods-a' ? rows : const [];

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    final failure = updateFailureOnce;
    if (failure != null) {
      updateFailureOnce = null;
      throw failure;
    }
    updates.add(Map<String, dynamic>.of(body));
    return _pcRow;
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    pastes.add(items);
    return BomPasteResult(targets: 1, added: items.length, removed: 0);
  }

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async =>
      throw UnimplementedError();

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async => throw UnimplementedError();
}

Future<void> _pumpTab(
  WidgetTester tester,
  _FakeBomRepo repo, {
  double? productWeightGrams,
  List<GoodsListItem> picked = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        bomComponentPickerProvider.overrideWithValue(
          (context, ref) async => picked,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsBomCreate,
          Perm.goodsBomEdit,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'goods-a',
            canCreate: true,
            canEdit: true,
            canDelete: false,
            productWeightGrams: productWeightGrams,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openEditForPc(WidgetTester tester) async {
  await tester.tap(find.text('PC E-15'));
  await tester.pump();
  await tester.tap(find.widgetWithText(UtenButton, '编辑'));
  await tester.pumpAndSettle();
}

void main() {
  test('千克单位的期间边换算成克，认不出的单位不换算', () {
    expect(_pcRow.isPeriodicEdge, isTrue);
    expect(_pcRow.periodicUnitWeightGrams, closeTo(12.5, 1e-9));
    expect(_shellRow.periodicUnitWeightGrams, isNull);
    expect(periodicGramsPerBaseUnit('kg'), 1000);
    expect(periodicGramsPerBaseUnit('克'), 1);
    expect(periodicGramsPerBaseUnit('吨'), isNull);
    expect(periodicGramsText(12.5), '12.5');
    expect(periodicGramsText(8), '8');
    expect(periodicGramsUnusual(0.05), isTrue);
    expect(periodicGramsUnusual(6000), isTrue);
    expect(periodicGramsUnusual(12.5), isFalse);
    expect(periodicGramsDeviates(12.5, 10), isTrue);
    expect(periodicGramsDeviates(11, 10), isFalse);
    expect(periodicGramsDeviates(12.5, null), isFalse);
    final parsed = GoodsBomItem.fromJson({
      'id': 'x',
      'componentGoodsId': 'pc',
      'componentIssueMethod': 'PERIODIC',
      'unitWeightGrams': 9.5,
      'warnings': ['与货品资料单重相差 25%'],
    });
    expect(parsed.periodicUnitWeightGrams, 9.5);
    expect(parsed.warnings, ['与货品资料单重相差 25%']);
  });

  testWidgets('期间边的数量列按克显示，普通行照旧显示数量', (tester) async {
    await _pumpTab(tester, _FakeBomRepo());

    expect(find.text('12.5 克'), findsOneWidget);
    expect(find.text('0.0125'), findsNothing);
    expect(find.text('数量'), findsOneWidget, reason: '表头名不变');
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑期间边：按克输入、提交 unitWeightGrams，只读列不提交，偏差标黄', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo, productWeightGrams: 10);
    await _openEditForPc(tester);

    final field = find.byKey(const Key('goods-bom-edit-qty'));
    expect(find.widgetWithText(TextField, '单个重量 (克)'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '12.5');
    expect(
      find.byKey(const Key('goods-bom-periodic-readonly-note')),
      findsOneWidget,
    );
    // 12.5 克与货品资料单重 10 克相差 25%：标黄提醒核对 (不拦截)。
    expect(find.byKey(const Key('goods-bom-weight-deviation')), findsOneWidget);

    await tester.enterText(field, '11');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('goods-bom-weight-deviation')), findsNothing);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updates, hasLength(1));
    final body = repo.updates.single;
    expect(body['unitWeightGrams'], 11);
    expect(body['qty'], closeTo(0.011, 1e-9));
    expect(body.containsKey('controlStage'), isFalse);
    expect(body.containsKey('consumptionBasis'), isFalse);
    expect(body.containsKey('hardGate'), isFalse);
    expect(body.containsKey('confirmUnusualWeight'), isFalse);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单个重量小于 0.1 克要二次确认，确认后才提交', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(tester, repo);
    await _openEditForPc(tester);

    await tester.enterText(find.byKey(const Key('goods-bom-edit-qty')), '0.05');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('单个重量 0.05 克看起来不太对'), findsOneWidget);
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    expect(repo.updates, isEmpty);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-bom-unusual-weight-confirm')));
    await tester.pumpAndSettle();

    expect(repo.updates, hasLength(1));
    expect(repo.updates.single['unitWeightGrams'], 0.05);
    expect(repo.updates.single['confirmUnusualWeight'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加第二种整批领料的料：按克填，确认双料后提交', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(
      tester,
      repo,
      picked: const [
        GoodsListItem(
          id: 'abs',
          code: 'M02',
          name: 'ABS 757',
          unitName: '千克',
          issueMethod: GoodsIssueMethod.periodic,
          periodicCostBasis: GoodsPeriodicCostBasis.own,
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('goods-bom-add-component')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择组件'));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('goods-bom-add-qty-abs'));
    expect(find.widgetWithText(TextField, '单个重量 (克)'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    await tester.enterText(field, '8');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 本产品已有一条期间边 (PC E-15)，再加一种要确认是双色 / 双料。
    expect(find.textContaining('同时用两种料'), findsWidgets);
    await tester.tap(
      find.byKey(const Key('goods-bom-second-material-confirm')),
    );
    await tester.pumpAndSettle();

    expect(repo.pastes, hasLength(1));
    final item = repo.pastes.single.single;
    expect(item['componentGoodsId'], 'abs');
    expect(item['unitWeightGrams'], 8);
    expect(item['qty'], closeTo(0.008, 1e-9));
    expect(item['confirmSecondPeriodicMaterial'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('辅料 (色母) 不写进 BOM：本地拦下不发请求', (tester) async {
    final repo = _FakeBomRepo();
    await _pumpTab(
      tester,
      repo,
      picked: const [
        GoodsListItem(
          id: 'masterbatch',
          name: '黑色母',
          unitName: '千克',
          issueMethod: GoodsIssueMethod.periodic,
          periodicCostBasis: GoodsPeriodicCostBasis.shared,
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('goods-bom-add-component')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择组件'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goods-bom-add-qty-masterbatch')),
      '2',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.pastes, isEmpty);
    expect(find.textContaining('不写进 BOM'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端回 422 要人确认：弹框确认后带上确认字段重发', (tester) async {
    final repo = _FakeBomRepo()
      ..updateFailureOnce = ApiException(
        'VALIDATION_FAILED',
        '这个产品要同时用两种料吗',
        fieldErrors: const [
          ApiFieldError(
            field: 'confirmSecondPeriodicMaterial',
            message: '「外壳」要同时用两种料吗 (双色 / 双料)?',
          ),
        ],
      );
    await _pumpTab(tester, repo);
    await _openEditForPc(tester);

    await tester.enterText(find.byKey(const Key('goods-bom-edit-qty')), '11');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updates, isEmpty);
    expect(find.textContaining('要同时用两种料吗 (双色 / 双料)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('periodic-bom-confirm')));
    await tester.pumpAndSettle();

    expect(repo.updates, hasLength(1));
    expect(repo.updates.single['confirmSecondPeriodicMaterial'], isTrue);
    expect(repo.updates.single['unitWeightGrams'], 11);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组件单位不能按克换算：按基本单位填，只提交 qty', (tester) async {
    final repo = _FakeBomRepo(rows: const [_tonRow]);
    await _pumpTab(tester, repo);
    await tester.tap(find.text('吨包树脂'));
    await tester.pump();
    await tester.tap(find.widgetWithText(UtenButton, '编辑'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '单个重量 (吨)'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('goods-bom-edit-qty')))
          .controller!
          .text,
      '0.00002',
    );
    await tester.enterText(
      find.byKey(const Key('goods-bom-edit-qty')),
      '0.00003',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updates, hasLength(1));
    final body = repo.updates.single;
    expect(body['qty'], closeTo(0.00003, 1e-12));
    expect(body.containsKey('unitWeightGrams'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
