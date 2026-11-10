import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_confirmation_summary.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_allocation_view.dart';
import 'package:uten_imp/shared/models/inbound_allocation.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  testWidgets(
    'confirmation keeps only aggregates for 1000 lines and returns cancellation without a write',
    (tester) async {
      bool? accepted;
      await _pump(tester, onAccepted: (value) => accepted = value);
      await tester.tap(find.text('打开确认'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1000 行 · 2 个仓库', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('61100 个', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('不应重复列出'), findsNothing);
      expect(find.textContaining('计划部预定'), findsNothing);
      expect(find.text('审核员：验收员(QA-01)'), findsOneWidget);
      await tester.tap(find.text('返回修改'));
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same reviewer quality release remains an explicit confirmation fact',
    (tester) async {
      await _pump(tester, ownRelease: true);
      await tester.tap(find.text('打开确认'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp('本单品质放行.*由当前账号执行'), findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(UtenConfirmationSummary), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cross-warehouse and unknown scope remain visible without repeating goods',
    (tester) async {
      await _pump(tester, exceptions: true);
      await tester.tap(find.text('打开确认'));
      await tester.pumpAndSettle();
      expect(find.textContaining('跨仓 1 行：实际 五金仓，预定 配件仓'), findsOneWidget);
      expect(find.textContaining('1 行预计去向待核对'), findsOneWidget);
      expect(find.textContaining('不绑定原计划'), findsOneWidget);
      expect(find.textContaining('不应重复列出'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'aggregate confirmation fits desktop and narrow large text without item scrolling',
    (tester) async {
      for (final variant in [
        (size: const Size(1200, 850), scale: 1.0, dark: false),
        (size: const Size(390, 850), scale: 1.5, dark: true),
      ]) {
        tester.view.physicalSize = variant.size;
        tester.view.devicePixelRatio = 1;
        final capture = GlobalKey();
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await loadAuditScreenshotFonts(tester);
        }
        await _pump(
          tester,
          scale: variant.scale,
          dark: variant.dark,
          capture: capture,
        );
        await tester.tap(find.text('打开确认'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('61100 个', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('不应重复列出'), findsNothing);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await saveAuditScreenshot(
            tester,
            capture,
            'arrival-summary-${variant.size.width.toInt()}-${variant.dark ? 'dark' : 'light'}',
          );
        }
        await tester.tap(find.text('返回修改'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
      tester.view.reset();
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  ValueChanged<bool>? onAccepted,
  bool exceptions = false,
  bool ownRelease = false,
  double scale = 1,
  bool dark = false,
  GlobalKey? capture,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWith(_ReviewerSession.new)],
      child: RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: const bool.fromEnvironment('UI_CAPTURE')
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          darkTheme: const bool.fromEnvironment('UI_CAPTURE')
              ? auditScreenshotTheme(buildDarkTheme())
              : buildDarkTheme(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('打开确认'),
                onPressed: () async {
                  final accepted =
                      await showWarehouseInboundAllocationConfirmDialog(
                        context,
                        title: '先入库后质检(3 张收货单)',
                        actionLabel: '登记先入库',
                        ownRelease: ownRelease,
                        summary: const UtenConfirmationSummary(
                          facts: [
                            UtenConfirmationFact(
                              label: '本次登记',
                              value: '1000 行 · 2 个仓库',
                              info: '按库位上架送检，合格自动转正入库，不合格从库位退回。',
                            ),
                            UtenConfirmationFact(
                              label: '到货实物量',
                              value: '61100 个',
                            ),
                          ],
                        ),
                        sections: [
                          for (var i = 0; i < 1000; i++)
                            WarehouseInboundAllocationSection(
                              id: '$i',
                              goodsLabel: '不应重复列出-$i',
                              quantity: '61.1',
                              unitName: '个',
                              allocations: [
                                WarehouseInboundAllocation(
                                  kind: exceptions && i == 1
                                      ? WarehouseInboundAllocationKind.unknown
                                      : WarehouseInboundAllocationKind
                                            .exactAnalysis,
                                  qty: 61.1,
                                  qtyExact: '61.1',
                                  warehouseMatches: !exceptions || i != 0,
                                  actualWarehouseName: '五金仓',
                                  targetWarehouseName: '配件仓',
                                ),
                              ],
                            ),
                        ],
                      );
                  onAccepted?.call(accepted);
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ReviewerSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'qa',
      code: 'QA-01',
      name: '验收员',
      employeeId: 'qa-employee',
    ),
  );
}
