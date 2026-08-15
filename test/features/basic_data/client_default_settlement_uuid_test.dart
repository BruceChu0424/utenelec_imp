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
    final pageSource = File(
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
        'Future<List<ReferenceMethodOption>?> _loadSettlementMethods()',
        '// ---- 客户 新建/编辑/删除',
      );
      expect(loader, contains('if (_settlementOptionsLoading) return null'));
      expect(loader, contains('barrierDismissible: false'));
      expect(loader, contains('final methods = await'));
      expect(loader, contains('if (methods.isEmpty)'));
      expect(loader, contains("context.appError('暂无可用结账方式"));
      expect(loader, contains('return null;'));
      expect(loader, contains('on ApiException catch'));
      expect(loader, contains("context.appError('加载结账方式失败，请重试')"));

      final create = _between(
        pageSource,
        'Future<void> _showClientCreate()',
        'Future<bool> _doCreateClient',
      );
      _expectLoadGuardBeforeDialog(create);

      final edit = _between(
        pageSource,
        'Future<void> _showClientEdit(ClientDetail d)',
        'Future<bool> _doUpdateClient',
      );
      _expectLoadGuardBeforeDialog(edit);
      expect(edit, contains('!settlementMethods.any('));
      expect(edit, contains('method.id == d.defaultSettlementMethodId'));
      expect(edit, contains('请先修复客户结账方式关联'));
    });
  });
}

void _expectLoadGuardBeforeDialog(String source) {
  final load = source.indexOf('await _loadSettlementMethods()');
  final guard = source.indexOf('settlementMethods == null) return');
  final dialog = source.indexOf('showMasterEditDialog(');
  expect(load, greaterThanOrEqualTo(0));
  expect(guard, greaterThan(load));
  expect(dialog, greaterThan(guard));
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  expect(startIndex, greaterThanOrEqualTo(0));
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}
