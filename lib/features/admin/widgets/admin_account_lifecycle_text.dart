import 'package:flutter/widgets.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../models/admin_models.dart';

/// A missing state is not evidence that an account merely needs enabling.
String adminAuthorizationRestrictionText(
  BuildContext context,
  AdminUserSummary user,
) => user.knownAccountState
    ? user.authorizationRestrictionReason
    : AppLocalizations.of(context).accountStateRefreshRequired;
