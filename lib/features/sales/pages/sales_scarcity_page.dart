import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

/// V178 稀缺库存让单（主管仲裁页）：选货品 → 列出该货品全部生效预留（跨颜色，
/// 按优先级升序、创建时间升序）→ 对低优先级行"让单"释放现货预留回池。
/// 让单 = 复用既有释放原语 + 出货驳回同款状态回退；缺口自动回调度待排产并通知被让单销售。
class SalesScarcityPage extends ConsumerStatefulWidget {
  const SalesScarcityPage({
    super.key,
    this.initialGoodsId,
    this.initialColorId,
  });
  final String? initialGoodsId;
  final String? initialColorId;

  @override
  ConsumerState<SalesScarcityPage> createState() => _SalesScarcityPageState();
}

class _SalesScarcityPageState extends ConsumerState<SalesScarcityPage> {
  String? _goodsId;
  String? _goodsName;
  List<ScarceReservation>? _rows;
  bool _loading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _goodsId = widget.initialGoodsId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded();
      if (_goodsId != null) _load();
    });
  }

  Future<void> _pickGoods() async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    setState(() {
      _goodsId = g.id;
      _goodsName = g.name;
      _rows = null;
    });
    await _load();
  }

  Future<void> _load() async {
    final gid = _goodsId;
    if (gid == null) return;
    setState(() => _loading = true);
    final rows = await context.guardLoad(
      () => ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .scarceReservations(gid),
      errorFallback: '预留查询失败',
    );
    if (!mounted) return;
    setState(() {
      _rows = rows ?? const [];
      _loading = false;
    });
  }

  Future<void> _yield(ScarceReservation r) async {
    final reserved = r.reservedQty ?? 0;
    if (reserved <= 0) {
      context.appInfo('该行无生效预留可让');
      return;
    }
    final qtyCtrl = TextEditingController(text: reserved.toStringAsFixed(2));
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让单 · 释放现货预留'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${r.clientName ?? '—'} · ${r.orderNo ?? '—'}',
              style: Theme.of(ctx).textTheme.labelMedium,
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: qtyCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(hintText: '让单数量（0 < 数量 ≤ $reserved）'),
            ),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(hintText: '让单原因（必填）'),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认让单'),
          ),
        ],
      ),
    );
    final qty = double.tryParse(qtyCtrl.text.trim());
    final reason = reasonCtrl.text.trim();
    qtyCtrl.dispose();
    reasonCtrl.dispose();
    if (!mounted) return;
    if (ok != true) return;
    if (qty == null || qty <= 0 || qty > reserved) {
      context.appWarning('让单数量须 > 0 且 ≤ $reserved');
      return;
    }
    if (reason.isEmpty) {
      context.appWarning('让单须填原因');
      return;
    }
    setState(() => _busy = true);
    final d = await context.guardAction(
      () => ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .yieldReservation(
            r.orderItemId!,
            qty: qty,
            reason: reason,
            yielderOrderNo: r.orderNo,
          ),
      success: '已让单 ${qty.toStringAsFixed(2)}，库存已回池',
      errorFallback: '让单失败，请稍后重试',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (d != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '稀缺库存让单',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: SalesRoutePath.hub),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                      label: Text(_goodsName ?? '选择货品'),
                      onPressed: _busy ? null : _pickGoods,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_goodsId == null) {
      return const Center(child: Text('请先选择货品，查看谁在占用现货预留'));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    final rows = _rows ?? [];
    if (rows.isEmpty) {
      return const Center(child: Text('该货品暂无生效预留占用'));
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = rows[i];
        final overdue = (r.overdueDays ?? 0) > 0;
        return ListTile(
          title: Text('${r.clientName ?? '—'} · ${r.orderNo ?? '—'}'),
          subtitle: Text(
            '优先级 ${priorityLabel(r.priority)} · 预留 ${r.reservedQty?.toStringAsFixed(2) ?? '-'}'
            ' · 交货 ${r.deliverDate ?? '-'}'
            '${overdue ? ' · 已逾期 ${r.overdueDays} 天' : ''}',
          ),
          trailing: UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.swap_horiz_outlined,
            onPressed: _busy ? null : () => _yield(r),
            child: const Text('让单'),
          ),
        );
      },
    );
  }
}
