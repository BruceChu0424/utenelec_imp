// Production Windows engine + production bootstrap/providers + real HTTP.
// Only filesystem roots are isolated. No business API, repository or session is replaced.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

const _account = String.fromEnvironment(
  'UTEN_FEEDBACK_ACCOUNT',
  defaultValue: 'feedback-mould-qa',
);
const _returnsAccount = String.fromEnvironment('UTEN_FEEDBACK_RETURNS_ACCOUNT');
const _runtimeRoot = String.fromEnvironment('UTEN_FEEDBACK_RUNTIME_ROOT');
const _evidenceRoot = String.fromEnvironment('UTEN_FEEDBACK_EVIDENCE_DIR');
const _configPath = String.fromEnvironment('UTEN_FEEDBACK_PRIVATE_CONFIG');
final _capture = GlobalKey();
final _observations = <Map<String, Object?>>[];

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
  final clock = Stopwatch()..start();
  while (true) {
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
  expect(tester.takeException(), isNull, reason: stage);
}

Future<void> _settled(WidgetTester tester) => _wait(
  tester,
  () => find.byType(UtenBusyOverlay).evaluate().isEmpty,
  'busy-completed',
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _settled(tester);
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 50));
  final reachable = finder.hitTestable();
  expect(reachable, findsWidgets);
  await tester.tap(reachable.last);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _screen(WidgetTester tester, String scene) async {
  await tester.pump();
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
    'actual Windows bootstrap and master read, sort, print, cancellation',
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
      try {
        await prepareAcceptanceRuntime(rootPath: runtime.path);
        await application.bootstrapUtenApp(
          bindingFactory: () => binding,
          applicationWrapperForTesting: (child) =>
              RepaintBoundary(key: _capture, child: child),
        );
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
        final cold = Stopwatch()..start();
        router.go('/basicinfo/mould');
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
      } finally {
        if (container?.read(sessionProvider).isLoggedIn == true) {
          await container!.read(sessionProvider.notifier).logout();
        }
        final bytes = await AppDiagnostics.log?.export();
        var completedMouldReads = 0, exportCreates = 0;
        if (bytes != null) {
          await File(
            '$_evidenceRoot/actual-http-and-client.log',
          ).writeAsBytes(bytes, flush: true);
          for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
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
        }
        final networkProved = completedMouldReads >= 2 && exportCreates == 0;
        _observations.add({
          'scene': 'actual-http-observation',
          'completedMouldReads': completedMouldReads,
          'exportJobsCreatedAfterCancellation': exportCreates,
        });
        await File('$_evidenceRoot/result.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'surface': networkProved
                ? 'windows-engine-real-http'
                : 'windows-engine-real-http-attempt',
            'nativeOS': Platform.operatingSystem,
            'frameworkTarget': foundation.defaultTargetPlatform.name,
            'debugEngine': foundation.kDebugMode,
            'passed': passed && networkProved,
            'businessApiReplaced': false,
            'repositoryReplaced': false,
            'sessionReplaced': false,
            'runtimeRoot': runtime.path,
            'scenes': _observations,
            'returnsRequested': _returnsAccount.isNotEmpty,
          }),
          flush: true,
        );
        if (passed) {
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
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
