import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';

void main() {
  test('list and detail parse server-authoritative object capabilities', () {
    final list = ClientListItem.fromJson({
      'id': 'client-1',
      'name': '客户一号',
      'writable': true,
      'accessManageable': false,
    });
    final detail = ClientDetail.fromJson({
      'id': 'client-1',
      'name': '客户一号',
      'writable': false,
      'accessManageable': true,
      'accessReason': 'UNASSIGNED',
    });

    expect(list.writable, isTrue);
    expect(list.accessManageable, isFalse);
    expect(detail.writable, isFalse);
    expect(detail.accessManageable, isTrue);
    expect(detail.accessReasonLabel, '待分配（可设置负责人）');
    expect(detail.readOnlyActionHint, '请先设置负责人');
  });

  test('missing object capabilities fail closed for legacy responses', () {
    final list = ClientListItem.fromJson({'id': 'client-1'});
    final detail = ClientDetail.fromJson({'id': 'client-1'});

    expect(list.writable, isFalse);
    expect(list.accessManageable, isFalse);
    expect(detail.writable, isFalse);
    expect(detail.accessManageable, isFalse);
    expect(detail.accessReason, ClientAccessReason.unknown);
    expect(detail.accessReasonLabel, '只读（访问来源未标明）');
  });

  test(
    'detail reason distinguishes manageable, shared and owner-scope read-only',
    () {
      ClientDetail detail(String reason) => ClientDetail.fromJson({
        'id': 'client-1',
        'ownerEmployeeId': 'owner-1',
        'accessReason': reason,
      });

      expect(
        detail(ClientAccessReason.manageable).accessReasonLabel,
        '可管理（具体操作仍按功能权限）',
      );
      expect(detail(ClientAccessReason.shared).accessReasonLabel, '单客户共享（只读）');
      expect(detail(ClientAccessReason.shared).readOnlyActionHint, '仅可查看');
      expect(
        detail(ClientAccessReason.ownerScopeReadOnly).accessReasonLabel,
        '负责人数据范围（只读）',
      );
    },
  );
}
