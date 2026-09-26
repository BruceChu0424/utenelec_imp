// 各 hub 新建单据卡的计数回归（准则 14-徽章与计数口径 §草稿）。
//
// **2026-09-11 口径反转**：草稿改走红底白字徽章并逐级累加（[UtenDraftBadge]）。
// **2026-09-24 模块三段式修订**（docs/01-规划/2026-09-24-模块三段式统一*.md）：
// hub 单据卡全部改为 creator-only 的新建入口（直达 /new），用户口径「新建入口
// 不需要通知数量徽章」——**hub 新建卡一律不挂数**；草稿的三处可见面 =
// ① 新建页顶栏「草稿(N)」按钮 ② 任务中心/列表页「草稿」分段 ③ 模块顶栏药丸
// 与工作台模块卡的待办累计（服务端红链照旧登记，不改）。
//
// 本文件钉死：
//  · 采购/委外/仓库 hub 的新建单据卡上没有任何草稿徽章（UtenDraftBadge findsNothing）；
//  · 顶栏「待办 N」药丸仍按服务端容器合计累计（含草稿），0 时不渲染；
//  · 无 *:view 权限时新建卡（create 门控）照常渲染，且不带任何数字。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_draft_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../helpers/badge_summary_fixture.dart';

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
        // Production return badges read the real session/network preferences.
        sharedPreferencesProvider.overrideWithValue(_preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        draftCountsProvider.overrideWith((ref) => counts),
        // 顶栏「待办 N」= 服务端算好的容器数(ADR-108); 夹具里只有草稿入口, 按服务端目录
        // 口径求和(仓库草稿入口只取整表合计, 不加调拨/盘点切片)。
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: {
              BadgeEntry.purchaseDrafts: (
                counts.purchaseOrder +
                    counts.purchaseReceipt +
                    counts.purchaseReturn,
                0,
              ),
              BadgeEntry.subcontractDrafts: (
                counts.subcontractOrder +
                    counts.subcontractReturn +
                    counts.subcontractMaterialReturn +
                    counts.subcontractWaste,
                0,
              ),
              BadgeEntry.warehouseDrafts: (counts.stockDocument, 0),
            },
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: hub,
      ),
    ),
  );
  // Drain the real badge providers' initial async reads before assertions and disposal.
  await tester.pumpAndSettle();
}

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  group('采购 hub（2026-09-24 三段式：新建卡不挂数）', () {
    // 新建卡只走 *:create 路由权限（creator-only）；「计划下达的采购申请」只读卡走 view。
    const perms = {
      Perm.purchaseOrderView,
      Perm.purchaseOrderCreate,
      Perm.purchaseReceiptView,
      Perm.purchaseReceiptCreate,
      Perm.purchaseReturnView,
      Perm.purchaseReturnCreate,
      Perm.purchaseRequestView,
    };

    testWidgets('订货/收货/退货新建卡无草稿徽章，顶栏药丸仍累计', (tester) async {
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

      // 新建卡一律不挂数（2026-09-24 口径）：卡上没有任何草稿徽章与裸数字。
      expect(find.byType(UtenDraftBadge), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsNothing);
      // 新建区卡标签带「新建」前缀，落点为 /new（进卡即新建态）。
      expect(find.text('新建采购订货单'), findsOneWidget);
      expect(find.text('新建采购收货单'), findsOneWidget);
      expect(find.text('新建采购退货单'), findsOneWidget);
      // 顶栏那枚是本模块累计 1+2+3（自解释「待办 N」药丸，含草稿，照旧累计）。
      expect(
        find.byKey(const ValueKey('uten-module-todo-chip')),
        findsOneWidget,
      );
      expect(find.text('待办 6'), findsOneWidget);
    });

    testWidgets('草稿为 0 时顶栏药丸整个不渲染（不留「0」噪声）', (tester) async {
      await _pumpHub(
        tester,
        const PurchaseHubPage(),
        permissions: perms,
        counts: DraftCounts.empty,
      );

      expect(find.text('0'), findsNothing);
      // 顶栏累计为 0 时整枚药丸也不渲染（没有待办就不该有红色）。
      expect(find.byKey(const ValueKey('uten-module-todo-chip')), findsNothing);
    });

    testWidgets('无收货/退货查看权限时新建卡不渲染（新建页守卫=create+view）', (tester) async {
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

      // 新建页路由守卫 = create AND view：无 *:view 时收货/退货新建卡整张隐藏
      //（浏览与新建都以查看权限为前提）；可见的卡也不带任何草稿数字。
      expect(find.text('新建采购订货单'), findsOneWidget);
      expect(find.text('新建采购收货单'), findsNothing);
      expect(find.text('新建采购退货单'), findsNothing);
      expect(find.byType(UtenDraftBadge), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsNothing);
    });
  });

  group('委外 hub（2026-09-24 三段式：新建卡不挂数）', () {
    testWidgets('订货/成品退回/余料退回/损耗新建卡无草稿徽章', (tester) async {
      await _pumpHub(
        tester,
        const SubcontractHubPage(),
        permissions: const {
          Perm.subcontractOrderView,
          Perm.subcontractOrderCreate,
          Perm.subcontractReturnView,
          Perm.subcontractReturnCreate,
          Perm.subcontractMaterialReturnView,
          Perm.subcontractMaterialReturnCreate,
          Perm.subcontractWasteView,
          Perm.subcontractWasteCreate,
        },
        counts: const DraftCounts(
          subcontractOrder: 4,
          subcontractReturn: 5,
          subcontractMaterialReturn: 6,
          subcontractWaste: 7,
        ),
      );

      expect(find.byType(UtenDraftBadge), findsNothing);
      expect(find.text('4'), findsNothing);
      expect(find.text('5'), findsNothing);
      expect(find.text('6'), findsNothing);
      expect(find.text('7'), findsNothing);
      // 顶栏累计 4+5+6+7（含草稿，照旧累计）。
      expect(find.text('待办 22'), findsOneWidget);
    });
  });

  group('仓库 hub（2026-09-24 三段式：新建卡不挂数）', () {
    testWidgets('新建区六卡无草稿徽章，顶栏累计按整表合计', (tester) async {
      await _pumpHub(
        tester,
        const WarehouseHubPage(),
        permissions: const {Perm.stockDocView, Perm.stockDocCreate},
        counts: const DraftCounts(
          stockDocument: 11,
          stockTransfer: 2,
          stockCheck: 9,
        ),
      );

      // 新建区卡上没有任何草稿徽章（调拨/盘点切片不再上卡）。
      expect(
        find.descendant(
          of: find.byType(UtenDraftBadge),
          matching: find.byType(UtenDraftBadge),
        ),
        findsNothing,
      );
      expect(find.byType(UtenDraftBadge), findsNothing);
      expect(find.text('2'), findsNothing);
      expect(find.text('9'), findsNothing);
      expect(find.text('新建调拨单'), findsOneWidget);
      expect(find.text('新建盘点单'), findsOneWidget);
      expect(find.text('新建其它出库'), findsOneWidget);
      expect(find.text('新建其它入库'), findsOneWidget);
      // 顶栏累计仍按整模块合计显示 11。
      expect(find.text('待办 11'), findsOneWidget);
    });

    testWidgets('任务中心一卡在，旧四张任务卡不在', (tester) async {
      await _pumpHub(
        tester,
        const WarehouseHubPage(),
        permissions: const {Perm.stockDocView, Perm.stockDocCreate},
        counts: const DraftCounts(stockDocument: 11),
      );

      expect(find.text('仓库任务中心'), findsOneWidget);
      expect(find.text('出库任务中心'), findsNothing);
      expect(find.text('入库任务中心'), findsNothing);
      expect(find.text('生产领料任务中心'), findsNothing);
      expect(find.text('品质部检查结果'), findsNothing);
    });
  });
}
