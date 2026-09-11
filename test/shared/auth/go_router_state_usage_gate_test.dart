import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// go_router 14.8 无限重挂载事故的静态闸门（2026-09-04 整站卡死，见
// docs/03-页面/生产物料分析页.md 事故记录）。
//
// 危险模型：`GoRouterState.of(context)` 会向上爬路由并对
// GoRouterStateRegistry（InheritedNotifier）建立 inherited 依赖；
// 在「非 go_router 页路由」（Navigator.push 的 MaterialPageRoute、
// showDialog/BottomSheet 等命令式路由）的 build/布局期调用会触发无限
// 重挂载循环（点开即整站卡死，栈 600+ 层直至进程死亡）。
//
// 安全边界（审核口径，新增调用必须落入其一）：
//  A. 点击/回调期调用（onTap、按钮 onPressed、对话框动作等）；
//  B. GoRoute 页路由的 build 期（settings is Page，不发生爬升）；
//  C. 带 try/catch 的 fail-closed 封装（如 nav_helpers.currentLocationOr）。
// `GoRouter.of(context)` 与 context.go/push/pop/canPop 查的是普通
// InheritedWidget（router 配置），不挂 InheritedNotifier 依赖，不受本闸门约束。
//
// 本测试锁定全库 `GoRouterState.of(` 的出现位置：新增或漂移即失败，
// 强制到本文件登记并注明上述 A/B/C 归类，防止同类事故复发。
void main() {
  test('GoRouterState.of call sites stay on the reviewed allowlist', () {
    const allowlist = <String, int>{
      // 2026-09-10 UtenBackButton 默认返回改为委托 nav_helpers.backTo，本文件不再
      // 直接调用 GoRouterState.of（全站返回契约只在 nav_helpers 维护一份）。
      'lib/core/router/nav_helpers.dart': 3, // A+C: 回调期 + fail-closed 封装
      // page_resume_provider.dart 的两处命中都在文档注释里（无代码调用）。
      'lib/core/router/page_resume_provider.dart': 2, // DOC: 注释示例
      'lib/features/finance/pages/finance_doc_list_page.dart':
          1, // B: GoRoute build 惰性 ??=
      'lib/features/production/pages/production_daily_report_list_page.dart':
          1, // B
      'lib/features/production/pages/production_plan_list_page.dart': 1, // B
      'lib/features/purchase/pages/purchase_doc_list_page.dart': 1, // B
      'lib/features/sales/pages/sales_doc_list_page.dart': 1, // B
      // 2026-09-05 订单进度查询页：GoRoute build 惰性 ??= 记录本页路径供
      // onPageResume（与各列表页同款 B 类用法）。
      'lib/features/sales/pages/sales_order_progress_page.dart': 1, // B
      'lib/features/shell/pages/main_shell_page.dart':
          3, // A+B: Tab 回调×2 + 根级 build×1
      'lib/features/subcontract/pages/subcontract_business_list_pages.dart':
          1, // B
      'lib/features/warehouse/pages/stock_doc_list_page.dart': 1, // B
      'lib/features/warehouse/widgets/production_finished_inbound_tasks_view.dart':
          2, // A: 行点击回调
      // 本闸门的事故修复本体：settings is! Page 先行 fail-closed，再调
      // GoRouterState.of（此时必然命中本路由，不发生爬升）。
      'lib/shared/auth/page_permission_action.dart': 1, // C: fail-closed 守卫后调用
    };
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '请在仓库根目录运行本测试');

    final actual = <String, int>{};
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final count = 'GoRouterState.of('
          .allMatches(entity.readAsStringSync())
          .length;
      if (count > 0) {
        actual[entity.path.replaceAll('\\', '/')] = count;
      }
    }

    final unregistered = actual.keys.where(
      (path) => !allowlist.containsKey(path),
    );
    expect(
      unregistered,
      isEmpty,
      reason:
          '发现未登记的 GoRouterState.of 调用：$unregistered\n'
          '该 API 在命令式路由（Navigator.push/showDialog）的 build 期调用会触发'
          ' go_router 14.8 无限重挂载（整站卡死）。请归类 A/B/C 后登记进本测试；'
          '命令式子弹层一律改用 fail-closed 模式（参考 '
          'lib/shared/auth/page_permission_action.dart 的 _scopeFromRouter）。',
    );

    final removed = allowlist.keys.where((path) => !actual.containsKey(path));
    expect(
      removed,
      isEmpty,
      reason: 'allowlist 里的文件已不含 GoRouterState.of 调用，请同步清理登记：$removed',
    );

    // 同文件内新增调用也要过审（次数锁定）：新增/减少都要求更新登记并归类。
    for (final entry in actual.entries) {
      expect(
        entry.value,
        allowlist[entry.key],
        reason:
            '${entry.key} 的 GoRouterState.of 出现次数（${entry.value}）与'
            '登记（${allowlist[entry.key]}）不一致——新增调用必须归类 A/B/C 后'
            '更新本闸门；命令式子弹层（Navigator.push/showDialog 内的 build 期）'
            '禁止直接调用，须走 fail-closed 模式（参考 page_permission_action.dart）。',
      );
    }
  });
}
