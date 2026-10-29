import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/models/production_draw_request.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/repositories/production_draw_request_repository.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/widgets/workshop_task_material_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('WORKSHOP_MATERIAL_SCREENSHOTS');
const _continue = Key('workshop-material-continue');

class _Api extends Fake implements ApiClient {}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'worker',
      code: 'CJ1',
      name: '车间',
      permissions: [
        Perm.productionExecutionView,
        Perm.productionExecutionStart,
      ],
    ),
  );
}

ProductionWorkshopTaskMaterial _material(int index, {bool drawable = true}) =>
    ProductionWorkshopTaskMaterial.fromJson({
      'demandId': 'demand-$index',
      'goodsCode': 'WL-00$index',
      'goodsName': index == 3 ? '自制开关后座' : '轨道开关物料 $index',
      'colorName': '深灰色',
      'unitName': '个',
      'supplyRoute': index == 3 ? 'MAKE' : 'BUY',
      'directSupply': index == 3,
      'requiredQty': 12000,
      'issuedQty': 1200,
      'requestableQty': drawable ? 10800 : 0,
      'warehouseAvailableQty': drawable ? 10800 : 0,
      'shortageQty': drawable ? 0 : 10800,
      'state': drawable ? 'DRAWABLE' : 'SHORT_MAKE',
      if (index == 3) 'producingSegments': 'ZX202610280001|IN_PROGRESS',
    });

class _Materials extends Fake
    implements ProductionExecutionWorkbenchRepository {
  List<ProductionWorkshopTaskMaterial> rows = [
    _material(1),
    _material(2),
    _material(3, drawable: false),
  ];
  Object? error;
  @override
  Future<List<ProductionWorkshopTaskMaterial>> workshopTaskMaterials(
    String id,
  ) async {
    if (error != null) throw error!;
    return rows;
  }
}

Map<String, dynamic> _previewJson() => {
  'fingerprint': 'authoritative',
  'taskCount': 1,
  'documentCount': 2,
  'lineCount': 3,
  'tasks': [
    {'segmentId': 'segment', 'expectedVersion': 7},
  ],
  'summaries': <Map<String, dynamic>>[],
  'lines': [
    for (final (id, demand, warehouse) in [
      ('source-a', 'demand-1', 'warehouse-a'),
      ('source-b', 'demand-1', 'warehouse-b'),
      ('source-c', 'demand-2', 'warehouse-a'),
      // A response for another task must never become this dialog's choice.
      ('source-other', 'demand-3', 'warehouse-a'),
    ])
      {
        'segmentId': id == 'source-other' ? 'other-segment' : 'segment',
        'drawId': 'draw-$warehouse',
        'drawItemId': id,
        'demandId': demand,
        'warehouseId': warehouse,
        'goodsId': 'goods',
        'qty': 10800,
      },
  ],
};

class _Draw extends Fake implements ProductionDrawRequestRepository {
  int calls = 0;
  Object? error;
  Completer<void>? gate;
  Map<String, dynamic> json = _previewJson();
  @override
  Future<ProductionDrawRequestPreview> preview(
    List<ProductionDrawRequestItem> items,
  ) async {
    calls++;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return ProductionDrawRequestPreview.fromJson(json);
  }
}

Future<
  ({
    ProviderContainer container,
    GlobalKey capture,
    ValueNotifier<Set<String>?> result,
  })
>
_open(
  WidgetTester tester, {
  _Materials? materials,
  _Draw? draw,
  bool canDraw = true,
  Size size = const Size(1280, 720),
  double scale = 1,
  bool dark = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final capture = GlobalKey();
  final result = ValueNotifier<Set<String>?>(null);
  addTearDown(result.dispose);
  final task = ProductionExecutionWorkbenchSegment.fromJson({
    'segmentId': 'segment',
    'planId': 'plan',
    'planNo': 'SC001',
    'segmentCode': 'ZX202610280008',
    'lockVersion': 7,
    'productName': '哈萨克二联双联双控开关',
  });
  var theme = dark ? buildDarkTheme() : buildLightTheme();
  if (_capture) theme = auditScreenshotTheme(theme);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        apiClientProvider.overrideWithValue(_Api()),
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          materials ?? _Materials(),
        ),
        productionDrawRequestRepositoryProvider.overrideWithValue(
          draw ?? _Draw(),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => RepaintBoundary(
          key: capture,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('打开物料'),
              onPressed: () async {
                result.value = await showWorkshopTaskMaterialDialog(
                  context,
                  task: task,
                  canRequestDraw: canDraw,
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.text('打开物料')),
  );
  await tester.tap(find.text('打开物料'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return (container: container, capture: capture, result: result);
}

void main() {
  testWidgets(
    'material selection returns only its exact source UUIDs and no write',
    (tester) async {
      final draw = _Draw();
      final harness = await _open(tester, draw: draw);
      expect(
        tester.widget<UtenButton>(find.byKey(_continue)).onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('workshop-material-select-demand-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('去领料（1 种）'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('workshop-material-select-demand-3')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(_continue));
      await tester.pumpAndSettle();
      expect(harness.result.value, {'source-a', 'source-b'});
      expect(draw.calls, 1);
    },
  );

  testWidgets(
    'read-only and cancelled material views never request a draw preview',
    (tester) async {
      final draw = _Draw();
      final harness = await _open(tester, draw: draw, canDraw: false);
      expect(find.byKey(_continue), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('自制开关后座'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(harness.result.value, isNull);
      expect(draw.calls, 0);
    },
  );

  testWidgets('preview failure retries independently of material facts', (
    tester,
  ) async {
    final draw = _Draw()..error = StateError('Unavailable');
    await _open(tester, draw: draw);
    expect(find.text('轨道开关物料 1'), findsOneWidget);
    expect(tester.widget<UtenButton>(find.byKey(_continue)).onPressed, isNull);
    draw.error = null;
    await tester.ensureVisible(
      find.byKey(const Key('workshop-material-preview-retry')),
    );
    await tester.tap(find.byKey(const Key('workshop-material-preview-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workshop-material-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('去领料（2 种）'), findsOneWidget);
    expect(draw.calls, 2);
  });

  testWidgets(
    'owner invalidation removes the material view and ignores a late preview',
    (tester) async {
      final gate = Completer<void>();
      final draw = _Draw()..gate = gate;
      final harness = await _open(tester, draw: draw, settle: false);
      harness.container.read(sessionEpochProvider.notifier).state++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(WorkshopTaskMaterialDialog), findsNothing);
      expect(harness.result.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read scope changes retire a rendered material selection', (
    tester,
  ) async {
    final harness = await _open(tester);
    await tester.tap(find.byKey(const Key('workshop-material-select-all')));
    await tester.pumpAndSettle();
    harness.container.read(readScopeRevisionProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(find.byType(WorkshopTaskMaterialDialog), findsNothing);
    expect(harness.result.value, isNull);
  });

  testWidgets('checkbox keeps keyboard space activation', (tester) async {
    await _open(tester);
    final checkbox = find.byKey(
      const ValueKey('workshop-material-select-demand-1'),
    );
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
    Focus.of(
      tester.element(
        find.descendant(of: checkbox, matching: find.byType(CustomPaint)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    expect(tester.widget<UtenButton>(find.byKey(_continue)).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large BOM mounts a bounded number of rows while selecting all exact sources',
    (tester) async {
      final materials = _Materials()
        ..rows = [for (var i = 1; i <= 1000; i++) _material(i)];
      final draw = _Draw()
        ..json = {
          ..._previewJson(),
          'lines': [
            for (var i = 1; i <= 1000; i++)
              {
                'segmentId': 'segment',
                'drawId': 'draw',
                'drawItemId': 'source-$i',
                'demandId': 'demand-$i',
                'warehouseId': 'warehouse',
                'goodsId': 'goods-$i',
                'qty': 10800,
              },
          ],
        };
      final harness = await _open(tester, materials: materials, draw: draw);
      final mountedRows = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'workshop-task-material-row-',
            ),
      );
      expect(
        mountedRows.evaluate().length,
        lessThan(30),
        reason: '完整1000物料保留，列表只挂载视区附近的行',
      );
      expect(find.text('轨道开关物料 1000'), findsNothing);
      await tester.tap(find.byKey(const Key('workshop-material-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('去领料（1000 种）'), findsOneWidget);
      await tester.tap(find.byKey(_continue));
      await tester.pumpAndSettle();
      expect(harness.result.value, hasLength(1000));
      expect(harness.result.value, contains('source-1000'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, size, scale, dark) in [
    ('desktop', const Size(1280, 720), 1.0, false),
    ('mobile-dark-large', const Size(390, 844), 1.5, true),
    ('short-window', const Size(800, 360), 1.0, false),
  ]) {
    testWidgets(
      'material dialog $name keeps actions reachable with scrolling',
      (tester) async {
        final harness = await _open(
          tester,
          size: size,
          scale: scale,
          dark: dark,
        );
        if (name == 'short-window') {
          final firstChoice = find.byKey(
            const ValueKey('workshop-material-select-demand-1'),
          );
          expect(
            firstChoice.hitTestable(),
            findsOneWidget,
            reason: '短窗首屏须直接看到并可操作物料，不能只剩筛选与动作',
          );
          await tester.tap(firstChoice);
          await tester.pumpAndSettle();
          expect(tester.widget<Checkbox>(firstChoice).value, isTrue);
        }
        await tester.ensureVisible(
          find.byKey(const Key('workshop-material-select-all')),
        );
        await tester.tap(find.byKey(const Key('workshop-material-select-all')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(_continue));
        expect(find.byKey(_continue).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            harness.capture,
            'workshop-material-$name',
          );
        }
      },
    );
  }
}
