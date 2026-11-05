import '../config/finance_doc_config.dart';
import '../providers/finance_name_provider.dart';

/// Matches the existing server AccountPosting currency rule. Historical inputs
/// remain visible; selecting a new value never promises an unsupported posting.
bool financeEntryRequiresBaseCurrency(FinanceDocConfig config) =>
    config.isAllocate || config.isTransfer;

List<FinanceAccountReference> financeEntryAccountChoices(
  FinanceDocConfig config,
  FinanceNameService names,
) => [
  for (final account in names.accountReferences.values)
    if (!financeEntryRequiresBaseCurrency(config) || account.baseCurrency)
      account,
];

Map<String, String> financeEntryCurrencyChoices(
  FinanceDocConfig config,
  FinanceNameService names,
) => {
  for (final currency in names.currencyEntries.entries)
    if (!financeEntryRequiresBaseCurrency(config) ||
        names.currencyIsBase(currency.key) == true)
      currency.key: currency.value,
};
