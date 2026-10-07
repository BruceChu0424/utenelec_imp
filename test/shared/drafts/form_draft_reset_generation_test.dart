import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  test(
    'ordinary sign-in retains drafts, only a business reset changes the namespace',
    () {
      const before = AuthenticatedScope(userId: 'user', epoch: 1);
      const signedInAgain = AuthenticatedScope(userId: 'user', epoch: 2);
      const reset = AuthenticatedScope(
        userId: 'user',
        epoch: 3,
        businessResetGeneration: 1,
      );
      expect(
        formDraftStoragePrefix('server-a', before),
        formDraftStoragePrefix('server-a', signedInAgain),
      );
      expect(
        formDraftStoragePrefix('server-a', before),
        isNot(formDraftStoragePrefix('server-a', reset)),
      );
      expect(
        formDraftStorageOwnerPrefix('server-a', before),
        formDraftStorageOwnerPrefix('server-a', reset),
      );
      expect(
        formDraftStoragePrefix('server-a', reset),
        isNot(formDraftStoragePrefix('server-b', reset)),
      );
      expect(
        before,
        isNot(
          const AuthenticatedScope(
            userId: 'user',
            epoch: 1,
            businessResetGeneration: 1,
          ),
        ),
      );
    },
  );

  test(
    'user profile parses committed generation and refuses malformed values',
    () {
      final old = <String, dynamic>{'id': 'user', 'loginAccount': 'E001'};
      expect(UserProfile.fromJson(old).businessResetGeneration, 0);
      expect(
        UserProfile.fromJson({
          ...old,
          'businessResetGeneration': 4,
        }).businessResetGeneration,
        4,
      );
      for (final invalid in [null, -1, 1.5, '4', true]) {
        expect(
          () => UserProfile.fromJson({
            ...old,
            'businessResetGeneration': invalid,
          }),
          throwsFormatException,
        );
      }
    },
  );
}
