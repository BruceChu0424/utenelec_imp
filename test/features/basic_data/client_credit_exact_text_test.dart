import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/widgets/client_master_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';

void main() {
  test(
    'client exact aliases own detail and list values above double precision',
    () {
      const credit =
          '1234567890123456789012345678901234567890.123456789012345678901234';
      const floor = '0.000000000000000000000001';
      final detail = ClientDetail.fromJson(const {
        'id': 'client',
        'credit': 1,
        'creditExact': credit,
        'creditFloor': 0,
        'creditFloorExact': floor,
        'initTotal': 0,
        'initTotalExact': '-0.123456789012345678901234',
      });
      final row = ClientListItem.fromJson(const {
        'id': 'client',
        'credit': 1,
        'creditExact': credit,
        'creditFloor': 0,
        'creditFloorExact': floor,
      });
      expect(detail.creditExactText, credit);
      expect(detail.creditFloorExactText, floor);
      expect(detail.initTotalExactText, '-0.123456789012345678901234');
      expect(row.creditExactText, credit);
      expect(row.creditFloorExactText, floor);
    },
  );

  test(
    'explicit unknown alias stays unknown and legacy numeric reads remain compatible',
    () {
      final unknown = ClientDetail.fromJson(const {
        'id': 'client',
        'creditFloor': 0,
        'creditFloorExact': null,
      });
      expect(unknown.creditFloorExactText, '');
      final legacy = ClientListItem.fromJson(const {
        'id': 'client',
        'credit': 1.25,
        'creditFloor': 2,
      });
      expect(legacy.credit, 1.25);
      expect(legacy.creditExactText, '1.25');
      expect(legacy.creditFloorExactText, '2');
    },
  );

  test(
    'shared financial editor submits original decimal text and keeps rights/read-only boundaries',
    () {
      final fields = buildClientFields(
        const {},
        const [],
        l10n: AppLocalizationsZh(),
        financialWritable: true,
      );
      final controller = MasterEditFormController(
        fields: fields,
        initialValues: const {
          'name': '匿名客户',
          'status': '使用',
          'credit': '1.123456789012345678901234',
          'initTotal': '-0.123456789012345678901234',
          'creditFloor': '0.000000000000000000000001',
        },
      );
      addTearDown(controller.dispose);
      expect(
        fields
            .where(
              (f) => {'credit', 'initTotal', 'creditFloor'}.contains(f.key),
            )
            .every((f) => f.exactDecimal),
        isTrue,
      );
      final body = controller.buildBody()!;
      expect(body['credit'], '1.123456789012345678901234');
      expect(body['initTotal'], '-0.123456789012345678901234');
      expect(body['creditFloor'], '0.000000000000000000000001');
      final locked = MasterEditFormController(
        fields: buildClientFields(
          const {},
          const [],
          l10n: AppLocalizationsZh(),
          financialWritable: true,
          legacyCreditSnapshot: true,
        ),
        initialValues: const {
          'name': '匿名旧客户',
          'status': '使用',
          'credit': '1.123456789012345678901234',
        },
      );
      addTearDown(locked.dispose);
      expect(locked.buildBody()!.containsKey('credit'), isFalse);
    },
  );
}
