import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final noun in ['客户', '供应商', '货品', '模具']) {
    testWidgets(
      '$noun category displays columns and rows independently of category details and facets',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final selected = ValueNotifier('a');
        addTearDown(selected.dispose);
        final details = <String, Completer<ProductCategoryDetail>>{};
        final rows = <String, Completer<PagedResult<String>>>{};
        final facets = <String, Completer<MasterPaneFacets>>{};
        final config = MasterEntityPaneConfig<String, String>(
          noun: noun,
          icon: Icons.folder_outlined,
          defaultCodePrefix: 'T',
          columns: [
            MasterColumnDef<String>(
              key: 'name',
              label: '$noun名称',
              width: 200,
              value: (row) => row,
            ),
          ],
          idOf: (row) => row,
          labelOf: (row) => row,
          statusOf: (_) => '使用',
          loadCategory: (id) => (details[id] = Completer()).future,
          loadPage: (query) => (rows[query.categoryId!] = Completer()).future,
          loadFacets: (id) => (facets[id] = Completer()).future,
          batchEntityPath: '/master/test',
          statusResourceOf: (id) => '/master/test/$id',
          canCreate: false,
          canEdit: false,
          canDelete: false,
          canStatus: false,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(ApiClient(Dio())),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ValueListenableBuilder<String>(
                  valueListenable: selected,
                  builder: (_, category, _) =>
                      MasterEntityDetailPane<String, String>(
                        config: config,
                        categoryId: category,
                        externalKeyword: null,
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final finder = find.byType(MasterDataTableView<String>);
        expect(finder, findsOneWidget);
        expect(find.text('$noun名称'), findsOneWidget);
        final tableElement = tester.element(finder);
        rows['a']!.complete(
          const PagedResult(
            items: ['A-ROW'],
            page: 1,
            size: 20,
            total: 1,
            totalPages: 1,
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('A-ROW'), findsOneWidget);
        expect(details['a']!.isCompleted, isFalse);
        expect(facets['a']!.isCompleted, isFalse);

        selected.value = 'b';
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.element(finder), same(tableElement));
        expect(find.text('A-ROW'), findsNothing);
        expect(find.text('$noun名称'), findsOneWidget);
        details['b']!.completeError(
          ApiException('FORBIDDEN', '分类访问已撤销', httpStatus: 403),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('分类访问已撤销'), findsOneWidget);
        rows['b']!.complete(
          const PagedResult(
            items: ['DENIED-ROW'],
            page: 1,
            size: 20,
            total: 1,
            totalPages: 1,
          ),
        );
        details['a']!.complete(
          const ProductCategoryDetail(
            id: 'a',
            code: 'A',
            name: '旧分类',
            level: 0,
            path: '旧分类',
            childCount: 0,
          ),
        );
        for (final pending in facets.values) {
          pending.complete(const MasterPaneFacets(fields: {}, nullCounts: {}));
        }
        await tester.pumpAndSettle();
        expect(find.text('DENIED-ROW'), findsNothing);
        expect(find.text('A-ROW'), findsNothing);
        expect(find.text('旧分类'), findsNothing);
        expect(
          tester.widget<MasterDataTableView<String>>(finder).items,
          isEmpty,
        );
        await tester.tap(find.text('重试'));
        await tester.pump();
        details['b']!.complete(
          const ProductCategoryDetail(
            id: 'b',
            code: 'B',
            name: '新分类',
            level: 0,
            path: '新分类',
            childCount: 0,
          ),
        );
        rows['b']!.complete(
          const PagedResult<String>(
            items: [],
            page: 1,
            size: 20,
            total: 0,
            totalPages: 0,
          ),
        );
        facets['b']!.complete(
          const MasterPaneFacets(fields: {}, nullCounts: {}),
        );
        await tester.pumpAndSettle();
        expect(find.text('分类访问已撤销'), findsNothing);
        expect(find.text('新分类 (数量: 0)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
