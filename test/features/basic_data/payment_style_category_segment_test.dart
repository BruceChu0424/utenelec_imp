import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/payment_style_page.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/widgets/master_detail_card.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import '../../support/filter_segment_tap.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

class _Categories extends Fake implements PaymentStyleRepository {
  final requests = <String?>[];
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    requests.add(category);
    return const [];
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('收付款类别复用基础资料摘要卡、平铺树和相同字段回显', (tester) async {
    const capture = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
    final captureKey = GlobalKey();
    if (capture) await loadAuditScreenshotFonts(tester);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PopulatedCategories();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paymentStyleRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.paymentStyleView,
            Perm.paymentStyleEdit,
            Perm.paymentStyleReorder,
          }),
        ],
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
            home: const PaymentStylePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.widget<MasterDetailCard>(find.byType(MasterDetailCard));
    expect(card.title, '测试费用');
    expect(card.subtitle, contains('EXP-TEST'));
    final tree = tester.widget<UtenCategoryTreeView<PaymentStyleNode>>(
      find.byType(UtenCategoryTreeView<PaymentStyleNode>),
    );
    expect(tree.flatLevelColors, isTrue);
    expect(tree.rowMenuBuilder, isNotNull);
    if (capture) {
      await saveAuditScreenshot(
        tester,
        captureKey,
        'payment-style-shared-header',
      );
    }
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == '测试费用',
    );
    expect(name, findsOneWidget);
    await tester.enterText(name, '变更费用');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.updated?.toJson(), {'name': '变更费用'});
    expect(
      tester.widget<MasterDetailCard>(find.byType(MasterDetailCard)).title,
      '变更费用',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'payment category keeps its exact server value and does not clear on re-tap',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Categories();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            paymentStyleRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.paymentStyleView,
            }),
          ],
          child: const MaterialApp(home: PaymentStylePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.requests, ['EXPENSE']);
      await selectFilterSegment(tester, '收入');
      await tester.pumpAndSettle();
      expect(repository.requests, ['EXPENSE', 'INCOME']);
      await selectFilterSegment(tester, '收入');
      await tester.pumpAndSettle();
      expect(repository.requests, ['EXPENSE', 'INCOME']);
      await selectFilterSegment(tester, '结算方式');
      await tester.pumpAndSettle();
      expect(repository.requests.last, 'METHOD');
      expect(find.byTooltip('添加顶级类别'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PopulatedCategories extends Fake implements PaymentStyleRepository {
  PaymentStyleUpdateInput? updated;
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async => [
    PaymentStyleNode(
      id: 'style',
      code: 'EXP-TEST',
      name: updated?.name ?? '测试费用',
      category: 'EXPENSE',
      level: 0,
      status: '使用',
      children: const [],
    ),
  ];
  @override
  Future<PaymentStyleDetail> detail(String id) async => PaymentStyleDetail(
    id: 'style',
    code: 'EXP-TEST',
    name: updated?.name ?? '测试费用',
    category: 'EXPENSE',
    level: 0,
    path: '测试费用',
    childCount: 0,
    sortOrder: 15,
    receipt: true,
    status: '使用',
  );
  @override
  Future<PaymentStyleDetail> update(
    String id,
    PaymentStyleUpdateInput input,
  ) async {
    updated = input;
    return detail(id);
  }
}
