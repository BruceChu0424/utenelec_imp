// ADR-111 源码契约：主档页的批量启停/删除、组件信息粘贴与删除只走服务端命令，
// 不再在前端逐条循环调单条接口、catch 吞错(选 100 条就是 200 次串行请求的老路)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  const pages = [
    'lib/features/basic_data/pages/client_category_page.dart',
    'lib/features/basic_data/pages/supplier_category_page.dart',
    'lib/features/basic_data/pages/mould_category_page.dart',
    'lib/features/basic_data/pages/product_category_page.dart',
    'lib/features/basic_data/pages/color_page.dart',
  ];

  test('主档页不再逐条循环调单条状态/删除接口', () {
    for (final path in pages) {
      final source = _read(path);
      expect(
        RegExp(
          r'for \(final id in ids\)[\s\S]{0,400}?\.(delete|change)\(',
        ).hasMatch(source),
        isFalse,
        reason: '$path 仍在循环里逐条调状态/删除接口',
      );
      expect(source, isNot(contains('_batchSetClientStatus')));
      expect(source, isNot(contains('_batchSetSupplierStatus')));
      expect(source, isNot(contains('_batchSetMouldStatus')));
      expect(source, isNot(contains('_batchSetGoodsStatus')));
    }
    // 批量命令只有一个调用点：共享明细区(颜色页是扁平主档，直接用同一个仓库)。
    expect(
      _read('lib/features/basic_data/widgets/master_entity_detail_pane.dart'),
      contains('masterBatchRepositoryProvider'),
    );
    expect(
      _read('lib/features/basic_data/pages/color_page.dart'),
      contains('masterBatchRepositoryProvider'),
    );
  });

  test('组件信息粘贴与删除是一次请求的服务端原子命令', () {
    final goods = _read(
      'lib/features/basic_data/pages/product_category_page.dart',
    );
    expect(goods, contains('.paste('));
    expect(goods, isNot(contains('_applyPasteBom')));
    expect(goods, isNot(contains('goodsBomRepositoryProvider).create(')));
    expect(goods, isNot(contains('catch (_) {}')));
    final tab = _read('lib/features/basic_data/widgets/goods_bom_tab.dart');
    expect(tab, isNot(contains('grouped.entries')), reason: '跨层删除不再按父件分组逐组提交');
    // 「添加组件」弹窗同样走追加命令(ADR-111 评审修复)：仓库接口里已经没有逐条新建/删除，
    // 前端想循环调单条也无从调起。
    expect(tab, contains('mode: BomPasteMode.append'));
    expect(tab, isNot(contains('for (final body in bodies)')));
    final repo = _read(
      'lib/features/basic_data/repositories/goods_bom_repository.dart',
    );
    expect(repo, isNot(contains('Future<GoodsBomItem> create(')));
    expect(repo, isNot(contains('Future<void> delete(String goodsId')));
  });
}
