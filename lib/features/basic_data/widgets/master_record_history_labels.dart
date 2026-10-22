import 'package:flutter/material.dart';

import 'master_inline_edit.dart';

const masterHistoryViewPermissions = <String, String>{
  'goods': 'goods:view',
  'clients': 'client:view',
  'suppliers': 'supplier:view',
  'moulds': 'mould:view',
  'colors': 'color:view',
  'units': 'unit:view',
  'currencies': 'currency:view',
  'warehouses': 'warehouse:view',
  'accounts': 'account:view',
  'reference-methods': 'settlement_method:view',
  'payment-styles': 'payment_style:view',
};

const masterHistoryCategoryPermissions = <String, String>{
  'goods': 'material_category:view',
  'clients': 'client_category:view',
  'suppliers': 'supplier_category:view',
  'moulds': 'mould_category:view',
};

String masterHistoryEntityLabel(BuildContext context, String value) {
  final labels = switch (value) {
    'goods' => ('货品资料', 'Goods', '품목'),
    'clients' => ('客户资料', 'Customers', '고객'),
    'suppliers' => ('供应商资料', 'Suppliers', '공급업체'),
    'moulds' => ('模具资料', 'Moulds', '금형'),
    'colors' => ('颜色资料', 'Colours', '색상'),
    'units' => ('基本单位', 'Units', '기본 단위'),
    'currencies' => ('币种资料', 'Currencies', '통화'),
    'warehouses' => ('仓库资料', 'Warehouses', '창고'),
    'accounts' => ('账户资料', 'Accounts', '계좌'),
    'reference-methods' => ('结算方式', 'Settlement methods', '결제 방식'),
    'payment-styles' => ('收付款类别', 'Receipt/payment categories', '입출금 분류'),
    _ => ('全部资料', 'All records', '전체 자료'),
  };
  return masterEditText(context, labels.$1, labels.$2, labels.$3);
}

String masterHistoryActionLabel(BuildContext context, String value) {
  final labels = switch (value) {
    'CREATE' => ('新增', 'Created', '생성'),
    'EDIT' => ('修改', 'Edited', '수정'),
    'DELETE' => ('删除', 'Deleted', '삭제'),
    'RESTORE' => ('恢复', 'Restored', '복원'),
    'STATUS' => ('启停变更', 'Status changed', '상태 변경'),
    _ => ('全部操作', 'All actions', '전체 작업'),
  };
  return masterEditText(context, labels.$1, labels.$2, labels.$3);
}

String masterHistorySourceLabel(BuildContext context, String value) =>
    switch (value) {
      'CATEGORY' => masterEditText(context, '分类', 'Category', '분류'),
      'BOM' => masterEditText(context, '组装信息', 'Assembly', '조립 정보'),
      'EXTENSION' => masterEditText(context, '扩展资料', 'Custom fields', '확장 필드'),
      _ => masterEditText(context, '资料', 'Record', '자료'),
    };
