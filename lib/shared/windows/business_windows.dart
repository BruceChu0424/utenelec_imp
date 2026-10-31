import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_app_bar_action_button.dart';
import '../../components/feedback/uten_floating_window.dart';
import '../../core/router/route_access_policy.dart';
import '../providers/sensitive_read_boundary_provider.dart';

/// Shared entry projection; actual navigation and APIs retain their own guards.
final businessLocationAllowedProvider = Provider.autoDispose
    .family<bool, String>((ref, location) {
      final boundary = ref.watch(sensitiveReadBoundaryProvider);
      return businessLocationAllowedFor(
        boundary.permissions,
        boundary.superAdmin,
        location,
      );
    });

class BusinessWindow {
  BusinessWindow({required this.location, required this.title, this.extra});
  final String location;
  final String title;
  final Object? extra;
  final navigatorKey = GlobalKey<NavigatorState>();
  final windowKey = GlobalKey<UtenFloatingWindowState>();
}

class BusinessWindows extends ChangeNotifier {
  BusinessWindows(this._canOpen);

  final bool Function(String location) _canOpen;
  final _windows = <BusinessWindow>[];
  List<BusinessWindow> get windows => List.unmodifiable(_windows);

  bool open(String location, String title, {Object? extra}) {
    final uri = Uri.parse(location);
    if (uri.hasScheme || uri.hasAuthority || !uri.path.startsWith('/')) {
      throw ArgumentError.value(location, 'location');
    }
    // Re-read at the commit point: a previously rendered/awaited action may
    // outlive its permission snapshot.
    if (!_canOpen(location)) return false;
    _windows.add(
      BusinessWindow(location: location, title: title, extra: extra),
    );
    notifyListeners();
    return true;
  }

  void raise(BusinessWindow window) {
    if (_windows.isEmpty || identical(_windows.last, window)) return;
    if (!_windows.remove(window)) return;
    _windows.add(window);
    notifyListeners();
  }

  void close(BusinessWindow window) {
    if (_windows.remove(window)) notifyListeners();
  }

  void clear() {
    if (_windows.isEmpty) return;
    _windows.clear();
    notifyListeners();
  }
}

final businessWindowsProvider = Provider<BusinessWindows>((ref) {
  final windows = BusinessWindows(
    (location) => ref.read(businessLocationAllowedProvider(location)),
  );
  ref.listen(sensitiveReadBoundaryProvider, (before, after) {
    if (before != after) windows.clear();
  });
  ref.onDispose(windows.dispose);
  return windows;
});

/// Opens another view of the saved record/query. Drafts stay in their owner.
class BusinessWindowAction extends ConsumerWidget {
  const BusinessWindowAction({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = GoRouter.maybeOf(context);
    if (router == null) return const SizedBox.shrink();
    final location = router.state.uri.toString();
    final extra = router.state.extra;
    final boundary = ref.watch(sensitiveReadBoundaryProvider);
    if (!ref.watch(businessLocationAllowedProvider(location))) {
      return const SizedBox.shrink();
    }
    return UtenAppBarActionButton(
      key: const Key('business-open-window'),
      label: '新窗口',
      tooltip: '在独立窗口打开已保存资料，可拖动并排核对',
      onPressed: () {
        if (boundary != ref.read(sensitiveReadBoundaryProvider)) return;
        ref.read(businessWindowsProvider).open(location, title, extra: extra);
      },
    );
  }
}
