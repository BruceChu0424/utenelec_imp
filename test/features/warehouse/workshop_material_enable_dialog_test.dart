import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_enable_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _SetupOnlyApi extends ApiClient {
  _SetupOnlyApi() : super(Dio());
  final reads = <String>[];
  Map<String, dynamic>? saved;
  List<Map<String, dynamic>> candidates = [
    {'id': 'main-a', 'code': 'A', 'name': '启用主仓 A'},
  ];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/workshop-material/settings/main-warehouses') {
      return candidates;
    }
    throw ApiException('FORBIDDEN', '没有通用仓库或库存读取权限');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/workshop-material/settings/shop-a/in-progress-pending') {
      return {'products': <Object>[]};
    }
    throw ApiException('FORBIDDEN', '没有额外读取权限');
  }

  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/workshop-material/settings/shop-a');
    saved = Map<String, dynamic>.from(body! as Map);
    return {
      'workshopDepartmentId': 'shop-a',
      'workshopName': '目标车间',
      'periodicEnabled': true,
      'mainWarehouseId': saved!['mainWarehouseId'],
      'binWarehouseId': 'bin-a',
      'binWarehouseName': '目标车间内料仓',
      'rowVersion': 1,
    };
  }
}

Future<List<WmSetting>> _mount(
  WidgetTester tester,
  _SetupOnlyApi api, {
  String? initialMain,
}) async {
  final results = <WmSetting>[];
  tester.view
    ..physicalSize = const Size(1100, 950)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.workshopMaterialSetup,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        workshopMaterialRepositoryProvider.overrideWithValue(
          WorkshopMaterialRepository(api),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showWorkshopMaterialEnableDialog(
                  context,
                  setting: WmSetting(
                    workshopDepartmentId: 'shop-a',
                    workshopName: '目标车间',
                    periodicEnabled: false,
                    mainWarehouseId: initialMain,
                    allowedActions: const ['SETUP'],
                  ),
                );
                if (result != null) results.add(result);
              },
              child: const Text('开启车间'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('开启车间'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets(
    'setup-only opens and selects exact eligible main without warehouse dictionary permission',
    (tester) async {
      final api = _SetupOnlyApi();
      final results = await _mount(tester, api);
      expect(
        api.reads,
        containsAll([
          '/workshop-material/settings/main-warehouses',
          '/workshop-material/settings/shop-a/in-progress-pending',
        ]),
      );
      expect(
        api.reads.any(
          (p) => p.startsWith('/master/warehouses') || p.contains('/position'),
        ),
        false,
      );
      expect(find.textContaining('没有通用仓库'), findsNothing);
      await tester.tap(find.byKey(const Key('wm-enable-main-warehouse')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用主仓 A').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wm-enable-submit')));
      await tester.pumpAndSettle();
      expect(api.saved!['mainWarehouseId'], 'main-a');
      expect(api.saved!['enabled'], true);
      expect(results.single.workshopDepartmentId, 'shop-a');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale initial main is cleared when the eligible metadata no longer contains it',
    (tester) async {
      final api = _SetupOnlyApi();
      await _mount(tester, api, initialMain: 'disabled-old-main');
      await tester.tap(find.byKey(const Key('wm-enable-submit')));
      await tester.pumpAndSettle();
      expect(api.saved, isNull);
      expect(find.text('请选择放在哪个主仓下'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no main candidate explains the configuration and cannot submit a stale ID',
    (tester) async {
      final api = _SetupOnlyApi()..candidates = [];
      await _mount(tester, api, initialMain: 'old-main');
      expect(find.textContaining('没有可选的启用主仓'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wm-enable-submit')));
      await tester.pumpAndSettle();
      expect(api.saved, isNull);
    },
  );
}
