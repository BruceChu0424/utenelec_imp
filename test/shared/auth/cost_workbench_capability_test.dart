import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/cost_workbench_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const allCostPermissions = {
  Perm.goodsCostView,
  Perm.goodsCostEdit,
  Perm.goodsCostConfirm,
  Perm.goodsCostExport,
  Perm.goodsCostTemplate,
  Perm.financeReportView,
  Perm.financePostExecute,
};

void main() {
  test(
    'cost viewing is required by every editing and financial capability',
    () {
      final permissions = {...allCostPermissions}..remove(Perm.goodsCostView);
      final capabilities = CostWorkbenchCapability.fromPermissions(permissions);
      expect(capabilities.canRead, isFalse);
      expect(capabilities.canCreate, isFalse);
      expect(capabilities.canManageTemplates, isFalse);
      expect(capabilities.canExport, isFalse);
      expect(capabilities.canReadPostings, isFalse);
      expect(capabilities.canPost, isFalse);
      expect(capabilities.canConfirmSheet(serverAllowed: true), isFalse);
    },
  );

  test('sheet actions require both current grant and server object action', () {
    final all = CostWorkbenchCapability.fromPermissions(allCostPermissions);
    expect(all.canEditSheet(serverAllowed: true), isTrue);
    expect(all.canConfirmSheet(serverAllowed: true), isTrue);
    expect(all.canExportSheet(serverAllowed: true), isTrue);
    expect(all.canEditSheet(serverAllowed: false), isFalse);
    expect(all.canConfirmSheet(serverAllowed: false), isFalse);
    expect(all.canExportSheet(serverAllowed: false), isFalse);
    final readOnly = CostWorkbenchCapability.fromPermissions({
      Perm.goodsCostView,
    });
    expect(readOnly.canEditSheet(serverAllowed: true), isFalse);
    expect(readOnly.canConfirmSheet(serverAllowed: true), isFalse);
    expect(readOnly.canExportSheet(serverAllowed: true), isFalse);
  });

  test('posting requires report visibility and its own execute grant', () {
    for (final missing in [Perm.financeReportView, Perm.financePostExecute]) {
      final capabilities = CostWorkbenchCapability.fromPermissions(
        {...allCostPermissions}..remove(missing),
      );
      expect(capabilities.canPost, isFalse, reason: missing);
    }
    final costOnly = CostWorkbenchCapability.fromPermissions({
      Perm.goodsCostView,
    });
    expect(costOnly.canReadPostings, isFalse);
  });

  test(
    'template administration requires edit and its distinct template grant',
    () {
      for (final missing in [Perm.goodsCostEdit, Perm.goodsCostTemplate]) {
        final capabilities = CostWorkbenchCapability.fromPermissions(
          {...allCostPermissions}..remove(missing),
        );
        expect(capabilities.canManageTemplates, isFalse, reason: missing);
      }
    },
  );

  test(
    'same-user permission revocation updates open capability subscribers',
    () {
      final grants = StateProvider<Set<String>>((ref) => allCostPermissions);
      final container = ProviderContainer(
        overrides: [
          currentPermissionsProvider.overrideWith((ref) => ref.watch(grants)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        costWorkbenchCapabilityProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(container.read(costWorkbenchCapabilityProvider).canPost, isTrue);
      container.read(grants.notifier).state = {Perm.goodsCostView};
      final restricted = container.read(costWorkbenchCapabilityProvider);
      expect(restricted.canRead, isTrue);
      expect(restricted.canPost, isFalse);
      expect(restricted.canExportSheet(serverAllowed: true), isFalse);
      container.read(grants.notifier).state = {};
      expect(container.read(costWorkbenchCapabilityProvider).canRead, isFalse);
    },
  );
}
