import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/platform/desktop_window_modal.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/widgets/desktop_window_host.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

const _strip = Key('desktop-window-modal-barrier');
const _channel = MethodChannel('com.uten.imp/desktop_window');

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('UTEN_MODAL_CAPTURE')) return;
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final fullBleed in [false, true]) {
      testWidgets(
        '${platform.name}: modal mask matches the content at native strip, fullBleed=$fullBleed',
        (tester) async {
          final fixture = await _pump(tester, fullBleed: fullBleed);
          final result = showReauthDialog(
            fixture.root.currentContext!,
            verify: (_) async => 'token',
          );
          await tester.pumpAndSettle();
          final semantics = tester.ensureSemantics();
          await tester.pump();
          expect(find.semantics.byLabel('最小化'), findsNothing);
          semantics.dispose();
          expect(
            tester.getRect(find.byKey(_strip)),
            const Rect.fromLTWH(0, 0, 1000, 36),
          );
          final colors = await _sample(tester, fixture.capture);
          expect(
            colors.$1,
            colors.$2,
            reason: 'No uncovered or double-dimmed strip',
          );
          expect(colors.$1, isNot(Colors.white.toARGB32()));
          fixture.calls.clear();
          await tester.tapAt(
            tester.getCenter(find.byKey(const Key('desktop-window-close'))),
          );
          await tester.pump();
          expect(
            fixture.calls,
            isEmpty,
            reason: 'The modal owns the title strip',
          );
          expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
          await tester.enterText(find.byType(TextField).last, 'password');
          await tester.tap(find.byKey(const Key('reauth-confirm')));
          await tester.pumpAndSettle();
          expect(await result, 'token');
          expect(find.byKey(_strip), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  testWidgets(
    'stacked shell/root barriers fade, dismiss, and disappear under an opaque root page',
    (tester) async {
      final fixture = await _pump(tester, nested: true, zoom: 1.3);
      final shellContext = fixture.shell.currentContext!;
      unawaited(
        showDialog<void>(
          context: shellContext,
          useRootNavigator: false,
          builder: (_) => const AlertDialog(content: Text('shell dialog')),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: shellContext,
          builder: (_) => const AlertDialog(content: Text('root dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.registry.barriers, hasLength(2));
      await tester.tapAt(const Offset(20, 18));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(_strip),
        findsOneWidget,
        reason: 'Reverse transition retains the mask',
      );
      await tester.pumpAndSettle();
      expect(fixture.registry.barriers, hasLength(1));
      unawaited(
        fixture.root.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('opaque root page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_strip), findsNothing);
      fixture.root.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_strip), findsOneWidget);
      await tester.tapAt(const Offset(20, 18));
      await tester.pumpAndSettle();
      expect(find.byKey(_strip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'verification busy mask is visible inside yielded reauth, retries once and retains password',
    (tester) async {
      final fixture = await _pump(tester, busy: true);
      var pending = Completer<String>();
      var calls = 0;
      final result = showReauthDialog(
        fixture.root.currentContext!,
        verify: (_) {
          calls++;
          return pending.future;
        },
      );
      await _frames(tester);
      expect(find.text('outer operation'), findsNothing);
      await tester.enterText(find.byType(TextField).last, 'retained-password');
      await tester.tap(find.byKey(const Key('reauth-confirm')));
      await _frames(tester);
      expect(find.text('正在验证身份'), findsOneWidget);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reauth-confirm'))),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(calls, 1);
      pending.completeError(StateError('retry'));
      await _frames(tester);
      expect(find.text('正在验证身份'), findsNothing);
      expect(find.text('retained-password'), findsOneWidget);
      pending = Completer<String>();
      await tester.tap(find.byKey(const Key('reauth-confirm')));
      await _frames(tester);
      expect(calls, 2);
      pending.complete('token');
      await _frames(tester);
      expect(await result, 'token');
      expect(find.text('outer operation'), findsOneWidget);
      expect(find.byKey(_strip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid modal open-close, resize and zoom preserve the editor and mask lifetime',
    (tester) async {
      final fixture = await _pump(tester);
      await tester.enterText(find.byType(TextField), 'draft stays');
      final editor = tester.state(find.byType(EditableText));
      for (var i = 0; i < 20; i++) {
        unawaited(
          showGeneralDialog<void>(
            context: fixture.root.currentContext!,
            pageBuilder: (_, _, _) =>
                const Center(child: Material(child: Text('dialog'))),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        tester.view.physicalSize = Size(i.isEven ? 1100 : 1000, 800);
        fixture.zoom.value = [.85, 1.0, 1.3, 2.0][i % 4];
        await tester.pump();
        fixture.root.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(_strip), findsNothing);
        expect(tester.state(find.byType(EditableText)), same(editor));
        expect(find.text('draft stays'), findsOneWidget);
      }
      fixture.zoom.value = 1;
      await tester.pumpAndSettle();
      unawaited(
        showReauthDialog(
          fixture.root.currentContext!,
          verify: (_) async => 'token',
        ),
      );
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('UTEN_MODAL_CAPTURE')) {
        await tester.runAsync(() async {
          final boundary =
              fixture.capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final file = File(
            'output/modal-scroll-scope-20261103/reauth-full-window.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      fixture.root.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<(int, int)> _sample(WidgetTester tester, GlobalKey key) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = (await image.toByteData())!.buffer.asUint8List();
    int pixel(int x, int y) {
      final offset = (image.width * y + x) * 4;
      return Color.fromARGB(
        bytes[offset + 3],
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
      ).toARGB32();
    }

    final result = (pixel(10, 18), pixel(10, 60));
    image.dispose();
    return result;
  }))!;
}

class _Fixture {
  final root = GlobalKey<NavigatorState>();
  final shell = GlobalKey<NavigatorState>();
  final capture = GlobalKey();
  final registry = DesktopWindowModalRegistry();
  final zoom = ValueNotifier<double>(1);
  final calls = <String>[];
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  bool fullBleed = false,
  bool nested = false,
  bool busy = false,
  double zoom = 1,
}) async {
  UtenBusyOverlay.debugResetYield();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = _Fixture();
  fixture.zoom.value = zoom;
  final controller = DesktopWindowController(enabled: true);
  final rootObserver = DesktopWindowModalObserver(fixture.registry, layer: 1);
  final shellObserver = DesktopWindowModalObserver(fixture.registry);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, (call) async {
    fixture.calls.add(call.method);
    return call.method == 'getWindowState' ? {'maximized': false} : null;
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    rootObserver.dispose();
    shellObserver.dispose();
    fixture.registry.dispose();
    fixture.zoom.dispose();
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
    UtenBusyOverlay.debugResetYield();
  });
  final page = Scaffold(
    backgroundColor: Colors.white,
    body: Row(
      children: [
        const SizedBox(
          width: 200,
          child: DesktopWindowHeaderSurface(
            decoration: BoxDecoration(color: Colors.white),
            child: SizedBox.expand(),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              const Padding(padding: EdgeInsets.all(80), child: TextField()),
              if (busy) const UtenBusyOverlay(title: 'outer operation'),
            ],
          ),
        ),
      ],
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopWindowControllerProvider.overrideWithValue(controller),
        desktopWindowModalRegistryProvider.overrideWithValue(fixture.registry),
      ],
      child: MaterialApp(
        navigatorKey: fixture.root,
        navigatorObservers: [rootObserver],
        theme: buildLightTheme().copyWith(
          scaffoldBackgroundColor: Colors.white,
        ),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => RepaintBoundary(
          key: fixture.capture,
          child: DesktopWindowHost(
            mode: fullBleed ? DesktopWindowMode.login : DesktopWindowMode.main,
            overlayControls: fullBleed,
            child: ValueListenableBuilder<double>(
              valueListenable: fixture.zoom,
              child: child,
              builder: (context, zoom, child) =>
                  UtenDisplayZoomBox(fontFactor: zoom, child: child!),
            ),
          ),
        ),
        home: nested
            ? Navigator(
                key: fixture.shell,
                observers: [shellObserver],
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => page),
              )
            : page,
      ),
    ),
  );
  if (busy) {
    await _frames(tester);
  } else {
    await tester.pumpAndSettle();
  }
  return fixture;
}
