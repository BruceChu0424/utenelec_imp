import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/feedback/uten_center_alert.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/shared/widgets/master_detail_card.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_detail_menu.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  testWidgets(
    'detail menu resolves current permission and cancelling causes no mutation',
    (tester) async {
      var canDelete = true;
      var deleted = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: UtenHierarchyDetailMenu(
                entriesBuilder: () => [
                  if (canDelete)
                    UtenMenuItem(
                      label: '删除分类',
                      icon: Icons.delete_outline,
                      destructive: true,
                      onTap: () => deleted++,
                    ),
                  ...utenHierarchyCopyEntries(
                    tester.element(find.byType(MasterDetailCard)),
                    name: '外贸系列',
                    path: '成品 / 外贸系列',
                  ),
                ],
                child: const MasterDetailCard(
                  title: '外贸系列',
                  subtitle: 'HP · L2',
                  stats: [],
                  canEdit: false,
                ),
              ),
            ),
          ),
        ),
      );
      final trigger = find.byKey(const ValueKey('hierarchy-detail-menu'));
      expect(tester.getSize(trigger).width, greaterThanOrEqualTo(44));
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('删除分类'), findsOneWidget);
      await tester.tapAt(const Offset(2, 500));
      await tester.pumpAndSettle();
      expect(deleted, 0);
      canDelete = false;
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('删除分类'), findsNothing);
      expect(find.text('复制分类路径'), findsOneWidget);
      expect(deleted, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (
      name: 'desktop-light',
      size: const Size(1200, 800),
      dark: false,
      scale: 1.0,
    ),
    (name: 'desktop-dark', size: const Size(1200, 800), dark: true, scale: 1.0),
    (
      name: 'phone-large-text',
      size: const Size(390, 844),
      dark: false,
      scale: 2.0,
    ),
    (
      name: 'landscape-dark',
      size: const Size(640, 320),
      dark: true,
      scale: 2.0,
    ),
  ]) {
    for (final logout in [false, true]) {
      testWidgets(
        '${scenario.name} ${logout ? 'logout' : 'order'} uses readable width and reachable cancellation',
        (tester) async {
          const capture = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
          if (capture) await loadAuditScreenshotFonts(tester);
          tester.view.physicalSize = scenario.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final captureKey = GlobalKey();
          bool? returned;
          var writes = 0;
          final theme = scenario.dark ? buildDarkTheme() : buildLightTheme();
          await tester.pumpWidget(
            RepaintBoundary(
              key: captureKey,
              child: MaterialApp(
                theme: capture ? auditScreenshotTheme(theme) : theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scenario.scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () async {
                        returned = logout
                            ? await UtenCenterAlert.show(
                                context,
                                title: '退出登录',
                                message: '确定要退出登录吗?',
                                icon: Icons.logout_rounded,
                                confirmLabel: '退出登录',
                                cancelLabel: '取消',
                              )
                            : await UtenDialog.show(
                                context,
                                title: '确认本次下单',
                                content: const Text(
                                  '委外追加 100 个\n关联采购子件 100 个\n请核对本次将产生的申请。',
                                ),
                                confirmLabel: '确认下单',
                                cancelLabel: '取消',
                              );
                        if (returned == true) writes++;
                      },
                      child: const Text('打开'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(find.byType(UtenDialogHeading), findsOneWidget);
          final dialog = find.byType(Dialog).last;
          final width = tester
              .getSize(
                find
                    .descendant(of: dialog, matching: find.byType(Material))
                    .first,
              )
              .width;
          if (scenario.size.width >= 1000) {
            expect(width, 520);
          }
          expect(width, lessThanOrEqualTo(scenario.size.width));
          final cancel = find.text('取消');
          await tester.ensureVisible(cancel);
          await tester.pumpAndSettle();
          expect(cancel.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (capture) {
            await saveAuditScreenshot(
              tester,
              captureKey,
              'confirmation-${logout ? 'logout' : 'order'}-${scenario.name}',
            );
          }
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          expect(returned, isFalse);
          expect(writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
