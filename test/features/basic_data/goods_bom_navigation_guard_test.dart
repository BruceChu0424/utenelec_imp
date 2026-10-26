import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

import '../../support/goods_bom_edit_test_api.dart';

const _goods = GoodsDetail(id: 'goods-nav', name: '返回保护货品', writable: true);

class _Goods extends Fake implements GoodsRepository {
  @override
  Future<GoodsDetail> detail(String id) async => _goods;
}

class _Bom extends Fake implements GoodsBomRepository {
  GoodsBomItem item = const GoodsBomItem(
    id: 'nav-row',
    componentGoodsId: 'component',
    componentName: '组件',
    qty: 1,
  );
  int writes = 0;

  @override
  Future<List<GoodsBomItem>> list(String id) async => [item];

  @override
  Future<GoodsBomLearningSummary> learning(String id) async =>
      const GoodsBomLearningSummary();

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    writes++;
    item = GoodsBomItem.fromJson({...bomItemTestJson(item), ...body});
    return item;
  }
}

void main() {
  for (final navigation in ['header', 'system', 'go', 'platform']) {
    testWidgets(
      '$navigation return asks before losing BOM edits and supports all three decisions',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bom = _Bom();
        final api = GoodsBomEditTestApi(bom);
        final router = GoRouter(
          routes: [
            DraftAwareGoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('资料列表')),
            ),
            DraftAwareGoRoute(
              path: '/goods',
              builder: (_, _) => const Scaffold(
                body: GoodsDetailBody(
                  initialDetail: _goods,
                  initialCategoryId: null,
                  initialTab: GoodsDetailTab.bom,
                  canCreate: false,
                  canEdit: false,
                  canStatus: false,
                  canBomCreate: false,
                  canBomEdit: true,
                  canBomDelete: false,
                  onToggleStatus: null,
                  onDelete: null,
                  onDataChanged: null,
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentPermissionsProvider.overrideWithValue({
                Perm.goodsView,
                Perm.goodsBomEdit,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              goodsRepositoryProvider.overrideWithValue(_Goods()),
              goodsBomRepositoryProvider.overrideWithValue(bom),
              apiClientProvider.overrideWithValue(api),
              colorDictProvider.overrideWith((ref) async => const []),
              unitDictProvider.overrideWith((ref) async => const []),
            ],
            child: MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> openAndEdit() async {
          router.push<void>('/goods');
          await tester.pumpAndSettle();
          await enterBomEdit(tester);
          await tester.enterText(
            await activateBomEditor(
              tester,
              'goods-bom-inline-qty-goods-nav/nav-row',
            ),
            '5',
          );
        }

        Future<void> requestBack() async {
          switch (navigation) {
            case 'system':
              await tester.binding.handlePopRoute();
            case 'go':
              router.go('/');
            case 'platform':
              // Browser back/forward updates are delivered through this same
              // platform route-information callback, rather than maybePop.
              await router.routeInformationProvider.didPushRouteInformation(
                RouteInformation(uri: Uri.parse('/')),
              );
            default:
              await tester.tap(find.byKey(const Key('goods-detail-back')));
          }
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('goods-bom-save-confirm')),
            findsOneWidget,
          );
          expect(api.commitCalls, 0);
        }

        await openAndEdit();
        await requestBack();
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        expect(find.byType(GoodsDetailBody), findsOneWidget);
        expect(
          tester
              .widget<TextField>(
                await activateBomEditor(
                  tester,
                  'goods-bom-inline-qty-goods-nav/nav-row',
                ),
              )
              .controller!
              .text,
          '5',
        );
        await requestBack();
        await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
        await tester.pumpAndSettle();
        expect(find.text('资料列表'), findsOneWidget);
        expect(bom.item.qty, 1);
        expect(bom.writes, 0);

        await openAndEdit();
        await requestBack();
        await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
        await tester.pumpAndSettle();
        expect(find.text('资料列表'), findsOneWidget);
        expect(bom.item.qty, 5);
        expect(bom.writes, 1);
        expect(api.commitCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
