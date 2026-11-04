import '../../auth/read_owner_fence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../auth/permissions.dart';
import '../../drafts/form_draft_store.dart';
import 'weigh_count_dialog.dart';

class WeighCountRecoveryPage extends ConsumerStatefulWidget {
  const WeighCountRecoveryPage({super.key, this.draftId});
  final String? draftId;
  @override
  ConsumerState<WeighCountRecoveryPage> createState() => _State();
}

class _State extends ConsumerState<WeighCountRecoveryPage> {
  late bool Function() _ownerCurrent;
  @override
  void initState() {
    super.initState();
    _ownerCurrent = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) setState(() {});
    });
  }

  WeighCountResult? _result;
  @override
  Widget build(BuildContext context) {
    if (!_ownerCurrent()) return const Text('身份、权限或来源已变化，请重新进入原草稿。');
    final permissions = ref.watch(currentPermissionsProvider);
    final draft = ref
        .watch(formDraftsProvider)
        .where(
          (d) =>
              d.id == widget.draftId &&
              d.draftKind == 'weigh_count' &&
              permissions.contains(d.permission),
        )
        .firstOrNull;
    WeighCountRequest? request;
    if (draft?.data['request'] case final Map<Object?, Object?> raw) {
      try {
        request = WeighCountRequest.fromDraftJson(
          Map<String, dynamic>.from(raw),
        );
      } catch (_) {}
    }
    return Scaffold(
      appBar: const UtenAppBar(title: '称重算数量'),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: request == null
            ? const Text('原称重草稿不存在或当前权限已变化。')
            : _result != null
            ? SelectableText(
                '原请求已核对。净重：${_result!.netKgText} kg${_result!.qtyExact == null ? '' : '；数量：${_result!.qtyExact}'}。请返回原业务单按来源回填，本页不会自动修改原单。',
              )
            : WeighCountPanel(
                request: request,
                resumeDraftId: draft!.id,
                embedded: true,
                onSubmit: (value) => setState(() => _result = value),
              ),
      ),
    );
  }
}
