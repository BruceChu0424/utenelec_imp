import 'package:flutter/widgets.dart';

String localizedText(BuildContext context, String zh, String en, String ko) =>
    switch (Localizations.localeOf(context).languageCode) {
      'en' => en,
      'ko' => ko,
      _ => zh,
    };
