import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_overlay.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  test(
    'grant and revoke rebuild the real AI identity without granting administration',
    () {
      final grants = StateProvider<Set<String>>((ref) => const {});
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'employee'),
          ),
          currentPermissionsProvider.overrideWith((ref) => ref.watch(grants)),
          isSuperAdminProvider.overrideWithValue(false),
          apiBaseUrlProvider.overrideWithValue('https://example.test/api'),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(aiChatIdentityProvider, (_, _) {});
      addTearDown(subscription.close);

      expect(container.read(aiChatIdentityProvider), isNull);
      container.read(grants.notifier).state = {Perm.aiUse};
      expect(container.read(aiChatIdentityProvider)?.permissions, Perm.aiUse);
      expect(container.read(aiChatIdentityProvider)?.superAdmin, isFalse);
      expect(
        container.read(currentPermissionsProvider),
        isNot(contains(Perm.authorizationManage)),
      );

      container.read(grants.notifier).state = {Perm.employeeView};
      expect(container.read(aiChatIdentityProvider), isNull);
    },
  );
}
