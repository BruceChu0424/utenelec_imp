import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';

void main() {
  group('委外发料安全门禁', () {
    test('新增发料审核关闭且原因可操作', () {
      const config = SubcontractDocConfig.materialIssue;

      expect(config.approvalEnabled, isFalse);
      expect(config.approvalBlockedReason, contains('BOM 快照'));
      expect(config.approvalBlockedReason, contains('子件台账'));
      expect(config.approvalBlockedReason, contains('409'));
      expect(SubcontractDocConfig.receipt.approvalEnabled, isTrue);
    });

    test('旧 issuedQty 仅解析为历史兼容字段', () {
      final item = SubcontractDocItem.fromJson({
        'id': 'legacy-order-item',
        'issuedQty': 12.5,
      });

      expect(item.legacyIssuedQty, 12.5);
    });

    test('引入和详情界面不再把历史累计量当作剩余发料量', () {
      final picker = File(
        'lib/features/subcontract/widgets/subcontract_link_picker.dart',
      ).readAsStringSync();
      final detail = File(
        'lib/features/subcontract/pages/subcontract_doc_detail_page.dart',
      ).readAsStringSync();
      final edit = File(
        'lib/features/subcontract/pages/subcontract_doc_edit_page.dart',
      ).readAsStringSync();

      expect(picker, isNot(contains('.issuedQty')));
      expect(picker, isNot(contains('legacyIssuedQty')));
      expect(picker, contains('!cfg.approvalEnabled'));
      expect(picker, contains('新增发料审核暂不可用'));
      expect(detail, contains('onDisabledTap'));
      expect(detail, contains('审核暂不可用'));
      expect(edit, contains('可保存草稿，但不能作为已发料事实'));
    });

    test('材料退和损耗文案符合当前库存口径', () {
      expect(
        SubcontractDocConfig.materialReturn.approveEffect,
        isNot(contains('订货已材料退')),
      );
      expect(SubcontractDocConfig.waste.approveEffect, contains('不会再次扣公司库存'));
    });
  });
}
