import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_other_issue_dialog.dart';

void main() {
  for (final interaction in ['tap', 'hover']) {
    testWidgets(
      'other issue help is inline by $interaction and validation stays visible',
      (tester) async {
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale('zh'),
              home: Scaffold(
                body: WorkshopMaterialOtherIssueDialog(
                  workshopId: 'workshop',
                  materials: [],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        const guidance = '试模、清机、报废的料在这里登记, 记车间费用, 不摊给产品。';
        expect(find.text(guidance), findsNothing);
        final hint = find.byWidgetPredicate(
          (widget) => widget is UtenFieldHintIcon && widget.info == guidance,
        );
        final title = find.text('试模清机等用料');
        expect(hint, findsOneWidget);
        expect(title, findsOneWidget);
        expect(
          tester.getRect(hint).center.dy,
          closeTo(tester.getRect(title).center.dy, 16),
        );
        if (interaction == 'tap') {
          await tester.tap(hint);
          await tester.pumpAndSettle();
        } else {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(380, 830));
          await mouse.moveTo(tester.getCenter(hint));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(find.text(guidance), findsOneWidget);
          await mouse.removePointer();
        }
        expect(find.text(guidance), findsOneWidget);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('wm-other-issue-submit')));
        await tester.pumpAndSettle();
        expect(find.text('请选择料'), findsOneWidget);
        expect(find.text(guidance), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
