// 工作台组内卡片长按拖动换位（_ReorderableModuleGrid）widget 测试。
//
// 链路：长按卡片 → 拖到另一张卡片上悬停 → DragTarget.onMove/onAccept →
// layoutNotifier.reorderItem → 状态更新（防抖持久化由基类负责，这里只断言状态）。
//
// 夹具口径：普通用户只授予财税部 4 张卡的权限 → 页面只渲染财税部一组
// （common 组的我的访客卡带 60s 轮询角标，不授予 visitorHostConfirm 即不挂载）；
// 财务徽标的 4 个计数源全部 stub 成 0，不触网、不产生轮询 Timer。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/providers/workbench_layout_provider.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/features/finance/providers/finance_procurement_approval_count_provider.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sales_shipment_finance_count_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';

class _StubSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  testWidgets('长按拖动组内卡片到另一张卡片上换位并写入布局状态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _StubSession()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(const <String>{
          // 只放行财税部 4 张卡（/finance hub、报销审批、工资条生成、工资条审核）
          Perm.financeReportView,
          Perm.expenseApprove,
          Perm.payrollGenerate,
          Perm.payrollReview,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        // 财务徽标 4 个计数源 stub：不触网、无轮询
        financeProcurementApprovalCountProvider.overrideWith((ref) async => 0),
        salesOrderFinanceConfirmationCountProvider.overrideWith(
          (ref) async => 0,
        ),
        salesShipmentFinanceCountProvider.overrideWith((ref) async => 0),
        financeArrivalExceptionCountProvider.overrideWith((ref) async => 0),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: WorkbenchModuleArea()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 只渲染财税部一组，默认顺序：钱流管理 / 报销审批 / 工资条生成 / 工资条审核
    expect(find.text('财税部'), findsOneWidget);
    expect(find.text('常用功能'), findsNothing);
    expect(
      container.read(workbenchLayoutProvider).itemOrders,
      isEmpty,
      reason: '未拖动前不应有组内排序记录',
    );

    // 长按「钱流管理」起拖（超过 kLongPressTimeout），移到「工资条审核」上松手
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('钱流管理')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(find.text('工资条审核')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      container.read(workbenchLayoutProvider).itemOrders['fin'],
      [
        '/expense/approval',
        '/payroll/generate',
        '/payroll/review',
        RouteName.finance,
      ],
      reason: '拖到组内最后一张上：被拖卡片落到目标之后（末位），其余顺移',
    );

    // 推进时间让防抖持久化 Timer 自然触发完毕，否则测试收尾报「Timer still pending」
    await tester.pump(const Duration(seconds: 1));
  });
}
