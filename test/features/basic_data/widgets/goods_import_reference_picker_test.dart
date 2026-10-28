import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_task_progress_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_import_reference_picker.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'importer-a'),
);

class _Categories extends Fake implements ProductCategoryRepository {
  int reads = 0;
  Completer<List<ProductCategoryNode>>? pending;

  @override
  Future<List<ProductCategoryNode>> tree() async {
    reads++;
    return pending?.future ??
        [
          ProductCategoryNode(
            id: 'root',
            code: 'G',
            name: '货品资料',
            level: 0,
            goodsCount: 0,
            children: [
              ProductCategoryNode(
                id: 'finished',
                code: 'F',
                name: '成品',
                level: 1,
                goodsCount: 0,
                children: [
                  ProductCategoryNode(
                    id: 'leaf',
                    code: 'L',
                    name: '20A/45A-N系列',
                    level: 2,
                    goodsCount: 0,
                    children: const [],
                  ),
                ],
              ),
            ],
          ),
        ];
  }
}

class _Fixture {
  final categories = _Categories();
  GoodsImportReferenceSelection? picked;
  bool closed = false;
  bool current = true;
  late ProviderContainer container;
}

Future<_Fixture> _open(
  WidgetTester tester, {
  required String field,
  String currentValue = '',
  List<String> draftValues = const [],
  List<String> currentCategorySegments = const [],
  _Fixture? fixture,
  bool settle = true,
  bool unitFailure = false,
  Size size = const Size(1400, 900),
  double textScale = 1,
}) async {
  final result = fixture ?? _Fixture();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        productCategoryRepositoryProvider.overrideWithValue(result.categories),
        colorDictProvider.overrideWith(
          (_) async => const [
            ColorListItem(id: 'red', name: '红'),
            ColorListItem(id: 'white', name: '白'),
          ],
        ),
        unitDictProvider.overrideWith((_) async {
          if (unitFailure) throw ApiException('FORBIDDEN', '暂不能读取单位');
          return const [
            UnitListItem(id: 'piece', name: '个'),
            UnitListItem(id: 'box', name: '箱'),
          ];
        }),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              result.container = ProviderScope.containerOf(context);
              return Column(
                children: [
                  Text('当前：$currentValue'),
                  TextButton(
                    onPressed: () async {
                      result.picked = await pickGoodsImportReference(
                        context,
                        ref,
                        field: field,
                        currentValue: currentValue,
                        draftValues: draftValues,
                        currentCategorySegments: currentCategorySegments,
                        isCurrent: () => result.current,
                      );
                      result.closed = true;
                    },
                    child: const Text('打开选择器'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开选择器'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }
  return result;
}

void main() {
  testWidgets(
    'category selection returns the full true path including empty categories and delimiter-bearing names',
    (tester) async {
      final fixture = await _open(tester, field: 'categoryPath');
      expect(fixture.categories.reads, 1);
      expect(find.text('20A/45A-N系列'), findsOneWidget);
      await tester.tap(find.text('20A/45A-N系列'));
      await tester.pumpAndSettle();
      expect(fixture.closed, isFalse);
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(fixture.picked?.value, '货品资料 / 成品 / 20A/45A-N系列');
      expect(fixture.picked?.categorySegments, ['货品资料', '成品', '20A/45A-N系列']);
    },
  );

  testWidgets(
    'current category path can be confirmed without guessing delimiters',
    (tester) async {
      final fixture = await _open(
        tester,
        field: 'categoryPath',
        currentValue: '货品资料-成品-20A/45A-N系列',
        currentCategorySegments: ['货品资料', '成品', '20A/45A-N系列'],
      );
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(fixture.picked?.categorySegments, ['货品资料', '成品', '20A/45A-N系列']);
    },
  );

  testWidgets(
    'named values combine session dictionaries and draft names but only return after confirmation',
    (tester) async {
      final fixture = await _open(
        tester,
        field: 'colorName',
        currentValue: '红',
        draftValues: [' 新蓝 ', '红', '新蓝'],
      );
      await tester.enterText(
        find.byKey(const ValueKey('goods-import-reference-search-colorName')),
        '新蓝',
      );
      await tester.pumpAndSettle();
      final option = find.byKey(
        const ValueKey('goods-import-reference-option-colorName-新蓝'),
      );
      expect(option, findsOneWidget);
      await tester.tap(option);
      await tester.pump();
      expect(fixture.closed, isFalse);
      await tester.tap(
        find.byKey(const ValueKey('goods-import-reference-confirm-colorName')),
      );
      await tester.pumpAndSettle();
      expect(fixture.picked?.value, '新蓝');
      expect(fixture.picked?.categorySegments, isEmpty);
    },
  );

  testWidgets(
    'canceling a staged unit choice leaves the original input untouched',
    (tester) async {
      final fixture = await _open(tester, field: 'unitName', currentValue: '个');
      await tester.tap(
        find.byKey(const ValueKey('goods-import-reference-option-unitName-箱')),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '取消'));
      await tester.pumpAndSettle();
      expect(fixture.closed, isTrue);
      expect(fixture.picked, isNull);
      expect(find.text('当前：个'), findsOneWidget);
    },
  );

  testWidgets(
    'dictionary failures show the actual error and preserve the existing input',
    (tester) async {
      final fixture = await _open(
        tester,
        field: 'unitName',
        currentValue: '个',
        unitFailure: true,
      );
      expect(fixture.closed, isTrue);
      expect(fixture.picked, isNull);
      expect(find.text('当前：个'), findsOneWidget);
      expect(
        fixture.container.read(appNotificationProvider).single.message,
        '暂不能读取单位',
      );
      expect(
        find.byKey(const ValueKey('goods-import-reference-options-unitName')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'identity invalidation closes loading immediately and suppresses a late category tree',
    (tester) async {
      final fixture = _Fixture()
        ..categories.pending = Completer<List<ProductCategoryNode>>();
      await _open(
        tester,
        field: 'categoryPath',
        fixture: fixture,
        settle: false,
      );
      expect(find.byType(UtenTaskProgressDialog), findsOneWidget);
      fixture.container.read(_identity.notifier).state =
          const AuthenticatedScope(userId: 'importer-b');
      await tester.pumpAndSettle();
      expect(find.byType(UtenTaskProgressDialog), findsNothing);
      fixture.categories.pending!.complete([]);
      await tester.pumpAndSettle();
      expect(fixture.closed, isTrue);
      expect(fixture.picked, isNull);
      expect(find.text('选择分类'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity invalidation removes an already open dictionary panel',
    (tester) async {
      final fixture = await _open(
        tester,
        field: 'colorName',
        currentValue: '红',
      );
      fixture.container.read(_identity.notifier).state =
          const AuthenticatedScope(userId: 'importer-b');
      await tester.pumpAndSettle();
      expect(fixture.closed, isTrue);
      expect(fixture.picked, isNull);
      expect(find.text('选择颜色'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long names stay single line in a compact large-text picker', (
    tester,
  ) async {
    const name = '这是一项很长很长的导入颜色名称用于检查窄屏省略号';
    await _open(
      tester,
      field: 'colorName',
      draftValues: [name],
      size: const Size(390, 844),
      textScale: 2,
    );
    final row = find.byKey(
      const ValueKey('goods-import-reference-option-colorName-$name'),
    );
    final label = tester.widget<Text>(
      find.descendant(of: row, matching: find.text(name)),
    );
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
