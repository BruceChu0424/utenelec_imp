import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/dashboard/models/dashboard_overview.dart';

void main() {
  test(
    'parses aggregated production todo and only server-returned metrics',
    () {
      final overview = DashboardOverview.fromJson({
        'departmentCode': 'DEPT_PROD',
        'departmentName': '生产部',
        'generatedAt': '2026-07-31T01:00:00Z',
        'metrics': [
          {
            'id': 'production-pending',
            'title': '待排产产品',
            'value': '26',
            'subtitle': '按销售订单需求实时汇总',
            'tone': 'warning',
            'route': '/production/schedule',
            'sensitive': false,
          },
        ],
        'todos': [
          {
            'id': 'production-pending',
            'title': '你有 26 个产品待生产',
            'summary': '已合并同类生产需求，进入排产工作台统一处理',
            'count': 26,
            'urgentCount': 3,
            'tone': 'warning',
            'route': '/production/schedule',
            'sourceType': 'PRODUCTION',
            'completable': false,
          },
        ],
        'intelligence': <Map<String, dynamic>>[],
      });

      expect(overview.departmentName, '生产部');
      expect(overview.todos, hasLength(1));
      expect(overview.todos.single.count, 26);
      expect(overview.todos.single.title, '你有 26 个产品待生产');
      expect(
        overview.metrics.any((metric) => metric.id == 'cash-balance'),
        isFalse,
        reason: '没有权限时服务端不会返回余额指标',
      );
    },
  );

  test('parses notice todo completion and verified source link', () {
    final overview = DashboardOverview.fromJson({
      'departmentCode': 'DEPT_FIN',
      'departmentName': '财务部',
      'generatedAt': '2026-07-31T01:00:00Z',
      'metrics': <Map<String, dynamic>>[],
      'todos': [
        {
          'id': 'notice-1',
          'title': '核对出口退税资料',
          'summary': '请在截止日前完成',
          'count': 1,
          'urgentCount': 0,
          'tone': 'info',
          'route': '/notice/n1',
          'sourceType': 'NOTICE',
          'sourceId': 'n1',
          'dueAt': '2026-08-03T15:59:00Z',
          'completable': true,
        },
      ],
      'intelligence': [
        {
          'id': 'p1',
          'title': '出口业务增值税政策',
          'summary': '按商品代码和申报条件核对。',
          'category': 'EXPORT',
          'sourceName': '中华人民共和国财政部',
          'sourceUrl': 'https://www.mof.gov.cn/example.htm',
          'publishedOn': '2026-01-30',
          'capturedAt': '2026-07-31T00:00:00Z',
        },
      ],
    });

    expect(overview.todos.single.sourceType, 'NOTICE');
    expect(overview.todos.single.completable, isTrue);
    expect(overview.intelligence.single.sourceUrl, startsWith('https://'));
  });
}
