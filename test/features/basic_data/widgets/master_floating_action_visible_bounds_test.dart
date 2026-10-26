import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  testWidgets(
    'clipped local viewport reserves enough real clearance for the final row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 760,
                height: 320,
                child: ClipRect(
                  key: const Key('clipped-table-viewport'),
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minHeight: 600,
                    maxHeight: 600,
                    child: MasterDataTableView<String>(
                      columns: [
                        for (var i = 0; i < 4; i++)
                          MasterColumnDef<String>(
                            key: 'c$i',
                            label: '字段$i',
                            width: 240,
                            value: (row) => '$row ${'x' * 40}',
                          ),
                      ],
                      items: [for (var i = 0; i < 60; i++) 'row-$i'],
                      selectable: true,
                      idOf: (row) => row,
                      rowKeyOf: (row) => row,
                      rowWidgetKeyOf: (row) => ValueKey('clipped-$row'),
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      batchActionsBuilder: (_, _) => [
                        UtenButton(
                          key: const Key('clipped-action'),
                          size: UtenButtonSize.large,
                          onPressed: () {},
                          child: const Text('办理操作'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(const Key('clipped-action'));
      final viewport = tester.getRect(
        find.byKey(const Key('clipped-table-viewport')),
      );
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(viewport.bottom));
      final body = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      body.jumpTo(body.maxScrollExtent);
      await tester.pumpAndSettle();
      final row = tester.getRect(find.byKey(const ValueKey('clipped-row-59')));
      final group = tester.getRect(find.byType(UtenFloatingActionGroup));
      expect(row.bottom, lessThanOrEqualTo(group.top - 11 + .5));
      expect(group.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(action.hitTestable(), findsOneWidget);
    },
  );

  for (final height in [650.0, 950.0, 1300.0]) {
    for (final selected in [false, true]) {
      testWidgets(
        'real master pane actions remain visible at $height selected=$selected through header and fullscreen',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(1366, height));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          var creates = 0;
          final config = MasterEntityPaneConfig<String, String>(
            noun: '货品',
            icon: Icons.inventory_2_outlined,
            defaultCodePrefix: 'HP',
            columns: [
              for (var i = 0; i < 9; i++)
                MasterColumnDef<String>(
                  key: 'c$i',
                  label: '货品字段$i',
                  width: 180,
                  value: (row) => '$row 字段$i',
                ),
            ],
            inlineFields: {
              'c0': MasterInlineField<String>(key: 'c0', read: (row) => row),
            },
            onInlineSave: (_, _, _) async {},
            idOf: (row) => row,
            statusOf: (_) => '使用',
            labelOf: (row) => row,
            loadCategory: (id) async => ProductCategoryDetail(
              id: id,
              code: 'C1',
              name: '货品分类与装配组件',
              level: 2,
              path: '公司 / 成品 / 货品分类与装配组件',
              childCount: 0,
              effectivePrefix: 'HP',
            ),
            loadPage: (query) async => PagedResult<String>(
              items: [for (var i = 0; i < 20; i++) '货品${query.page}-$i'],
              page: query.page,
              size: 20,
              total: 9691,
              totalPages: 485,
            ),
            loadFacets: (_) async =>
                const MasterPaneFacets(fields: {}, nullCounts: {}),
            batchEntityPath: '/master/goods',
            statusResourceOf: (id) => '/master/goods/$id',
            canCreate: true,
            canEdit: true,
            canDelete: false,
            canStatus: false,
            onCreate: (_) async {
              creates++;
            },
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                apiClientProvider.overrideWithValue(ApiClient(Dio())),
                sessionProvider.overrideWith(_Session.new),
                authenticatedScopeProvider.overrideWithValue(
                  const AuthenticatedScope(userId: 'floating-master-test'),
                ),
                currentPermissionsProvider.overrideWithValue({
                  Perm.goodsView,
                  Perm.goodsEdit,
                  Perm.goodsCreate,
                }),
                isSuperAdminProvider.overrideWithValue(false),
                sharedPreferencesProvider.overrideWithValue(preferences),
              ],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                home: Scaffold(
                  appBar: AppBar(title: const Text('货品资料')),
                  body: MasterEntityDetailPane<String, String>(
                    config: config,
                    categoryId: 'category',
                    externalKeyword: null,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final tableFinder = find.byType(MasterDataTableView<String>);
          MasterDataTableView<String> table() => tester.widget(tableFinder);
          if (selected) {
            table().onSelectedIdsChanged!({'货品1-0'});
            await tester.pumpAndSettle();
          }
          final add = find.byKey(const ValueKey('master-add-entity'));
          final edit = find.text('编辑模式');
          void visibleActions(String phase) {
            for (final target in [add, edit]) {
              final rect = tester.getRect(target);
              expect(rect.top, greaterThanOrEqualTo(0), reason: phase);
              expect(rect.bottom, lessThanOrEqualTo(height), reason: phase);
              expect(target.hitTestable(), findsOneWidget, reason: phase);
            }
          }

          visibleActions('expanded header');
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(creates, 1);
          final ancestors = find.ancestor(
            of: tableFinder,
            matching: find.byType(Scrollable),
          );
          final outer = tester.state<ScrollableState>(ancestors.first).position;
          outer.jumpTo(outer.maxScrollExtent);
          await tester.pumpAndSettle();
          visibleActions('collapsed header');
          final toggle = find.byKey(
            const ValueKey('master-table-fullscreen-toggle'),
          );
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          visibleActions('fullscreen');
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(creates, 2);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          outer.jumpTo(outer.minScrollExtent);
          await tester.pumpAndSettle();
          visibleActions('expanded again');
          expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
