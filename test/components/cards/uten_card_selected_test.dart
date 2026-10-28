// UtenCard.selected 选中态契约：底色复用全站「选中行」定稿色、边框转主色加粗。
// 主从列表「当前项」反馈的唯一维护入口（2026-10-27 权限页「按员工」首发）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

Widget _host(ThemeData theme) => MaterialApp(
  theme: theme,
  home: const Scaffold(
    body: Column(
      children: [
        UtenCard(key: ValueKey('plain'), child: Text('普通')),
        UtenCard(key: ValueKey('picked'), selected: true, child: Text('选中')),
      ],
    ),
  ),
);

Material _cardMaterial(WidgetTester tester, Key key) => tester.widget<Material>(
  find.descendant(of: find.byKey(key), matching: find.byType(Material)).first,
);

void main() {
  testWidgets('浅色主题：选中卡用定稿选中底色 + 主色 1.5 描边', (tester) async {
    final theme = ThemeData.light();
    await tester.pumpWidget(ProviderScope(child: _host(theme)));

    final plain = _cardMaterial(tester, const ValueKey('plain'));
    expect(plain.color, theme.colorScheme.surface);
    expect(
      (plain.shape! as RoundedRectangleBorder).side,
      const BorderSide(color: UtenColors.border),
    );

    final picked = _cardMaterial(tester, const ValueKey('picked'));
    expect(picked.color, UtenColors.tableSelectedRow);
    expect(
      (picked.shape! as RoundedRectangleBorder).side,
      BorderSide(color: theme.colorScheme.primary, width: 1.5),
    );
  });

  testWidgets('深色主题：选中卡用 teal900 定稿底色', (tester) async {
    final theme = ThemeData.dark();
    await tester.pumpWidget(ProviderScope(child: _host(theme)));

    final picked = _cardMaterial(tester, const ValueKey('picked'));
    expect(picked.color, UtenColors.tableSelectedRowDark);
    expect(
      (picked.shape! as RoundedRectangleBorder).side,
      BorderSide(color: theme.colorScheme.primary, width: 1.5),
    );
  });
}
