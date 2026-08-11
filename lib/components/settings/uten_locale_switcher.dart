// UtenLocaleSwitcher - 语言切换 UI
// 文档：docs/02-组件库/UtenLocaleSwitcher.md（待写）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/locale_provider.dart';

/// Uten 语言切换器（设置页用）
class UtenLocaleSwitcher extends ConsumerWidget {
  const UtenLocaleSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeProvider);
    final notifier = ref.read(localeProvider.notifier);

    final options = <(Locale, String, String)>[
      (chinaLocale, '简体中文（中国大陆）', '中文'),
      (englishLocale, 'English', '英文'),
      (koreanLocale, '한국어', '한국어'),
    ];

    return RadioGroup<String>(
      groupValue: current.toLanguageTag(),
      onChanged: (value) {
        if (value == null) return;
        final selected = options
            .map((option) => option.$1)
            .firstWhere((locale) => locale.toLanguageTag() == value);
        notifier.set(selected);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (locale, label, _) in options)
            RadioListTile<String>(
              value: locale.toLanguageTag(),
              title: Text(label),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              dense: true,
            ),
        ],
      ),
    );
  }
}
