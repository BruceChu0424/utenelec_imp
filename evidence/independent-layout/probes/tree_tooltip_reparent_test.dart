import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

Widget host() => MaterialApp(
  theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
  builder: (_, child) => UtenDisplayZoomBox(
    fontFactor: 1, child: UtenControlTheme(child: child!),
  ),
  home: Scaffold(
    body: UtenSplitView(
      minTwoPaneWidth: 840,
      selectedLeadingLabel: '全部模具',
      leading: UtenCategoryTreeView<PaymentStyleNode>(
        nodes: [PaymentStyleNode(id:'all',code:'ALL',name:'全部模具',children:const [])],
        showSearch: false,
      ),
      trailing: const TextField(key: ValueKey('retained-input')),
    ),
  ),
);

void main() {
  for (final hover in [false,true]) {
    testWidgets('actual tree ${hover ? 'hover' : 'legal nohover'} first narrowing',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280,900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('retained-input')), '7.125 unsaved');
      final mouse=await tester.createGesture(kind:PointerDeviceKind.mouse);
      await mouse.addPointer(location:const Offset(2,2));
      addTearDown(mouse.removePointer);
      if(hover) {
        await mouse.moveTo(tester.getCenter(find.text('全部模具').first));
        await tester.pump(const Duration(milliseconds:800));
        await tester.pumpAndSettle();
      }
      tester.view.physicalSize=const Size(714,764);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('7.125 unsaved'),findsOneWidget);
    });
  }
}
