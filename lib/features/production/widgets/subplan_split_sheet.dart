// 「按车间拆分生成子计划」面板——可定制化拆分（老流程复刻）。
//
// 列出父计划 MRP 里的自制件（本身有 BOM 的组件），每行可：
//   ① 勾选（默认全选，可只拆一部分——"有时候不是全部加载"）
//   ② 改本次排产量（默认=净需求，≤净需求，服务端另有防超产硬校验）
//   ③ 选归属车间（默认父计划车间；生产部 6 个种子车间下拉）
// 确认后按车间分组、每个车间生成一张草稿子计划（POST /plans/{id}/mrp/generate-subplans）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/models/department_node.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';

/// 弹拆分面板；返回请求行（null=取消）。调用方负责 POST 与结果展示。
Future<List<Map<String, dynamic>>?> showSubplanSplitSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<MrpRow> selfMadeRows,
  String? defaultDepartmentId,
  String? defaultWorkshopName,
}) {
  final sheet = _SplitSheet(
    rows: selfMadeRows,
    defaultDepartmentId: defaultDepartmentId,
    defaultWorkshopName: defaultWorkshopName,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.9,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<List<Map<String, dynamic>>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 860, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _LineState {
  _LineState(this.row, String defaultQty)
    : qtyCtrl = TextEditingController(text: defaultQty);
  final MrpRow row;
  bool checked = true;
  final TextEditingController qtyCtrl;
  String? departmentId;
  String? workshopName;
}

class _SplitSheet extends ConsumerStatefulWidget {
  const _SplitSheet({
    required this.rows,
    this.defaultDepartmentId,
    this.defaultWorkshopName,
  });

  final List<MrpRow> rows;
  final String? defaultDepartmentId;
  final String? defaultWorkshopName;

  @override
  ConsumerState<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends ConsumerState<_SplitSheet> {
  late final List<_LineState> _lines;

  @override
  void initState() {
    super.initState();
    _lines = [
      for (final r in widget.rows)
        _LineState(r, _fmt(r.net))
          ..departmentId = widget.defaultDepartmentId
          ..workshopName = widget.defaultWorkshopName,
    ];
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.qtyCtrl.dispose();
    }
    super.dispose();
  }

  String _fmt(double? v) => v == null
      ? ''
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  /// 已选行按车间的分组数（决定生成几张子计划）。
  int get _groupCount {
    final keys = <String?>{};
    for (final l in _lines) {
      if (l.checked) keys.add(l.departmentId);
    }
    return keys.length;
  }

  void _confirm() {
    final items = <Map<String, dynamic>>[];
    for (final l in _lines) {
      if (!l.checked) continue;
      final qty = double.tryParse(l.qtyCtrl.text);
      final net = l.row.net ?? 0;
      if (qty == null || qty <= 0) {
        context.appError('${l.row.goodsName ?? l.row.goodsCode} 的排产量无效');
        return;
      }
      if (qty > net + 1e-6) {
        context.appError(
          '${l.row.goodsName ?? l.row.goodsCode} 超过净需求 ${_fmt(net)}',
        );
        return;
      }
      items.add({
        'goodsId': l.row.goodsId,
        if (l.row.colorId != null) 'colorId': l.row.colorId,
        if (l.row.unitId != null) 'unitId': l.row.unitId,
        'qty': qty,
        if (l.departmentId != null) 'departmentId': l.departmentId,
        if (l.workshopName != null && l.workshopName!.isNotEmpty)
          'workshopName': l.workshopName,
      });
    }
    if (items.isEmpty) {
      context.appError('请至少勾选一行');
      return;
    }
    Navigator.of(context).pop(items);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workshops = ref.watch(productionWorkshopTreeProvider).valueOrNull;
    final checkedCount = _lines.where((l) => l.checked).length;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s8,
                UtenSpacing.s12,
                UtenSpacing.s4,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '按车间拆分生成子计划',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                0,
                UtenSpacing.s16,
                UtenSpacing.s8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '勾选要拆的自制件、改数量、选车间——按车间分组，每个车间生成一张草稿子计划',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                itemCount: _lines.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: UtenSpacing.s8),
                itemBuilder: (_, i) => _lineCard(theme, _lines[i], workshops),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '已选 $checkedCount 行 · 分 $_groupCount 个车间',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s16),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  UtenButton(
                    icon: Icons.splitscreen_rounded,
                    onPressed: checkedCount == 0 ? null : _confirm,
                    child: Text('生成 $_groupCount 张子计划'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineCard(
    ThemeData theme,
    _LineState l,
    List<DepartmentNode>? workshops,
  ) {
    final r = l.row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: l.checked,
              onChanged: (v) => setState(() => l.checked = v ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${r.goodsName ?? r.goodsCode ?? '—'}'
                    '${r.spec != null && r.spec!.isNotEmpty ? ' · ${r.spec}' : ''}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '毛需求 ${_fmt(r.gross)} · 库存 ${_fmt(r.onhand)} · '
                    '在途 ${_fmt(r.openPo)} · 净需求 ${_fmt(r.net)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Row(
                    children: [
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: l.qtyCtrl,
                          enabled: l.checked,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: '本次排产（≤${_fmt(r.net)}）',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: l.departmentId ?? '',
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: '归属车间',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('未指定车间'),
                            ),
                            for (final w
                                in workshops ?? const <DepartmentNode>[])
                              DropdownMenuItem(
                                value: w.id,
                                child: Text(w.name),
                              ),
                          ],
                          onChanged: l.checked
                              ? (v) => setState(() {
                                  if (v == null || v.isEmpty) {
                                    l.departmentId = null;
                                    l.workshopName = null;
                                  } else {
                                    l.departmentId = v;
                                    l.workshopName =
                                        (workshops ?? const <DepartmentNode>[])
                                            .where((w) => w.id == v)
                                            .map((w) => w.name)
                                            .firstOrNull;
                                  }
                                })
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
