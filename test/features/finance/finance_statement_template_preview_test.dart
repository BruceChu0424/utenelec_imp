import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/report/shared/report_print_preview.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
  });
  for (final kind in ['balance', 'profit']) {
    testWidgets(
      '$kind template renders the authoritative columns in print preview',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final capture = GlobalKey();
        final table = (await tester.runAsync(
          () => loadBoundedReportPrintPreview(
            api: _TemplateApi(_fixture(kind)),
            endpointOf: () =>
                '/finance/reports/gl/${kind == 'balance' ? 'balance-sheet' : 'profit-monthly'}',
            queryOf: () => const {'layout': 'template'},
            isCurrent: () => true,
            useSuggestedWidths: true,
          ),
        ))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showUtenPrintPreview(
                        showOutputScope: false,
                        context: context,
                        title: kind == 'balance' ? '资产负债表' : '利润表',
                        subtitle: '编制单位：本地回归样例  单位：元',
                        applyTableProjection: false,
                        loader: () async => table,
                      ),
                      child: const Text('模板预览'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('模板预览'));
        await tester.pumpAndSettle();
        expect(find.textContaining('本地回归样例'), findsWidgets);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await boundary.toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'output/finance-template-audit-20261031/ui/$kind-template.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }
      },
    );
  }
}

Map<String, dynamic> _fixture(String kind) {
  final generated = File('server/target/finance-statement-fixtures/$kind.json');
  if (const bool.fromEnvironment('UI_CAPTURE')) {
    if (!generated.existsSync()) {
      throw StateError(
        'Run the financial asset PostgreSQL regression before UI_CAPTURE',
      );
    }
    return jsonDecode(generated.readAsStringSync()) as Map<String, dynamic>;
  }
  final balance = kind == 'balance';
  final keys = balance
      ? [
          'assetItem',
          'assetLineNo',
          'assetEnd',
          'assetStart',
          'liabilityItem',
          'liabilityLineNo',
          'liabilityEnd',
          'liabilityStart',
        ]
      : ['item', 'lineNo', 'yearAmount', 'monthAmount'];
  final labels = balance
      ? ['资产', '行次', '期末余额', '年初余额', '负债和所有者权益', '行次', '期末余额', '年初余额']
      : ['项目', '行次', '本年累计金额', '本月金额'];
  final values = balance
      ? <Object>['固定资产原价', 18, '1200.0000', '0', '实收资本', 48, '1200.0000', '0']
      : <Object>['四、净利润', 32, '-100.0000', '-100.0000'];
  return {
    'columns': [
      for (var i = 0; i < keys.length; i++)
        {
          'key': keys[i],
          'label': labels[i],
          'type': i % 4 == 0
              ? 'text'
              : i % 4 == 1
              ? 'int'
              : 'money',
        },
    ],
    'rows': [
      {for (var i = 0; i < keys.length; i++) keys[i]: values[i]},
    ],
    'page': 1,
    'size': 1,
    'total': 1,
    'totalPages': 1,
  };
}

class _TemplateApi extends ApiClient {
  _TemplateApi(this.response) : super(Dio());
  final Map<String, dynamic> response;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {...response, 'readScopeVersion': 'financial-template-fixture'};
}
