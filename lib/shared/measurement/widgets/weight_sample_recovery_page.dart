import '../../auth/read_owner_fence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../auth/permissions.dart';
import '../../drafts/form_draft_store.dart';
import '../weight_params.dart';
import 'weight_sample_dialog.dart';

/// Purpose-bound draft host. It never reads inventory or expands read authority.
class WeightSampleRecoveryPage extends ConsumerStatefulWidget {
  const WeightSampleRecoveryPage({super.key, required this.draftId});
  final String? draftId;
  @override
  ConsumerState<WeightSampleRecoveryPage> createState() => _State();
}

class _State extends ConsumerState<WeightSampleRecoveryPage> {
  late bool Function() _ownerCurrent;
  @override
  void initState() {
    super.initState();
    _ownerCurrent = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) setState(() {});
    });
  }

  bool _opening = false;
  String? _error;
  Future<void> _open() async {
    if (_opening || !_ownerCurrent()) return;
    final draft = ref
        .read(formDraftsProvider)
        .where((d) => d.id == widget.draftId)
        .firstOrNull;
    final permissions = ref.read(currentPermissionsProvider);
    if (!ref.read(weightSampleAllowedProvider) ||
        draft == null ||
        draft.draftKind != 'weight_sample' ||
        !permissions.contains(draft.permission) ||
        Uri.tryParse(draft.route)?.path != '/measurement/weight-sample') {
      setState(() => _error = '这份称样草稿不可恢复，请检查当前账号、服务器和原称样权限。');
      return;
    }
    final data = draft.data;
    final goodsId = data['goodsId'], title = data['goodsTitle'];
    if (goodsId is! String || goodsId.isEmpty || title is! String) {
      setState(() => _error = '原称样范围缺失，原草稿已保留。');
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await showWeightSampleDialog(
        context,
        goodsId: goodsId,
        goodsTitle: title,
        baseUnitName: data['baseUnitName'] as String?,
        warehouseId: data['warehouseId'] as String?,
        supplierId: data['supplierId'] as String?,
        supplierName: data['supplierName'] as String?,
        resumeDraftId: draft.id,
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ownerCurrent()) return const Text('身份、权限或来源已变化，请重新进入原草稿。');
    final allowed = ref.watch(weightSampleAllowedProvider);
    ref.watch(formDraftsProvider);
    return Scaffold(
      appBar: const UtenAppBar(title: '称样校准'),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '恢复原称样输入；结果待核对时保留原请求编号。'),
            const SizedBox(height: 16),
            UtenButton(
              onPressed: allowed && !_opening ? _open : null,
              child: const Text('恢复称样草稿'),
            ),
            const SizedBox(height: 8),
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => popOrBackTo(context, defaultPath: '/dashboard'),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
