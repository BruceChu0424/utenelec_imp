import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_node_actions.dart';

const _categoryId = '00000000-0000-0000-0000-000000000001';

class _Categories implements ProductCategoryRepository {
  Object? previewFailure;
  int previewCalls = 0;
  int deleteCalls = 0;
  int goodsCount = 0;

  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: _categoryId,
      code: 'C',
      name: '导入后的货品分类',
      level: 0,
      children: const [],
    ),
  ];

  @override
  Future<ProductCategoryDeletePreview> deletePreview(String id) async {
    expectSync(id, _categoryId);
    previewCalls++;
    if (previewFailure case final failure?) throw failure;
    return ProductCategoryDeletePreview(
      id: _categoryId,
      descendantCount: 0,
      goodsCount: goodsCount,
    );
  }

  @override
  Future<void> delete(String id) async {
    expectSync(id, _categoryId);
    deleteCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MouldCategories implements MouldCategoryRepository {
  _MouldCategories(this.categories);
  final _Categories categories;

  @override
  Future<List<ProductCategoryNode>> tree() => categories.tree();

  @override
  Future<MouldCategoryDeletePreview> deletePreview(String id) async {
    final preview = await categories.deletePreview(id);
    return MouldCategoryDeletePreview(
      id: preview.id,
      descendantCount: preview.descendantCount,
      mouldCount: preview.goodsCount,
    );
  }

  @override
  Future<void> delete(String id) => categories.delete(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  _Categories categories, {
  bool mould = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        apiClientProvider.overrideWithValue(
          ApiClient(
            Dio()
              ..interceptors.add(
                InterceptorsWrapper(
                  onRequest: (request, handler) => handler.resolve(
                    Response(
                      requestOptions: request,
                      statusCode: 200,
                      data: {'items': <Object>[], 'totalElements': 0},
                    ),
                  ),
                ),
              ),
          ),
        ),
        apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'category-maintainer'),
        ),
        currentPermissionsProvider.overrideWithValue({
          if (mould) ...{
            Perm.mouldView,
            Perm.mouldCategoryView,
            Perm.mouldCategoryDelete,
          } else ...{
            Perm.goodsView,
            Perm.materialCategoryView,
            Perm.materialCategoryDelete,
          },
        }),
        isSuperAdminProvider.overrideWithValue(false),
        productCategoryRepositoryProvider.overrideWithValue(categories),
        mouldCategoryRepositoryProvider.overrideWithValue(
          _MouldCategories(categories),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: mould ? const MouldCategoryPage() : const ProductCategoryPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final virtualRoot = find.byTooltip('展开全部模具');
  if (virtualRoot.evaluate().isNotEmpty) {
    await tester.tap(virtualRoot);
    await tester.pumpAndSettle();
  }
}

Future<void> _deleteFromTree(WidgetTester tester) {
  final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
    find.byType(UtenCategoryTreeView<ProductCategoryNode>),
  );
  ProductCategoryNode? target(Iterable<ProductCategoryNode> nodes) {
    for (final node in nodes) {
      if (node.id == _categoryId) return node;
      final nested = target(node.children);
      if (nested != null) return nested;
    }
    return null;
  }

  final actions =
      tree.trailingBuilder!(target(tree.nodes)!) as UtenHierarchyNodeActions;
  return Future<void>.sync(actions.operations.delete!.onInvoke);
}

void main() {
  for (final mould in [false, true]) {
    final noun = mould ? '模具' : '货品';
    for (final failure in [
      ApiException('NETWORK', '删除范围暂时无法读取'),
      StateError('Unexpected preview response'),
    ]) {
      testWidgets('$noun删除范围预检失败不能退回通用确认：${failure.runtimeType}', (
        tester,
      ) async {
        final categories = _Categories()..previewFailure = failure;
        await _pump(tester, categories, mould: mould);
        final pending = _deleteFromTree(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();

        expect(categories.previewCalls, 1);
        expect(categories.deleteCalls, 0);
        expect(find.text('删除失败'), findsOneWidget);
        expect(find.textContaining('无法确认删除范围，请重试后再删除。'), findsOneWidget);
        expect(find.text('删除分类'), findsNothing);
        expect(find.widgetWithText(FilledButton, '删除'), findsNothing);
        if (failure is ApiException) {
          expect(find.textContaining(failure.message), findsOneWidget);
        }

        await tester.tap(find.byType(UtenCloseButton).last);
        await tester.pumpAndSettle();
        await pending;
        expect(categories.deleteCalls, 0);

        // The failed attempt releases the action so an explicit retry can
        // obtain a fresh scope and still cancel without deleting anything.
        categories.previewFailure = null;
        final retry = _deleteFromTree(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        expect(categories.previewCalls, 2);
        expect(find.text('删除分类'), findsOneWidget);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        await retry;
        expect(categories.deleteCalls, 0);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('含$noun分类说明级联影响，用户确认后才发送删除', (tester) async {
      final categories = _Categories()..goodsCount = 25;
      await _pump(tester, categories, mould: mould);
      final pending = _deleteFromTree(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.text('• 25 个$noun'), findsOneWidget);
      if (!mould) {
        expect(find.textContaining('这些货品的组装信息（BOM）也会删除'), findsOneWidget);
      }
      expect(find.text('删除分类'), findsOneWidget);
      expect(categories.deleteCalls, 0);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      await pending;
      expect(categories.deleteCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$noun空分类预检成功且用户确认后才发送删除', (tester) async {
      final categories = _Categories();
      await _pump(tester, categories, mould: mould);
      final pending = _deleteFromTree(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.text('删除分类'), findsOneWidget);
      expect(categories.deleteCalls, 0);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      await pending;
      expect(categories.deleteCalls, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
