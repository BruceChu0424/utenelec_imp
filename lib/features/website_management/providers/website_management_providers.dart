import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/website_management.dart';
import '../repositories/website_management_repository.dart';

final websiteManagementRepositoryProvider =
    Provider<WebsiteManagementRepository>(
      (ref) => DioWebsiteManagementRepository(ref.watch(apiClientProvider)),
    );

typedef WebsiteExternalLauncher = Future<bool> Function(Uri uri);
final websiteExternalLauncherProvider = Provider<WebsiteExternalLauncher>(
  (ref) =>
      (uri) => launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        // Browser navigation in the current tab also works after the grant await;
        // a new popup would lose its user gesture and can be silently blocked.
        webOnlyWindowName: '_self',
      ),
);

final websiteManagementProvider =
    FutureProvider.autoDispose<WebsiteManagementSnapshot>((ref) async {
      final owner = ref.watch(authenticatedScopeProvider);
      final permissions = ref.watch(currentPermissionsProvider);
      final endpoint = ref.watch(apiBaseUrlProvider);
      if (owner == null || !permissions.contains(Perm.websiteView)) {
        throw AuthenticatedRequestScope.changed();
      }
      var current = true;
      ref.onDispose(() => current = false);
      final api = ref.watch(apiClientProvider);
      final repository = ref.watch(websiteManagementRepositoryProvider);
      final scope = await api.captureRequestScope(
        isCurrent: () =>
            current &&
            ref.read(authenticatedScopeProvider) == owner &&
            ref.read(apiBaseUrlProvider) == endpoint &&
            ref.read(currentPermissionsProvider).contains(Perm.websiteView),
      );
      return scope.run(() async {
        final info = await repository.load();
        await scope.verify();
        try {
          final check = await repository.check();
          await scope.verify();
          return WebsiteManagementSnapshot(info, check: check);
        } catch (error) {
          if (isSessionBoundaryError(error)) rethrow;
          await scope.verify();
          return WebsiteManagementSnapshot(info, checkError: error);
        }
      });
    });
