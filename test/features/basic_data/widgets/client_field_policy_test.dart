import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/basic_data/widgets/client_master_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_create_fields.dart';

void main() {
  test(
    'sales editors omit all protected finance fields while preserving shipment policy',
    () {
      final fields = buildClientFields(
        const {},
        const [],
        l10n: AppLocalizationsZh(),
      );
      final controller = MasterEditFormController(
        fields: fields,
        initialValues: const {
          'name': '客户',
          'status': '使用',
          'bank': '原开户行',
          'initTotal': '100',
          'creditFloor': '5000',
          'defaultShipmentPolicy': 'ALLOW_PARTIAL',
        },
      );
      addTearDown(controller.dispose);
      final body = controller.buildBody();
      expect(body, isNotNull);
      expect(body!['name'], '客户');
      expect(body['defaultShipmentPolicy'], 'ALLOW_PARTIAL');
      expect(body.keys.toSet().intersection(clientFinancialFieldKeys), isEmpty);
    },
  );

  test(
    'legacy Credit snapshot never round-trips through editable financial submissions',
    () {
      final fields = buildClientFields(
        const {},
        const [],
        l10n: AppLocalizationsZh(),
        financialWritable: true,
        legacyCreditSnapshot: true,
      );
      final controller = MasterEditFormController(
        fields: fields,
        initialValues: const {
          'name': '历史客户',
          'status': '使用',
          'credit': '99999999999999.9999',
          'bank': '财务改开户行',
        },
      );
      addTearDown(controller.dispose);
      expect(
        fields.singleWhere((field) => field.key == 'credit').readOnly,
        isTrue,
      );
      final body = controller.buildBody();
      expect(body, isNotNull);
      expect(body!['bank'], '财务改开户行');
      expect(body.containsKey('credit'), isFalse);
    },
  );

  test('finance-only editor omits ordinary master fields', () {
    final fields = buildClientFields(
      const {},
      const [],
      l10n: AppLocalizationsZh(),
      ordinaryWritable: false,
      financialWritable: true,
    );
    final controller = MasterEditFormController(
      fields: fields,
      initialValues: const {
        'name': '客户',
        'status': '使用',
        'bank': '新开户行',
        'initTotal': '100',
      },
    );
    addTearDown(controller.dispose);
    final body = controller.buildBody();
    expect(body, isNotNull);
    expect(body!['bank'], '新开户行');
    expect(body['initTotal'], 100);
    expect(body.containsKey('name'), isFalse);
    expect(body.containsKey('status'), isFalse);
    expect(body.containsKey('defaultShipmentPolicy'), isFalse);
  });

  test('inline creation keeps protected dictionary selectors read-only', () {
    final fields = masterInlineCreateFields(
      buildClientFields(const {}, const [], l10n: AppLocalizationsZh()),
      options: {
        'defaultSettlementMethodId': () async => const [],
        'defaultCurrencyId': () async => const [],
      },
    );
    for (final key in clientFinancialFieldKeys) {
      expect(
        fields.singleWhere((field) => field.key == key).readOnly,
        isTrue,
        reason: key,
      );
    }
  });
}
