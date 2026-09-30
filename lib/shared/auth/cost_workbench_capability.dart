import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'permissions.dart';

/// Cost workspace capabilities projected from the server-granted permission set.
/// Sheet actions additionally require the object's current server capability;
/// these flags never replace endpoint authorization or historical-state guards.
class CostWorkbenchCapability {
  CostWorkbenchCapability.fromPermissions(Set<String> permissions)
    : canRead = permissions.contains(Perm.goodsCostView),
      _canEdit = permissions.contains(Perm.goodsCostEdit),
      _canConfirm = permissions.contains(Perm.goodsCostConfirm),
      _canExport = permissions.contains(Perm.goodsCostExport),
      _canTemplate = permissions.contains(Perm.goodsCostTemplate),
      _canReadFinance = permissions.contains(Perm.financeReportView),
      _canPostFinance = permissions.contains(Perm.financePostExecute);

  final bool canRead;
  final bool _canEdit, _canConfirm, _canExport, _canTemplate;
  final bool _canReadFinance, _canPostFinance;

  bool get canCreate => canRead && _canEdit;
  bool get canExport => canRead && _canExport;
  bool get canManageTemplates => canCreate && _canTemplate;
  bool get canReadPostings => canRead && _canReadFinance;
  bool get canPost => canReadPostings && _canPostFinance;

  bool canEditSheet({required bool serverAllowed}) =>
      canCreate && serverAllowed;
  bool canConfirmSheet({required bool serverAllowed}) =>
      canRead && _canConfirm && serverAllowed;
  bool canExportSheet({required bool serverAllowed}) =>
      canExport && serverAllowed;

  /// Shared export button retains its own live permission check after dialogs.
  static const exportPermission = Perm.goodsCostExport;
}

/// Watching this projection masks/restricts open editors immediately on revoke.
/// Mutating callbacks read it again after awaiting user confirmation.
final costWorkbenchCapabilityProvider = Provider<CostWorkbenchCapability>(
  (ref) => CostWorkbenchCapability.fromPermissions(
    ref.watch(currentPermissionsProvider),
  ),
);
