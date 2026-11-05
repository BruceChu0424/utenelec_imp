// Runs the production bootstrap, router, providers, repositories and actual HTTP
// against the disposable Spring/PostgreSQL harness. No business API is mocked.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uten_imp/app.dart';
import 'package:uten_imp/main.dart' as application;
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/config/finance_report_config.dart';
import 'package:uten_imp/features/finance/config/finance_requirement_names.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_procurement_confirmation_dialog.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/app_visibility_provider.dart'
    show isVisibleLifecycle;
import '../tool/finance_acceptance_platform.dart';

final _capture = GlobalKey();
final _evidence = <Map<String, Object?>>[];
const _control = 'http://127.0.0.1:18090/__acceptance__';
const _run = String.fromEnvironment(
  'UTEN_ACCEPTANCE_RUN',
  defaultValue: 'actual-v2',
);
const _phase = String.fromEnvironment(
  'UTEN_ACCEPTANCE_PHASE',
  defaultValue: 'all',
);
const _policyReference = '隔离实际客户端异常恢复核对，保持原路线和日期';

// Read-only native lifecycle evidence. No lifecycle/focus test setters or OS
// activation calls are made here; the orchestrator activates only its owned app.
late _ActualWindowObservation _windowObservation;

class _ActualWindowObservation with WidgetsBindingObserver {
  _ActualWindowObservation(this.binding) {
    binding.addObserver(this);
  }
  final WidgetsBinding binding;
  final clock = Stopwatch()..start();
  final focusByView = <int, bool>{};
  int focusEvents = 0, lifecycleEvents = 0;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycleEvents++;
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    focusEvents++;
    focusByView[event.viewId] = event.state == ui.ViewFocusState.focused;
  }

  int viewId(WidgetTester tester, BuildContext? owner) {
    if (owner != null && owner.mounted) {
      try {
        return View.of(owner).viewId;
      } catch (_) {
        /* A deactivated owner is evidence, never an excuse to bypass its route. */
      }
    }
    return tester.view.viewId;
  }

  bool ready(WidgetTester tester, BuildContext? owner) {
    // Match the owning UtenOverlayLifecycle: the native integration binding
    // may not publish lifecycle telemetry. Keep that explicitly unknown rather
    // than inventing resumed, and still reject every observed blur/inactive.
    return (binding.lifecycleState == null ||
            binding.lifecycleState == AppLifecycleState.resumed) &&
        focusByView[viewId(tester, owner)] != false;
  }

  Map<String, Object?> snapshot(WidgetTester tester, {BuildContext? owner}) {
    final lifecycle = binding.lifecycleState;
    final view = viewId(tester, owner);
    final routes = <Map<String, Object?>>[];
    bool? ticker;
    bool contextReadable = owner?.mounted ?? false;
    if (contextReadable) {
      try {
        ticker = TickerMode.getValuesNotifier(owner!).value.enabled;
        var route = ModalRoute.of(owner);
        final visited = <ModalRoute<dynamic>>{};
        while (route != null && visited.add(route)) {
          routes.add({
            'type': route.runtimeType.toString(),
            'current': route.isCurrent,
            'active': route.isActive,
          });
          final navigator = route.navigator;
          if (navigator == null || !navigator.mounted) break;
          route = ModalRoute.of(navigator.context);
        }
      } catch (_) {
        contextReadable = false;
      }
    }
    return {
      'elapsedMs': clock.elapsedMilliseconds,
      'lifecycle': lifecycle?.name ?? 'not-observed',
      'pollingVisibleByLifecycle': isVisibleLifecycle(lifecycle),
      'viewId': view,
      'viewFocusObserved': focusByView.containsKey(view),
      'lastObservedViewFocused': focusByView[view],
      'focusEvents': focusEvents,
      'lifecycleEvents': lifecycleEvents,
      'ownerMounted': owner?.mounted ?? false,
      'ownerContextReadable': contextReadable,
      'tickerEnabled': ticker,
      'routeChain': routes,
      'ownerRouteCount': routes.length,
      'allOwnerRoutesCurrent': routes.every(
        (route) => route['current'] == true,
      ),
      'hasScheduledFrame': binding.hasScheduledFrame,
    };
  }

  void dispose() => binding.removeObserver(this);
}

void _recordWindow(
  WidgetTester tester,
  String phase, {
  BuildContext? owner,
  String? menuLabel,
}) {
  // Only framework state and fixed UI-action labels are recorded: no account,
  // credential, document body, field value, route arguments or provider data.
  final state = {
    'scene': 'actual-window-observation',
    'phase': phase,
    'menu': ?menuLabel,
    ..._windowObservation.snapshot(tester, owner: owner),
  };
  _evidence.add(state);
  debugPrint('OWNED_WINDOW_OBSERVATION ${jsonEncode(state)}');
}

Future<void> _ownedForeground(
  WidgetTester tester,
  String phase, {
  BuildContext? owner,
}) async {
  if (_windowObservation.ready(tester, owner)) return;
  final state = _windowObservation.snapshot(tester, owner: owner);
  debugPrint(
    'AWAITING_OWNED_WINDOW_FOREGROUND ${jsonEncode({'phase': phase, ...state})}',
  );
  _evidence.add({
    'scene': 'awaiting-owned-window-foreground',
    'phase': phase,
    ...state,
  });
  await _wait(
    tester,
    () => _windowObservation.ready(tester, owner),
    'owned window foreground ($phase)',
    timeout: const Duration(minutes: 15),
    diagnosticOwner: owner,
  );
  _recordWindow(
    tester,
    'foreground-observed-$phase',
    owner: owner != null && owner.mounted ? owner : null,
  );
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready,
  String name, {
  Duration timeout = const Duration(seconds: 90),
  Duration stableFor = Duration.zero,
  BuildContext? diagnosticOwner,
}) async {
  final timer = Stopwatch()..start();
  Duration? quietSince;
  while (true) {
    final resourceTitle = find.textContaining(
      RegExp('处理器占用|系统内存占用'),
      findRichText: true,
      skipOffstage: false,
    );
    final acknowledge = find
        .text('已知悉', findRichText: true, skipOffstage: false)
        .hitTestable();
    if (resourceTitle.evaluate().isNotEmpty &&
        acknowledge.evaluate().isNotEmpty) {
      await tester.tap(acknowledge.last);
      await tester.pump(const Duration(milliseconds: 150));
      _evidence.add({
        'scene': 'test-host-resource-warning',
        'status': 'observed-and-acknowledged',
      });
      quietSince = null;
      continue;
    }
    if (ready()) {
      quietSince ??= timer.elapsed;
      if (timer.elapsed - quietSince >= stableFor) break;
    } else {
      quietSince = null;
    }
    if (timer.elapsed > timeout) {
      _recordWindow(
        tester,
        'wait-timeout',
        owner: diagnosticOwner != null && diagnosticOwner.mounted
            ? diagnosticOwner
            : null,
      );
      await _rawScreen(tester, 'failure-${name.hashCode.toUnsigned(32)}');
      fail('Actual application timed out: $name');
    }
    await tester.pump(const Duration(milliseconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull, reason: name);
}

Future<void> _settled(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await _wait(
    tester,
    () =>
        find.byType(UtenBusyOverlay).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.text('正在查询报表').evaluate().isEmpty,
    'request/busy completion',
    stableFor: const Duration(milliseconds: 650),
  );
}

Future<void> _tapText(WidgetTester tester, String label) async {
  await _settled(tester);
  await _ownedForeground(tester, 'before-control-tap');
  var target = find.text(label, findRichText: true).hitTestable();
  if (target.evaluate().isEmpty) {
    for (final menuLabel in ['原请求操作', '财务操作', '表格操作']) {
      var menu = find.byTooltip(menuLabel).hitTestable();
      if (menu.evaluate().isEmpty) menu = find.text(menuLabel).hitTestable();
      if (menu.evaluate().isNotEmpty) {
        final owner = menu.last.evaluate().last;
        await _ownedForeground(tester, 'before-project-menu', owner: owner);
        _recordWindow(
          tester,
          'before-project-menu',
          owner: owner,
          menuLabel: menuLabel,
        );
        await tester.tap(menu.last);
        await tester.pump();
        _recordWindow(
          tester,
          'after-project-menu-tap',
          owner: owner,
          menuLabel: menuLabel,
        );
        await _wait(
          tester,
          () => find
              .text(label, findRichText: true)
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'project menu action $label',
          timeout: const Duration(seconds: 8),
          diagnosticOwner: owner,
        );
        target = find.text(label, findRichText: true).hitTestable();
        if (target.evaluate().isNotEmpty) break;
      }
    }
  }
  if (target.evaluate().isEmpty) {
    target = find.text(label, findRichText: true);
    if (target.evaluate().isEmpty) {
      _recordWindow(tester, 'missing-control');
      await _rawScreen(
        tester,
        'failure-control-${label.hashCode.toUnsigned(32)}',
      );
    }
    expect(target, findsWidgets, reason: 'Actual control: $label');
    await tester.ensureVisible(target.last);
    await tester.pump(const Duration(milliseconds: 100));
    target = find.text(label).hitTestable();
  }
  if (target.evaluate().isEmpty) {
    _recordWindow(tester, 'unreachable-control');
    await _rawScreen(
      tester,
      'failure-unreachable-${label.hashCode.toUnsigned(32)}',
    );
  }
  expect(target, findsWidgets, reason: 'Reachable actual control: $label');
  await _ownedForeground(
    tester,
    'before-reachable-control',
    owner: target.last.evaluate().last,
  );
  await tester.tap(target.last);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _input(WidgetTester tester, String label, String value) async {
  final field = find.descendant(
    of: find.widgetWithText(UtenInput, label),
    matching: find.byType(TextField),
  );
  expect(field, findsOneWidget);
  await _ownedForeground(
    tester,
    'before-input',
    owner: field.evaluate().single,
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _openDraft(WidgetTester tester, String title) async {
  final row = find.text(title).hitTestable();
  expect(row, findsWidgets);
  await _ownedForeground(
    tester,
    'before-open-draft',
    owner: row.last.evaluate().last,
  );
  // The actual desktop table selects on one click and opens on double-click.
  await tester.tap(row.last);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(row.last);
  await _settled(tester);
}

Future<void> _artifact(String name, List<int> bytes) async {
  await Dio().post<void>(
    '$_control/artifact',
    data: Stream.value(bytes),
    options: Options(
      headers: {'X-Acceptance-Name': name, 'Content-Length': bytes.length},
      contentType: name.endsWith('.png') ? 'image/png' : 'application/json',
    ),
  );
}

Future<void> _chooseReport(
  WidgetTester tester,
  FinanceReportCard card,
  int index,
) async {
  await _settled(tester);
  final toolbar = find.byType(UtenFilterToolbar<int>);
  await _ownedForeground(
    tester,
    'before-report-selection',
    owner: toolbar.evaluate().single,
  );
  final current = tester
      .widget<UtenFilterToolbar<int>>(toolbar)
      .selected
      .single;
  if (current == index) return;
  final label = card.variants[index].label;
  final direct = find
      .descendant(of: toolbar, matching: find.text(label))
      .hitTestable();
  if (direct.evaluate().isNotEmpty) {
    await tester.tap(direct.last);
  } else {
    final opener = find
        .descendant(
          of: toolbar,
          matching: find.text(card.variants[current].label),
        )
        .hitTestable();
    expect(opener, findsWidgets);
    await tester.tap(opener.last);
    await _wait(
      tester,
      () => find.text(label).hitTestable().evaluate().isNotEmpty,
      'project report-selection panel',
    );
    await _tapText(tester, label);
  }
  await _settled(tester);
  expect(
    tester.widget<UtenFilterToolbar<int>>(toolbar).selected,
    {index},
    reason: 'Actual selected report $label',
  );
}

Future<void> _screen(WidgetTester tester, String scene) async {
  await _settled(tester);
  final captured = await _rawScreen(tester, scene);
  expect(captured, isTrue, reason: 'Actual rendered capture: $scene');
  expect(tester.takeException(), isNull, reason: scene);
}

Future<bool> _rawScreen(WidgetTester tester, String scene) async {
  // Flush an actual pending frame without waiting for busy/foreground again.
  // Failure capture must not recurse into the wait that is currently failing.
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await tester.pump();
  final state = _windowObservation.snapshot(
    tester,
    owner: _capture.currentContext,
  );
  ui.Image? image;
  try {
    final context = _capture.currentContext;
    if (context == null || !context.mounted) {
      throw StateError('Capture owner is not mounted');
    }
    final object = context.findRenderObject();
    if (object is! RenderRepaintBoundary ||
        !object.attached ||
        object.debugNeedsPaint) {
      throw StateError('Capture boundary has not painted an actual frame');
    }
    image = await object.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Capture returned no PNG bytes');
    const surface = kIsWeb ? 'web' : 'windows';
    await _artifact('$surface-$_run-$scene.png', bytes.buffer.asUint8List());
    _evidence.add({
      'scene': scene,
      'surface': surface,
      'width': image.width,
      'height': image.height,
      'status': scene.startsWith('failure-') ? 'observed-failure' : 'rendered',
      'window': state,
    });
    return true;
  } catch (error) {
    _evidence.add({
      'scene': scene,
      'status': 'capture-unavailable',
      'errorType': error.runtimeType.toString(),
      'window': state,
    });
    debugPrint(
      'OWNED_WINDOW_CAPTURE_UNAVAILABLE ${jsonEncode({'scene': scene, 'errorType': error.runtimeType.toString(), 'window': state})}',
    );
    return false;
  } finally {
    image?.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  _windowObservation = _ActualWindowObservation(binding);
  tearDownAll(_windowObservation.dispose);
  testWidgets(
    'actual financial application routes, long directory and committed-reply recovery',
    (tester) async {
      await prepareAcceptanceRuntime();
      await application.bootstrapUtenApp(
        bindingFactory: () => binding,
        applicationWrapperForTesting: (child) =>
            RepaintBoundary(key: _capture, child: child),
      );
      await _wait(
        tester,
        () => find.byType(UtenApp).evaluate().isNotEmpty,
        'production bootstrap',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(UtenApp)),
        listen: false,
      );
      final router = container.read(appRouterProvider);
      const surface = kIsWeb ? 'web' : 'windows';
      // Synthetic fixture login uses the ordinary authenticated session lifecycle.
      // No password/OS authentication dialog is automated or security guard bypassed.
      await container
          .read(sessionProvider.notifier)
          .login(
            account: 'SU-finance-ui-$surface',
            password: 'FinanceUiSynthetic-2026!',
          );
      await _wait(
        tester,
        () => container.read(sessionProvider).isLoggedIn,
        'real loopback login',
      );
      try {
        if (_phase == 'recover-first-payable') {
          router.go('/finance');
          await _settled(tester);
          await _tapText(tester, '草稿');
          await _settled(tester);
          await _openDraft(tester, '首次应付设置');
          await _wait(
            tester,
            () => find
                .byKey(const Key('finance-durable-command'))
                .evaluate()
                .isNotEmpty,
            'first-payable original after native process restart',
          );
          await _screen(tester, 'first-payable-after-process-restart');
          await _tapText(tester, '核对原操作结果');
          await _settled(tester);
          expect(
            find.byKey(const Key('finance-durable-command')),
            findsNothing,
          );
          final policy = await container
              .read(apiClientProvider)
              .get('/finance/procurement-payable-recognitions/policy');
          expect(policy['sourceReference'], _policyReference);
          _evidence.add({
            'scene': 'first-payable-after-process-restart',
            'status': 'passed',
            'revision': policy['revision'],
          });
          return;
        }
        if (_phase != 'stage-first-payable') {
          router.go('/finance/report/gl');
          await _settled(tester);
          await _chooseReport(tester, financeGlCard, 0);
          router.go('/finance');
          await _settled(tester);
          final priorDelay =
              (await Dio().get<Map<String, dynamic>>(
                    '$_control/state',
                  )).data!['delayedReadReplies']
                  as int;
          await Dio().post<void>(
            '$_control/delay',
            data: {
              'path': '/api/finance/reports/gl/trial-balance',
              'milliseconds': 1800,
            },
          );
          router.go('/finance/report/gl');
          final delayed = Stopwatch()..start();
          while (true) {
            await tester.pump(const Duration(milliseconds: 80));
            final state = (await Dio().get<Map<String, dynamic>>(
              '$_control/state',
            )).data!;
            if ((state['delayedReadReplies'] as int) > priorDelay) break;
            if (delayed.elapsed > const Duration(seconds: 30)) {
              fail('Actual delayed read never started');
            }
          }
          router.go('/finance');
          await _settled(tester);
          await Future<void>.delayed(const Duration(milliseconds: 2000));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(FinanceHubPage), findsOneWidget);
          expect(find.text('本年累计金额'), findsNothing);
          await _screen(tester, 'late-read-keeps-current-page');
          for (final route in <String>[
            '/finance',
            '/finance/applications',
            '/applications',
            '/finance/audits',
            '/finance/sales-shipment-audits',
            '/finance/assets',
            '/finance/ar-ap',
            '/finance/payables',
            '/finance/report/statement',
            '/finance/report/account-flow',
            for (final type in FinanceDocType.values)
              RoutePath.financeDocNew(type.pathSegment),
          ]) {
            router.go(route);
            await _settled(tester);
            await _screen(
              tester,
              'route-${route.replaceAll('/', '-').replaceAll(RegExp(r'^-'), '')}',
            );
          }
          for (final card in [
            financeSummaryCard,
            financeReconCard,
            financeCostCard,
            financeGlCard,
          ]) {
            router.go('/finance/report/${card.id}');
            await _settled(tester);
            for (var index = 0; index < card.variants.length; index++) {
              await _chooseReport(tester, card, index);
              await _screen(tester, '${card.id}-$index');
            }
          }
          router.go('/finance/report/gl');
          await _settled(tester);
          await _chooseReport(tester, financeGlCard, 0);
          await _settled(tester);
          await _tapText(tester, FinanceRequirementNames.chartCodes);
          await _settled(tester);
          final search = find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.hintText == '搜索科目编码或名称',
          );
          expect(search, findsOneWidget);
          for (final query in ['匿名压力科目1', '匿名压力科目100', '匿名压力科目10003']) {
            await tester.enterText(search, query);
            await tester.pump(const Duration(milliseconds: 350));
          }
          await _wait(
            tester,
            () => find.text('匿名压力科目10003').evaluate().isNotEmpty,
            'complete tail of 10003 directory',
          );
          await _screen(tester, 'directory-tail-10003');
          await _tapText(tester, '修改名称');
          await _settled(tester);
          await _input(tester, '科目名称', '匿名压力科目10003-完整界面复核');
          await _input(tester, '修改依据', '隔离实际客户端核对，保原代码和业务金额');
          await Dio().post<void>(
            '$_control/fault',
            data: {
              'method': 'PUT',
              'path': '/api/finance/chart/90010003/metadata',
            },
          );
          await _tapText(tester, '保存名称');
          await _settled(tester);
          await _wait(
            tester,
            () =>
                find.text('核对原修改结果').evaluate().isNotEmpty ||
                find.text('原请求操作').evaluate().isNotEmpty,
            'committed write with lost response',
          );
          await _screen(tester, 'metadata-lost-reply');
          await _tapText(tester, '核对原修改结果');
          await _settled(tester);
          await _tapText(tester, '关闭');
          await _settled(tester);
        }
        router.go('/finance');
        await _settled(tester);
        unawaited(
          showFinanceProcurementPolicyDialog(
            tester.element(find.byType(FinanceHubPage)),
          ),
        );
        await _wait(
          tester,
          () => find
              .byKey(const Key('finance-durable-command'))
              .evaluate()
              .isNotEmpty,
          'real first-payable policy launcher',
        );
        await _settled(tester);
        await _screen(tester, 'first-payable-policy');
        final api = container.read(apiClientProvider);
        final beforePolicy = await api.get(
          '/finance/procurement-payable-recognitions/policy',
        );
        await _input(tester, '启用或变更依据', _policyReference);
        await Dio().post<void>(
          '$_control/fault',
          data: {
            'method': 'PUT',
            'path': '/api/finance/procurement-payable-recognitions/policy',
          },
        );
        final save = find.byKey(const ValueKey('finance-command-save'));
        final savePosition = tester.getCenter(save);
        await tester.tap(save);
        await tester.tapAt(savePosition);
        await _settled(tester);
        await _wait(
          tester,
          () => find.text('稍后核对').evaluate().isNotEmpty,
          'original first-payable write result',
        );
        await _screen(tester, 'first-payable-lost-reply');
        if (_phase == 'stage-first-payable') {
          await _artifact(
            '$surface-$_run-interruption-checkpoint.json',
            utf8.encode(
              jsonEncode({
                'localOnly': true,
                'syntheticData': true,
                'expectedRevision': (beforePolicy['revision'] as int) + 1,
                'phase': 'committed-reply-lost-original-draft-checkpointed',
                'awaitingDeliberateProcessInterruption': true,
              }),
            ),
          );
          // The orchestrator verifies this exact owned executable and then
          // deliberately terminates it. This round is recorded as interrupted,
          // never as a green test; the next process must recover through UI.
          while (true) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        await _tapText(tester, '稍后核对');
        await _settled(tester);
        expect(find.byKey(const Key('finance-durable-command')), findsNothing);
        await _tapText(tester, '草稿');
        await _settled(tester);
        await _openDraft(tester, '首次应付设置');
        await _wait(
          tester,
          () => find
              .byKey(const Key('finance-durable-command'))
              .evaluate()
              .isNotEmpty,
          'persisted first-payable draft from actual hub',
        );
        await _screen(tester, 'first-payable-resumed-original');
        await _tapText(tester, '核对原操作结果');
        await _settled(tester);
        expect(find.byKey(const Key('finance-durable-command')), findsNothing);
        final afterPolicy = await api.get(
          '/finance/procurement-payable-recognitions/policy',
        );
        expect(afterPolicy['revision'], (beforePolicy['revision'] as int) + 1);
        expect(afterPolicy['sourceReference'], _policyReference);
        expect(afterPolicy['enabled'], beforePolicy['enabled']);
        expect(afterPolicy['effectiveFrom'], beforePolicy['effectiveFrom']);
        _evidence.add({
          'scene': 'first-payable-committed-reply-lost-leave-hub-restore',
          'status': 'passed',
          'revisionDelta': 1,
        });
        final directory = await api.get('/finance/chart');
        expect(
          (directory['items'] as List).length,
          greaterThanOrEqualTo(10003),
        );
        final proxy = (await Dio().get<Map<String, dynamic>>(
          '$_control/state',
        )).data!;
        expect(proxy['droppedCommittedReplies'], greaterThanOrEqualTo(2));
        _evidence.add({
          'scene': 'complete-directory-and-network-fault',
          'directoryRows': (directory['items'] as List).length,
          'committedRepliesDropped': proxy['droppedCommittedReplies'],
          'status': 'passed',
        });
      } finally {
        await _artifact(
          '$surface-$_run-evidence.json',
          utf8.encode(jsonEncode(_evidence)),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
