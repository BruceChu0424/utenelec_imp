import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/models/notice_group.dart';

void main() {
  test(
    'read and interaction updates preserve grouping and resolved audit facts',
    () {
      final resolvedAt = DateTime.utc(2026, 10, 28, 8);
      final original = Notice(
        id: 'review',
        title: '订单审核',
        content: '结果',
        type: NoticeType.approval,
        publisher: '财务',
        publishedAt: DateTime.utc(2026, 10, 28),
        isRead: false,
        aggregateKind: 'SALES_ORDER',
        aggregateId: 'order-1',
        interactive: true,
        resolvedAt: resolvedAt,
        resolvedReason: 'APPROVED',
        blessingTemplates: const ['工作顺利'],
      );
      final updated = original.copyWith(
        isRead: true,
        ackCount: 3,
        myAcked: true,
      );
      expect(noticeGroupKeyOf(updated), noticeGroupKeyOf(original));
      expect(updated.interactive, isTrue);
      expect(updated.isResolved, isTrue);
      expect(updated.resolvedAt, resolvedAt);
      expect(updated.resolvedReason, 'APPROVED');
      expect(updated.blessingTemplates, original.blessingTemplates);
      expect(updated.myAcked, isTrue);
    },
  );
}
