import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../auth/permissions.dart';

final productionFqcPendingCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  final permissions = ref.watch(currentPermissionsProvider);
  if (!permissions.contains(Perm.productionQualityInspectionView)) {
    return 0;
  }
  final json = await ref
      .watch(apiClientProvider)
      .get(ApiEndpoints.productionQualityInspectionCount);
  return (json['count'] as num?)?.toInt() ?? 0;
});
