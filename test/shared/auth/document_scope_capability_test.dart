import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

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
  test('a retained previous capability is closed during refresh and error', () {
    const previous = AsyncData(
      DocumentScopeCapability(
        scope: 'finance',
        writeAll: true,
        writableOwnerIds: <String>{},
      ),
    );
    final refreshing = const AsyncLoading<DocumentScopeCapability>()
        .copyWithPrevious(previous);
    final failed = AsyncError<DocumentScopeCapability>(
      StateError('revoked'),
      StackTrace.current,
    ).copyWithPrevious(previous);
    expect(refreshing.value?.writeAll, isTrue);
    expect(documentOwnerCanWrite(refreshing, 'owner'), isFalse);
    expect(documentOwnerCanWrite(failed, 'owner'), isFalse);
  });
}
