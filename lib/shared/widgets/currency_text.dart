import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/utils/currency_display.dart';

/// One palette for currency labels in tables, inspectors and form choices.
Color currencyTextColor(BuildContext context, {String? name, String? code}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (currencyColorRole(name: name, code: code)) {
    'Cny' => dark ? UtenColors.currencyCnyOnDark : UtenColors.currencyCny,
    'Usd' => dark ? UtenColors.currencyUsdOnDark : UtenColors.currencyUsd,
    'Hkd' => dark ? UtenColors.currencyHkdOnDark : UtenColors.currencyHkd,
    'Eur' => dark ? UtenColors.currencyEurOnDark : UtenColors.currencyEur,
    'Jpy' => dark ? UtenColors.currencyJpyOnDark : UtenColors.currencyJpy,
    'Gbp' => dark ? UtenColors.currencyGbpOnDark : UtenColors.currencyGbp,
    'Sgd' => dark ? UtenColors.currencySgdOnDark : UtenColors.currencySgd,
    'Aud' => dark ? UtenColors.currencyAudOnDark : UtenColors.currencyAud,
    'Cad' => dark ? UtenColors.currencyCadOnDark : UtenColors.currencyCad,
    'Krw' => dark ? UtenColors.currencyKrwOnDark : UtenColors.currencyKrw,
    'Rub' => dark ? UtenColors.currencyRubOnDark : UtenColors.currencyRub,
    'Chf' => dark ? UtenColors.currencyChfOnDark : UtenColors.currencyChf,
    _ => dark ? UtenColors.currencyOtherOnDark : UtenColors.currencyOther,
  };
}

class CurrencyText extends StatelessWidget {
  const CurrencyText({super.key, this.name, this.code});

  final String? name;
  final String? code;

  @override
  Widget build(BuildContext context) => Text(
    financeCurrencyDisplayLabel(name: name, code: code) ?? '未登记',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: currencyTextColor(context, name: name, code: code),
      fontWeight: FontWeight.w600,
    ),
  );
}
