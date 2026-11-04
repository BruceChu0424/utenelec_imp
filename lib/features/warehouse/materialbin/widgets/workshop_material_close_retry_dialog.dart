import '../../../../shared/drafts/form_draft_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/auth/read_owner_fence.dart';
import '../../../../shared/drafts/form_draft_catalog.dart';
import '../../../../shared/drafts/form_draft_mixin.dart';
import '../../../../shared/providers/authenticated_scope_provider.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';

Future<WmCloseStatus?> showWmCloseRetryDialog(
  BuildContext context, {
  required String periodId,
  String? resumeDraftId,
  bool autoStart = true,
}) => showDialog<WmCloseStatus>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _Editor(periodId: periodId, resume: resumeDraftId, autoStart: autoStart),
);

class _Editor extends ConsumerStatefulWidget {
  const _Editor({required this.periodId, this.resume, required this.autoStart});
  final String periodId;
  final String? resume;
  final bool autoStart;
  @override
  ConsumerState<_Editor> createState() => _State();
}

class _State extends ConsumerState<_Editor> with FormDraftMixin<_Editor> {
  String _key = 'wm-close-retry-${const Uuid().v4()}';
  bool _busy = false, _ready = false;
  String? _error;
  late bool Function() _owner;
  bool get _current => mounted && _owner() && formDraftIdentityIsCurrent;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.workshopMaterialCloseRetry.spec();
  @override
  bool get formDraftEnabled => ref.read(authenticatedScopeProvider) != null;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  String? get formDraftResumeId => widget.resume;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'periodId': widget.periodId,
    'key': _key,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> value) async {
    if (value['periodId'] != widget.periodId ||
        value['key'] is! String ||
        (value['key'] as String).isEmpty) {
      throw StateError('原结算范围或请求编号缺失');
    }
    _key = value['key'] as String;
  }

  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (!_current) return;
      setState(() => _ready = true);
      if (widget.autoStart && widget.resume == null) await _send();
    });
  }

  Future<void> _send() async {
    if (!_current ||
        !_ready ||
        _busy ||
        !ref
            .read(currentPermissionsProvider)
            .contains(Perm.workshopMaterialCount)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = formDraftEnabled
          ? await captureFormDraftRequestScope()
          : null;
      Future<WmCloseStatus> send() => ref
          .read(workshopMaterialRepositoryProvider)
          .closeRetry(widget.periodId, idempotencyKey: _key);
      final result = await runFormDraftSubmission(
        () => scope == null ? send() : scope.run(send),
      );
      if (!_current) return;
      await completeFormDraft();
      if (mounted && _current) Navigator.pop(context, result);
    } catch (error) {
      if (_current) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : '本次结算请求结果待核对，原编号与精度已保留，请只重试原请求。',
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    UtenAlertDialog(
      title: const Text('车间物料结算'),
      content: Text(
        !_current
            ? '身份或来源已变化，原请求保留，请重新进入。'
            : _error ?? '按原期间办理结算；需要取舍时选择本次精度，原实际用量保留。',
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭，保留原请求'),
        ),
        UtenButton(
          onPressed: _current && _ready && !_busy ? _send : null,
          isLoading: _busy,
          child: Text(formDraftHasUnknownSubmission ? '核对原结算请求' : '继续本次结算'),
        ),
      ],
    ),
  );
}

class WmCloseRetryRecoveryPage extends ConsumerWidget {
  const WmCloseRetryRecoveryPage({super.key, this.draftId});
  final String? draftId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref
        .watch(formDraftsProvider)
        .where(
          (d) =>
              d.id == draftId &&
              d.draftKind == 'workshop_material_close_retry' &&
              d.permission == Perm.workshopMaterialCount,
        )
        .firstOrNull;
    final allowed = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.workshopMaterialCount);
    return Scaffold(
      appBar: const UtenAppBar(title: '车间物料结算'),
      body: Center(
        child: UtenButton(
          onPressed: !allowed || draft == null
              ? null
              : () async {
                  final id = draft.data['periodId'];
                  if (id is String) {
                    await showWmCloseRetryDialog(
                      context,
                      periodId: id,
                      resumeDraftId: draft.id,
                      autoStart: false,
                    );
                  }
                },
          child: const Text('恢复原结算请求'),
        ),
      ),
    );
  }
}
