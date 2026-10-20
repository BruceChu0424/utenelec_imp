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
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';

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
    expect(
      find.descendant(
        of: find.byType(MasterDetailCard),
        matching: find.text('编辑'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('payment-style-node-edit-style')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.byType(UtenFormGrid),
      ),
      findsNWidgets(2),
    );
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
  for (final scenario in [
    (name: '普通类别', locked: false, disabled: false, viewOnly: false),
    (name: '系统科目', locked: true, disabled: false, viewOnly: false),
    (name: '停用类别', locked: false, disabled: true, viewOnly: false),
    (name: '仅查看', locked: false, disabled: false, viewOnly: true),
  ]) {
    testWidgets('${scenario.name}同行与右键动作共用权限和保护口径', (tester) async {
      final repository = _PopulatedCategories(
        locked: scenario.locked,
        disabled: scenario.disabled,
      );
      await _pumpPolicy(tester, repository, viewOnly: scenario.viewOnly);
      final tree = tester.widget<UtenCategoryTreeView<PaymentStyleNode>>(
        find.byType(UtenCategoryTreeView<PaymentStyleNode>),
      );
      final node = tree.nodes.single;
      final entries = tree.rowMenuBuilder!(node)
          .whereType<UtenMenuItem>()
          .toList();
      if (scenario.viewOnly) {
        expect(entries, isEmpty);
        expect(
          find.byKey(const ValueKey('payment-style-node-edit-style')),
          findsNothing,
        );
      } else {
        final add = tester.widget<IconButton>(
          find.byKey(const ValueKey('payment-style-node-add-style')),
        );
        final status = tester.widget<IconButton>(
          find.byKey(const ValueKey('payment-style-node-status-style')),
        );
        expect(add.onPressed != null, !scenario.locked && !scenario.disabled);
        expect(
          entries.firstWhere((entry) => entry.label == '新增子类别').enabled,
          add.onPressed != null,
        );
        expect(status.onPressed != null, !scenario.locked);
        expect(
          entries
              .firstWhere(
                (entry) => entry.label == (scenario.disabled ? '启用' : '停用'),
              )
              .enabled,
          status.onPressed != null,
        );
        expect(
          find.byKey(const ValueKey('payment-style-node-edit-style')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('窄屏大字目录同行可编辑，专用表单用共享网格且操作可达', (tester) async {
    await _pumpPolicy(tester, _PopulatedCategories(), width: 390, scale: 1.6);
    await tester.tap(
      find.byKey(const ValueKey('payment-style-open-directory')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('payment-style-node-edit-style')),
    );
    await tester.pumpAndSettle();
    expect(find.text('编辑类别'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.byType(UtenFormGrid),
      ),
      findsNWidgets(2),
    );
    await tester.ensureVisible(find.text('取消').last);
    expect(find.text('取消').last.hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
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
  _PopulatedCategories({this.locked = false, this.disabled = false});
  final bool locked;
  final bool disabled;
  String get code => locked ? '031' : 'EXP-TEST';
  String get status => disabled ? '禁用' : '使用';
  PaymentStyleUpdateInput? updated;
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async => [
    PaymentStyleNode(
      id: 'style',
      code: code,
      name: updated?.name ?? '测试费用',
      category: 'EXPENSE',
      level: 0,
      status: status,
      children: const [],
    ),
  ];
  @override
  Future<PaymentStyleDetail> detail(String id) async => PaymentStyleDetail(
    id: 'style',
    code: code,
    name: updated?.name ?? '测试费用',
    category: 'EXPENSE',
    level: 0,
    path: '测试费用',
    childCount: 0,
    sortOrder: 15,
    receipt: true,
    status: status,
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

Future<void> _pumpPolicy(
  WidgetTester tester,
  PaymentStyleRepository repository, {
  bool viewOnly = false,
  double width = 1400,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paymentStyleRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue({
          Perm.paymentStyleView,
          if (!viewOnly) ...[
            Perm.paymentStyleCreate,
            Perm.paymentStyleEdit,
            Perm.paymentStyleStatus,
            Perm.paymentStyleReorder,
          ],
        }),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const PaymentStylePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
