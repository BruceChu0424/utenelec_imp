import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/settings/settings_section.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';

const _help = '选择主仓时包含自身和全部子仓。实际仓库权限和数据仍按当前登录员工授权计算。';

Widget _host(Widget child, {double scale = 1}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 640),
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(body: SizedBox(width: 360, child: child)),
    ),
  ),
);

void main() {
  for (final custom in [false, true]) {
    for (final interaction in ['hover', 'tap', 'keyboard']) {
      testWidgets('app bar help $interaction with custom title $custom', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            UtenAppBar(
              title: '库存',
              titleWidget: custom ? const Text('库存') : null,
              info: _help,
              showPagePermissionAction: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_help), findsNothing);
        final title = tester.getRect(find.text('库存'));
        final hint = tester.getRect(find.byType(UtenFieldHintIcon));
        expect(hint.left, greaterThanOrEqualTo(title.right));
        expect((title.center.dy - hint.center.dy).abs(), lessThan(2));
        expect(
          tester
              .widget<UtenAppBar>(find.byType(UtenAppBar))
              .preferredSize
              .height,
          56,
        );
        if (interaction == 'hover') {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(700, 500));
          await mouse.moveTo(hint.center);
          await tester.pump(const Duration(milliseconds: 251));
          await tester.pumpAndSettle();
          await mouse.removePointer();
        } else if (interaction == 'keyboard') {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.byType(UtenFieldHintIcon));
          await tester.pumpAndSettle();
        }
        expect(find.text(_help), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('hub help never navigates, while the entry still opens', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        UtenHubCard(
          icon: Icons.inventory_2_outlined,
          label: '库存',
          description: _help,
          onTap: () => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_help), findsNothing);
    final title = tester.getRect(find.text('库存'));
    final hint = tester.getRect(find.byType(UtenFieldHintIcon));
    expect((title.center.dy - hint.center.dy).abs(), lessThan(2));
    await tester.tap(find.byType(UtenFieldHintIcon));
    await tester.pumpAndSettle();
    expect(find.text(_help), findsOneWidget);
    expect(opened, 0);
    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings help does not expand its setting', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsItem(title: '字体大小', subtitle: _help, child: Text('设置内容')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_help), findsNothing);
    expect(find.text('设置内容'), findsNothing);
    await tester.tap(find.byType(UtenFieldHintIcon));
    await tester.pumpAndSettle();
    expect(find.text(_help), findsOneWidget);
    expect(find.text('设置内容'), findsNothing);
    await tester.tap(find.text('字体大小'));
    await tester.pumpAndSettle();
    expect(find.text('设置内容'), findsOneWidget);
  });

  for (final inline in [false, true]) {
    testWidgets(
      'summary retains exact value and adjacent help, inline $inline',
      (tester) async {
        await tester.pumpWidget(
          _host(
            UtenSummaryField(
              label: '原币金额',
              value: '123456789.123456 元',
              info: _help,
              inline: inline,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('123456789.123456 元'), findsOneWidget);
        expect(find.text(_help), findsNothing);
        await tester.tap(find.byType(UtenFieldHintIcon));
        await tester.pumpAndSettle();
        expect(find.text(_help), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('long help stays within a narrow enlarged viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final message = List.filled(8, _help).join('\n\n');
    await tester.pumpWidget(
      _host(
        SettingsItem(
          title: '安装说明',
          subtitle: message,
          child: const Text('设置内容'),
        ),
        scale: 1.8,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(UtenFieldHintIcon));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    final scroll = find.ancestor(
      of: find.text(message),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroll, findsOneWidget);
    final tooltip = tester.getRect(scroll);
    expect(tooltip.left, greaterThanOrEqualTo(0));
    expect(tooltip.right, lessThanOrEqualTo(390));
    expect(tooltip.top, greaterThanOrEqualTo(0));
    expect(tooltip.bottom, lessThanOrEqualTo(640));
    await tester.drag(scroll, const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
