@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/features/admin/widgets/permission_action_badge.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  final catalog =
      jsonDecode(
            File(
              'server/src/main/resources/permission-help.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final entries = (catalog['permissions'] as List).cast<Map<String, dynamic>>();
  for (final width in [1440.0, 375.0]) {
    testWidgets('权限说明在 $width 宽可悬停或点击展开且不改变授权', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final help = entries.firstWhere(
        (entry) => entry['code'] == 'sales_order:view',
      );
      final boundary = GlobalKey();
      var toggles = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildLightTheme(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 800),
                  textScaler: TextScaler.linear(width < 400 ? 1.6 : 1),
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: CheckboxListTile(
                    value: false,
                    onChanged: (_) => toggles++,
                    title: PermissionTitleBlock(
                      name: help['name'] as String,
                      actionType: PermissionActionType.view,
                      description: help['description'] as String,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final icon = find.byType(UtenFieldHintIcon);
      if (width > 400) {
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(icon));
        await tester.pump(const Duration(milliseconds: 600));
      } else {
        await tester.tap(icon);
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(help['description'] as String), findsOneWidget);
      expect(toggles, 0);
      expect(tester.takeException(), isNull);
      if (width < 400) {
        final scroll = find.byType(SingleChildScrollView).last;
        await tester.drag(scroll, const Offset(0, -320));
        await tester.pumpAndSettle();
        expect(toggles, 0);
        expect(
          tester
              .state<ScrollableState>(
                find.descendant(of: scroll, matching: find.byType(Scrollable)),
              )
              .position
              .pixels,
          greaterThan(0),
        );
      }
      if (Platform.environment['UTEN_CAPTURE_PERMISSION_HELP'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final target = File(
            'output/readonly-permission-unification/permission-help-${width.toInt()}.png',
          );
          await target.parent.create(recursive: true);
          await target.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
