import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/bom_component_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Categories extends Fake implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'parts',
      code: 'PART',
      name: '半成品',
      level: 0,
      legacyId: 2149,
      children: [],
    ),
  ];
}

class _Goods extends Fake implements GoodsRepository {
  final exclusions = <bool>[];
  PagedResult<GoodsListItem> result() => const PagedResult(
    items: [
      GoodsListItem(
        id: 'inactive-part',
        code: 'OLD01',
        name: '停用旧件',
        status: '禁用',
        categoryId: 'parts',
      ),
    ],
    page: 1,
    size: 100,
    total: 1,
    totalPages: 1,
  );
  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
    bool includeRelated = false,
  }) async {
    exclusions.add(excludeDisabled);
    expect(excludeStub, isTrue);
    return result();
  }

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? sort,
    String? order,
  }) async {
    exclusions.add(excludeDisabled);
    expect(excludeStub, isTrue);
    return result();
  }

  @override
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    exclusions.add(excludeDisabled);
    return {'parts'};
  }
}

class _Launcher extends ConsumerWidget {
  const _Launcher(this.done);
  final ValueChanged<List<GoodsListItem>> done;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: TextButton(
      onPressed: () async =>
          done(await ref.read(bomComponentRemovalPickerProvider)(context, ref)),
      child: const Text('选择待移除组件'),
    ),
  );
}

void main() {
  testWidgets(
    'the shared removal picker browses searches and selects inactive old components',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final goods = _Goods();
      List<GoodsListItem>? selected;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            currentPermissionsProvider.overrideWithValue({
              Perm.goodsView,
              Perm.goodsBomEdit,
              Perm.goodsBomDelete,
            }),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'operator'),
            ),
            isSuperAdminProvider.overrideWithValue(false),
            productCategoryRepositoryProvider.overrideWithValue(_Categories()),
            goodsRepositoryProvider.overrideWithValue(goods),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: _Launcher((value) => selected = value),
          ),
        ),
      );
      await tester.tap(find.text('选择待移除组件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('半成品'));
      await tester.pumpAndSettle();
      expect(find.text('停用旧件'), findsOneWidget);
      expect(goods.exclusions, isNotEmpty);
      await tester.enterText(
        find.byKey(const Key('uten-goods-picker-search')),
        '旧件',
      );
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(goods.exclusions.every((exclude) => !exclude), isTrue);
      await tester.tap(find.text('停用旧件'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.text('确定(1)'));
      await tester.pumpAndSettle();
      expect(selected!.single.id, 'inactive-part');
    },
  );
}
