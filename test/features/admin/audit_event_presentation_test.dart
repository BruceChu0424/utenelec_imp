import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/audit_event_presentation.dart';

void main() {
  group('销售历史单据查看叙事', () {
    const cases = <String, String>{
      'view_sales_quote_detail_history': '销售报价历史单据',
      'view_sales_order_detail_history': '销售订单历史单据',
      'view_sales_shipment_detail_history': '销售出货历史单据',
      'view_sales_other_shipment_detail_history': '销售其他出库历史单据',
      'view_sales_return_detail_history': '销售退货历史单据',
    };

    for (final entry in cases.entries) {
      test('用业务单号展示${entry.value}', () {
        expect(
          AuditEventPresentation.salesViewNarrative(
            action: entry.key,
            targetName: 'SO-2026-001',
          ),
          '查看了${entry.value}：SO-2026-001',
        );
        expect(
          AuditEventPresentation.salesViewObjectText(
            action: entry.key,
            targetName: 'SO-2026-001',
          ),
          '${entry.value} · SO-2026-001',
        );
      });
    }

    test('现代销售详情生成清晰但不带历史字样的叙事', () {
      expect(
        AuditEventPresentation.salesViewNarrative(
          action: 'view_sales_order_detail',
          targetName: 'SO-2026-001',
        ),
        '查看了销售订单详情：SO-2026-001',
      );
    });

    test('允许后端的中文历史标识作为无单号回退', () {
      expect(
        AuditEventPresentation.salesViewNarrative(
          action: 'view_sales_order_detail_history',
          targetName: '旧系统销售订单(编号 86)',
        ),
        '查看了销售订单历史单据：旧系统销售订单(编号 86)',
      );
    });

    for (final unsafeName in <String?>[
      null,
      ' ',
      '未知',
      '123e4567-e89b-42d3-a456-426614174099',
      '/api/sales/orders/123e4567-e89b-42d3-a456-426614174099',
      'https://internal.example/sales/orders/1',
    ]) {
      test('空值或技术标识安全回退：$unsafeName', () {
        expect(
          AuditEventPresentation.salesViewNarrative(
            action: 'view_sales_order_detail_history',
            targetName: unsafeName,
          ),
          '查看了销售订单历史单据(单号未记录)',
        );
      });
    }
  });

  test('操作人优先使用后端中文展示名且从不回退到 UUID', () {
    expect(
      AuditEventPresentation.actorLabel(
        actorDisplay: '王小明(sales01)',
        actorName: '王小明',
        actorAccount: 'sales01',
      ),
      '王小明(sales01)',
    );
    expect(
      AuditEventPresentation.actorLabel(
        actorName: '王小明',
        actorAccount: 'sales01',
      ),
      '王小明(sales01)',
    );
    expect(AuditEventPresentation.actorLabel(), '未知操作人');
  });
}
