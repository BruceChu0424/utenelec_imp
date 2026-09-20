import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/expense_settings.dart';

final expenseSettingsProvider = FutureProvider.autoDispose<ExpenseSettings>((
  ref,
) async {
  ref.watch(masterDataSessionKeyProvider);
  return ExpenseSettings.fromJson(
    await ref.watch(apiClientProvider).get('/expense-claims/settings'),
  );
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
