// ADR-156 委外任务中心「齐套情况」弹窗。
//
// 委外价格每天不同：委外申请的直属物料够做至少一套才解锁生成委外订货单，订货数量
// 不能超过「这次可下单」。弹窗按申请明细逐条显示 委外件 / 剩余未下单 / 够做套数 /
// 可下单，并列出每种直属物料的 每套用量 / 需要 / 专属库存 / 已被占用 / 现在能用 /
// 还缺 / 够做套数，让委外人员看清「卡在哪种料」。数量全部由服务端算好，只读。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_application_kit.dart';
import '../repositories/subcontract_kit_repository.dart';
import 'subcontract_draw_status.dart';

/// 打开齐套情况弹窗；[applicationItemIds] = 这一行(一张委外申请)的申请明细，
/// [title] = 委外申请号(弹窗标题用，可空)。
Future<void> showSubcontractApplicationKitDialog(
  BuildContext context, {
  required SubcontractKitGateway gateway,
  required List<String> applicationItemIds,
  String? title,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SubcontractApplicationKitDialog(
    gateway: gateway,
    applicationItemIds: applicationItemIds,
    title: title,
  ),
);

class _SubcontractApplicationKitDialog extends StatefulWidget {
  const _SubcontractApplicationKitDialog({
    required this.gateway,
    required this.applicationItemIds,
    this.title,
  });

  final SubcontractKitGateway gateway;
  final List<String> applicationItemIds;
  final String? title;

  @override
  State<_SubcontractApplicationKitDialog> createState() =>
      _SubcontractApplicationKitDialogState();
}

class _SubcontractApplicationKitDialogState
    extends State<_SubcontractApplicationKitDialog> {
  List<SubcontractApplicationKit>? _kits;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kits = await Future.wait([
        for (final id in widget.applicationItemIds)
          widget.gateway.applicationKit(id),
      ]);
      if (!mounted) return;
      setState(() {
        _kits = kits;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '齐套情况加载失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final kits = _kits;
    final title = widget.title?.trim() ?? '';
    return Dialog(
      key: const Key('subcontract-kit-dialog'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1180,
          maxHeight: size.height * 0.88,
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.fact_check_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      title.isEmpty ? '齐套情况' : '齐套情况 · $title',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '委外价格每天不同，直属物料够做至少一套才解锁生成委外订货单；'
                '可下单 = 剩余未下单与现有物料够做的套数取小，订货数量超出会被拒绝。'
                '物料被别的委外单先占走时可下单会变少。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (_loading && kits == null)
                const Padding(
                  padding: EdgeInsets.all(UtenSpacing.s24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null && kits == null)
                // 图标 + 原话 + 「重试」整块放得下，不用先滚动才点得到重试。
                SizedBox(
                  height: 320,
                  child: UtenEmpty.error(
                    message: '无法加载齐套情况',
                    description: _error,
                    actionLabel: '重试',
                    onAction: _load,
                  ),
                )
              else if (kits != null)
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, kit) in kits.indexed) ...[
                          if (index > 0) const Divider(height: UtenSpacing.s24),
                          _KitSection(kit: kit),
                        ],
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: UtenSpacing.s12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  UtenButton(
                    type: UtenButtonType.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条申请明细：委外件 + 剩余未下单 / 够做套数 / 可下单 + 直属物料表。
class _KitSection extends StatelessWidget {
  const _KitSection({required this.kit});

  final SubcontractApplicationKit kit;

  String _qty(double value, String unit) =>
      '${subcontractDrawQty(value)}${unit.trim().isEmpty ? '' : ' ${unit.trim()}'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = !kit.bomMissing && kit.orderableQty <= 0;
    final partial =
        !kit.bomMissing &&
        kit.orderableQty > 0 &&
        kit.orderableQty < kit.openQty;
    final goods = [
      kit.goodsCode,
      kit.goodsName,
      kit.colorName,
    ].where((part) => part.trim().isNotEmpty).join(' ');
    final facts = <(String, String)>[
      ('剩余未下单', _qty(kit.openQty, kit.unitName)),
      ('够做套数', subcontractDrawQty(kit.kitQty)),
      (
        '可下单',
        locked
            ? '0(等物料齐套)'
            : partial
            ? '${_qty(kit.orderableQty, kit.unitName)}(可部分下单)'
            : _qty(kit.orderableQty, kit.unitName),
      ),
    ];
    return Column(
      key: ValueKey('subcontract-kit-item-${kit.applicationItemId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '委外件 ${goods.isEmpty ? '—' : goods}',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Wrap(
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s4,
          children: [
            for (final (label, value) in facts)
              Text.rich(
                TextSpan(
                  text: '$label ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  children: [
                    TextSpan(
                      text: value,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: label == '可下单' && locked
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (kit.bomMissing)
          Text(
            '委外件还没有 BOM，没有直属物料可算；请在任务中心点状态「通知研发完善」。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else
          _materialTable(kit),
      ],
    );
  }

  Widget _materialTable(
    SubcontractApplicationKit kit,
  ) => MasterDataTableView<SubcontractKitMaterial>(
    tableKey:
        'features.subcontract.widgets.subcontract_application_kit_dialog.KitSection._materialTable.1',
    key: ValueKey('subcontract-kit-materials-${kit.applicationItemId}'),
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    embedded: true,
    showFullscreenToggle: false,
    columns: [
      MasterColumnDef(
        key: 'goodsName',
        label: '物料名称',
        width: 180,
        value: (row) => _label(row.goodsName),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (row) => _label(row.goodsCode),
      ),
      MasterColumnDef(
        key: 'colorName',
        label: '颜色',
        width: 90,
        value: (row) => _label(row.colorName),
      ),
      MasterColumnDef(
        key: 'unitName',
        label: '单位',
        width: 70,
        value: (row) => _label(row.unitName),
      ),
      _qtyColumn('bomUnitQty', '每套用量', (row) => row.bomUnitQty),
      _qtyColumn('neededQty', '需要', (row) => row.neededQty),
      _qtyColumn('exactQty', '专属库存', (row) => row.exactQty),
      _qtyColumn('claimedQty', '已被占用', (row) => row.claimedQty),
      _qtyColumn('freeQty', '现在能用', (row) => row.freeQty),
      _qtyColumn('shortQty', '还缺', (row) => row.shortQty),
      _qtyColumn('kitQty', '够做套数', (row) => row.kitQty),
    ],
    items: kit.materials,
    emptyMessage: '这条申请没有需要发外的直属物料',
  );

  static MasterColumnDef<SubcontractKitMaterial> _qtyColumn(
    String key,
    String label,
    double Function(SubcontractKitMaterial row) qty,
  ) => MasterColumnDef(
    key: key,
    label: label,
    width: 96,
    type: 'number',
    value: (row) => subcontractDrawQty(qty(row)),
  );

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';
}
