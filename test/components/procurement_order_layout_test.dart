import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';

void main() {
  for (final entries in [
    <String, String>{},
    {'supplier-1': '供应商'},
  ]) {
    testWidgets('采购与委外核心字段在字典加载前后保持一致 $entries', (tester) async {
      late List<String> purchase;
      late List<String> subcontract;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              purchase = purchaseGridColumns(
                (_) async {},
                context: context,
                showSource: true,
                supplierRequired: true,
                supplierEntries: entries,
                showCommercial: true,
                showAllowedOverReceipt: true,
                showRemark: true,
              ).map((column) => column.key).toList();
              subcontract = subcontractGridColumns(
                (_) async {},
                SubcontractDocConfig.by(SubcontractDocType.order),
                context: context,
                supplierRequired: true,
                supplierEntries: entries,
                showCommercial: true,
                showRemark: true,
              ).map((column) => column.key).toList();
              return const SizedBox();
            },
          ),
        ),
      );
      expect(purchase, [
        'goods',
        'goodsCode',
        'colorName',
        'source',
        'supplier',
        'qty',
        'allowedOverReceiptPct',
        'price',
        'amount',
        'currency',
        'taxRate',
        'settlement',
        'remark',
        'giftQty',
        'physicalQty',
      ]);
      expect(subcontract, [
        'goods',
        'goodsCode',
        'colorName',
        'source',
        'supplier',
        'qty',
        'allowedLossPct',
        'price',
        'amount',
        'currency',
        'taxRate',
        'settlement',
        'remark',
      ]);
    });
  }
}
