import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_learning_panel.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Future<void> _pump(WidgetTester tester, Map<String, dynamic> summary) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        goodsBomLearningProvider('shell').overrideWith((ref) async => summary),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(body: GoodsBomLearningPanel(goodsId: 'shell')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unlearned item explains when valid samples begin', (
    tester,
  ) async {
    await _pump(tester, {'active': false});
    expect(find.textContaining('尚无学习记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'learned cumulative quantities and per-unit usage remain distinct',
    (tester) async {
      await _pump(tester, {
        'active': true,
        'enabled': true,
        'totalOutputQty': 400,
        'sampleCount': 2,
        'unitName': '个',
        'materials': [
          {
            'goodsId': 'plastic',
            'goodsName': '塑料',
            'goodsCode': 'P01',
            'unitName': '千克',
            'totalNetQty': 42,
            'averageQty': 0.105,
          },
        ],
      });
      expect(find.text('自动更新 BOM'), findsOneWidget);
      expect(find.textContaining('累计实际产量: 400 个'), findsOneWidget);
      expect(find.text('0.105'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('manual ownership is explained without technical reason codes', (
    tester,
  ) async {
    await _pump(tester, {
      'active': true,
      'enabled': false,
      'blockedReason': 'MANUAL_BOM',
      'totalOutputQty': 400,
      'sampleCount': 2,
      'materials': <Map<String, dynamic>>[],
    });
    expect(find.textContaining('自动更新已暂停'), findsOneWidget);
    expect(find.text('MANUAL_BOM'), findsNothing);
    expect(find.text('自动更新 BOM'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
