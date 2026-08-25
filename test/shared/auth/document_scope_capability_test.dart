import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';

void main() {
  test(
    'manual visible owners remain read-only while handover owners can write',
    () {
      final capability = DocumentScopeCapability.fromJson(const {
        'scope': 'finance',
        'writeAll': false,
        'writableOwnerIds': ['owner-self', 'owner-handed-over'],
      });

      expect(capability.canWrite('owner-self'), isTrue);
      expect(capability.canWrite('owner-handed-over'), isTrue);
      expect(capability.canWrite('owner-manual-visible'), isFalse);
      expect(capability.canWrite(null), isFalse);
    },
  );

  test('writeAll is explicit and malformed responses fail closed', () {
    final all = DocumentScopeCapability.fromJson(const {
      'scope': 'stock_doc',
      'writeAll': true,
      'writableOwnerIds': <String>[],
    });

    expect(all.canWrite('any-owner'), isTrue);
    expect(all.canWrite(null), isFalse);
    expect(
      () => DocumentScopeCapability.fromJson(const {
        'scope': 'finance',
        'writeAll': 'yes',
        'writableOwnerIds': <String>[],
      }),
      throwsFormatException,
    );
  });

  test('loading and error capability states are read-only', () {
    const loading = AsyncLoading<DocumentScopeCapability>();
    final error = AsyncError<DocumentScopeCapability>(
      StateError('offline'),
      StackTrace.current,
    );

    expect(documentOwnerCanWrite(loading, 'owner-self'), isFalse);
    expect(documentOwnerCanWrite(error, 'owner-self'), isFalse);
  });

  test(
    'repository calls current-subject scope endpoint and validates scope',
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
                data: const {
                  'scope': 'purchase',
                  'writeAll': false,
                  'writableOwnerIds': ['owner-1'],
                },
              ),
            );
          },
        ),
      );

      final repository = DioDocumentScopeCapabilityRepository(ApiClient(dio));
      final capability = await repository.current(DocumentDataScope.purchase);

      expect(captured.method, 'GET');
      expect(captured.uri.path, '/api/auth/me/document-scopes/purchase');
      expect(capability.canWrite('owner-1'), isTrue);
    },
  );

  test('repository rejects a response for a different scope', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const {
              'scope': 'sales',
              'writeAll': true,
              'writableOwnerIds': <String>[],
            },
          ),
        ),
      ),
    );

    final repository = DioDocumentScopeCapabilityRepository(ApiClient(dio));

    expect(
      repository.current(DocumentDataScope.finance),
      throwsFormatException,
    );
  });
}
