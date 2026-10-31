import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_app_bar_action_button.dart';
import '../../components/feedback/uten_floating_window.dart';
import '../providers/sensitive_read_boundary_provider.dart';

class BusinessWindow {
  BusinessWindow({required this.location, required this.title, this.extra});
  final String location;
  final String title;
  final Object? extra;
  final navigatorKey = GlobalKey<NavigatorState>();
  final windowKey = GlobalKey<UtenFloatingWindowState>();
}

class BusinessWindows extends ChangeNotifier {
  final _windows = <BusinessWindow>[];
  List<BusinessWindow> get windows => List.unmodifiable(_windows);

  void open(String location, String title, {Object? extra}) {
    final uri = Uri.parse(location);
    if (uri.hasScheme || uri.hasAuthority || !uri.path.startsWith('/')) {
      throw ArgumentError.value(location, 'location');
    }
    _windows.add(
      BusinessWindow(location: location, title: title, extra: extra),
    );
    notifyListeners();
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
  final windows = BusinessWindows();
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
    return UtenAppBarActionButton(
      key: const Key('business-open-window'),
      label: '新窗口',
      tooltip: '在独立窗口打开已保存资料，可拖动并排核对',
      onPressed: () => ref
          .read(businessWindowsProvider)
          .open(router.state.uri.toString(), title, extra: router.state.extra),
    );
  }
}
