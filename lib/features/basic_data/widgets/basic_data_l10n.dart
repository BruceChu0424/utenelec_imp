// Localized strings for basic-data widgets.
//
// Several basic-data pages are also mounted by other features' tests without
// localization delegates; falling back to the generated Chinese (template)
// strings keeps those hosts rendering instead of throwing, the same fallback
// used by production_execution_batch_page / uten_field_hint_icon.
import 'package:flutter/widgets.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';

AppLocalizations basicDataL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    AppLocalizationsZh();
