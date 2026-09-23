import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
