import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_import_repository.dart';

void main() {
  test(
    'merge carries large selections in the body and preserves the file',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'targets': 1,
                  'added': 1,
                  'removed': 0,
                  'levels': 1,
                  'updatedCount': 10,
                  'ignoredCount': 3,
                  'filledCount': 2,
                  'unchangedCount': 4,
                },
              ),
            );
          },
        ),
      );
      final repository = DioGoodsBomImportRepository(ApiClient(dio));
      final bytes = Uint8List.fromList([0x50, 0x4b, 3, 4]);
      final keys = {
        for (var i = 0; i < 2000; i++) 'bom:parent-$i:component-$i',
      };
      final result = await repository.commit(
        'parent',
        bytes,
        mode: BomImportMode.merge,
        stateFingerprint: 'v1:file-state',
        replaceRowKeys: keys,
      );
      expect(captured.queryParameters, isEmpty);
      final body = captured.data as Map<String, dynamic>;
      expect(base64Decode(body['file'] as String), bytes);
      expect(body['stateFingerprint'], 'v1:file-state');
      expect(body['mode'], 'MERGE');
      expect(body['replaceRowKeys'], keys.toList());
      expect(result.updatedCount, 10);
      expect(result.filledCount, 2);
      expect(result.ignoredCount, 3);
      expect(result.unchangedCount, 4);
    },
  );

  test('detect uses raw bytes and parses component differences', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {
                'reviewRows': [
                  {
                    'rowKey': 'bom:p:c',
                    'rowNum': 3,
                    'seq': '1.2',
                    'name': '组件',
                    'code': 'A01',
                    'matchType': 'CODE',
                    'changes': [
                      {
                        'field': 'qty',
                        'label': '设计使用数量',
                        'oldValue': '1.0000',
                        'newValue': '2.5000',
                        'kind': 'CONFLICT',
                      },
                    ],
                  },
                ],
                'addedRows': 1,
                'conflictRows': 1,
                'stateFingerprint': 'fp',
              },
            ),
          );
        },
      ),
    );
    final bytes = Uint8List.fromList([1, 2]);
    final report = await DioGoodsBomImportRepository(
      ApiClient(dio),
    ).detect('p', bytes);
    expect(captured.data, same(bytes));
    expect(captured.contentType, 'application/octet-stream');
    expect(report.reviewRows.single.seq, '1.2');
    expect(report.reviewRows.single.hasConflicts, isTrue);
    expect(report.reviewRows.single.changes.single.newValue, '2.5000');
    expect(report.addedRows, 1);
  });
}
