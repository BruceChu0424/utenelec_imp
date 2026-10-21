import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../support/goods_bom_edit_test_api.dart';

GoodsBomItem _row(String id, {bool children = false}) => GoodsBomItem(
  id: 'edge-$id',
  componentGoodsId: id,
  componentName: '组件$id',
  qty: 1,
  hasChildren: children,
);

class _Repo extends Fake implements GoodsBomRepository {
  final tree = <String, List<GoodsBomItem>>{};
  final pending = <String, Completer<List<GoodsBomItem>>>{};
  final calls = <String>[];
  Completer<int>? deleting;
  VoidCallback? beforeDelete;
  int deleteCalls = 0;

  @override
  Future<List<GoodsBomItem>> list(String id) async {
    calls.add(id);
    return pending[id]?.future ?? tree[id] ?? const [];
  }

  @override
  Future<GoodsBomLearningSummary> learning(String id) async =>
      const GoodsBomLearningSummary();

  @override
  Future<int> deleteMany(String id, List<String> itemIds) async {
    deleteCalls++;
    beforeDelete?.call();
    final result = await (deleting?.future ?? Future.value(itemIds.length));
    tree[id]?.removeWhere((item) => itemIds.contains(item.id));
    return result;
  }
}

Future<GoodsBomTabState> _pump(
  WidgetTester tester,
  _Repo repo, {
  ValueChanged<bool>? onInteraction,
}) async {
  final bomKey = GlobalKey<GoodsBomTabState>();
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        apiClientProvider.overrideWithValue(GoodsBomEditTestApi(repo)),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsBomEdit,
          Perm.goodsBomDelete,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GoodsBomTab(
            key: bomKey,
            goodsId: 'root',
            canCreate: false,
            canEdit: true,
            canDelete: true,
            onInteractionChanged: onInteraction,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bomKey.currentState!;
}

void main() {
  testWidgets(
    'slow refresh keeps the large displayed table scrollable and caches its projection',
    (tester) async {
      final repo = _Repo()
        ..tree['root'] = [for (var i = 0; i < 512; i++) _row('$i')];
      final bom = await _pump(tester, repo);
      final tableFinder = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView,
      );
      final originalRows = tester
          .widget<MasterDataTableView<Object?>>(tableFinder)
          .items;
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(
        identical(
          originalRows,
          tester.widget<MasterDataTableView<Object?>>(tableFinder).items,
        ),
        isTrue,
      );
      final scroll = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere(
            (state) =>
                state.position.axis == Axis.vertical &&
                state.position.maxScrollExtent > 500,
          );
      final vertical = find.byElementPredicate(
        (element) =>
            element is StatefulElement && identical(element.state, scroll),
      );
      await tester.drag(vertical, const Offset(0, -1000));
      await tester.pumpAndSettle();
      final before = scroll.position.pixels;
      expect(before, greaterThan(0));
      repo.pending['root'] = Completer<List<GoodsBomItem>>();
      unawaited(bom.refresh());
      await tester.pump();
      expect(find.byKey(const Key('goods-bom-read-progress')), findsOneWidget);
      expect(
        identical(
          originalRows,
          tester.widget<MasterDataTableView<Object?>>(tableFinder).items,
        ),
        isTrue,
      );
      expect(scroll.position.pixels, closeTo(before, 0.1));
      await tester.drag(vertical, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 250));
      expect(scroll.position.pixels, greaterThan(before));
      repo.pending['root']!.complete(repo.tree['root']);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-read-progress')), findsNothing);
      expect(scroll.position.pixels, greaterThan(before));
    },
  );

  testWidgets(
    'expanded refresh bounds sibling reads and deduplicates shared assemblies',
    (tester) async {
      final repo = _Repo()
        ..tree['root'] = [
          for (var i = 0; i < 6; i++) _row('part-$i', children: true),
        ];
      for (var i = 0; i < 6; i++) {
        repo.tree['part-$i'] = [_row('shared', children: true)];
      }
      repo.tree['shared'] = [_row('leaf')];
      final bom = await _pump(tester, repo);
      for (var i = 0; i < 6; i++) {
        await tester.tap(
          find.byKey(ValueKey('goods-bom-tree-toggle-edge-part-$i')),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-edge-shared')).first,
      );
      await tester.pumpAndSettle();
      repo.calls.clear();
      for (var i = 0; i < 6; i++) {
        repo.pending['part-$i'] = Completer<List<GoodsBomItem>>();
      }
      unawaited(bom.refresh());
      await tester.pump(const Duration(milliseconds: 50));
      expect(repo.calls.toSet(), {
        'root',
        'part-0',
        'part-1',
        'part-2',
        'part-3',
      });
      for (var i = 0; i < 4; i++) {
        repo.pending['part-$i']!.complete(repo.tree['part-$i']);
      }
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(repo.calls, hasLength(7));
      for (var i = 4; i < 6; i++) {
        repo.pending['part-$i']!.complete(repo.tree['part-$i']);
      }
      await tester.pumpAndSettle();
      expect(repo.calls.where((id) => id == 'shared'), hasLength(1));
      expect(find.text('组件leaf'), findsWidgets);
    },
  );

  testWidgets(
    'deletion waits for reviewed commit and paints progress before writing',
    (tester) async {
      final repo = _Repo()..tree['root'] = [_row('remove')];
      final interactions = <bool>[];
      await _pump(tester, repo, onInteraction: interactions.add);
      await enterBomEdit(tester);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
      await tester.pumpAndSettle();
      expect(repo.deleteCalls, 0);
      expect(repo.tree['root'], hasLength(1));
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pumpAndSettle();
      repo.deleting = Completer<int>();
      repo.beforeDelete = () =>
          expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      expect(repo.deleteCalls, 0);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(repo.deleteCalls, 1);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(interactions.last, isTrue);
      repo.deleting!.complete(1);
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(interactions.last, isFalse);
    },
  );
}
