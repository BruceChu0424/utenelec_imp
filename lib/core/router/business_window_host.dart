import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/feedback/uten_floating_window.dart';
import '../../components/layout/uten_page_window_scope.dart';
import '../../shared/drafts/form_draft_navigation.dart';
import '../../shared/windows/business_windows.dart';
import 'app_router.dart';
import 'page_resume_provider.dart';

/// Same pages, repositories, permissions and editors as the main application.
/// Each window owns navigation and resume signals; auth remains shared.
class BusinessWindowHost extends ConsumerWidget {
  const BusinessWindowHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.watch(businessWindowsProvider);
    return UtenPageWindowScope(
      actionBuilder: (context, title) {
        if (ModalRoute.of(context)?.settings is! Page) return null;
        final path = GoRouter.maybeOf(context)?.state.uri.path;
        if (path == null ||
            !(path == '/basicinfo' ||
                path.startsWith('/basicinfo/') ||
                path == '/production/where-used')) {
          return null;
        }
        return const BusinessWindowAction(title: '资料对照');
      },
      child: LayoutBuilder(
        builder: (context, area) => ListenableBuilder(
          listenable: windows,
          builder: (context, _) => Stack(
            children: [
              Positioned.fill(child: child),
              for (final window in windows.windows)
                Positioned.fill(
                  key: ObjectKey(window),
                  child: _WindowProviderScope(
                    child: _BusinessWindowView(
                      window: window,
                      onTile: () {
                        final all = windows.windows;
                        final columns = (area.maxWidth / 480).floor().clamp(
                          1,
                          all.length,
                        );
                        final rows = (all.length / columns).ceil();
                        final width = area.maxWidth / columns;
                        final height = area.maxHeight / rows;
                        for (var i = 0; i < all.length; i++) {
                          all[i].windowKey.currentState?.arrange(
                            Rect.fromLTWH(
                              (i % columns) * width + 4,
                              (i ~/ columns) * height + 4,
                              width - 8,
                              height - 8,
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Raising/adding another window must retain the existing provider override
/// identities, including its router, navigation history and editor ownership.
class _WindowProviderScope extends StatefulWidget {
  const _WindowProviderScope({required this.child});
  final Widget child;

  @override
  State<_WindowProviderScope> createState() => _WindowProviderScopeState();
}

class _WindowProviderScopeState extends State<_WindowProviderScope> {
  final _overrides = [
    pageResumeProvider.overrideWith((ref) => (location: '', tick: 0)),
  ];

  @override
  Widget build(BuildContext context) =>
      ProviderScope(overrides: _overrides, child: widget.child);
}

class _BusinessWindowView extends ConsumerStatefulWidget {
  const _BusinessWindowView({required this.window, required this.onTile});
  final BusinessWindow window;
  final VoidCallback onTile;

  @override
  ConsumerState<_BusinessWindowView> createState() =>
      _BusinessWindowViewState();
}

class _BusinessWindowViewState extends ConsumerState<_BusinessWindowView> {
  WindowRouteInformation? _information;
  bool _closing = false;

  Future<void> _close(GoRouter router) async {
    if (_closing) return;
    _closing = true;
    try {
      if (await FormDraftNavigation.confirmRouterExit(router) && mounted) {
        ref.read(businessWindowsProvider).close(widget.window);
      }
    } finally {
      _closing = false;
    }
  }

  @override
  void dispose() {
    _information?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(businessWindowRouterProvider(widget.window));
    _information ??= WindowRouteInformation(router);
    return Listener(
      onPointerDown: (_) =>
          ref.read(businessWindowsProvider).raise(widget.window),
      child: UtenFloatingWindow(
        key: widget.window.windowKey,
        headerTrailing: IconButton(
          tooltip: '并排排列所有窗口',
          icon: const Icon(Icons.view_column_rounded),
          onPressed: widget.onTile,
        ),
        title: widget.window.title,
        initialSize: const Size(1040, 720),
        minSize: const Size(300, 240),
        collapseIcon: Icons.compare_rounded,
        onClose: () => _close(router),
        body: LayoutBuilder(
          builder: (context, area) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: Size(area.maxWidth, area.maxHeight)),
            child: Router<Object>(
              routerDelegate: router.routerDelegate,
              routeInformationParser: router.routeInformationParser,
              routeInformationProvider: _information,
            ),
          ),
        ),
      ),
    );
  }
}

/// Isolates a nested router from browser URL/history and platform Back events.
/// go_router still receives the committed match list after pop/replace so a
/// permission/session refresh cannot replay a previously visited location.
class WindowRouteInformation extends RouteInformationProvider
    with ChangeNotifier {
  WindowRouteInformation(this.router) {
    _value = router.routeInformationProvider.value;
    router.routeInformationProvider.addListener(_changed);
    WidgetsBinding.instance.removeObserver(router.routeInformationProvider);
  }

  final GoRouter router;
  late RouteInformation _value;
  bool _reporting = false;

  @override
  RouteInformation get value => _value;

  void _changed() {
    if (_reporting) return;
    _value = router.routeInformationProvider.value;
    notifyListeners();
  }

  @override
  void routerReportsNewRouteInformation(
    RouteInformation routeInformation, {
    RouteInformationReportingType type = RouteInformationReportingType.none,
  }) {
    _reporting = true;
    try {
      router.restore(router.routerDelegate.currentConfiguration);
      _value = routeInformation;
    } finally {
      _reporting = false;
    }
  }

  @override
  void dispose() {
    router.routeInformationProvider.removeListener(_changed);
    super.dispose();
  }
}
