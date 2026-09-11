import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_gauge_ring.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

void main() {
  UtenGaugeRingPainter painterOf(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<UtenGaugeRingPainter>()
      .single;

  testWidgets('draws the value fraction and the semantic status color', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const UtenGaugeRing(
          value: 85,
          status: UtenGaugeStatus.warning,
          label: '系统内存',
          warning: 80,
          critical: 90,
          statusText: '留意',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final painter = painterOf(tester);
    expect(painter.fraction, closeTo(0.85, 0.0001));
    expect(painter.progressColor, UtenColors.warningText);
    expect(painter.dashed, isFalse);
    expect(painter.warningFraction, closeTo(0.8, 0.0001));
    expect(painter.criticalFraction, closeTo(0.9, 0.0001));
    expect(find.text('85'), findsOneWidget);
    expect(find.text('%'), findsOneWidget);
  });

  testWidgets(
    'a missing value stays empty and dashed instead of showing zero',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          const UtenGaugeRing(
            value: null,
            status: UtenGaugeStatus.unknown,
            label: '连接池',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final painter = painterOf(tester);
      expect(painter.fraction, 0);
      expect(painter.dashed, isTrue);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    },
  );

  testWidgets('a value beyond the ring maximum never overdraws the arc', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const UtenGaugeRing(
          value: 900,
          status: UtenGaugeStatus.critical,
          label: '积压',
          warning: 50,
          critical: 500,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final painter = painterOf(tester);
    expect(painter.fraction, 1);
    expect(painter.criticalFraction, isNull, reason: '超出满量程的刻度不画');
    expect(painter.progressColor, UtenColors.errorText);
  });

  for (final quiet in [_Quiet.lite, _Quiet.reducedMotion, _Quiet.offstage]) {
    testWidgets('$quiet jumps straight to the new value without a transition', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const UtenGaugeRing(
            value: 10,
            status: UtenGaugeStatus.normal,
            label: '处理器',
          ),
          quiet: quiet,
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _harness(
          const UtenGaugeRing(
            value: 90,
            status: UtenGaugeStatus.normal,
            label: '处理器',
          ),
          quiet: quiet,
        ),
      );
      await tester.pump();
      expect(painterOf(tester).fraction, closeTo(0.9, 0.0001));
    });
  }

  testWidgets('standard tier animates from the old value to the new one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const UtenGaugeRing(
          value: 10,
          status: UtenGaugeStatus.normal,
          label: '处理器',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _harness(
        const UtenGaugeRing(
          value: 90,
          status: UtenGaugeStatus.normal,
          label: '处理器',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = painterOf(tester).fraction;
    expect(mid, greaterThan(0.1));
    expect(mid, lessThan(0.9));
    await tester.pumpAndSettle();
    expect(painterOf(tester).fraction, closeTo(0.9, 0.0001));
  });

  testWidgets('reads out label, value and status as one node', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(
        const UtenGaugeRing(
          value: 12,
          status: UtenGaugeStatus.normal,
          label: '处理器',
          statusText: '正常',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('处理器 12%,正常'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('huge fonts cap the diameter and keep the number readable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const UtenGaugeRing(
          value: 100,
          status: UtenGaugeStatus.critical,
          label: '磁盘',
        ),
        textScale: 2.4,
      ),
    );
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(AspectRatio));
    expect(size.width, size.height);
    expect(size.width, lessThanOrEqualTo(140 * 1.6 + 0.01));
    expect(size.width, greaterThan(140));
    expect(find.text('100'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow parent shrinks the ring instead of overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const SizedBox(
          width: 60,
          child: UtenGaugeRing(
            value: 50,
            status: UtenGaugeStatus.normal,
            label: '磁盘',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AspectRatio)), const Size(60, 60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('equal-height card rows can measure the ring intrinsically', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: UtenGaugeRing(
                  value: 50,
                  status: UtenGaugeStatus.normal,
                  label: '磁盘',
                  caption: '12 / 100',
                ),
              ),
              Expanded(child: Text('旁边的卡片')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('12 / 100'), findsOneWidget);
  });
}

enum _Quiet { none, lite, reducedMotion, offstage }

Widget _harness(Widget child, {_Quiet quiet = _Quiet.none, double? textScale}) {
  Widget body = Align(alignment: Alignment.topLeft, child: child);
  if (quiet == _Quiet.offstage) body = TickerMode(enabled: false, child: body);
  return ProviderScope(
    overrides: [
      performanceProvider.overrideWith(
        quiet == _Quiet.lite ? _LiteTier.new : _StandardTier.new,
      ),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: quiet == _Quiet.reducedMotion,
          textScaler: TextScaler.linear(textScale ?? 1),
        ),
        child: Scaffold(body: body),
      ),
    ),
  );
}

class _StandardTier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.standard;
}

class _LiteTier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.lite;
}
