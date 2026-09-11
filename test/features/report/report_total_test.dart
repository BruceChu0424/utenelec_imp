// 报表服务端合计（ReportTotal / reportTotalEntry / reportTotalsBar）契约。
//
// 核心不变量：本层**不做任何加法**。服务端按单位/币种分好组，前端只负责拼接；
// 因此「不同单位相加」在结构上就不可能发生，测试逐条把这些边界钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_data.dart';
import 'package:uten_imp/features/report/shared/report_total.dart';

void main() {
  group('ReportTotal 解析', () {
    test('从 ReportTableResponse 解析 totals', () {
      final data = parseReportResponse(<String, dynamic>{
        'columns': <Object?>[],
        'rows': <Object?>[],
        'page': 1,
        'totalPages': 3,
        'total': 137,
        'totals': <Object?>[
          <String, dynamic>{
            'key': 'qty',
            'label': '合计数量',
            'type': 'number',
            'groupKey': 'unitName',
            'groups': <Object?>[
              <String, dynamic>{'unit': '个', 'value': 900},
              <String, dynamic>{'unit': '箱', 'value': 20},
            ],
          },
        ],
      }, 1);

      expect(data.totals, hasLength(1));
      expect(data.totals.single.key, 'qty');
      expect(data.totals.single.grouped, isTrue);
      expect(data.totals.single.groups, hasLength(2));
    });

    test('响应没有 totals 字段时为空（老接口不炸）', () {
      final data = parseReportResponse(<String, dynamic>{
        'columns': <Object?>[],
        'rows': <Object?>[],
      }, 1);
      expect(data.totals, isEmpty);
    });
  });

  group('reportTotalEntry', () {
    test('多单位拼接而不是相加', () {
      final entry = reportTotalEntry(
        const ReportTotal(
          key: 'qty',
          label: '合计数量',
          type: 'number',
          groupKey: 'unitName',
          groups: [
            ReportTotalGroup(unit: '个', value: 900),
            ReportTotalGroup(unit: '箱', value: 20),
          ],
        ),
      );

      expect(entry.label, '合计数量');
      expect(entry.value, '900 个 · 20 箱');
      // 920 = 跨单位相加，绝不允许出现。
      expect(entry.value, isNot(contains('920')));
    });

    test('多币种拼接而不是相加，金额保留两位小数', () {
      final entry = reportTotalEntry(
        const ReportTotal(
          key: 'amount',
          label: '合计金额',
          type: 'money',
          groupKey: 'currencyCode',
          groups: [
            ReportTotalGroup(unit: 'CNY', value: 1234.5),
            ReportTotalGroup(unit: 'USD', value: 200),
          ],
        ),
      );

      expect(entry.value, '1,234.50 CNY · 200.00 USD');
      expect(entry.value, isNot(contains('1434')));
    });

    test('无分组维度时渲染纯数值，不带「单位未维护」', () {
      final entry = reportTotalEntry(
        const ReportTotal(
          key: 'docCount',
          label: '合计单据数',
          type: 'number',
          groupKey: null,
          groups: [ReportTotalGroup(unit: null, value: 42)],
        ),
      );

      expect(entry.value, '42');
      expect(entry.value, isNot(contains('单位未维护')));
    });

    test('有分组维度但某组分组值为空 → 该组标「单位未维护」', () {
      final entry = reportTotalEntry(
        const ReportTotal(
          key: 'qty',
          label: '合计数量',
          type: 'number',
          groupKey: 'unitName',
          groups: [
            ReportTotalGroup(unit: '个', value: 5),
            ReportTotalGroup(unit: null, value: 3),
          ],
        ),
      );

      expect(entry.value, '5 个 · 3 单位未维护');
    });

    test('无分组（服务端聚合无数据）→ 值为空，由合计条整体隐藏而不是显示 0', () {
      final entry = reportTotalEntry(
        const ReportTotal(
          key: 'qty',
          label: '合计数量',
          type: 'number',
          groupKey: 'unitName',
          groups: [],
        ),
      );

      expect(entry.value, isEmpty);
      expect(entry.value, isNot('0'));
    });
  });

  group('reportTotalsBar', () {
    test('没有合计项时返回 null（整条不渲染，绝不退化成当前页求和）', () {
      expect(reportTotalsBar(const []), isNull);
    });

    test('所有合计项都无值时返回 null', () {
      expect(
        reportTotalsBar(const [
          ReportTotal(
            key: 'qty',
            label: '合计数量',
            type: 'number',
            groupKey: 'unitName',
            groups: [],
          ),
        ]),
        isNull,
      );
    });

    test('有值时返回合计条', () {
      expect(
        reportTotalsBar(const [
          ReportTotal(
            key: 'qty',
            label: '合计数量',
            type: 'number',
            groupKey: 'unitName',
            groups: [ReportTotalGroup(unit: '个', value: 7)],
          ),
        ]),
        isNotNull,
      );
    });
  });
}
