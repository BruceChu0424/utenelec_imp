import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/paging/shared_read_provider_owner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/business_application.dart';
import '../repositories/business_application_repository.dart';

final businessApplicationDetailProvider = FutureProvider.autoDispose
    .family<BusinessApplication, String>(
      (ref, id) {
        final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
        return runSharedProviderRead(
          ref,
          () async {
            ref.watch(masterDataSessionKeyProvider);
            ref.watch(exportContextEpochProvider);
            return ref.watch(businessApplicationRepositoryProvider).get(id);
          },
          isCurrent: () =>
              ref.read(sensitiveReadBoundaryProvider) == readBoundary,
        );
      },
      dependencies: [
        masterDataSessionKeyProvider,
        exportContextEpochProvider,
        businessApplicationRepositoryProvider,
      ],
    );
final businessApplicationCountsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>(
      (ref) {
        final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
        return runSharedProviderRead(
          ref,
          () async {
            ref.watch(masterDataSessionKeyProvider);
            ref.watch(exportContextEpochProvider);
            return ref.watch(businessApplicationRepositoryProvider).counts();
          },
          isCurrent: () =>
              ref.read(sensitiveReadBoundaryProvider) == readBoundary,
        );
      },
      dependencies: [
        masterDataSessionKeyProvider,
        exportContextEpochProvider,
        businessApplicationRepositoryProvider,
      ],
    );
