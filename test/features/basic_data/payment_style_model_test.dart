import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';

void main() {
  group('PaymentStyleUpdateInput', () {
    test('moveToRoot 显式序列化且不混入 parentId', () {
      const input = PaymentStyleUpdateInput(
        name: '差旅费',
        moveToRoot: true,
        sortOrder: 20,
        status: '使用',
      );

      final json = input.toJson();

      expect(json['moveToRoot'], isTrue);
      expect(json, isNot(contains('parentId')));
      expect(json['name'], '差旅费');
      expect(json['sortOrder'], 20);
    });

    test('未请求移到顶级时不发送 moveToRoot', () {
      const input = PaymentStyleUpdateInput(
        name: '差旅费',
        parentId: 'expense-root',
      );

      final json = input.toJson();

      expect(json['parentId'], 'expense-root');
      expect(json, isNot(contains('moveToRoot')));
    });

    test('快捷状态更新不携带名称、父级或业务标志', () {
      const input = PaymentStyleUpdateInput(status: '禁用');

      final json = input.toJson();

      expect(json, {'status': '禁用'});
    });

    test('关联账户只序列化 UUID 真源', () {
      const input = PaymentStyleUpdateInput(
        linkedAccountId: '7f60bc84-9c45-47bb-88bf-a787e3e10fd0',
      );

      final json = input.toJson();

      expect(json['linkedAccountId'], input.linkedAccountId);
      expect(json, isNot(contains('linkedAccountLegacyId')));
    });

    test('无 UUID 关联时不会产生 legacy 兜底字段', () {
      const input = PaymentStyleSaveInput(
        code: '',
        name: '银行存款',
        category: 'ACCOUNT',
      );

      final json = input.toJson();

      expect(json, isNot(contains('linkedAccountLegacyId')));
      expect(json, isNot(contains('linkedAccountId')));
    });
  });
}
