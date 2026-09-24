import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/profile/widgets/profile_change_diff_row.dart';

void main() {
  testWidgets(
    'profile review places the complete new value below a struck old row at narrow width',
    (tester) async {
      const oldValue = '原地址第一行\n第二行\n第三行\n第四行不应被截断';
      const newValue = '新地址第一行\n第二行\n第三行\n第四行也应完整显示';
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: ProfileChangeDiffRow(
                  item: ProfileChangeItem(
                    id: 'change',
                    batchId: 'batch',
                    fieldCode: 'hujiAddress',
                    fieldLabel: '户籍地址',
                    fieldGroup: 'contact',
                    oldValue: oldValue,
                    newValue: newValue,
                    status: ProfileChangeStatus.pending,
                    submittedBy: 'employee',
                    submittedAt: DateTime(2026, 9, 23),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenRevisionStrike), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(oldValue)).dy,
        lessThan(tester.getTopLeft(find.text(newValue)).dy),
      );
      expect(tester.widget<Text>(find.text(newValue)).maxLines, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
