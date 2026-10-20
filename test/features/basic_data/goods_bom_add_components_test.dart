import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
// 组装信息「添加组件」(ADR-111 评审修复)：勾选多个组件后只发一次服务端追加命令，
// 整批原子；服务端逐行拒绝的原因留在弹窗里给人改，不再逐个新建、失败只报「N 个跳过」。
// 2026-10-19 起弹窗是可拖动缩放的无蒙版浮窗（UtenFloatingWindow），断言按浮窗类型找。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

/// 伪仓库：记录每次粘贴(追加)调用；第一次按服务端 409 的样子逐行拒绝，之后成功。
class _RecordingBomRepo implements GoodsBomRepository {
  _RecordingBomRepo({this.rejectFirst = true});

  final bool rejectFirst;
  final pasteCalls =
      <
        ({
          BomPasteMode mode,
          List<BomPasteTarget> targets,
          List<Map<String, dynamic>> items,
        })
      >[];
  var listCalls = 0;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls++;
    return const [];
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    pasteCalls.add((mode: mode, targets: targets, items: items));
    if (rejectFirst && pasteCalls.length == 1) {
      throw ApiException(
        'CONFLICT',
        '粘贴没有生效：有 1 处问题，现有组件没有任何改动',
        httpStatus: 409,
        fieldErrors: const [
          ApiFieldError(field: '第 2 行 S01 螺丝', message: '粘贴到「A 成品」会形成组装环路'),
        ],
      );
    }
    return BomPasteResult(
      targets: targets.length,
      added: items.length,
      removed: 0,
    );
  }

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async =>
      throw UnimplementedError();

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async => throw UnimplementedError();

  @override
  Future<int> move(String goodsId, List<GoodsBomMove> moves) async => 0;

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async => throw UnimplementedError();

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      throw UnimplementedError();

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) async => throw UnimplementedError();
}

const _picked = [
  GoodsListItem(id: 'goods-x', code: 'K01', name: '外壳', price: 3),
  GoodsListItem(id: 'goods-y', code: 'S01', name: '螺丝', price: 0.2),
];

Future<void> _openAddDialog(WidgetTester tester, _RecordingBomRepo repo) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: ApiClient(Dio()),
            permissions: {Perm.goodsView, Perm.goodsBomCreate},
            superAdmin: false,
          ),
        ),
        goodsBomRepositoryProvider.overrideWithValue(repo),
        bomComponentPickerProvider.overrideWithValue(
          (context, ref) async => _picked,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsBomCreate,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'goods-a',
            canCreate: true,
            canEdit: false,
            canDelete: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('goods-bom-add-component')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('选择组件'));
  await tester.pumpAndSettle();
  expect(find.textContaining('外壳'), findsOneWidget);
  expect(find.textContaining('螺丝'), findsOneWidget);
}

void main() {
  testWidgets('两个组件一次追加请求：服务端拒绝时逐行原因留在弹窗、改好再存才关闭', (tester) async {
    final repo = _RecordingBomRepo();
    await _openAddDialog(tester, repo);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 只发了一次请求、目标是添加位置(顶层=本货品)、两行一起提交。
    expect(repo.pasteCalls, hasLength(1));
    final first = repo.pasteCalls.single;
    expect(first.mode, BomPasteMode.append);
    expect(first.targets.map((t) => t.goodsId), ['goods-a']);
    expect(first.targets.single.expectedItemIds, isNull);
    expect(first.items.map((i) => i['componentGoodsId']), [
      'goods-x',
      'goods-y',
    ]);
    // 被拒：弹窗还在，整体原因 + 逐行原因都看得到。
    expect(find.byType(UtenFloatingWindow), findsOneWidget);
    expect(find.byKey(const Key('goods-bom-add-error')), findsOneWidget);
    expect(find.textContaining('现有组件没有任何改动'), findsOneWidget);
    expect(
      find.textContaining('第 2 行 S01 螺丝：粘贴到「A 成品」会形成组装环路'),
      findsOneWidget,
    );

    final reloadsBefore = repo.listCalls;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repo.pasteCalls, hasLength(2));
    expect(find.byType(UtenFloatingWindow), findsNothing, reason: '整批成功才关弹窗');
    expect(repo.listCalls, greaterThan(reloadsBefore), reason: '成功后重载组装树');
  });

  testWidgets('设计使用数量不合法在本地拦下，不发任何请求', (tester) async {
    final repo = _RecordingBomRepo(rejectFirst: false);
    await _openAddDialog(tester, repo);

    // 2026-10-19 二轮起已选区是紧凑表格：数量 key 直接挂在 TextField 上。
    Finder qtyField(String goodsId) =>
        find.byKey(ValueKey('goods-bom-add-qty-$goodsId'));
    for (final goodsId in ['goods-x', 'goods-y']) {
      expect(qtyField(goodsId), findsOneWidget);
      expect(
        tester.widget<TextField>(qtyField(goodsId)).decoration!.hintText,
        '设计使用数量',
      );
    }
    await tester.enterText(qtyField('goods-x'), '0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.pasteCalls, isEmpty);
    expect(find.text('「外壳」设计使用数量必须是大于 0 的数字'), findsOneWidget);
  });

  testWidgets('设计使用数量清空即报错，不再静默按 1 提交', (tester) async {
    final repo = _RecordingBomRepo(rejectFirst: false);
    await _openAddDialog(tester, repo);
    final qtyField = find.byKey(const ValueKey('goods-bom-add-qty-goods-y'));

    await tester.enterText(qtyField, '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.pasteCalls, isEmpty);
    expect(find.text('「螺丝」请填写设计使用数量'), findsOneWidget);

    await tester.enterText(qtyField, '0.25');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repo.pasteCalls.single.items.map((i) => i['qty']), [1.0, 0.25]);
  });

  testWidgets('浮窗是页面内浮层：可缩成悬浮球再展开（现场不丢），关闭即清', (tester) async {
    final repo = _RecordingBomRepo(rejectFirst: false);
    await _openAddDialog(tester, repo);

    // 2026-10-19 二轮：浮窗挂在页面 Stack 里（非路由弹窗、无蒙版 barrier），
    // 底层组装表格照常可点可滚。
    expect(find.byType(UtenFloatingWindow), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('goods-bom-add-qty-goods-x')),
      '3',
    );
    await tester.pumpAndSettle();

    // 缩小成悬浮球：窗口内容收起。
    await tester.tap(find.byTooltip('缩小成悬浮球'));
    await tester.pumpAndSettle();
    expect(find.text('添加位置'), findsNothing);

    // 点球展开：现场复原，已填数量不丢。
    await tester.tap(find.byIcon(Icons.post_add_rounded));
    await tester.pumpAndSettle();
    expect(find.text('添加位置'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('goods-bom-add-qty-goods-x')),
          )
          .controller!
          .text,
      '3',
    );

    // 关闭按钮 → 会话关闭，浮窗从页面卸载。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenFloatingWindow), findsNothing);
    expect(repo.pasteCalls, isEmpty);
  });
}
