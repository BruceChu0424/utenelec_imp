// 各 hub 卡片的草稿计数回归（准则 14-徽章与计数口径 §草稿）。
//
// **2026-09-11 口径反转**：草稿原本是「浏览型计数」，走标题后的中性括号 `(N)`
// 且永不累加；当日用户推翻——草稿是本人开了头没交出去的活，改走**红底白字徽章**
// （[UtenDraftBadge] → [UtenNotificationBadge]）并逐级累加到 hub / 工作台。
// 本文件随之从「断言草稿绝不用红徽章」改为「断言草稿就是红徽章」。
//
// 仍然钉死的两条去重口径：
//  · 仓库「调拨」「盘点」各显自己的 doc_type 切片，不显整模块合计；
//  · 销售「客户零星发货」不显草稿数（与「销售出货」同表，两处各显一次会双计）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_draft_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

Future<void> _pumpHub(
  WidgetTester tester,
  Widget hub, {
  required Set<String> permissions,
  required DraftCounts counts,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        draftCountsProvider.overrideWith((ref) async => counts),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: hub,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  group('采购 hub', () {
    // 订货/收货/退货三张卡都是 skipListOnCreate（点进直达新建页），
    // 故 hub 显隐走 *:create 路由权限；草稿数字仍受各自 *:view 门控。
    const perms = {
      Perm.purchaseOrderView,
      Perm.purchaseOrderCreate,
      Perm.purchaseReceiptView,
      Perm.purchaseReceiptCreate,
      Perm.purchaseReturnView,
      Perm.purchaseReturnCreate,
      Perm.purchaseRequestView,
    };

    testWidgets('收货/退货卡显示自己的草稿红徽章（此前两张卡没有任何数字）', (tester) async {
      await _pumpHub(
        tester,
        const PurchaseHubPage(),
        permissions: perms,
        counts: const DraftCounts(
          purchaseOrder: 1,
          purchaseReceipt: 2,
          purchaseReturn: 3,
        ),
      );

      // 草稿 = 红底白字徽章里的裸数字，不再是 `(N)`。
      expect(find.byType(UtenDraftBadge), findsNWidgets(3));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('(1)'), findsNothing);
      expect(find.text('(2)'), findsNothing);
      expect(find.text('(3)'), findsNothing);
      // 卡上的三个数字确实由草稿红徽章画出（顶栏那枚模块累计要排除掉）。
      final drawn =
          tester
              .widgetList<UtenNotificationBadge>(
                find.descendant(
                  of: find.byType(UtenDraftBadge),
                  matching: find.byType(UtenNotificationBadge),
                ),
              )
              .map((badge) => badge.count)
              .where((count) => count > 0)
              .toList()
            ..sort();
      expect(drawn, [1, 2, 3]);
      // 顶栏那枚是本模块累计 1+2+3。2026-09-11 起它不再是一颗裸红数字
      // （用户问「右上角为什么有个消息数量徽章」），改成自解释的「待办 N」药丸。
      expect(
        find.byKey(const ValueKey('uten-module-todo-chip')),
        findsOneWidget,
      );
      expect(find.text('待办 6'), findsOneWidget);
    });

    testWidgets('草稿为 0 时徽章整个不渲染（不留「0」噪声）', (tester) async {
      await _pumpHub(
        tester,
        const PurchaseHubPage(),
        permissions: perms,
        counts: DraftCounts.empty,
      );

      // 组件仍在树上（权限允许），但 count=0 时自身返回 SizedBox.shrink。
      for (final badge in tester.widgetList<UtenNotificationBadge>(
        find.byType(UtenNotificationBadge),
      )) {
        expect(badge.count, 0);
      }
      expect(find.text('0'), findsNothing);
      expect(find.text('(0)'), findsNothing);
      // 顶栏累计为 0 时整枚药丸也不渲染（没有待办就不该有红色）。
      expect(find.byKey(const ValueKey('uten-module-todo-chip')), findsNothing);
    });

    testWidgets('无收货/退货查看权限时，这两张卡与其数字都不出现', (tester) async {
      await _pumpHub(
        tester,
        const PurchaseHubPage(),
        permissions: const {
          Perm.purchaseOrderView,
          Perm.purchaseOrderCreate,
          Perm.purchaseReceiptCreate,
          Perm.purchaseReturnCreate,
        },
        counts: const DraftCounts(
          purchaseOrder: 1,
          purchaseReceipt: 2,
          purchaseReturn: 3,
        ),
      );

      // 卡片仍在（create 权限允许进新建页），但没有 *:view 就不显草稿数。
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsNothing);
    });
  });

  group('委外 hub', () {
    testWidgets('成品退回/余料退回/损耗与责任各显自己的草稿红徽章', (tester) async {
      await _pumpHub(
        tester,
        const SubcontractHubPage(),
        permissions: const {
          Perm.subcontractOrderView,
          Perm.subcontractReturnView,
          Perm.subcontractMaterialReturnView,
          Perm.subcontractWasteView,
        },
        counts: const DraftCounts(
          subcontractOrder: 4,
          subcontractReturn: 5,
          subcontractMaterialReturn: 6,
          subcontractWaste: 7,
        ),
      );

      expect(find.byType(UtenDraftBadge), findsNWidgets(4));
      expect(find.text('4'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('无权限的单据卡不渲染数字', (tester) async {
      await _pumpHub(
        tester,
        const SubcontractHubPage(),
        permissions: const {Perm.subcontractOrderView},
        counts: const DraftCounts(subcontractOrder: 4, subcontractWaste: 7),
      );

      expect(find.text('4'), findsOneWidget);
      expect(find.text('7'), findsNothing);
    });
  });

  group('仓库 hub', () {
    testWidgets('调拨/盘点各显 doc_type 切片，而不是整模块合计', (tester) async {
      await _pumpHub(
        tester,
        const WarehouseHubPage(),
        permissions: const {Perm.stockDocView},
        counts: const DraftCounts(
          stockDocument: 11,
          stockTransfer: 2,
          stockCheck: 9,
        ),
      );

      expect(find.text('2'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      // 整模块合计（11）只给新建页的「草稿」按钮与顶栏模块累计用；
      // 出现在**卡片的草稿徽章**上才是双计。
      expect(
        find.descendant(
          of: find.byType(UtenDraftBadge),
          matching: find.text('11'),
        ),
        findsNothing,
      );
      expect(find.text('待办 11'), findsOneWidget); // 顶栏累计那一枚（自解释药丸）
    });

    testWidgets('切片为 0 时不渲染（整模块合计不会漏到卡上）', (tester) async {
      await _pumpHub(
        tester,
        const WarehouseHubPage(),
        permissions: const {Perm.stockDocView},
        counts: const DraftCounts(stockDocument: 11),
      );

      // 卡片上没有任何草稿徽章（两个切片都是 0）。
      for (final badge in tester.widgetList<UtenNotificationBadge>(
        find.descendant(
          of: find.byType(UtenDraftBadge),
          matching: find.byType(UtenNotificationBadge),
        ),
      )) {
        expect(badge.count, 0);
      }
      // 顶栏累计仍按整模块合计显示 11（切片为 0 不代表模块没草稿）。
      expect(find.text('待办 11'), findsOneWidget);
    });
  });
}
