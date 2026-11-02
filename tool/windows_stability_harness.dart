// Offline native-engine fixture. No authentication, HTTP, business writes,
// installer or updater. Run only as an internal test executable.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_log.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/widgets/diagnostic_log_tile.dart';

import 'stability_receipt_stub.dart'
    if (dart.library.io) 'stability_receipt_native.dart';

Future<void> main(List<String> arguments) async {
  UtenWidgetsFlutterBinding();
  await AppDiagnostics.initialize();
  final receipt = arguments
      .where((value) => value.startsWith('--fixture-receipt='))
      .map((value) => value.substring('--fixture-receipt='.length))
      .firstOrNull;
  runApp(
    _Fixture(
      receipt: receipt,
      extreme:
          arguments.contains('--extreme') ||
          Uri.base.queryParameters['stress'] == '1',
    ),
  );
}

class _Fixture extends StatefulWidget {
  const _Fixture({this.receipt, this.extreme = false});
  final String? receipt;
  final bool extreme;
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
  bool logExportOk = false;
  final decoder = ResponsiveJsonDecoder();
  Uint8List? payload;
  int? payloadReadyAt;
  int generation = 0,
      activeReads = 0,
      cancelledReads = 0,
      completeReads = 0,
      loadedRows = 0;
  final updateRejections = <String, int>{};
  void Function(FlutterErrorDetails)? oldError;

  @override
  void initState() {
    super.initState();
    if (widget.extreme) {
      unawaited(
        (kIsWeb ? _largeWebFixture(50000) : compute(_largeFixture, 50000)).then(
          (bytes) {
            payload = bytes;
            payloadReadyAt = watch.elapsedMilliseconds;
          },
        ),
      );
    }
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
    churn = Timer.periodic(Duration(milliseconds: widget.extreme ? 8 : 80), (
      _,
    ) {
      if (!moving || !mounted) return;
      if (widget.extreme &&
          payloadReadyAt != null &&
          watch.elapsedMilliseconds - payloadReadyAt! >= 40000) {
        setState(() => moving = false);
        generation++;
        if (dialogOpen) navigator.currentState!.pop();
        unawaited(_read(finalRead: true));
        unawaited(_save());
        return;
      }
      setState(() => tick++);
      if (widget.extreme && tick % 3 == 0) {
        generation++;
        if (activeReads < 2) unawaited(_read());
      }
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
      'extreme': widget.extreme,
      'cancelledReads': cancelledReads,
      'completeReads': completeReads,
      'loadedRows': loadedRows,
      'logExportOk': logExportOk,
    });
    if (kIsWeb) debugPrint('STABILITY_RECEIPT $json');
    if (widget.receipt != null) {
      await writeStabilityReceipt(widget.receipt!, json);
    }
  }

  Future<void> _read({bool finalRead = false}) async {
    final bytes = payload;
    if (bytes == null || !mounted) return;
    final own = generation;
    activeReads++;
    try {
      if (!finalRead && own.isOdd) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final value = await decoder.decodeBytes(
        bytes,
        isCurrent: () => mounted && own == generation,
      );
      if (!mounted || own != generation) throw const UiWorkCancelled();
      final items = (value as Map)['items'] as List;
      if (items.length != 50000 ||
          (items.last as Map)['quantity'] != '0001.0000000000000001') {
        errors.add('Large fixture lost rows or precision');
      }
      completeReads++;
      if (finalRead) {
        setState(() => loadedRows = items.length);
        final exported = utf8.decode(await AppDiagnostics.log!.export());
        logExportOk =
            exported.contains('app.start') &&
            (kIsWeb || exported.contains('native.start'));
        if (!logExportOk) errors.add('Log export omitted a required layer');
        AppDiagnostics.record(
          'stress.final_load',
          fields: {'count': loadedRows},
        );
        await _save();
      }
    } on UiWorkCancelled {
      cancelledReads++;
    } catch (error, stack) {
      if (mounted) errors.add(error.runtimeType.toString());
      AppDiagnostics.recordError('stress.load_failed', error, stack);
    } finally {
      activeReads--;
    }
  }

  @override
  void dispose() {
    pulse?.cancel();
    churn?.cancel();
    FlutterError.onError = oldError;
    editor.dispose();
    generation++;
    decoder.dispose();
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
            if (widget.extreme) Text('Loaded synthetic rows: $loadedRows'),
            const DiagnosticLogTile(),
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

Uint8List _largeFixture(int count) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'items': List.generate(
        count,
        (index) => {
          'id': 'synthetic-$index',
          'name': 'Synthetic item $index',
          'quantity': '0001.0000000000000001',
          'amount': '9999999999999.1234567890',
        },
      ),
    }),
  ),
);

Future<Uint8List> _largeWebFixture(int count) async {
  // Served only by the offline test server. Avoid measuring fixture creation
  // as if it were production decoding; this is synthetic data with no auth.
  final client = Dio();
  try {
    final response = await client.get<List<int>>(
      Uri.base.resolve('stress-fixture.json').toString(),
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data!;
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  } finally {
    client.close();
  }
}
