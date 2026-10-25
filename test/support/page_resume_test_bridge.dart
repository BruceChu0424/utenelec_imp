import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';

/// Production app_router installs this same router-to-provider connection.
/// Place below ProviderScope and above MaterialApp.router in focused tests.
class PageResumeTestBridge extends ConsumerStatefulWidget {
  const PageResumeTestBridge({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<PageResumeTestBridge> createState() =>
      _PageResumeTestBridgeState();
}

class _PageResumeTestBridgeState extends ConsumerState<PageResumeTestBridge> {
  late VoidCallback _detach;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() => _detach = attachPageResume(
    widget.router,
    ref.read(pageResumeProvider.notifier),
  );

  @override
  void didUpdateWidget(PageResumeTestBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router == widget.router) return;
    _detach();
    _attach();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
