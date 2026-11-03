import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'page_preparation_coordinator.dart';

/// No identity dependency: running reads retain their physical slots across
/// login/permission/transport revisions. Their data leases own authorization.
final pagePreparationBudgetProvider = Provider((ref) {
  final budget = PagePreparationBudget();
  ref.onDispose(budget.dispose);
  return budget;
});

/// Retire old jobs synchronously, then notify the view after the current build.
/// A watched repository may rebuild lazily during a widget's read; publishing
/// another provider notification in that stack violates Riverpod's UI boundary.
void Function() pagePreparationRetirementCallback(
  Ref ref,
  void Function() retire,
) {
  var scheduled = false;
  return () {
    retire();
    if (scheduled) return;
    scheduled = true;
    scheduleMicrotask(() {
      scheduled = false;
      if (ref.mounted) ref.notifyListeners();
    });
  };
}
