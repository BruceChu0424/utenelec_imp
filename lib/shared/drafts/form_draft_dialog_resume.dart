import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/nav_helpers.dart';
import '../../core/ui/action_feedback.dart';
import '../auth/permissions.dart';
import 'form_draft_catalog.dart';

export 'form_draft_catalog.dart';

String? dialogDraftId(BuildContext context, {String? kind}) {
  final parameters = dialogDraftParameters(context);
  if (kind != null && parameters['draftForm'] != kind) return null;
  return parameters['draftId'];
}

ValueKey<String>? dialogDraftPageKey(BuildContext context) =>
    goRouterPageStateOrNull(context)?.pageKey;

Map<String, String> dialogDraftParameters(BuildContext context) =>
    goRouterPageStateOrNull(context)?.uri.queryParameters ?? const {};

/// Reconstructs a new-record dialog from its owning page, including when only
/// query parameters change and GoRouter retains the page's existing State.
class FormDraftDialogResume extends ConsumerStatefulWidget {
  const FormDraftDialogResume({
    super.key,
    required this.descriptor,
    required this.onResume,
    required this.child,
    this.ready = true,
  });

  final FormDraftDescriptor descriptor;
  final Future<void> Function(Map<String, String> parameters) onResume;
  final Widget child;
  final bool ready;

  @override
  ConsumerState<FormDraftDialogResume> createState() =>
      _FormDraftDialogResumeState();
}

class _FormDraftDialogResumeState extends ConsumerState<FormDraftDialogResume> {
  String? _openedId;

  @override
  Widget build(BuildContext _) {
    final parameters = dialogDraftParameters(context);
    final id = parameters['draftId'];
    if (widget.ready &&
        id != null &&
        id != _openedId &&
        parameters['draftForm'] == widget.descriptor.dialogKind) {
      _openedId = id;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (!ref
            .read(currentPermissionsProvider)
            .contains(widget.descriptor.permission)) {
          context.appError('当前账号无权继续填写这份草稿');
          return;
        }
        try {
          await widget.onResume(parameters);
        } catch (error) {
          if (mounted) context.appApiError(error);
          return;
        }
        if (!mounted) return;
        final current = goRouterPageStateOrNull(context)?.uri;
        if (current == null || current.queryParameters['draftId'] != id) return;
        final remaining = Map<String, String>.of(current.queryParameters)
          ..remove('draftId')
          ..remove('draftForm')
          ..remove('categoryId')
          ..remove('parentId');
        context.replace(current.replace(queryParameters: remaining).toString());
      });
    }
    return widget.child;
  }
}
