import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

import '../support/audit_screenshot_support.dart';

void main() {
  const captureScreenshots = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
  for (final scenario in [
    (width: 375.0, dark: false, scale: 1.0, locale: 'zh', copy: '复制所选文字'),
    (
      width: 760.0,
      dark: true,
      scale: 1.3,
      locale: 'en',
      copy: 'Copy selected text',
    ),
    (width: 1280.0, dark: false, scale: 1.6, locale: 'ko', copy: '선택한 텍스트 복사'),
  ]) {
    testWidgets(
      'selected text menu fits ${scenario.width} ${scenario.locale}',
      (tester) async {
        tester.view.physicalSize = Size(scenario.width, 680);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadAuditScreenshotFonts(tester);
        final koreanFont = await loadAuditKoreanScreenshotFont(
          tester,
          requiredForCapture: captureScreenshots && scenario.locale == 'ko',
        );
        final oldShadows = debugDisableShadows;
        if (captureScreenshots) debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = oldShadows);
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(scenario.locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: auditScreenshotTheme(
              scenario.dark ? buildDarkTheme() : buildLightTheme(),
              fontFamilyFallback: koreanFont == null ? null : [koreanFont],
            ),
            builder: (context, child) => RepaintBoundary(
              key: capture,
              child: UtenContextMenuPolicy(
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
                  child: child!,
                ),
              ),
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: MasterDataTableView<String>(
                  columns: [
                    MasterColumnDef(
                      key: 'code',
                      label: '编号',
                      width: 160,
                      value: (row) => row,
                    ),
                    MasterColumnDef(
                      key: 'name',
                      label: '货品名称',
                      width: 280,
                      value: (row) => '单联单控开关 $row',
                    ),
                    MasterColumnDef(
                      key: 'spec',
                      label: '规格',
                      width: 160,
                      value: (_) => '86 × 86',
                    ),
                  ],
                  items: const ['280108001', '280108002', '280108003'],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  selectable: true,
                  idOf: (row) => row,
                  onSelectedIdsChanged: (_) {},
                  rowMenuBuilder: (_) => [
                    UtenMenuItem(label: '查看货品', onTap: () {}),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rich = find.descendant(
          of: find.text('280108001'),
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(rich);
        final textBox = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 9),
            )
            .single;
        final start = paragraph.localToGlobal(
          Offset(textBox.left + 0.1, (textBox.top + textBox.bottom) / 2),
        );
        final end = paragraph.localToGlobal(
          Offset(textBox.right + 1, (textBox.top + textBox.bottom) / 2),
        );
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(end);
        await mouse.up();
        await tester.pumpAndSettle();
        final right = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await right.up();
        await tester.pumpAndSettle();
        final copy = find.text(scenario.copy);
        expect(copy, findsOneWidget);
        final rect = tester.getRect(copy);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(scenario.width));
        expect(copy.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (captureScreenshots) {
          await saveAuditScreenshot(
            tester,
            capture,
            'table-text-copy-${scenario.width.toInt()}-${scenario.locale}',
          );
        }
      debugDisableShadows = oldShadows;
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }
}
