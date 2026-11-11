// Production Windows engine + production bootstrap/providers + real HTTP.
// Only filesystem roots are isolated. No business API, repository or session is replaced.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uten_imp/app.dart';
import 'package:uten_imp/main.dart' as application;
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_log.dart';
import 'package:uten_imp/core/io/client_private_paths.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../tool/finance_acceptance_platform.dart';
import '../test/support/first_flutter_failure_capture.dart';

const _account = String.fromEnvironment(
  'UTEN_FEEDBACK_ACCOUNT',
  defaultValue: 'feedback-mould-qa',
);
const _returnsAccount = String.fromEnvironment('UTEN_FEEDBACK_RETURNS_ACCOUNT');
const _runtimeRoot = String.fromEnvironment('UTEN_FEEDBACK_RUNTIME_ROOT');
const _evidenceRoot = String.fromEnvironment('UTEN_FEEDBACK_EVIDENCE_DIR');
const _configPath = String.fromEnvironment('UTEN_FEEDBACK_PRIVATE_CONFIG');
const _sourceHead = String.fromEnvironment('UTEN_FEEDBACK_SOURCE_SHA');
const _backendSourceHead = String.fromEnvironment(
  'UTEN_FEEDBACK_BACKEND_SOURCE_SHA',
);
const _windowScenario = String.fromEnvironment(
  'UTEN_FEEDBACK_WINDOW_SCENARIO',
  defaultValue: 'original-714',
);
final _capture = GlobalKey();
final _observations = <Map<String, Object?>>[];
FirstFlutterFailureCapture? _flutterFailure;
var _nativeWindowSequence = 0;

void _checkFlutterFailure(WidgetTester tester) {
  final Object? pending = tester.takeException();
  if (_flutterFailure?.first != null) _flutterFailure!.throwFirst();
  if (pending != null) throw pending;
}

Finder get _mouldFinder => find.byWidgetPredicate(
  (widget) => widget is MasterDataTableView<MouldListItem>,
);
MasterDataTableView<MouldListItem> _mould(WidgetTester tester) =>
    tester.widget<MasterDataTableView<MouldListItem>>(_mouldFinder);

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready,
  String stage, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  _flutterFailure?.phase = stage;
  final clock = Stopwatch()..start();
  while (true) {
    _checkFlutterFailure(tester);
    final resourceWarning = find.textContaining(
      RegExp('处理器占用|系统内存占用'),
      findRichText: true,
    );
    final acknowledge = find.text('已知悉', findRichText: true).hitTestable();
    if (resourceWarning.evaluate().isNotEmpty &&
        acknowledge.evaluate().isNotEmpty) {
      await tester.tap(acknowledge.last);
      await tester.pump(const Duration(milliseconds: 100));
      _observations.add({
        'scene': 'host-resource-warning',
        'status': 'observed-and-acknowledged',
      });
      continue;
    }
    if (ready()) break;
    if (clock.elapsed > timeout) {
      await _screen(tester, 'failure-$stage');
      fail('Actual Windows application did not complete: $stage');
    }
    await tester.pump(const Duration(milliseconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 80));
  _checkFlutterFailure(tester);
}

Future<Map<String, dynamic>> _resizeNativeWindow(
  WidgetTester tester,
  Size requested,
  String stage, {
  bool cleanup = false,
}) async {
  _flutterFailure?.phase = stage;
  final sequence = ++_nativeWindowSequence;
  final token = sequence.toString().padLeft(4, '0');
  final request = File('$_evidenceRoot/native-window-request-$token.json');
  final temporary = File('${request.path}.tmp');
  temporary.writeAsStringSync(
    jsonEncode({
      'sourceHead': _sourceHead,
      'sequence': sequence,
      'width': requested.width,
      'height': requested.height,
      'phase': stage,
      'scenario': _windowScenario,
    }),
    flush: true,
  );
  temporary.renameSync(request.path);
  final result = File('$_evidenceRoot/native-window-result-$token.json');
  if (cleanup) {
    final elapsed = Stopwatch()..start();
    while (!result.existsSync() &&
        elapsed.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!result.existsSync()) {
      throw StateError('Native cleanup geometry response missing');
    }
  } else {
    await _wait(tester, result.existsSync, stage);
  }
  final receipt = jsonDecode(result.readAsStringSync()) as Map<String, dynamic>;
  if (cleanup && receipt['expectedWindowAlreadyClosed'] == true) {
    _observations.add({
      'scene': stage,
      'expectedOwnedWindowAlreadyClosed': true,
      'replacementWindowsTouched': false,
    });
    return receipt;
  }
  if (receipt['ok'] != true) {
    throw StateError(
      'Owned native window request failed: ${receipt['errorType']} ${receipt['message']}',
    );
  }
  final after = receipt['after'] as Map<String, dynamic>;
  expect(
    (after['clientLogicalWidth'] as num).toDouble(),
    closeTo(requested.width, 2),
  );
  expect(
    (after['clientLogicalHeight'] as num).toDouble(),
    closeTo(requested.height, 2),
  );
  if (!cleanup) {
    await _wait(
      tester,
      () =>
          ((tester.view.physicalSize.width / tester.view.devicePixelRatio) -
                      requested.width)
                  .abs() <=
              2 &&
          ((tester.view.physicalSize.height / tester.view.devicePixelRatio) -
                      requested.height)
                  .abs() <=
              2,
      '$stage-engine-metrics',
    );
  }
  _observations.add({
    'scene': stage,
    'nativeRequestSequence': sequence,
    'nativeApi': receipt['nativeApi'],
    'requestedClientWidth': requested.width,
    'requestedClientHeight': requested.height,
    'observedNativeClientWidth': after['clientLogicalWidth'],
    'observedNativeClientHeight': after['clientLogicalHeight'],
    'engineLogicalWidth':
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
    'engineLogicalHeight':
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
    'fakeViewMetricsUsed': false,
    'scenario': _windowScenario,
    'belowInteractiveMinimumStress': receipt['belowInteractiveMinimumStress'],
    'setWindowPosFlags': receipt['setWindowPosFlags'],
  });
  return receipt;
}

Future<void> _wideNarrowMouldMenu(WidgetTester tester) async {
  await _resizeNativeWindow(tester, const Size(1280, 900), 'mould-wide-native');
  final category = find.text('全部模具').hitTestable().first;
  expect(category, findsOneWidget);
  final tooltip = find
      .ancestor(of: category, matching: find.byType(Tooltip))
      .first;
  expect(tooltip, findsOneWidget);
  final tooltipWidget = tester.widget<Tooltip>(tooltip);
  final message =
      tooltipWidget.message ?? tooltipWidget.richMessage?.toPlainText();
  expect(message, isNotEmpty);
  int tooltipTextMatches() => find
      .descendant(
        of: tooltip,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == message,
        ),
      )
      .evaluate()
      .length;
  bool tooltipVisible() => tester
      .widgetList<FadeTransition>(
        find.descendant(of: tooltip, matching: find.byType(FadeTransition)),
      )
      .any((fade) => fade.opacity.value > .9);
  final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
  Object? firstFailure;
  StackTrace? firstStack;
  try {
    await mouse.addPointer(location: tester.getCenter(category));
    await mouse.moveTo(tester.getCenter(category));
    await _wait(
      tester,
      () => tooltipVisible() && tooltipTextMatches() >= 1,
      'mould-category-tooltip-visible',
    );
    _observations.add({
      'scene': 'mould-wide-category-tooltip',
      'matchingRichTexts': tooltipTextMatches(),
      'tooltipFadeVisible': tooltipVisible(),
      'realMouseKind': true,
    });
    await _screen(tester, 'mould-wide-category-tooltip');
    // Retain this pointer location through the native resize. Do not dismiss the tooltip.
    const narrowWidth = _windowScenario == 'supported-min800' ? 800.0 : 714.0;
    await _resizeNativeWindow(
      tester,
      const Size(narrowWidth, 764),
      'mould-$_windowScenario-before-operation',
    );
    await _screen(tester, 'mould-narrow-before-menu');
    final operation = find
        .descendant(of: _mouldFinder, matching: find.byTooltip('表格操作'))
        .hitTestable();
    final inlinePrint = find.text('预览打印').hitTestable();
    await _wait(
      tester,
      () =>
          operation.evaluate().isNotEmpty || inlinePrint.evaluate().isNotEmpty,
      'mould-table-operation-presentation',
    );
    if (operation.evaluate().isNotEmpty) {
      _observations.add({
        'scene': 'narrow-operation-presentation',
        'presentation': 'menu',
        'scenario': _windowScenario,
      });
      await _mouseClick(
        tester,
        mouse,
        operation,
        'mould-table-operation-click',
      );
      await _wait(
        tester,
        () => find
            .byKey(const ValueKey('uten-anchored-popup'))
            .evaluate()
            .isNotEmpty,
        'mould-table-operation-open',
      );
      await _screen(tester, 'mould-narrow-table-operation');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _wait(
        tester,
        () => find
            .byKey(const ValueKey('uten-anchored-popup'))
            .evaluate()
            .isEmpty,
        'mould-table-operation-closed',
      );
    } else {
      _observations.add({
        'scene': 'narrow-operation-presentation',
        'presentation': 'inline',
        'scenario': _windowScenario,
      });
      await _mouseClick(tester, mouse, inlinePrint, 'mould-inline-print-click');
      await _wait(
        tester,
        () => find
            .byKey(const ValueKey('table-output-all'))
            .evaluate()
            .isNotEmpty,
        'mould-inline-print-scope',
      );
      await _screen(tester, 'mould-narrow-inline-operation');
      final scope = find
          .ancestor(
            of: find.byKey(const ValueKey('table-output-all')),
            matching: find.byType(UtenDialogFrame),
          )
          .first;
      await _tap(
        tester,
        find.descendant(of: scope, matching: find.byType(UtenCloseButton)),
        stage: 'mould-inline-print-scope-cancel',
      );
      await _wait(
        tester,
        () => find.byKey(const ValueKey('table-output-all')).evaluate().isEmpty,
        'mould-inline-print-scope-closed',
      );
    }
    expect(_mould(tester).items, hasLength(1626));
    await _resizeNativeWindow(
      tester,
      const Size(1280, 900),
      'mould-wide-restored',
    );
    expect(_mould(tester).items, hasLength(1626));
    await _screen(tester, 'mould-wide-restored');
  } catch (error, stack) {
    firstFailure = error;
    firstStack = stack;
  } finally {
    try {
      await mouse.removePointer();
    } catch (error, stack) {
      firstFailure ??= error;
      firstStack ??= stack;
      _observations.add({
        'scene': 'mouse-cleanup-error',
        'exceptionType': error.runtimeType.toString(),
      });
    }
  }
  if (firstFailure != null) {
    Error.throwWithStackTrace(firstFailure, firstStack!);
  }
}

Future<void> _mouseClick(
  WidgetTester tester,
  TestGesture mouse,
  Finder finder,
  String stage,
) async {
  await _settled(tester);
  _flutterFailure?.phase = stage;
  final reachable = finder.hitTestable();
  expect(reachable, findsWidgets);
  await tester.ensureVisible(reachable.last);
  final position = tester.getCenter(reachable.last);
  await mouse.moveTo(position);
  await mouse.down(position);
  await mouse.up();
  await tester.pump(const Duration(milliseconds: 100));
  _checkFlutterFailure(tester);
}

Future<void> _settled(WidgetTester tester) => _wait(
  tester,
  () => find.byType(UtenBusyOverlay).evaluate().isEmpty,
  'busy-completed',
);

Future<void> _tap(
  WidgetTester tester,
  Finder finder, {
  String stage = 'control-tap',
}) async {
  await _settled(tester);
  _flutterFailure?.phase = stage;
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 50));
  final reachable = finder.hitTestable();
  expect(reachable, findsWidgets);
  await tester.tap(reachable.last);
  await tester.pump(const Duration(milliseconds: 100));
  _checkFlutterFailure(tester);
}

Future<void> _screen(WidgetTester tester, String scene) async {
  _flutterFailure?.phase = 'screen:$scene';
  await tester.pump();
  if (!scene.startsWith('failure-')) {
    _checkFlutterFailure(tester);
  }
  final context = _capture.currentContext;
  if (context == null || !context.mounted) {
    if (!scene.startsWith('failure-')) {
      fail('Actual capture owner is unavailable');
    }
    return;
  }
  final object = context.findRenderObject();
  if (object is! RenderRepaintBoundary || object.debugNeedsPaint) {
    if (!scene.startsWith('failure-')) {
      fail('Actual frame has not painted');
    }
    return;
  }
  final image = await object.toImage();
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Actual engine returned no PNG');
    final destination = File('$_evidenceRoot/screenshots/$scene.png');
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    _observations.add({
      'scene': scene,
      'surface': 'windows-engine-real-http',
      'width': image.width,
      'height': image.height,
      'lifecycle':
          WidgetsBinding.instance.lifecycleState?.name ?? 'not-observed',
    });
  } finally {
    image.dispose();
  }
}

Future<void> _login(
  ProviderContainer container,
  WidgetTester tester,
  String account,
  String password,
) async {
  await container
      .read(sessionProvider.notifier)
      .login(account: account, password: password);
  await _wait(
    tester,
    () => container.read(sessionProvider).isLoggedIn,
    'login',
  );
  expect(container.read(sessionProvider).user?.superAdmin, isFalse);
  expect(container.read(apiBaseUrlProvider), 'http://127.0.0.1:28630/api');
}

Future<void> _returnPicker(
  WidgetTester tester,
  ProviderContainer container,
  bool purchase,
) async {
  final router = container.read(appRouterProvider);
  router.go(purchase ? '/purchase/returns/new' : '/subcontract/returns/new');
  await _wait(
    tester,
    () => purchase
        ? find.byType(UtenEditableGrid<PurchaseGridRow>).evaluate().isNotEmpty
        : find
              .byType(UtenEditableGrid<SubcontractGridRow>)
              .evaluate()
              .isNotEmpty,
    purchase ? 'purchase-editor' : 'subcontract-editor',
  );
  await _settled(tester);
  late TextEditingController quantity;
  late Listenable goods;
  if (purchase) {
    final row = tester
        .widget<UtenEditableGrid<PurchaseGridRow>>(
          find.byType(UtenEditableGrid<PurchaseGridRow>),
        )
        .controller
        .rows
        .first;
    quantity = row.qty;
    goods = row.goodsNotifier;
  } else {
    final row = tester
        .widget<UtenEditableGrid<SubcontractGridRow>>(
          find.byType(UtenEditableGrid<SubcontractGridRow>),
        )
        .controller
        .rows
        .first;
    quantity = row.qty;
    goods = row.goodsNotifier;
  }
  final field = find.byWidgetPredicate(
    (widget) => widget is TextField && identical(widget.controller, quantity),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, '7.125');
  for (var attempt = 0; attempt < 3; attempt++) {
    await _tap(
      tester,
      find.byWidgetPredicate(
        (widget) =>
            widget is RequiredCellFrame && identical(widget.listenable, goods),
      ),
    );
    await _wait(
      tester,
      () => find.byType(UtenPickerConfirmBar).evaluate().isNotEmpty,
      'actual-goods-picker',
    );
    await _settled(tester);
    if (attempt == 0) {
      await _screen(
        tester,
        '${purchase ? 'purchase' : 'subcontract'}-goods-picker',
      );
    }
    await _tap(
      tester,
      find.descendant(
        of: find.byType(UtenPickerConfirmBar),
        matching: find.text('取消'),
      ),
    );
    await _wait(
      tester,
      () => find.byType(UtenPickerConfirmBar).evaluate().isEmpty,
      'picker-cancel',
    );
    expect(quantity.text, '7.125');
  }
  await _screen(
    tester,
    '${purchase ? 'purchase' : 'subcontract'}-retained-quantity',
  );
  router.go('/');
  bool editorPresent() => purchase
      ? find.byType(UtenEditableGrid<PurchaseGridRow>).evaluate().isNotEmpty
      : find.byType(UtenEditableGrid<SubcontractGridRow>).evaluate().isNotEmpty;
  await _wait(
    tester,
    () => find.text('不保存').evaluate().isNotEmpty || !editorPresent(),
    'synthetic-draft-exit',
  );
  if (find.text('不保存').evaluate().isNotEmpty) {
    await _tap(tester, find.text('不保存'));
  }
  await _wait(tester, () => !editorPresent(), 'synthetic-editor-left');
  await _settled(tester);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual Windows bootstrap, native narrow tooltip/menu, read sort print cancellation',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      expect(
        foundation.defaultTargetPlatform,
        foundation.TargetPlatform.windows,
      );
      expect(foundation.kDebugMode, isTrue);
      expect(_runtimeRoot, isNotEmpty);
      expect(_configPath, isNotEmpty);
      expect(_evidenceRoot, isNotEmpty);
      expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(_sourceHead), isTrue);
      expect(
        _windowScenario,
        isIn(['original-714', 'supported-min800', 'below-min714']),
      );
      _observations.clear();
      _nativeWindowSequence = 0;
      final runtime = Directory(_runtimeRoot).absolute;
      expect(runtime.isAbsolute, isTrue);
      expect(
        Directory('${runtime.path}/UTEN Local Test').existsSync(),
        isFalse,
        reason:
            'Every cold run owns a fresh support root; old credentials/drafts are preserved',
      );
      final config =
          jsonDecode(await File(_configPath).readAsString())
              as Map<String, dynamic>;
      final password = config['syntheticAccountPassword'] as String;
      ProviderContainer? container;
      var passed = false;
      Object? primaryError;
      StackTrace? primaryStack;
      var completedMouldReads = 0, exportCreates = 0;
      var networkProved = false;
      void rememberError(Object error, StackTrace stack, String phase) {
        primaryError ??= error;
        primaryStack ??= stack;
        _observations.add({
          'scene': '$phase-error',
          'exceptionType': error.runtimeType.toString(),
        });
      }

      void publishFailureSync(String phase, {FlutterErrorDetails? framework}) {
        try {
          File('$_evidenceRoot/result.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'surface': 'windows-engine-real-http-attempt',
              'sourceHead': _sourceHead,
              'declaredBackendSourceHead': _backendSourceHead.isEmpty
                  ? null
                  : _backendSourceHead,
              'backendIdentityVerifiedByThisHarness': false,
              'windowScenario': _windowScenario,
              'belowMinimumIsNotFormalSupport':
                  _windowScenario == 'below-min714',
              'passed': false,
              'publicationPhase': phase,
              'cleanupComplete': false,
              'networkObservationComplete': false,
              'primaryFailureType':
                  primaryError?.runtimeType.toString() ??
                  framework?.exception.runtimeType.toString(),
              'firstFlutterErrorCaptured': _flutterFailure?.first != null,
              'businessApiReplaced': false,
              'repositoryReplaced': false,
              'sessionReplaced': false,
              'scenes': List<Map<String, Object?>>.of(_observations),
            }),
            flush: true,
          );
        } catch (error) {
          _observations.add({
            'scene': 'emergency-result-publication-error',
            'exceptionType': error.runtimeType.toString(),
          });
        }
      }

      final flutterFailure = _flutterFailure = FirstFlutterFailureCapture(
        Directory(_evidenceRoot),
        sourceHead: _sourceHead,
        onFirstCaptured: (details) => publishFailureSync(
          'first-framework-synchronous-before-cleanup',
          framework: details,
        ),
      );
      flutterFailure.install();
      var cleanupComplete = false;
      var networkObservationComplete = false;

      try {
        await prepareAcceptanceRuntime(rootPath: runtime.path);
        await application.bootstrapUtenApp(
          bindingFactory: () => binding,
          applicationWrapperForTesting: (child) {
            // Diagnostics may have added its handler during bootstrap. Chain it.
            flutterFailure.install();
            return RepaintBoundary(key: _capture, child: child);
          },
        );
        flutterFailure.install();
        await _wait(
          tester,
          () => find.byType(UtenApp).evaluate().isNotEmpty,
          'production-bootstrap',
        );
        final support = await getApplicationSupportDirectory();
        String canonical(String value) => Directory(
          value,
        ).resolveSymbolicLinksSync().replaceAll('\\', '/').toLowerCase();
        final owner = '${canonical(runtime.path)}/';
        expect(canonical(support.path), startsWith(owner));
        final logDirectory = AppDiagnostics.log?.store.directory;
        expect(logDirectory, isNotNull);
        expect(canonical(logDirectory!), startsWith(owner));
        final pathReceipt =
            jsonDecode(
                  await File(
                    '${support.path}/localtest-runtime-receipt.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        for (final key in [
          'applicationSupport',
          'applicationCache',
          'temporaryCache',
          'exportDirectory',
          'nativeLogs',
          'preferencesAndSecureStoreRoot',
        ]) {
          expect(
            canonical(pathReceipt[key] as String),
            startsWith(owner),
            reason: 'Actual runtime path: $key',
          );
        }
        container = ProviderScope.containerOf(
          tester.element(find.byType(UtenApp)),
          listen: false,
        );
        await _login(container, tester, _account, password);
        final encryptedStore = File(
          '${support.path}/flutter_secure_storage.dat',
        );
        await _wait(tester, encryptedStore.existsSync, 'private-dpapi-store');
        _observations.add({
          'scene': 'real-private-storage',
          'supportInPrivateRoot': true,
          'nativeLogsInPrivateRoot': true,
          'dpapiFileExists': true,
          'credentialContentsInspected': false,
        });
        final router = container.read(appRouterProvider);
        router.go('/basicinfo/mould');
        await _wait(
          tester,
          () =>
              find.text('全部模具').evaluate().isNotEmpty ||
              _mouldFinder.evaluate().isNotEmpty,
          'mould-entry',
        );
        final cold = Stopwatch()..start();
        if (find.text('全部模具').evaluate().isNotEmpty) {
          await _tap(tester, find.text('全部模具'));
        }
        await _wait(
          tester,
          () =>
              _mouldFinder.evaluate().length == 1 &&
              _mould(tester).items.length == 1626 &&
              !_mould(tester).isLoading &&
              !_mould(tester).loadingMore,
          'complete-mould-read',
        );
        expect(
          tester
              .widget<UtenExportButton>(find.byType(UtenExportButton).first)
              .enabled,
          isTrue,
        );
        _observations.add({
          'scene': 'complete-mould-read',
          'rows': 1626,
          'coldReadMs': cold.elapsedMilliseconds,
        });
        await _screen(tester, 'mould-complete');
        await _wideNarrowMouldMenu(tester);
        await _tap(tester, find.text('套数'));
        await _wait(
          tester,
          () => find.text('从小到大').evaluate().isNotEmpty,
          'sort-menu',
        );
        await _tap(tester, find.text('从小到大'));
        await _wait(
          tester,
          () =>
              _mouldFinder.evaluate().length == 1 &&
              _mould(tester).items.length == 1626 &&
              !_mould(tester).loadingMore &&
              _mould(tester).sortColumn == 'tqty' &&
              _mould(tester).sortAscending &&
              _mould(tester).items.first.code == 'AU-01626',
          'server-sorted-moulds',
        );
        expect(_mould(tester).items.first.tqty, 1.125);
        expect(
          _mould(tester).items.map((row) => row.id).toSet(),
          hasLength(1626),
        );
        expect(_mould(tester).items.map((row) => row.code).toList(), [
          for (var number = 1626; number >= 1; number--)
            'AU-${number.toString().padLeft(5, '0')}',
        ]);
        await _screen(tester, 'mould-tqty-ascending');
        await _tap(tester, find.text('预览打印'));
        await _wait(
          tester,
          () => find
              .byKey(const ValueKey('table-output-all'))
              .evaluate()
              .isNotEmpty,
          'print-scope',
        );
        await _tap(tester, find.byKey(const ValueKey('table-output-all')));
        await _wait(
          tester,
          () => find.textContaining('共 1626 行').evaluate().isNotEmpty,
          'complete-paper-preview',
        );
        final preview = find
            .ancestor(
              of: find.text('预览 · 模具资料'),
              matching: find.byType(UtenDialogFrame),
            )
            .first;
        expect(
          find.descendant(of: preview, matching: find.text('AU-01626')),
          findsWidgets,
        );
        await _screen(tester, 'mould-complete-sorted-print');
        await _tap(tester, find.text('下载Excel'));
        await _wait(
          tester,
          () => find
              .byKey(const Key('uten-export-filename'))
              .evaluate()
              .isNotEmpty,
          'nested-export-dialog',
        );
        await _screen(tester, 'mould-nested-export-cancel');
        await _tap(tester, find.text('取消'));
        await _wait(
          tester,
          () =>
              find.byKey(const Key('uten-export-filename')).evaluate().isEmpty,
          'nested-export-cancelled',
        );
        await _tap(
          tester,
          find.descendant(of: preview, matching: find.byType(UtenCloseButton)),
        );
        await _wait(
          tester,
          () => find.text('预览 · 模具资料').evaluate().isEmpty,
          'preview-closed',
        );
        await _tap(tester, find.text('导出模具'));
        await _wait(
          tester,
          () => find
              .byKey(const Key('uten-export-filename'))
              .evaluate()
              .isNotEmpty,
          'direct-export-dialog',
        );
        await _screen(tester, 'mould-direct-export-cancel');
        await _tap(tester, find.text('取消'));
        await _wait(
          tester,
          () =>
              find.byKey(const Key('uten-export-filename')).evaluate().isEmpty,
          'direct-export-cancelled',
        );
        expect(_mould(tester).items.length, 1626);
        expect(_mould(tester).items.first.code, 'AU-01626');
        _observations.add({
          'scene': 'mould-read-sort-print-cancel',
          'status': 'passed',
          'rows': 1626,
        });
        if (_returnsAccount.isNotEmpty) {
          await container.read(sessionProvider.notifier).logout();
          await _login(container, tester, _returnsAccount, password);
          await _returnPicker(tester, container, true);
          await _returnPicker(tester, container, false);
          _observations.add({
            'scene': 'two-return-pickers',
            'status': 'passed',
            'openCancelPerType': 3,
            'retainedQuantity': '7.125',
          });
        }
        passed = true;
      } catch (error, stack) {
        rememberError(error, stack, 'scenario');
      } finally {
        if (primaryError != null || flutterFailure.first != null) {
          publishFailureSync(
            'scenario-before-cleanup',
            framework: flutterFailure.first,
          );
        }
        if (flutterFailure.first case final first?) {
          rememberError(
            first.exception,
            first.stack ?? StackTrace.current,
            'first-framework',
          );
        }
        try {
          await _resizeNativeWindow(
            tester,
            const Size(1280, 900),
            'cleanup-native-wide',
            cleanup: true,
          );
          cleanupComplete = true;
        } catch (error, stack) {
          rememberError(error, stack, 'native-window-cleanup');
        }
        try {
          if (container?.read(sessionProvider).isLoggedIn == true) {
            await container!.read(sessionProvider.notifier).logout();
          }
        } catch (error, stack) {
          rememberError(error, stack, 'logout');
        }
        try {
          final bytes = await AppDiagnostics.log?.export();
          if (bytes != null) {
            await File(
              '$_evidenceRoot/actual-http-and-client.log',
            ).writeAsBytes(bytes, flush: true);
            // The production bundle joins complete JSON log files with blank
            // separator lines. Preserve all raw bytes, parse nonempty records.
            for (final line in const LineSplitter().convert(
              utf8.decode(bytes),
            )) {
              if (line.trim().isEmpty) continue;
              final record = jsonDecode(line) as Map<String, dynamic>;
              final path = record['path'] as String? ?? '';
              if (record['event'] == 'request.end' &&
                  record['status'] == 200 &&
                  path.endsWith('/master/moulds/summaries')) {
                completedMouldReads++;
              }
              if (record['event'] == 'request.begin' &&
                  record['method'] == 'POST' &&
                  path.endsWith('/report-export-jobs')) {
                exportCreates++;
              }
            }
            networkObservationComplete = true;
          }
        } catch (error, stack) {
          rememberError(error, stack, 'evidence');
        }
        if (flutterFailure.first case final first?) {
          rememberError(
            first.exception,
            first.stack ?? StackTrace.current,
            'first-framework',
          );
        }
        networkProved = completedMouldReads >= 2 && exportCreates == 0;
        _observations.add({
          'scene': 'actual-http-observation',
          'completedMouldReads': completedMouldReads,
          'exportJobsCreatedAfterCancellation': exportCreates,
        });
        try {
          File('$_evidenceRoot/result.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'surface': networkProved
                  ? 'windows-engine-real-http'
                  : 'windows-engine-real-http-attempt',
              'nativeOS': Platform.operatingSystem,
              'publicationPhase': 'final-cleanup-observed',
              'cleanupComplete': cleanupComplete,
              'networkObservationComplete': networkObservationComplete,
              'sourceHead': _sourceHead,
              'declaredBackendSourceHead': _backendSourceHead.isEmpty
                  ? null
                  : _backendSourceHead,
              'backendIdentityVerifiedByThisHarness': false,
              'windowScenario': _windowScenario,
              'belowMinimumIsNotFormalSupport':
                  _windowScenario == 'below-min714',
              'frameworkTarget': foundation.defaultTargetPlatform.name,
              'debugEngine': foundation.kDebugMode,
              'passed':
                  passed &&
                  networkProved &&
                  primaryError == null &&
                  flutterFailure.first == null,
              'primaryFailureType': primaryError?.runtimeType.toString(),
              'businessApiReplaced': false,
              'repositoryReplaced': false,
              'sessionReplaced': false,
              'runtimeRoot': runtime.path,
              'scenes': _observations,
              'returnsRequested': _returnsAccount.isNotEmpty,
              'firstFlutterErrorCaptured': flutterFailure.first != null,
              'flutterErrorNotificationCount': flutterFailure.count,
              'firstFlutterErrorPersistenceFailureType': flutterFailure
                  .persistenceError
                  ?.runtimeType
                  .toString(),
              'firstFlutterErrorPublicationFailureType': flutterFailure
                  .publicationError
                  ?.runtimeType
                  .toString(),
            }),
            flush: true,
          );
        } catch (error, stack) {
          rememberError(error, stack, 'result-publication');
        }
        flutterFailure.restore();
        if (flutterFailure.first case final first?) {
          rememberError(
            first.exception,
            first.stack ?? StackTrace.current,
            'first-framework',
          );
        }
      }
      final failure = primaryError;
      if (failure != null) Error.throwWithStackTrace(failure, primaryStack!);
      expect(
        completedMouldReads,
        greaterThanOrEqualTo(2),
        reason: 'Cold read and sort must reach the actual HTTP service',
      );
      expect(
        exportCreates,
        0,
        reason: 'Cancelling either export dialog must not create a job',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
