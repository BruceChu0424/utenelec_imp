import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';

void main() {
  test('RdTaskRow.fromJson parses backend fields', () {
    final row = RdTaskRow.fromJson({
      'id': 't1',
      'taskNo': 'RD26080001',
      'title': '维护货品 BOM',
      'category': 'BOM',
      'status': 'OPEN',
      'priority': 'URGENT',
      'rowVersion': 3,
      'goodsId': 'g1',
      'goodsName': '成品A',
      'goodsCode': 'P001',
      'orderItemId': 'oi1',
      'sourceDocType': 'SALES_ORDER_ITEM',
      'sourceDocId': 'o1',
      'sourceDocNo': 'XD26080001',
      'assigneeEmployeeId': null,
      'assigneeName': null,
      'reporterEmployeeId': 'e1',
      'reporterName': '张三',
      'dueDate': '2026-08-10',
      'startedAt': null,
      'completedAt': null,
      'createdAt': '2026-08-02T10:00:00Z',
      'closeNote': null,
      'allowedActions': ['RESOLVE', 'ASSIGN'],
    });
    expect(row.id, 't1');
    expect(row.taskNo, 'RD26080001');
    expect(row.category, 'BOM');
    expect(row.rowVersion, 3);
    expect(row.goodsName, '成品A');
    expect(row.isOpen, isTrue);
    expect(row.allowedActions, ['RESOLVE', 'ASSIGN']);
  });

  test('labels map status/category to Chinese', () {
    expect(rdTaskStatusLabel('OPEN'), '待处理');
    expect(rdTaskStatusLabel('IN_PROGRESS'), '进行中');
    expect(rdTaskStatusLabel('DONE'), '已完成');
    expect(rdTaskStatusLabel('CANCELED'), '已取消');
    expect(rdTaskCategoryLabel('BOM'), 'BOM维护');
    expect(rdTaskCategoryLabel('ECN'), 'ECN');
  });

  test('RdTaskData.fromJson parses pagination envelope', () {
    final data = RdTaskData.fromJson({
      'items': [
        {
          'id': 't1',
          'taskNo': 'RD1',
          'title': 'x',
          'category': 'OTHER',
          'status': 'OPEN',
          'priority': 'NORMAL',
          'rowVersion': 1,
          'allowedActions': <String>[],
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    });
    expect(data.items.length, 1);
    expect(data.total, 1);
    expect(data.totalPages, 1);
    expect(data.items.first.isOpen, isTrue);
  });
}
