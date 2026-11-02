import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/feedback/uten_floating_window.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/layout/uten_page_window_scope.dart';
import '../../components/layout/uten_page_layout.dart';
import '../../components/layout/uten_split_handle.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/widgets/goods_bom_comparison_workspace.dart';
import '../../shared/drafts/form_draft_navigation.dart';
import '../../shared/windows/business_windows.dart';
import 'app_router.dart';
import 'page_resume_provider.dart';

/// Same pages, repositories, permissions and editors as the main application.
/// Each window owns navigation and resume signals; auth remains shared.
class BusinessWindowHost extends ConsumerStatefulWidget {
  const BusinessWindowHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<BusinessWindowHost> createState() => _BusinessWindowHostState();
}

class _BusinessWindowHostState extends ConsumerState<BusinessWindowHost> {
  final _handleKey = GlobalKey();
  List<BusinessWindow> _tiled = [];
  List<BusinessWindow> _comparisonPair = [];
  Size _size = Size.zero;
  double _ratio = .5;
  bool _comparing = false, _opening = false;
  static const _margin = UtenSpacing.s8;
  static const _gap = UtenSpacing.s24;

  bool get _twoColumns => _tiled.length == 2 && _size.width >= 640;
  double get _usableWidth => _size.width - _margin * 2 - _gap;
  double get _leftWidth =>
      (_usableWidth * _ratio).clamp(300.0, _usableWidth - 300);

  void _arrange() {
    if (!mounted || _tiled.isEmpty) return;
    if (_twoColumns) {
      final left = _leftWidth;
      _tiled[0].windowKey.currentState?.arrange(
        Rect.fromLTWH(_margin, _margin, left, _size.height - _margin * 2),
      );
      _tiled[1].windowKey.currentState?.arrange(
        Rect.fromLTWH(
          _margin + left + _gap,
          _margin,
          _usableWidth - left,
          _size.height - _margin * 2,
        ),
      );
      return;
    }
    final columns = (_size.width / 480).floor().clamp(1, _tiled.length);
    final rows = (_tiled.length / columns).ceil();
    final width =
        (_size.width - _margin * 2 - (columns - 1) * _margin) / columns;
    final height = (_size.height - _margin * 2 - (rows - 1) * _margin) / rows;
    for (var i = 0; i < _tiled.length; i++) {
      _tiled[i].windowKey.currentState?.arrange(
        Rect.fromLTWH(
          _margin + (i % columns) * (width + _margin),
          _margin + (i ~/ columns) * (height + _margin),
          width,
          height,
        ),
      );
    }
  }

  void _tile() {
    final all = ref.read(businessWindowsProvider).windows;
    setState(() {
      _tiled = [
        ..._tiled.where(all.contains),
        ...all.where((w) => !_tiled.contains(w)),
      ];
    });
    _arrange();
  }

  void _resize(double delta) {
    if (!_twoColumns) return;
    setState(
      () => _ratio =
          ((_leftWidth + delta).clamp(300.0, _usableWidth - 300)) /
          _usableWidth,
    );
    _arrange();
  }

  Future<void> _menu() async {
    final box = _handleKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          origin.dx,
          origin.dy + box.size.height / 2 + 24,
          box.size.width,
          0,
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'compare',
          child: ListTile(
            leading: Icon(Icons.difference_outlined),
            title: Text('对比左右 BOM'),
            subtitle: Text('查看差异、选择替换或替换全部组件'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'equal', child: Text('恢复左右各一半')),
      ],
    );
    if (!mounted) return;
    if (action == 'equal') {
      setState(() => _ratio = .5);
      _arrange();
    } else if (action == 'compare') {
      await _openComparison();
    }
  }

  Future<void> _chooseComparison(BusinessWindow window) async {
    final all = ref.read(businessWindowsProvider).windows;
    if (all.length < 2) return;
    final others = all.where((item) => !identical(item, window)).toList();
    final other = others.length == 1
        ? others.single
        : await showDialog<BusinessWindow>(
            context: context,
            builder: (context) => UtenAlertDialog(
              title: const Text('选择另一个对比窗口'),
              showCloseButton: true,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final candidate in others)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, candidate),
                      child: Text(
                        '窗口 ${all.indexOf(candidate) + 1} · ${candidate.title}',
                      ),
                    ),
                ],
              ),
            ),
          );
    if (mounted && other != null) await _openComparison([window, other]);
  }

  Future<void> _openComparison([List<BusinessWindow>? chosen]) async {
    if (_opening || (chosen ?? _tiled).length != 2) return;
    _opening = true;
    final pair = List<BusinessWindow>.of(chosen ?? _tiled);
    try {
      for (final window in pair) {
        final router = window.activeRouter;
        if (router == null ||
            !await FormDraftNavigation.confirmRouterExit(router)) {
          return;
        }
        if (!mounted ||
            !ref.read(businessWindowsProvider).windows.contains(window)) {
          return;
        }
      }
      if (mounted &&
          pair.every(ref.read(businessWindowsProvider).windows.contains)) {
        setState(() {
          _comparisonPair = pair;
          _comparing = true;
        });
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
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
          builder: (context, _) {
            final size = Size(area.maxWidth, area.maxHeight);
            final oldCount = _tiled.length;
            _tiled = _tiled.where(windows.windows.contains).toList();
            if (!_comparisonPair.every(windows.windows.contains)) {
              _comparing = false;
            }
            if (_size != size || oldCount != _tiled.length) {
              _size = size;
              WidgetsBinding.instance.addPostFrameCallback((_) => _arrange());
            }
            return Stack(
              children: [
                Positioned.fill(child: widget.child),
                for (final window in windows.windows)
                  Positioned.fill(
                    key: ObjectKey(window),
                    child: _WindowProviderScope(
                      child: _BusinessWindowView(
                        window: window,
                        onTile: _tile,
                        onManualLayout: () => setState(() => _tiled = []),
                        onCompare: windows.windows.length >= 2
                            ? () => _chooseComparison(window)
                            : null,
                      ),
                    ),
                  ),
                if (_twoColumns && !_comparing)
                  Positioned(
                    left: _margin + _leftWidth,
                    top: _margin,
                    bottom: _margin,
                    width: _gap,
                    child: UtenSplitHandle(
                      key: _handleKey,
                      width: _gap,
                      tooltip: '点击对比 BOM · 长按或拖动调整左右比例 · 双击均分',
                      onDelta: _resize,
                      onReset: () {
                        setState(() => _ratio = .5);
                        _arrange();
                      },
                      onTap: _menu,
                    ),
                  ),
                if (_comparing && _comparisonPair.length == 2)
                  Positioned.fill(
                    child: GoodsBomComparisonWorkspace(
                      leftWindow: _comparisonPair[0],
                      rightWindow: _comparisonPair[1],
                      initialRatio: _ratio,
                      onClose: () => setState(() => _comparing = false),
                    ),
                  ),
              ],
            );
          },
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
  const _BusinessWindowView({
    required this.window,
    required this.onTile,
    required this.onManualLayout,
    required this.onCompare,
  });
  final BusinessWindow window;
  final VoidCallback onTile;
  final VoidCallback onManualLayout;
  final VoidCallback? onCompare;

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
    widget.window.activeRouter = null;
    _information?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(businessWindowRouterProvider(widget.window));
    _information ??= WindowRouteInformation(router);
    widget.window.activeRouter = router;
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    return Listener(
      onPointerDown: (_) =>
          ref.read(businessWindowsProvider).raise(widget.window),
      child: Theme(
        data: theme.copyWith(
          scaffoldBackgroundColor: surface,
          canvasColor: surface,
          appBarTheme: theme.appBarTheme.copyWith(
            backgroundColor: surface,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        child: UtenFloatingWindow(
          backgroundColor: surface,
          key: widget.window.windowKey,
          headerTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onCompare != null)
                IconButton(
                  tooltip: '对比货品 BOM',
                  icon: const Icon(Icons.difference_outlined),
                  onPressed: widget.onCompare,
                ),
              IconButton(
                tooltip: '并排排列所有窗口',
                icon: const Icon(Icons.view_column_rounded),
                onPressed: widget.onTile,
              ),
            ],
          ),
          title: widget.window.title,
          initialSize: const Size(1040, 720),
          minSize: const Size(300, 240),
          collapseIcon: Icons.compare_rounded,
          onClose: () => _close(router),
          onManualLayout: widget.onManualLayout,
          body: UtenPageScrollRoleScope.local(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s12,
                UtenSpacing.s12,
              ),
              child: LayoutBuilder(
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
