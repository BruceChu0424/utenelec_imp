import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final scenario in [
    (kind: 'goods', empty: true, categoryAccess: true, width: 1600.0),
    (kind: 'goods', empty: true, categoryAccess: true, width: 375.0),
    (kind: 'goods', empty: false, categoryAccess: true, width: 1600.0),
    (kind: 'goods', empty: false, categoryAccess: true, width: 834.0),
    (kind: 'goods', empty: false, categoryAccess: false, width: 1600.0),
    (kind: 'client', empty: true, categoryAccess: true, width: 1600.0),
    (kind: 'supplier', empty: true, categoryAccess: true, width: 1600.0),
    (kind: 'mould', empty: true, categoryAccess: true, width: 1600.0),
  ]) {
    testWidgets(
      '${scenario.kind} empty=${scenario.empty} categoryAccess=${scenario.categoryAccess} ${scenario.width} 逐字输入不丢焦点',
      (tester) async {
        tester.view.physicalSize = Size(scenario.width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              final path = request.path;
              final Object data;
              if (path.endsWith('/tree')) {
                data = scenario.empty
                    ? []
                    : [
                        {
                          'id': 'cat-a',
                          'code': 'A',
                          'name': '分类A',
                          'level': 0,
                          'children': <Object?>[],
                        },
                      ];
              } else if (path.endsWith('/search-category-ids')) {
                data = <String>[];
              } else if (path.endsWith('/facets')) {
                data = <String, Object?>{};
              } else if (path.contains('-categories/')) {
                data = {
                  'id': 'cat-a',
                  'code': 'A',
                  'name': '分类A',
                  'path': '/cat-a/',
                  'childCount': 0,
                };
              } else {
                data = {
                  'items': <Object?>[],
                  'page': 1,
                  'size': 20,
                  'total': 0,
                  'totalPages': 1,
                };
              }
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: data,
                ),
              );
            },
          ),
        );
        final page = switch (scenario.kind) {
          'goods' => const ProductCategoryPage(),
          'client' => const ClientCategoryPage(),
          'supplier' => const SupplierCategoryPage(),
          _ => const MouldCategoryPage(),
        };
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              apiClientProvider.overrideWithValue(ApiClient(dio)),
              currentPermissionsProvider.overrideWithValue({
                '${scenario.kind}:view',
                if (scenario.categoryAccess)
                  scenario.kind == 'goods'
                      ? Perm.materialCategoryView
                      : '${scenario.kind}_category:view',
              }),
              isSuperAdminProvider.overrideWithValue(false),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: page,
            ),
          ),
        );
        await tester.pumpAndSettle();
        Finder input() => find.descendant(
          of: find.byType(UtenSearchBar).hitTestable().first,
          matching: find.byType(EditableText),
        );
        final element = tester.element(input());
        final controller = tester.widget<EditableText>(input()).controller;
        await tester.tap(input());
        await tester.pump();
        expect(tester.widget<EditableText>(input()).focusNode.hasFocus, isTrue);
        // Send edits to the active input connection. Unlike tester.enterText(finder,...),
        // this never refocuses or reattaches a field after the page changes mode.
        tester.testTextInput.enterText('U');
        await tester.pump();
        expect(
          tester.element(input()),
          same(element),
          reason: '空查询进入全局查询不能换掉搜索字段',
        );
        expect(tester.widget<EditableText>(input()).focusNode.hasFocus, isTrue);
        expect(
          tester.widget<EditableText>(input()).controller,
          same(controller),
        );
        expect(controller.text, 'U');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'UA',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        expect(controller.text, 'UA');
        expect(tester.widget<EditableText>(input()).focusNode.hasFocus, isTrue);
        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        await tester.pumpAndSettle();
        expect(tester.element(input()), same(element));
        expect(tester.widget<EditableText>(input()).focusNode.hasFocus, isTrue);
        expect(controller.text, isEmpty);
        tester.testTextInput.enterText('Z');
        await tester.pumpAndSettle();
        expect(controller.text, 'Z');
        expect(
          tester.widget<EditableText>(input()).controller,
          same(controller),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
