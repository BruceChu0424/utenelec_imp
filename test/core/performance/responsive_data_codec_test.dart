import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/json_value_snapshot.dart';
import 'package:uten_imp/core/performance/responsive_data_codec.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  test(
    'JSON codec preserves raw incomplete text, exact decimals, keys and number spellings',
    () async {
      final raw = <String, dynamic>{
        'unfinished': '-',
        'exact': '999999999999.123456789012345678901234',
        'unicode': '中文😀\n\u0000"\\\ud800',
        'empty': '',
        'null': null,
        '__proto__': {'nested': true},
        'numbers': [0, -0.0, 1.0, 1e-20],
        'attachment': 'A' * 200000,
        'rows': List.generate(1000, (i) => {'id': i, 'qty': '0.', 'price': ''}),
      };
      final expected = jsonEncode(raw);
      final encoded = await encodeJsonResponsive(raw);
      expect(encoded, expected);
      expect(await decodeJsonResponsive(encoded), jsonDecode(expected));
    },
  );

  test('encoding owns nested containers before the first await', () async {
    final row = <String, dynamic>{'text': 'original'};
    final raw = <String, dynamic>{
      'rows': [row],
      'large': 'x' * 50000,
    };
    final future = encodeJsonResponsive(raw);
    row['text'] = 'later';
    (raw['rows'] as List).clear();
    expect((jsonDecode(await future) as Map)['rows'], [
      {'text': 'original'},
    ]);
  });

  test(
    'base64 and UTF8 preserve byte boundaries, BOM and invalid input semantics',
    () async {
      for (final size in [0, 1, 2, 3, 49151, 49152, 49153, 200000]) {
        final bytes = Uint8List.fromList(List.generate(size, (i) => i % 256));
        expect(await encodeBase64Responsive(bytes), base64Encode(bytes));
        expect(await decodeBase64Responsive(base64Encode(bytes)), bytes);
      }
      for (final value in ['TWE=', 'TQ%3D%3D', '-_8=']) {
        expect(await decodeBase64Responsive(value), base64Decode(value));
      }
      final longBase64 = base64Encode(
        Uint8List.fromList(List.filled(50002, 255)),
      );
      for (final value in [
        longBase64.replaceAll('/', '_').replaceAll('+', '-'),
        longBase64.replaceAll('=', '%3D'),
      ]) {
        expect(await decodeBase64Responsive(value), base64Decode(value));
      }
      await expectLater(
        decodeBase64Responsive('$longBase64='),
        throwsFormatException,
      );
      for (final value in [
        'A',
        'TWE',
        'TQ=Z',
        ' TQ==',
        '====',
        '%54Q==',
        'AB==',
      ]) {
        await expectLater(decodeBase64Responsive(value), throwsFormatException);
      }
      await expectLater(
        decodeBase64Responsive('${'AAAA' * 10000}AB=='),
        throwsFormatException,
      );
      for (final bytes in [
        Uint8List.fromList([239, 187, 191, 97]),
        Uint8List.fromList([239, 187, 191, ...List.filled(50000, 97)]),
      ]) {
        expect(await decodeUtf8Responsive(bytes), utf8.decode(bytes));
      }
      for (final invalid in [
        [0xc0, 0xaf],
        [0xed, 0xa0, 0x80],
        [0xf4, 0x90, 0x80, 0x80],
      ]) {
        final bytes = Uint8List.fromList([
          ...List.filled(50000, 97),
          ...invalid,
        ]);
        await expectLater(decodeUtf8Responsive(bytes), throwsFormatException);
        expect(
          await decodeUtf8Responsive(bytes, allowMalformed: true),
          utf8.decode(bytes, allowMalformed: true),
        );
      }
      final text = '中文😀\ufeff' * 10000;
      expect(await encodeUtf8Responsive(text), utf8.encode(text));
    },
  );

  test(
    'deferred attachment snapshots stay stable, retain original bytes and materialise fully',
    () async {
      final source = Uint8List.fromList(List.generate(100000, (i) => i % 251));
      final controller = PendingAttachmentController();
      expect(
        controller.add(
          PlatformFile(name: 'data.pdf', size: source.length, bytes: source),
        ),
        isNull,
      );
      final before = snapshotJsonValue(
        captureDeferredJsonValues(controller.exportDraft),
      );
      source[0] = 255;
      final after = snapshotJsonValue(
        captureDeferredJsonValues(controller.exportDraft),
      );
      expect(jsonValuesEqual(before, after), isTrue);
      expect(controller.items.single.bytes[0], 0);
      final decoded = await materializeJsonResponsive(before) as Map;
      expect(
        base64Decode(
          ((decoded['items'] as List).single as Map)['bytes'] as String,
        ),
        controller.items.single.bytes,
      );
      controller.dispose();
    },
  );

  test(
    'responsive restore cannot replace a newer file added while decoding',
    () async {
      final controller = PendingAttachmentController();
      final restoring = controller.restoreDraftResponsive({
        'items': [
          {
            'name': 'old.pdf',
            'contentType': 'application/pdf',
            'bytes': base64Encode(Uint8List(200000)),
          },
        ],
      });
      expect(
        controller.add(
          PlatformFile(
            name: 'new.pdf',
            size: 1,
            bytes: Uint8List.fromList([7]),
          ),
        ),
        isNull,
      );
      await expectLater(restoring, throwsA(isA<UiWorkCancelled>()));
      expect(controller.items.single.name, 'new.pdf');
      expect(controller.items.single.bytes, [7]);
      controller.dispose();
    },
  );

  test(
    'cancelled codecs never publish and incremental digest matches SHA256',
    () async {
      await expectLater(
        encodeJsonResponsive({'a': 1}, isCurrent: () => false),
        throwsA(isA<UiWorkCancelled>()),
      );
      final bytes = Uint8List.fromList(
        List.generate(1024 * 1024, (i) => i % 256),
      );
      expect(
        await sha256HexResponsive(bytes),
        sha256.convert(bytes).toString(),
      );
    },
  );
}
