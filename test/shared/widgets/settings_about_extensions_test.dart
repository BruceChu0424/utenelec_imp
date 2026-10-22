import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/settings_about_extensions.dart';

void main() {
  testWidgets('settings entries come from the nearest application host', (
    tester,
  ) async {
    Widget entries() => Builder(
      builder: (context) =>
          Column(children: SettingsAboutExtensions.of(context)),
    );

    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: entries()),
    );
    expect(find.text('Update'), findsNothing);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SettingsAboutExtensions(
          entries: const [Text('Update')],
          child: entries(),
        ),
      ),
    );
    expect(find.text('Update'), findsOneWidget);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SettingsAboutExtensions(
          entries: const [Text('Publish')],
          child: entries(),
        ),
      ),
    );
    expect(find.text('Update'), findsNothing);
    expect(find.text('Publish'), findsOneWidget);
  });
}
