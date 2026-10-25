import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_detail_sheet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_legacy_remark.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_read_only_fields.dart';

void main() {
  testWidgets('party inspectors share single-line readable legacy remarks', (
    tester,
  ) async {
    const raw = '[原始主档编号] {"code":"GY-OLD-1","mnumber":""}';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MasterReadOnlyFields(
            fields: const [MasterFieldDef(key: 'remark', label: 'Remark')],
            valueOf: (_) => raw,
          ),
        ),
      ),
    );
    final value = tester.widget<Text>(find.text('Original code: GY-OLD-1'));
    expect(value.maxLines, 1);
    expect(value.overflow, TextOverflow.ellipsis);
    expect(find.byTooltip('Original code: GY-OLD-1'), findsOneWidget);
    expect(raw, contains('"code"'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy code archive is readable and ordinary notes stay intact', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            expect(
              masterLegacyRemarkText(
                context,
                'Business note\n[原始主档编号] {"code":"Q9-M04-B【E3-02】","mnumber":""}',
              ),
              'Business note\nOriginal code: Q9-M04-B【E3-02】',
            );
            expect(
              masterLegacyRemarkText(
                context,
                '[原始主档编号] {"code":"A","mnumber":"B"}',
              ),
              'Original code: A · Original alternate code: B',
            );
            for (final raw in [
              'Ordinary note {"code":"A"}',
              '[原始主档编号] malformed',
              '[原始主档编号] {"code":"A"}',
              '[原始主档编号] {"code":"A","mnumber":"B","other":1}',
            ]) {
              expect(masterLegacyRemarkText(context, raw), raw);
            }
            return const SizedBox();
          },
        ),
      ),
    );
  });

  for (final width in [420.0, 1200.0]) {
    testWidgets('detail values stay on one line with full tooltip at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const value =
          'Very long mould note with original code and storage rack '
          'that should stay inside its field\nSecond line';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMasterDetailSheet(
                  context: context,
                  title: 'Mould',
                  rows: const [MasterDetailRow('Remark', value)],
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text(value));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.byTooltip(value), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
