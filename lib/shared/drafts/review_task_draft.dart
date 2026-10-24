import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../core/network/api_exception.dart';
import '../../core/router/nav_helpers.dart';
import '../../core/ui/app_notification.dart';
import '../auth/permissions.dart';
import 'form_draft_catalog.dart';
import 'form_draft_mixin.dart';
import 'task_form_drafts.dart';

export 'form_draft_catalog.dart';
export 'form_draft_mixin.dart';
export 'form_draft_store.dart' show formDraftsProvider;
export 'task_form_drafts.dart' show resumeTaskFormDraft, taskDraftStatus;
export 'form_draft_category.dart' show FormDraftCategoryScope;
export 'task_form_draft_recovery_notice.dart';

/// Raw review inputs belong to one authoritative subject and reviewed version.
/// Claims remain live capabilities and are never restored from local storage.
mixin ReviewTaskDraftMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, FormDraftMixin<T> {
  FormDraftDescriptor get reviewDraftDescriptor;
  String get reviewDraftRoute;
  Map<String, dynamic> get reviewDraftSource;
  bool get reviewDraftEditable;
  bool canDispatchReviewCommand(String action);
  Map<String, dynamic> captureReviewInputs();
  void restoreReviewInputs(Map<String, dynamic> inputs);
  Future<void> reloadReviewSource();
  Future<bool> recoverReviewCommand(Map<String, dynamic> command);
  void closeRecoveredReview();

  bool _reviewDraftActive = false;
  Map<String, dynamic> _reviewDraftSource = {};
  Map<String, dynamic>? _reviewCommand;
  Map<String, dynamic>? _reloadInputs;
  Map<String, dynamic>? _loadingSnapshot;

  @override
  bool get formDraftEnabled => _reviewDraftActive;
  // Claims and permissions are refreshed capabilities, never restored inputs.
  // submitReviewCommand rechecks both after the durable checkpoint.
  @override
  bool get formDraftTracksPermissionChanges => false;
  @override
  FormDraftSpec get formDraftSpec =>
      reviewDraftDescriptor.spec(route: reviewDraftRoute);
  @override
  Map<String, dynamic> captureFormDraft() =>
      _loadingSnapshot ??
      {
        'source': _reviewDraftSource,
        'inputs': captureReviewInputs(),
        'command': _reviewCommand,
      };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final command = data['command'];
    _reviewCommand = command is Map ? Map<String, dynamic>.from(command) : null;
    if (jsonEncode(data['source']) != jsonEncode(_reviewDraftSource)) {
      throw const FormatException('草稿对应的审核内容或版本已变化，原输入保留，请先读取当前审核结果');
    }
    final inputs = data['inputs'];
    if (inputs is! Map) throw const FormatException('审核草稿输入不完整');
    restoreReviewInputs(Map<String, dynamic>.from(inputs));
  }

  @override
  Future<void> Function()? get formDraftReloadSource => reloadReviewSource;
  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenButton(
    key: const Key('review-task-draft-read-recovery'),
    type: UtenButtonType.secondary,
    onPressed: formDraftBusy ? null : _recoverDraft,
    child: const Text('读取当前审核结果'),
  );

  Future<void> prepareReviewReload() async {
    if (!_reviewDraftActive ||
        formDraftHasUnknownSubmission ||
        formDraftRestorationBlocked) {
      return;
    }
    protectReviewInputs();
    await saveFormDraftNow();
  }

  void protectReviewInputs() {
    if (!_reviewDraftActive) return;
    _reloadInputs ??= captureReviewInputs();
    _loadingSnapshot ??= captureFormDraft();
  }

  void cancelReviewReload() {
    _loadingSnapshot = null;
    _reloadInputs = null;
  }

  Future<void> bindReviewDraft() async {
    final resume = goRouterPageStateOrNull(
      context,
    )?.uri.queryParameters['draftId'];
    if (!_reviewDraftActive) {
      if (!reviewDraftEditable && resume == null) return;
      _reviewDraftActive = true;
      _loadingSnapshot = null;
      _reviewDraftSource = Map<String, dynamic>.from(reviewDraftSource);
      await initializeFormDraft();
      return;
    }
    if (formDraftHasUnknownSubmission) return;
    if (formDraftRestorationBlocked) {
      // The shared read-only source reload retains the stale draft and creates
      // a fresh baseline only after this GET has positively finished.
      _reviewDraftSource = Map<String, dynamic>.from(reviewDraftSource);
      _loadingSnapshot = null;
      _reloadInputs = null;
      return;
    }
    if (jsonEncode(_reviewDraftSource) == jsonEncode(reviewDraftSource)) {
      final inputs = _reloadInputs;
      if (inputs != null) restoreReviewInputs(inputs);
      _loadingSnapshot = null;
    } else {
      // Preserve the old snapshot instead of applying it to newer business facts.
      _reviewDraftSource = Map<String, dynamic>.from(reviewDraftSource);
      _reviewCommand = null;
      _loadingSnapshot = null;
      await resetFormDraftAfterSubmission(preserveCurrentDraft: true);
    }
    _reloadInputs = null;
  }

  Future<R> submitReviewCommand<R>(
    String action,
    Future<R> Function() send, {
    Map<String, dynamic>? request,
  }) async {
    if (!formDraftIdentityIsCurrent ||
        formDraftRestorationBlocked ||
        formDraftHasUnknownSubmission ||
        !canDispatchReviewCommand(action)) {
      throw StateError('原审核输入或提交结果尚未核对，不能再次提交');
    }
    _reviewCommand = {
      'action': action,
      'source': _reviewDraftSource,
      'request': request,
    };
    final route = reviewDraftRoute;
    final source = jsonEncode(_reviewDraftSource);
    final permissions = Set<String>.of(ref.read(currentPermissionsProvider));
    return runFormDraftSubmission(() {
      if (!formDraftIdentityIsCurrent ||
          route != reviewDraftRoute ||
          source != jsonEncode(reviewDraftSource) ||
          !setEquals(permissions, ref.read(currentPermissionsProvider)) ||
          !canDispatchReviewCommand(action)) {
        throw ApiException(
          'CONFLICT',
          '审核对象、版本、权限或认领在保存输入期间已变化，本次未提交',
          httpStatus: 409,
        );
      }
      return send();
    });
  }

  Future<void> finishReviewDraft({bool keepEditing = false}) async {
    if (keepEditing) {
      _reviewCommand = null;
      _reviewDraftSource = Map<String, dynamic>.from(reviewDraftSource);
      await resetFormDraftAfterSubmission();
    } else {
      await completeFormDraft();
    }
  }

  Future<void> _recoverDraft() async {
    final route = reviewDraftRoute;
    final subject = _reviewDraftSource['subjectId'];
    final recovery = formDraftRecoveryId;
    bool isCurrent() =>
        mounted &&
        formDraftIdentityIsCurrent &&
        route == reviewDraftRoute &&
        subject == _reviewDraftSource['subjectId'] &&
        recovery == formDraftRecoveryId;
    if (!isCurrent() || formDraftBusy) return;
    try {
      final command = _reviewCommand;
      final confirmed = command != null && await recoverReviewCommand(command);
      if (!isCurrent()) return;
      if (confirmed) {
        await finishReviewDraft();
        if (isCurrent()) {
          closeRecoveredReview();
        }
      } else {
        await reloadReviewSource();
        if (mounted && isCurrent()) {
          context.appInfo('已读取当前审核事实；原输入与未确认提交仍保留，不会自动审批或重放');
        }
      }
    } on ApiException catch (error) {
      if (mounted && isCurrent()) {
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted && isCurrent()) {
        context.appError('当前审核结果尚未核实，原草稿继续保留');
      }
    }
  }
}

List<FormDraft> reviewTaskDraftsFor(
  Iterable<FormDraft> drafts,
  FormDraftDescriptor descriptor,
  String subjectId,
) => taskDraftsFor(
  drafts,
  matches: (draft) {
    final source = draft.data['source'];
    return descriptor.groups(draft) &&
        source is Map &&
        source['subjectId'] == subjectId;
  },
);
