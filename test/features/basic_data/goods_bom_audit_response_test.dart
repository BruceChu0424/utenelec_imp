import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

const _markTooltip = '点击标记已核对';
const _unmarkTooltip = '已核对，点击取消';

void main() {
  for (final fullscreen in [false, true]) {
    testWidgets(
      'audit responds immediately and permits independent edges (fullscreen: $fullscreen)',
      (tester) async {
        final repo = _AuditRepository({
          'goods-a': [
            _item('row-a1', 'goods-x', '外壳'),
            _item('row-a2', 'goods-y', '螺丝'),
          ],
        });
        await _pumpTab(tester, repo);
        if (fullscreen) {
          await tester.tap(
            find.byKey(const ValueKey('master-table-fullscreen-toggle')),
          );
          await tester.pumpAndSettle();
          expect(find.text('退出全屏'), findsOneWidget);
        }
        final oldAction = _auditButton(tester, _markTooltip, 0).onPressed!;

        await tester.tap(find.byTooltip(_markTooltip).first);
        await _pumpFrames(tester);

        expect(repo.requests, hasLength(1));
        expect(repo.requests.single.result.isCompleted, isFalse);
        expect(repo.requests.first.identity, ('goods-a', 'row-a1', true));
        expect(_saving('goods-a|row-a1'), findsOneWidget);
        expect(
          tester.widget(_saving('goods-a|row-a1')),
          isA<CircularProgressIndicator>(),
        );
        expect(find.byTooltip('正在保存核对标记'), findsOneWidget);

        // A stale click callback must obey the same pending guard as the new UI.
        oldAction();
        await tester.pump();
        expect(repo.requests, hasLength(1));
        await tester.tap(find.byTooltip(_markTooltip));
        await _pumpFrames(tester);
        expect(repo.requests, hasLength(2));
        expect(repo.requests.last.result.isCompleted, isFalse);
        expect(repo.requests.last.identity, ('goods-a', 'row-a2', true));
        expect(_saving('goods-a|row-a1'), findsOneWidget);
        expect(_saving('goods-a|row-a2'), findsOneWidget);

        // Complete the second request first: only that relationship leaves pending.
        repo.requests[1].result.complete(
          _item('row-a2', 'goods-y', '螺丝（服务端返回）', audited: true),
        );
        await _pumpFrames(tester);
        expect(_saving('goods-a|row-a1'), findsOneWidget);
        expect(_saving('goods-a|row-a2'), findsNothing);
        expect(find.text('螺丝（服务端返回）'), findsOneWidget);
        expect(find.byTooltip(_unmarkTooltip), findsOneWidget);
        expect(repo.listCalls, ['goods-a']);

        repo.requests[0].result.complete(
          _item('row-a1', 'goods-x', '外壳（服务端返回）', audited: true),
        );
        await tester.pumpAndSettle();
        expect(find.text('外壳（服务端返回）'), findsOneWidget);
        expect(find.byTooltip(_unmarkTooltip), findsNWidgets(2));
        expect(find.byTooltip('正在保存核对标记'), findsNothing);
        expect(repo.listCalls, ['goods-a'], reason: '审计成功只消费返回行，不重读清单');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed unmark preserves the audited value and allows a retry', (
    tester,
  ) async {
    final repo = _AuditRepository({
      'goods-a': [_item('row-a1', 'goods-x', '外壳', audited: true)],
    });
    await _pumpTab(tester, repo);
    await tester.tap(find.byTooltip(_unmarkTooltip));
    await tester.pump();
    expect(_saving('goods-a|row-a1'), findsOneWidget);
    expect(repo.requests.single.identity, ('goods-a', 'row-a1', false));

    repo.requests.single.result.completeError(
      ApiException('CONFLICT', '组件已被修改，请重试审计'),
    );
    await tester.pumpAndSettle();
    expect(find.text('组件已被修改，请重试审计'), findsOneWidget);
    expect(_saving('goods-a|row-a1'), findsNothing);
    expect(find.byTooltip(_unmarkTooltip), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
    expect(repo.listCalls, ['goods-a']);
    await tester.tap(find.byTooltip('关闭通知'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(_unmarkTooltip));
    await tester.pump();
    expect(repo.requests, hasLength(2));
    expect(repo.requests.last.identity, ('goods-a', 'row-a1', false));
    repo.requests.last.result.complete(_item('row-a1', 'goods-x', '外壳'));
    await tester.pumpAndSettle();
    expect(_saving('goods-a|row-a1'), findsNothing);
    expect(find.byTooltip(_markTooltip), findsOneWidget);
    expect(find.byTooltip(_unmarkTooltip), findsNothing);
    expect(repo.listCalls, ['goods-a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared nested edge updates both appearances without reloading its tree',
    (tester) async {
      final repo = _AuditRepository({
        'goods-a': [
          _item('row-left', 'goods-shared', '左装配', hasChildren: true),
          _item('row-right', 'goods-shared', '右装配', hasChildren: true),
          for (var i = 0; i < 25; i++)
            _item('row-filler-$i', 'goods-filler-$i', '其它组件 $i'),
        ],
        'goods-shared': [_sharedItem()],
        'goods-nested': [_item('row-deep', 'goods-leaf', '三级子件')],
      });
      await _pumpTab(tester, repo);
      await _expand(tester, 'row-left');
      await _expand(tester, 'row-shared');
      await _expand(tester, 'row-right');
      expect(_table(tester).items, hasLength(30));
      expect(find.text('共同组件'), findsNWidgets(2));
      expect(find.text('三级子件'), findsOneWidget);
      final loaded = List<String>.of(repo.listCalls);

      await tester.tap(find.text('共同组件').first);
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, {'goods-shared|row-shared'});
      final vertical = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .map((state) => state.position)
          .firstWhere(
            (position) =>
                position.axis == Axis.vertical && position.maxScrollExtent > 24,
          );
      vertical.jumpTo(24);
      await tester.pumpAndSettle();
      final offset = vertical.pixels;

      // Order is left assembly, shared component, deep child, right assembly,
      // and the second appearance of the same shared relationship.
      final oldSharedAction = _auditButton(tester, _markTooltip, 4).onPressed!;
      await tester.tap(find.byTooltip(_markTooltip).at(1));
      await tester.pump();
      expect(repo.requests.single.identity, (
        'goods-shared',
        'row-shared',
        true,
      ));
      expect(_saving('goods-shared|row-shared'), findsNWidgets(2));
      oldSharedAction();
      await tester.pump();
      expect(repo.requests, hasLength(1));

      repo.requests.single.result.complete(_sharedItem(audited: true));
      await tester.pumpAndSettle();
      expect(repo.listCalls, loaded, reason: '根清单和任何已展开子树均不重载');
      expect(find.byTooltip(_unmarkTooltip), findsNWidgets(2));
      expect(_saving('goods-shared|row-shared'), findsNothing);
      expect(find.text('三级子件'), findsOneWidget);
      final sharedCells = tester.widgetList<UtenTreeTableCell>(
        find.byKey(const ValueKey('goods-bom-tree-cell-row-shared')),
      );
      expect(sharedCells.map((cell) => cell.expanded), [true, false]);
      expect(_table(tester).selectedIds, {'goods-shared|row-shared'});
      expect(vertical.pixels, offset);
      // Audit writeback must retain the rest of the server DTO, including
      // learned usage, unit/specification and the ordinary design quantity.
      // 2026-10-10「数量+单位」口径：单位内联进数量列，独立「单位」列已撤除。
      expect(find.text('2.25 千克'), findsNWidgets(2));
      expect(find.text('2.375 千克'), findsNWidgets(2));
      expect(find.text('精密规格'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('goods-bom-learned-row-shared')),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh waits for audit and stale callbacks cannot edit its replacement',
    (tester) async {
      final repo = _AuditRepository({
        'goods-a': [_item('row-a1', 'goods-x', '原始组件')],
      });
      await _pumpTab(tester, repo);
      final oldAction = _auditButton(tester, _markTooltip, 0).onPressed!;
      await tester.tap(find.byTooltip(_markTooltip));
      await tester.pump();
      expect(repo.requests, hasLength(1));

      repo.tree['goods-a'] = [_item('row-a1', 'goods-x', '刷新后的组件')];
      // Exercise the same reload callback the table exposes for recovery.
      _table(tester).onRetry!();
      await _pumpFrames(tester);
      expect(find.text('原始组件'), findsOneWidget);
      expect(repo.listCalls, ['goods-a'], reason: '同一父件的刷新等审计写入完成');

      repo.requests.single.result.complete(
        _item('row-a1', 'goods-x', '迟到的旧审计响应', audited: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('刷新后的组件'), findsOneWidget);
      expect(find.text('迟到的旧审计响应'), findsNothing);
      expect(find.byTooltip(_markTooltip), findsOneWidget);
      expect(find.byTooltip(_unmarkTooltip), findsNothing);
      expect(_saving('goods-a|row-a1'), findsNothing);
      expect(repo.listCalls, ['goods-a', 'goods-a']);
      oldAction();
      await tester.pumpAndSettle();
      expect(repo.requests, hasLength(1), reason: '刷新前节点留下的回调不能编辑新节点');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a subtree GET overlapping audit is reread before adding its nodes',
    (tester) async {
      final repo = _AuditRepository({
        'goods-a': [
          _item('row-left', 'goods-shared', '左装配', hasChildren: true),
          _item('row-right', 'goods-shared', '右装配', hasChildren: true),
        ],
        'goods-shared': [_item('row-shared', 'goods-y', '原始组件')],
      });
      await _pumpTab(tester, repo);
      await _expand(tester, 'row-left');
      final staleRead = repo.delayNextList('goods-shared');
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-right')),
      );
      await _pumpFrames(tester);
      expect(repo.listCalls, ['goods-a', 'goods-shared', 'goods-shared']);

      await tester.tap(find.byTooltip(_markTooltip).at(1));
      await tester.pump();
      expect(repo.requests.single.identity, (
        'goods-shared',
        'row-shared',
        true,
      ));
      repo.tree['goods-shared'] = [
        _item('row-shared', 'goods-y', '最新组件', audited: true),
      ];
      repo.requests.single.result.complete(
        _item('row-shared', 'goods-y', '最新组件', audited: true),
      );
      await _pumpFrames(tester);
      expect(find.byTooltip(_unmarkTooltip), findsOneWidget);

      // This GET began before the PUT, but its obsolete snapshot arrives last.
      staleRead.complete([_item('row-shared', 'goods-y', '过期组件')]);
      await tester.pumpAndSettle();
      expect(repo.listCalls, [
        'goods-a',
        'goods-shared',
        'goods-shared',
        'goods-shared',
      ]);
      expect(find.text('最新组件'), findsNWidgets(2));
      expect(find.text('过期组件'), findsNothing);
      expect(find.byTooltip(_unmarkTooltip), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final changedIdentity in [true, false]) {
    testWidgets(
      'audit discards obsolete children (changed identity: $changedIdentity)',
      (tester) async {
        final repo = _AuditRepository({
          'goods-a': [_item('row-a1', 'goods-x', '原父组件', hasChildren: true)],
          'goods-x': [_item('row-x1', 'goods-y', '旧子件')],
          'goods-new': [_item('row-new1', 'goods-z', '新子件')],
        });
        await _pumpTab(tester, repo);
        await _expand(tester, 'row-a1');
        await tester.tap(find.text('旧子件'));
        await tester.pumpAndSettle();
        expect(_table(tester).selectedIds, {'goods-x|row-x1'});
        final loaded = List<String>.of(repo.listCalls);

        await tester.tap(find.byTooltip(_markTooltip).first);
        await tester.pump();
        repo.requests.single.result.complete(
          _item(
            'row-a1',
            changedIdentity ? 'goods-new' : 'goods-x',
            '变更后的父组件',
            audited: true,
            hasChildren: changedIdentity,
          ),
        );
        await tester.pumpAndSettle();

        expect(repo.listCalls, loaded);
        expect(find.text('变更后的父组件'), findsOneWidget);
        expect(find.text('旧子件'), findsNothing);
        expect(_table(tester).selectedIds, isEmpty);
        final cell = tester.widget<UtenTreeTableCell>(
          find.byKey(const ValueKey('goods-bom-tree-cell-row-a1')),
        );
        expect(cell.expanded, isFalse);
        expect(cell.hasChildren, changedIdentity);
        if (changedIdentity) {
          await _expand(tester, 'row-a1');
          expect(find.text('新子件'), findsOneWidget);
          expect(find.text('旧子件'), findsNothing);
          expect(repo.listCalls, [...loaded, 'goods-new']);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an old subtree expansion cannot attach beneath a changed component',
    (tester) async {
      final repo = _AuditRepository({
        'goods-a': [_item('row-a1', 'goods-x', '原父组件', hasChildren: true)],
        'goods-new': [_item('row-new1', 'goods-z', '新子件')],
      });
      await _pumpTab(tester, repo);
      final oldChildren = repo.delayNextList('goods-x');
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-a1')),
      );
      await _pumpFrames(tester);
      expect(repo.listCalls, ['goods-a', 'goods-x']);

      await tester.tap(find.byTooltip(_markTooltip));
      await tester.pump();
      repo.requests.single.result.complete(
        _item(
          'row-a1',
          'goods-new',
          '变更后的父组件',
          audited: true,
          hasChildren: true,
        ),
      );
      await _pumpFrames(tester);
      oldChildren.complete([_item('row-x1', 'goods-y', '旧子件')]);
      await tester.pumpAndSettle();

      expect(find.text('变更后的父组件'), findsOneWidget);
      expect(find.text('旧子件'), findsNothing);
      final cell = tester.widget<UtenTreeTableCell>(
        find.byKey(const ValueKey('goods-bom-tree-cell-row-a1')),
      );
      expect(cell.expanded, isFalse);
      expect(cell.subtitle, isNull);
      await _expand(tester, 'row-a1');
      expect(find.text('新子件'), findsOneWidget);
      expect(repo.listCalls, ['goods-a', 'goods-x', 'goods-new']);
      expect(tester.takeException(), isNull);
    },
  );
}

GoodsBomItem _item(
  String id,
  String componentGoodsId,
  String name, {
  bool audited = false,
  bool hasChildren = false,
}) => GoodsBomItem(
  id: id,
  componentGoodsId: componentGoodsId,
  componentCode: id,
  componentName: name,
  qty: 1,
  hasChildren: hasChildren,
  auditedAt: audited ? DateTime.utc(2026, 10) : null,
);

GoodsBomItem _sharedItem({bool audited = false}) => GoodsBomItem(
  id: 'row-shared',
  componentGoodsId: 'goods-nested',
  componentCode: 'SHARED-01',
  componentName: '共同组件',
  componentSpec: '精密规格',
  componentUnitName: '千克',
  componentColorName: '白色',
  qty: 2.25,
  price: 12.5,
  total: 28.125,
  hasChildren: true,
  systemLearned: true,
  actual: const BomActualUsage(
    qty: 2.375,
    perUnitQty: 2.375,
    status: BomActualStatus.actual,
    usesActual: true,
    netQty: 950,
    outputQty: 400,
    sampleCount: 3,
  ),
  auditedAt: audited ? DateTime.utc(2026, 10) : null,
);

Finder _saving(String rowKey) =>
    find.byKey(ValueKey('goods-bom-audit-saving-$rowKey'));

IconButton _auditButton(WidgetTester tester, String tooltip, int index) =>
    tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip(tooltip).at(index),
        matching: find.byType(IconButton),
      ),
    );

MasterDataTableView<dynamic> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<dynamic>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<dynamic>,
      ),
    );

Future<void> _pumpFrames(WidgetTester tester) async {
  // Pending spinners animate forever; settle only after every request finishes.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _expand(WidgetTester tester, String rowId) async {
  // The pinned selection column makes ensureVisible move these tree arrows
  // under its clip. They already fit in the 1600-pixel test viewport.
  await tester.tap(find.byKey(ValueKey('goods-bom-tree-toggle-$rowId')));
  await tester.pumpAndSettle();
}

Future<void> _pumpTab(WidgetTester tester, _AuditRepository repo) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue({Perm.goodsBomAudit}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GoodsBomTab(
                  goodsId: 'goods-a',
                  canCreate: false,
                  canEdit: true,
                  canDelete: false,
                ),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('审计模式'));
  await tester.pumpAndSettle();
}

class _AuditRequest {
  _AuditRequest(this.goodsId, this.itemId, this.audited);

  final String goodsId;
  final String itemId;
  final bool audited;
  final result = Completer<GoodsBomItem>();

  (String, String, bool) get identity => (goodsId, itemId, audited);
}

class _AuditRepository implements GoodsBomRepository {
  _AuditRepository(this.tree);

  final Map<String, List<GoodsBomItem>> tree;
  final listCalls = <String>[];
  final requests = <_AuditRequest>[];
  final _delayedReads = <String, List<Completer<List<GoodsBomItem>>>>{};

  Completer<List<GoodsBomItem>> delayNextList(String goodsId) {
    final result = Completer<List<GoodsBomItem>>();
    _delayedReads.putIfAbsent(goodsId, () => []).add(result);
    return result;
  }

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    final delayed = _delayedReads[goodsId];
    if (delayed != null && delayed.isNotEmpty) {
      return delayed.removeAt(0).future;
    }
    return List<GoodsBomItem>.of(tree[goodsId] ?? const []);
  }

  @override
  Future<GoodsBomItem> setAudited(String goodsId, String itemId, bool audited) {
    final request = _AuditRequest(goodsId, itemId, audited);
    requests.add(request);
    return request.result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
