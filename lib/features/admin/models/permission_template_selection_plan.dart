import '../../../shared/auth/permission_action_type.dart';
import 'admin_models.dart';

/// A responsive draft preview driven by the server's dependency metadata.
/// The server remains authoritative when validating and saving the template.
class PermissionTemplateSelectionPlan {
  const PermissionTemplateSelectionPlan({
    required this.codes,
    this.blocked = const [],
    this.relatedRemoved = const {},
  });
  final Set<String> codes;
  final List<String> blocked;
  final Set<String> relatedRemoved;

  static PermissionTemplateSelectionPlan select({
    required Set<String> current,
    required Iterable<AdminPermission> catalog,
    required String code,
    required bool enabled,
  }) {
    return selectMany(
      current: current,
      catalog: catalog,
      codes: [code],
      enabled: enabled,
    );
  }

  static PermissionTemplateSelectionPlan selectMany({
    required Set<String> current,
    required Iterable<AdminPermission> catalog,
    required Iterable<String> codes,
    required bool enabled,
  }) {
    final byCode = {
      for (final permission in catalog) permission.code: permission,
    };
    final next = {...current};
    final requested = codes.toSet();
    if (!enabled) {
      final removed = {...requested};
      var changed = true;
      while (changed) {
        changed = false;
        for (final selected in current) {
          if (!removed.contains(selected) &&
              (byCode[selected]?.requiredPermissions.any(removed.contains) ??
                  false)) {
            removed.add(selected);
            changed = true;
          }
        }
      }
      next.removeAll(removed);
      return PermissionTemplateSelectionPlan(
        codes: next,
        relatedRemoved: removed.difference(requested),
      );
    }
    next.addAll(requested);
    final pending = requested.toList();
    final visited = <String>{};
    final blocked = <String>{};
    while (pending.isNotEmpty) {
      final selected = pending.removeLast();
      if (!visited.add(selected)) continue;
      for (final required
          in byCode[selected]?.requiredPermissions ?? const <String>[]) {
        if (next.contains(required)) continue;
        final dependency = byCode[required];
        if (dependency == null ||
            dependency.actionType != PermissionActionType.view ||
            dependency.sensitivity != 'NORMAL' ||
            !dependency.grantPolicy.bulkEligible ||
            !dependency.grantPolicy.individuallyGrantable) {
          blocked.add(dependency?.name ?? required);
          continue;
        }
        next.add(required);
        pending.add(required);
      }
    }
    return blocked.isEmpty
        ? PermissionTemplateSelectionPlan(codes: next)
        : PermissionTemplateSelectionPlan(
            codes: {...current},
            blocked: blocked.toList()..sort(),
          );
  }
}
