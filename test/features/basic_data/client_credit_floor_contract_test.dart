import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';

void main() {
  test('client list and detail default a missing floor to zero', () {
    final listItem = ClientListItem.fromJson(const {
      'id': 'client-1',
      'creditFloor': 50000,
    });
    final detail = ClientDetail.fromJson(const {'id': 'client-1'});

    expect(listItem.creditFloor, 50000);
    expect(detail.creditFloor, 0);
  });

  // V630(2026-09-20)：客户「月结/现金/定金」货款类别标签整体退役——表单、列表列、
  // 详情初值和模型都不得再出现它；结账方式(默认结账方式/本单结账方式)是唯一条款。
  test('client editor and list no longer carry the retired payment label', () {
    final editorSource = File(
      'lib/features/basic_data/widgets/client_master_edit.dart',
    ).readAsStringSync();
    final listSource = File(
      'lib/features/basic_data/pages/client_category_page.dart',
    ).readAsStringSync();
    final detailSource = File(
      'lib/features/basic_data/pages/party_detail_page.dart',
    ).readAsStringSync();
    final modelSource = File(
      'lib/features/basic_data/models/client_node.dart',
    ).readAsStringSync();

    for (final source in [
      editorSource,
      listSource,
      detailSource,
      modelSource,
    ]) {
      expect(source, isNot(contains('salesPaymentType')));
      expect(source, isNot(contains('销售货款类型')));
      expect(source, isNot(contains('待人工分类')));
    }
    expect(editorSource, contains("key: 'defaultSettlementMethodId'"));
    expect(editorSource, contains("key: 'creditFloor'"));
    expect(editorSource, contains("label: '铺底额'"));
  });

  test(
    'legacy Credit is a read-only snapshot distinct from the active floor',
    () {
      final source =
          File(
            'lib/features/basic_data/pages/client_category_page.dart',
          ).readAsStringSync() +
          File(
            'lib/features/basic_data/widgets/client_master_edit.dart',
          ).readAsStringSync();

      expect(source, contains("if (d.legacyId != null) 'credit'"));
      expect(source, contains('legacyCreditSnapshot: d.legacyId != null'));
      expect(source, contains('旧库 Credit 快照（只读）'));
      expect(source, contains('信用额度 / 旧库 Credit 快照'));
      expect(source, contains("key: 'creditFloor'"));
    },
  );
}
