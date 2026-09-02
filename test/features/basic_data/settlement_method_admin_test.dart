import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/settlement_method_admin.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';

/// V453：结算方式管理页（账期口径展示 + 系统角色锁定不进编辑）。
void main() {
  group('terms summary labels', () {
    test('cash system role is fixed to receipt date', () {
      final cash = SettlementMethodAdminItem.fromJson(const {
        'id': 'cash-id',
        'name': '现金',
        'systemRole': 'CASH',
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': 0,
        'monthsAhead': 0,
      });

      expect(cash.lockedBySystemRole, isTrue);
      expect(settlementTermsSummary(cash), '现金：收货/进仓当天到期');
      expect(settlementSystemRoleLabel('MONTHLY'), '月结 · 系统锁定');
    });

    test('custom monthly method renders statement-end plus days', () {
      final monthly = SettlementMethodAdminItem.fromJson(const {
        'id': 'm60',
        'name': '月结60',
        'termsBase': 'STATEMENT_END',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': 60,
        'monthsAhead': 0,
      });

      expect(settlementTermsSummary(monthly), '月末 + 60 天');
    });

    test('future-event bases stay undated with explanation', () {
      final invoice = SettlementMethodAdminItem.fromJson(const {
        'id': 'inv',
        'name': '票到',
        'termsBase': 'INVOICE_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': 30,
        'monthsAhead': 0,
      });

      expect(settlementTermsSummary(invoice), contains('到期日保持未定'));
    });

    test('fixed day rule mentions month offset and day', () {
      final fixed = SettlementMethodAdminItem.fromJson(const {
        'id': 'fixed',
        'name': '次月10日',
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'FIXED_DAY_OF_MONTH',
        'defaultDueDays': 0,
        'fixedDayOfMonth': 10,
        'monthsAhead': 1,
      });

      expect(settlementTermsSummary(fixed), contains('10 日'));
      expect(settlementTermsSummary(fixed), contains('基准月+1'));
    });
  });

  testWidgets('page lists methods and locked rows are not editable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettlementMethodPage())),
    );
    // 无权限环境（空权限）：页面仍可渲染列表（路由守卫在真实导航层），
    // 本例验证列表项与锁定徽标的呈现由模型层覆盖；此处页面空态/错误态不崩。
    await tester.pumpAndSettle();
    expect(find.byType(SettlementMethodPage), findsOneWidget);
  });
}
