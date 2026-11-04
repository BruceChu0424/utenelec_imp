import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/business_application.dart';
import '../repositories/business_application_repository.dart';

final businessApplicationDetailProvider = FutureProvider.autoDispose
    .family<BusinessApplication, String>(
      (ref, id) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(exportContextEpochProvider);
        return ref.watch(businessApplicationRepositoryProvider).get(id);
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
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(exportContextEpochProvider);
        return ref.watch(businessApplicationRepositoryProvider).counts();
      },
      dependencies: [
        masterDataSessionKeyProvider,
        exportContextEpochProvider,
        businessApplicationRepositoryProvider,
      ],
    );
