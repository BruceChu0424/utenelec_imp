import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_import_file_reader.dart';

void main() {
  group('readGoodsImportFile', () {
    test('returns valid direct OOXML bytes', () async {
      final bytes = Uint8List.fromList(const [0x50, 0x4B, 0x03, 0x04]);
      final file = PlatformFile(
        name: 'goods.xlsx',
        size: bytes.length,
        bytes: bytes,
      );

      final result = await readGoodsImportFile(file);

      expect(result, same(bytes));
    });

    test('assembles a streamed workbook', () async {
      final file = PlatformFile(
        name: 'goods.xlsx',
        size: 6,
        readStream: Stream<List<int>>.fromIterable(const [
          [0x50, 0x4B],
          [0x03, 0x04, 0x01, 0x02],
        ]),
      );

      final result = await readGoodsImportFile(file);

      expect(result, Uint8List.fromList(const [0x50, 0x4B, 0x03, 0x04, 1, 2]));
    });

    test('rejects a declared file larger than the server limit', () async {
      final file = PlatformFile(
        name: 'goods.xlsx',
        size: maxGoodsImportBytes + 1,
        readStream: const Stream<List<int>>.empty(),
      );

      await expectLater(
        readGoodsImportFile(file),
        throwsA(
          isA<GoodsImportFileException>().having(
            (error) => error.message,
            'message',
            contains('50MB'),
          ),
        ),
      );
    });

    test(
      'rejects an empty stream even when size metadata is unknown',
      () async {
        final file = PlatformFile(
          name: 'goods.xlsx',
          size: 0,
          readStream: const Stream<List<int>>.empty(),
        );

        await expectLater(
          readGoodsImportFile(file),
          throwsA(
            isA<GoodsImportFileException>().having(
              (error) => error.message,
              'message',
              contains('为空'),
            ),
          ),
        );
      },
    );

    test('explains legacy or password-protected Office containers', () async {
      final bytes = Uint8List.fromList(const [
        0xD0,
        0xCF,
        0x11,
        0xE0,
        0xA1,
        0xB1,
        0x1A,
        0xE1,
      ]);
      final file = PlatformFile(
        name: 'goods.xlsx',
        size: bytes.length,
        bytes: bytes,
      );

      await expectLater(
        readGoodsImportFile(file),
        throwsA(
          isA<GoodsImportFileException>().having(
            (error) => error.message,
            'message',
            allOf(contains('旧版 .xls'), contains('未加密的 .xlsx')),
          ),
        ),
      );
    });

    test('rejects content that is not an OOXML ZIP package', () async {
      final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
      final file = PlatformFile(
        name: 'goods.xlsx',
        size: bytes.length,
        bytes: bytes,
      );

      await expectLater(
        readGoodsImportFile(file),
        throwsA(
          isA<GoodsImportFileException>().having(
            (error) => error.message,
            'message',
            contains('不是有效的 .xlsx'),
          ),
        ),
      );
    });
  });
}
