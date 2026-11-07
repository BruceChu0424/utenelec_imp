import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'pump_until.dart';

class _Wire implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '{"value":"original"}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Read extends StatefulWidget {
  const _Read(this.dio);
  final Dio dio;
  @override
  State<_Read> createState() => _ReadState();
}

class _ReadState extends State<_Read> {
  String? value;
  @override
  void initState() {
    super.initState();
    widget.dio.get<Map<String, dynamic>>('/read').then((response) {
      if (mounted) setState(() => value = response.data!['value'] as String);
    });
  }

  @override
  Widget build(BuildContext context) =>
      value == null ? const CircularProgressIndicator() : Text(value!);
}

Future<_Wire> _mount(WidgetTester tester) async {
  final wire = _Wire();
  final dio = Dio(BaseOptions(baseUrl: 'https://wire.fixture'))
    ..httpClientAdapter = wire;
  addTearDown(() => dio.close(force: true));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: _Read(dio))));
  return wire;
}

void main() {
  testWidgets(
    'fixed fifteen frames retain the original 750ms fake clock budget',
    (tester) async {
      final wire = await _mount(tester);
      final start = tester.binding.clock.now();
      for (var frame = 0; frame < 15; frame++) {
        await pumpWithIo(tester, const Duration(milliseconds: 50));
      }
      expect(
        tester.binding.clock.now().difference(start),
        const Duration(milliseconds: 750),
      );
      expect(find.text('original'), findsOneWidget);
      expect(wire.requests, 1);
    },
  );
  testWidgets(
    'real Dio bytes publish the original data within the original frame deadline',
    (tester) async {
      final wire = await _mount(tester);
      await pumpAndSettleWithIo(tester, timeout: const Duration(seconds: 2));
      expect(find.text('original'), findsOneWidget);
      expect(wire.requests, 1);
    },
  );
  testWidgets(
    'a concrete producer signal supports I/O without extending its timeout',
    (tester) async {
      final wire = await _mount(tester);
      await pumpUntil(
        tester,
        () => find.text('original').evaluate().isNotEmpty,
        reason: 'The actual wire result was not published',
        realIo: true,
      );
      expect(wire.requests, 1);
    },
  );
  testWidgets(
    'an endless loading frame still fails at the selected original deadline',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CircularProgressIndicator()),
      );
      await expectLater(
        () => pumpAndSettleWithIo(
          tester,
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(
          isA<FlutterError>().having(
            (error) => error.message,
            'message',
            'pumpAndSettle timed out',
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
