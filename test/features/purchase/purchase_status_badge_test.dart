// 订货单状态徽章财务口径测试：在审单不再误显「草稿」，
// 与列表状态列共用 purchaseOrderDisplayLabel/BadgeType 映射。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_status_badge.dart';
import 'package:uten_imp/shared/models/procurement_finance_approval.dart';

void main() {
  ProcurementFinanceApproval approval(String status) =>
      ProcurementFinanceApproval.fromJson({'status': status});

  testWidgets('pending-finance order badge shows waiting, not draft', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PurchaseStatusBadge(
            status: kPurchaseStatusDraft,
            financeApproval: approval('PENDING'),
          ),
        ),
      ),
    );
    expect(find.text('等待财务审核'), findsOneWidget);
    expect(find.text('草稿'), findsNothing);
  });

  testWidgets('rejected order badge shows finance rejection', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PurchaseStatusBadge(
            status: kPurchaseStatusDraft,
            financeApproval: approval('REJECTED'),
          ),
        ),
      ),
    );
    expect(find.text('财务退回'), findsOneWidget);
  });

  testWidgets('closed approved order keeps 结案 suffix with finance label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PurchaseStatusBadge(
            status: kPurchaseStatusApproved,
            closed: true,
            financeApproval: approval('APPROVED'),
          ),
        ),
      ),
    );
    expect(find.text('财务已通过·结案'), findsOneWidget);
  });

  testWidgets('docs without projection keep legacy status pill', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PurchaseStatusBadge(status: kPurchaseStatusDraft)),
      ),
    );
    expect(find.text('草稿'), findsOneWidget);
  });

  test('badge type mapping mirrors the label semantics', () {
    expect(
      purchaseOrderDisplayBadgeType(0, approval('PENDING')),
      UtenStatusBadgeType.warning,
    );
    expect(
      purchaseOrderDisplayBadgeType(0, approval('REJECTED')),
      UtenStatusBadgeType.danger,
    );
    expect(
      purchaseOrderDisplayBadgeType(1, approval('APPROVED')),
      UtenStatusBadgeType.success,
    );
    expect(
      purchaseOrderDisplayBadgeType(0, approval('DRAFT')),
      UtenStatusBadgeType.neutral,
    );
    // 终态与无投影/未知态回落单据 0/1/-1/2 语义。
    expect(
      purchaseOrderDisplayBadgeType(-1, approval('APPROVED')),
      UtenStatusBadgeType.danger,
    );
    expect(purchaseOrderDisplayBadgeType(0, null), UtenStatusBadgeType.neutral);
    expect(
      purchaseOrderDisplayBadgeType(1, approval('LEGACY_EFFECTIVE')),
      UtenStatusBadgeType.success,
    );
  });
}
