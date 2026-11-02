// Offline native-engine fixture. No authentication, HTTP, business writes,
// installer or updater. Run only as an internal test executable.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';

import 'stability_receipt_stub.dart'
    if (dart.library.io) 'stability_receipt_native.dart';

void main(List<String> arguments) {
  UtenWidgetsFlutterBinding();
  final receipt = arguments
      .where((value) => value.startsWith('--fixture-receipt='))
      .map((value) => value.substring('--fixture-receipt='.length))
      .firstOrNull;
  runApp(_Fixture(receipt: receipt));
}

class _Fixture extends StatefulWidget {
  const _Fixture({this.receipt});
  final String? receipt;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  final editorKey = GlobalKey();
  final editor = TextEditingController(text: '0001. retained input');
  final navigator = GlobalKey<NavigatorState>();
  final watch = Stopwatch()..start();
  Timer? pulse, churn;
  int tick = 0, lastPulse = 0, maxGap = 0, pulses = 0;
  bool dialogOpen = false, moving = true;
  final errors = <String>[];
  final updateRejections = <String, int>{};
  void Function(FlutterErrorDetails)? oldError;

  @override
  void initState() {
    super.initState();
    oldError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString());
      oldError?.call(details);
    };
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
      const channel = MethodChannel('com.uten.imp/desktop_window');
      await channel.invokeMethod<void>('setMode', 'main');
      await const MethodChannel(
        'com.uten.imp/window_title',
      ).invokeMethod<void>('setTitle', 'UTEN offline stability fixture');
      // Exercise the production channel with paths that cannot pass its private
      // staging gate. This never starts an updater or changes installation files.
      await Future.wait(
        List.generate(32, (_) async {
          try {
            await const MethodChannel(
              'com.uten.imp/client_update',
            ).invokeMethod<void>('installUpdate', {
              'packagePath': 'Z:\\uten-offline-invalid-package.zip',
              'sha256': List.filled(64, '0').join(),
              'buildNumber': 65535,
            });
            errors.add('Invalid update path was accepted');
          } on PlatformException catch (error) {
            updateRejections.update(
              error.code,
              (value) => value + 1,
              ifAbsent: () => 1,
            );
            if (!{
              'UNSAFE_UPDATE_PATH',
              'UPDATE_IN_PROGRESS',
            }.contains(error.code)) {
              errors.add('Unexpected update refusal: ${error.code}');
            }
          }
        }),
      );
      await _save();
    });
    pulse = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = watch.elapsedMilliseconds;
      if (lastPulse != 0 && now - lastPulse > maxGap) maxGap = now - lastPulse;
      lastPulse = now;
      pulses++;
    });
    churn = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!moving || !mounted) return;
      setState(() => tick++);
      if (tick % 25 == 0 && !dialogOpen) {
        dialogOpen = true;
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (context) => const AlertDialog(
            title: Text('Offline transition'),
            content: TextField(autofocus: true),
          ),
        ).whenComplete(() => dialogOpen = false);
      } else if (tick % 25 == 4 && dialogOpen) {
        navigator.currentState!.pop();
      }
      if (tick % 25 == 0) unawaited(_save());
    });
  }

  Future<void> _save() async {
    final json = jsonEncode({
      'tick': tick,
      'pulses': pulses,
      'maxEventLoopGapMs': maxGap,
      'retainedInput': editor.text,
      'frameworkErrors': errors,
      'updateRejections': updateRejections,
      'offlineFixture': true,
    });
    if (kIsWeb) debugPrint('STABILITY_RECEIPT $json');
    if (widget.receipt != null) {
      await writeStabilityReceipt(widget.receipt!, json);
    }
  }

  @override
  void dispose() {
    pulse?.cancel();
    churn?.cancel();
    FlutterError.onError = oldError;
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Move the same live editor between two parents. The accessibility bridge
    // must rebind its retained native delegate when AXTree reparents the node.
    final field = SizedBox(
      key: editorKey,
      width: 320,
      child: TextField(controller: editor),
    );
    return MaterialApp(
      navigatorKey: navigator,
      theme: buildLightTheme(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Offline stability fixture'),
          actions: [
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
              UtenWindowControls(
                native: true,
                showExpand: true,
                showMinimize: true,
                onClose: () => const MethodChannel(
                  'com.uten.imp/desktop_window',
                ).invokeMethod<void>('close'),
                onMinimize: () => const MethodChannel(
                  'com.uten.imp/desktop_window',
                ).invokeMethod<void>('minimize'),
                onExpand: () => const MethodChannel(
                  'com.uten.imp/desktop_window',
                ).invokeMethod<void>('toggleMaximize'),
              ),
          ],
        ),
        body: Column(
          children: [
            Text('Semantics reparent cycles: $tick'),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    label: 'Left host',
                    child: tick.isEven ? field : const SizedBox(height: 56),
                  ),
                ),
                Expanded(
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    label: 'Right host',
                    child: tick.isOdd ? field : const SizedBox(height: 56),
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: () {
                setState(() => moving = !moving);
                unawaited(_save());
              },
              child: Text(moving ? 'Pause churn' : 'Resume churn'),
            ),
            TextButton(
              onPressed: () {
                editor.text = '0001. verified live native input';
                unawaited(_save());
              },
              child: const Text('Verify live input'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: 80,
                itemBuilder: (context, index) => ListTile(
                  title: Text('Synthetic row $index / ${tick % 3}'),
                  subtitle: Text('Value ${index + tick}'),
                  trailing: TextButton(
                    onPressed: () {},
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
