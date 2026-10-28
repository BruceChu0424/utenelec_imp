import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';

void main() {
  group('client default settlement UUID models', () {
    test('list item parses UUID authority and display name', () {
      final item = ClientListItem.fromJson(const {
        'id': 'client-id',
        'defaultSettlementMethodId': 'settlement-uuid',
        'defaultSettlementMethodName': '月结',
      });

      expect(item.defaultSettlementMethodId, 'settlement-uuid');
      expect(item.defaultSettlementMethodName, '月结');
    });

    test('detail parses UUID authority and display name', () {
      final detail = ClientDetail.fromJson(const {
        'id': 'client-id',
        'defaultSettlementMethodId': 'settlement-uuid',
        'defaultSettlementMethodName': '现金',
      });

      expect(detail.defaultSettlementMethodId, 'settlement-uuid');
      expect(detail.defaultSettlementMethodName, '现金');
    });
  });

  group('client editor UUID-only contract', () {
    // 2026-09-14：客户编辑字段表与保存流程抽取到 client_master_edit.dart
    //（分类页与详情整页共用），源码契约随迁；新建弹窗仍留在分类页。
    final pageSource = File(
      'lib/features/basic_data/widgets/client_master_edit.dart',
    ).readAsStringSync();
    final categoryPageSource = File(
      'lib/features/basic_data/pages/client_category_page.dart',
    ).readAsStringSync();
    final formSource = File(
      'lib/features/basic_data/widgets/master_edit_dialog.dart',
    ).readAsStringSync();

    test('edit and status-save submit UUID and never legacy priceStyle', () {
      expect(pageSource, contains("key: 'defaultSettlementMethodId'"));
      expect(
        pageSource,
        contains(
          "'defaultSettlementMethodId': d.defaultSettlementMethodId ?? ''",
        ),
      );
      expect(
        pageSource,
        contains("'defaultSettlementMethodId': d.defaultSettlementMethodId"),
      );
      expect(pageSource, isNot(contains("'priceStyle'")));
    });

    test('clearing the optional UUID selector submits explicit null', () {
      final fieldBlock = _between(
        pageSource,
        "key: 'defaultSettlementMethodId'",
        "key: 'credit'",
      );

      expect(fieldBlock, contains('type: MasterFieldType.select'));
      expect(fieldBlock, isNot(contains('required: true')));
      expect(formSource, contains('body[f.key] = null;'));
    });

    test('loading, errors, and empty dictionaries fail closed', () {
      final loader = _between(
        pageSource,
        'Future<List<ReferenceMethodOption>?> loadClientSettlementMethods(',
        '/// 客户编辑弹窗（分类页与详情页共用）。[onSaved] 在保存成功后回调（刷新各自数据）。',
      );
      // Ownership, duplicate loads and late completions are exercised by the
      // real full-editor widget tests; this contract keeps UUID dictionary use.
      expect(
        loader,
        contains('loadMasterReferenceOptions<ReferenceMethodOption>'),
      );
      expect(loader, contains('.settlementMethods()'));
      expect(loader, contains("emptyMessage: '暂无可用结账方式"));
      expect(loader, contains("errorFallback: '加载结账方式失败，请重试'"));
      final sharedLoader = File(
        'lib/features/basic_data/widgets/master_reference_options_loader.dart',
      ).readAsStringSync();
      expect(sharedLoader, contains('values.isEmpty && emptyMessage != null'));
      expect(sharedLoader, contains('context.appError(emptyMessage)'));
      expect(
        sharedLoader,
        contains('context.appApiError(error, fallback: errorFallback)'),
      );
      expect(sharedLoader, contains('return null;'));
      final blockingTask = File(
        'lib/components/feedback/uten_task_progress_dialog.dart',
      ).readAsStringSync();
      expect(blockingTask, contains('barrierDismissible: false'));

      // 2026-09-14：新建仍留在分类页，编辑流程在共享模块 showClientMasterEdit。
      final create = _between(
        categoryPageSource,
        'Future<void> _showClientCreate(',
        'Future<bool> _doCreateClient',
      );
      _expectCreateLoadGuardBeforeDialog(create);

      final edit = _between(
        pageSource,
        'Future<void> showClientMasterEdit(',
        '    onSubmit: (body) async {',
      );
      _expectEditLoadGuardBeforeDialog(edit);
      // 2026-09-15 用户口径「点击编辑报错」：原守卫在当前默认结账方式已停用时
      // 直接报错拦死编辑。现改为追加带「已停用」标注的选项保住原值（客户可顺手
      // 改掉），编辑不再被单个字典值挡住；V592 默认币种同款保值。
      expect(
        edit,
        contains(
          'settlementOptions.any((m) => m.id == d.defaultSettlementMethodId)',
        ),
      );
      expect(edit, contains('已停用'));
      expect(edit, isNot(contains('请先修复客户结账方式关联')));
    });
  });
}

void _expectCreateLoadGuardBeforeDialog(String source) {
  final load = source.indexOf(
    'await loadClientSettlementMethods(context, ref)',
  );
  final guard = source.indexOf('settlementMethods == null) return');
  final dialog = source.indexOf('showMasterEditDialog(');
  expect(load, greaterThanOrEqualTo(0));
  expect(guard, greaterThan(load));
  expect(dialog, greaterThan(guard));
}

void _expectEditLoadGuardBeforeDialog(String source) {
  final load = source.indexOf('await loadClientSettlementMethods(');
  final guard = source.indexOf('|| settlementMethods == null) return');
  final dialog = source.indexOf('await showMasterEditDialog(');
  expect(load, greaterThanOrEqualTo(0));
  expect(guard, greaterThan(load));
  expect(dialog, greaterThan(guard));
  expect(source, contains('owner: owner'));
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  expect(startIndex, greaterThanOrEqualTo(0));
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}
