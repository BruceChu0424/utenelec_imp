import 'package:flutter/widgets.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';

final _fallback = AppLocalizationsZh();

/// Business field help uses the app locale; isolated previews keep a Chinese fallback.
AppLocalizations workflowFieldText(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ?? _fallback;
