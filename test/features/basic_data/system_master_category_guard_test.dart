import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/system_master_category_guard.dart';

void main() {
  group('system uncategorized category guard', () {
    test('uses only the server-derived UUID authority flag', () {
      expect(isSystemUncategorizedCategory(systemManaged: true), isTrue);
      expect(isSystemUncategorizedCategory(systemManaged: false), isFalse);
    });

    test('blocks mutation without taking away normal edit permission', () {
      expect(
        canMutateMasterCategory(hasEditPermission: true, systemManaged: true),
        isFalse,
      );
      expect(
        canMutateMasterCategory(hasEditPermission: true, systemManaged: false),
        isTrue,
      );
      expect(
        canMutateMasterCategory(hasEditPermission: false, systemManaged: false),
        isFalse,
      );
    });
  });

  testWidgets('protection notice explains the missing edit/delete actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SystemMasterCategoryProtectionNotice()),
      ),
    );

    expect(
      find.text(systemUncategorizedCategoryProtectionMessage),
      findsOneWidget,
    );
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, systemUncategorizedCategoryProtectionMessage);
  });
}
