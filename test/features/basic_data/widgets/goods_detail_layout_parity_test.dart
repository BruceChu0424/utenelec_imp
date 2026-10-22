import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_detail_action_layout.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('查看和编辑共用四列容量及字段顺序，窄屏和大字自动回退', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
          colorDictProvider.overrideWith((ref) async => const []),
          unitDictProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GoodsDetailBody(
              initialDetail: GoodsDetail(
                id: 'layout-parity',
                name: '布局货品',
                code: 'QA001',
                nameEn: 'Layout goods',
                status: '使用',
                sourceType: '自制',
                writable: true,
              ),
              initialCategoryId: null,
              canCreate: false,
              canEdit: true,
              canStatus: false,
              canBomCreate: false,
              canBomEdit: false,
              canBomDelete: false,
              onToggleStatus: null,
              onDelete: null,
              onDataChanged: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    UtenFormGrid firstGrid() =>
        tester.widget<UtenFormGrid>(find.byType(UtenFormGrid).first);
    final view = firstGrid();
    final before = [
      for (final field in view.children.take(4))
        tester.getRect(find.byWidget(field)),
    ];
    expect(before.map((rect) => rect.top).toSet(), hasLength(1));
    expect(find.byType(UtenDetailActionLayout), findsOneWidget);
    expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final edit = firstGrid();
    final after = [
      for (final field in edit.children.take(4))
        tester.getRect(find.byWidget(field)),
    ];
    for (var i = 0; i < before.length; i++) {
      expect(after[i].left, closeTo(before[i].left, 0.01));
      expect(after[i].width, closeTo(before[i].width, 0.01));
    }
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    final narrow = firstGrid();
    final first = tester.getRect(find.byWidget(narrow.children[0]));
    final second = tester.getRect(find.byWidget(narrow.children[1]));
    expect(second.top, greaterThan(first.bottom));
    expect(tester.takeException(), isNull);
  });
}
