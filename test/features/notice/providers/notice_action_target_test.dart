import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';

Notice _notice(String route, String? event) => Notice(
  id: 'legacy',
  title: '车间领退料',
  content: '',
  type: NoticeType.task,
  publisher: '仓库',
  publishedAt: DateTime.utc(2026, 10, 22),
  isRead: false,
  actionRoute: route,
  sourceEvent: event,
);

void main() {
  test('既存内料仓领退料通知按明确事件定位新方向，保留其它查询和通知返回上下文', () {
    for (final entry in {
      'WORKSHOP_MATERIAL_REQUISITION_PENDING': ('outbound', 'DRAW'),
      'WORKSHOP_MATERIAL_RETURN_PENDING': ('inbound', 'RETURN'),
    }.entries) {
      final notice = _notice(
        '/warehouse/tasks?group=workshopMaterial&scopeWarehouseId=leaf&keyword=LL1',
        entry.key,
      );
      final result = Uri.parse(noticeActionTarget(notice)!);
      expect(result.path, '/warehouse/tasks');
      expect(result.queryParameters, {
        'group': entry.value.$1,
        'section': entry.value.$2,
        'scopeWarehouseId': 'leaf',
        'keyword': 'LL1',
        'returnTo': '/notice',
      });
      expect(
        notice.actionRoute,
        '/warehouse/tasks?group=workshopMaterial&scopeWarehouseId=leaf&keyword=LL1',
      );
    }
  });

  test('明确section、新方向、其它事件与其它页面保持既有目标', () {
    for (final entry in [
      (
        '/warehouse/tasks?group=workshopMaterial&section=count',
        'WORKSHOP_MATERIAL_REQUISITION_PENDING',
      ),
      (
        '/warehouse/tasks?group=outbound&section=DRAW',
        'WORKSHOP_MATERIAL_REQUISITION_PENDING',
      ),
      (
        '/warehouse/tasks?group=workshopMaterial',
        'WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT',
      ),
      ('/warehouse/tasks?group=workshopMaterial', null),
      (
        '/workshop-material/bin?workshopId=w1',
        'WORKSHOP_MATERIAL_RETURN_PENDING',
      ),
    ]) {
      final original = Uri.parse(entry.$1);
      final result = Uri.parse(
        noticeActionTarget(_notice(entry.$1, entry.$2))!,
      );
      expect(result.path, original.path);
      expect(result.queryParameters, {
        ...original.queryParameters,
        'returnTo': '/notice',
      });
    }
  });
}
