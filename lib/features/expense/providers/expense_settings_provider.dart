import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/paging/shared_read_provider_owner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/expense_settings.dart';

final expenseSettingsProvider = FutureProvider.autoDispose<ExpenseSettings>((
  ref,
) async {
  final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
  return runSharedProviderRead(ref, () async {
    ref.watch(masterDataSessionKeyProvider);
    return ExpenseSettings.fromJson(
      await ref.watch(apiClientProvider).get('/expense-claims/settings'),
    );
  }, isCurrent: () => ref.read(sensitiveReadBoundaryProvider) == readBoundary);
});

Future<void> saveExpenseSettings(
  WidgetRef ref,
  ExpenseSettings settings,
) async {
  await ref
      .read(apiClientProvider)
      .put('/expense-claims/settings', body: settings.toJson());
  ref.invalidate(expenseSettingsProvider);
}
