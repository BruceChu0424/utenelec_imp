import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/network/responsive_json_transformer.dart';

void main() {
  late ResponsiveJsonDecoder decoder;
  late ResponsiveJsonTransformer transformer;
  setUp(() {
    decoder = ResponsiveJsonDecoder();
    transformer = ResponsiveJsonTransformer(decoder);
  });
  tearDown(() => decoder.dispose());

  Future<dynamic> response(
    String text, {
    ResponseType type = ResponseType.json,
    String contentType = 'application/json',
  }) => transformer.transformResponse(
    RequestOptions(path: '/fixture', responseType: type),
    ResponseBody.fromString(
      text,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    ),
  );

  test(
    'large response preserves Unicode, exact strings, order and nulls',
    () async {
      final source = <String, dynamic>{
        'items': List.generate(
          3000,
          (index) => {
            'id': '$index',
            'name': '物料😀$index',
            'exact': '98765432109876.1234567890',
            'amount': index / 10,
            'empty': null,
            'flags': [true, false],
          },
        ),
      };
      expect(await response(jsonEncode(source)), source);
    },
  );

  test(
    'problem JSON, void, plain text, stream and bytes retain Dio contracts',
    () async {
      expect(
        await response(
          '{"code":"CONFLICT"}',
          contentType: 'application/problem+json',
        ),
        {'code': 'CONFLICT'},
      );
      expect(await response(''), isNull);
      expect(await response('not json', contentType: 'text/plain'), 'not json');
      expect(
        await response('{"ok":true}', type: ResponseType.plain),
        '{"ok":true}',
      );
      expect(
        await response('abc', type: ResponseType.bytes),
        utf8.encode('abc'),
      );
      expect(
        await response('abc', type: ResponseType.stream),
        isA<ResponseBody>(),
      );
    },
  );

  test('malformed JSON fails without returning a partial success', () async {
    await expectLater(response('{"items":[1,2,'), throwsFormatException);
    await expectLater(response(' ' * 70000 + '{'), throwsFormatException);
  });

  test('custom response decoder is respected', () async {
    final result = await transformer.transformResponse(
      RequestOptions(
        path: '/custom',
        responseDecoder: (_, _, _) => '{"custom":true}',
      ),
      ResponseBody.fromString(
        'ignored',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    expect(result, {'custom': true});
  });

  test('disposed response owner cannot publish decoded data', () async {
    decoder.dispose();
    await expectLater(
      decoder.decodeBytes(Uint8List.fromList([123, 125])),
      throwsStateError,
    );
  });
}
