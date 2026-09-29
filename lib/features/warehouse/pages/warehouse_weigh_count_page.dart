// 独立称重计数页 (ADR-135 §6.4, review/product.md §2; /warehouse/weigh-count, stock:view)。
//
// 手机放在秤旁用: 先选货品, 下面就是单据里「称重计数」弹窗的同一份面板 (WeighCountPanel,
// 场景 standalone): 毛重 (可多次称重相加) - 皮重 x 件数 = 净重, 按单重折算件数
// (95% 区间 + 可靠度); 录入「本批抽样」可提高精度, 有称样权限 (到货入库 / 仓库单据编辑 /
// 单重管理 任一) 时点「保存抽样」存一条称样记录, 单重立即重算、越学越准。
// 本页不改任何库存: 只算数, 可选保存抽样。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/widgets/weigh_count_dialog.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';

class WarehouseWeighCountPage extends ConsumerStatefulWidget {
  const WarehouseWeighCountPage({super.key});

  @override
  ConsumerState<WarehouseWeighCountPage> createState() =>
      _WarehouseWeighCountPageState();
}

class _WarehouseWeighCountPageState
    extends ConsumerState<WarehouseWeighCountPage> {
  GoodsListItem? _goods;

  /// 换货品 / 保存抽样后推进, 面板整个重建 (从空白开始下一次称重)。
  int _round = 0;

  /// 最近一次保存抽样后服务端回的单重 (页面上方提示用)。
  WeightParams? _latest;

  String _titleOf(GoodsListItem g) => [
    g.name ?? '',
    g.code ?? '',
    g.colorName ?? '',
  ].where((s) => s.trim().isNotEmpty).join(' ');

  Future<void> _pickGoods() async {
    final picked = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.all,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _goods = picked;
      _latest = null;
      _round++;
    });
  }

  void _onSubmit(WeighCountResult result) {
    final sample = result.sample;
    if (sample == null || !sample.saved) return;
    final resolved = sample.detail?.resolved;
    setState(() {
      _latest = resolved;
      _round++;
    });
    final unit = resolved?.currentUnitWeightKg;
    context.appSuccess(
      unit == null
          ? '抽样已保存'
          : '抽样已保存, 当前单重 ${formatUnitWeight(unit, unitName: _goods?.unitName)} '
                '(${resolved!.effectiveTier.label})',
    );
  }

  void _openLearning(String goodsId) {
    final path = RouteName.stockItemDetail(goodsId, tab: 'weight');
    final allowed = locationAllowedFor(
      ref.read(currentPermissionsProvider),
      ref.read(isSuperAdminProvider),
      path,
    );
    if (!allowed) {
      context.appWarning('没有库存查看权限, 打不开单重学习');
      return;
    }
    context.push(path);
  }

  Widget _goodsCard(ThemeData theme) {
    final goods = _goods;
    return UtenCard(
      key: const Key('weigh-count-goods-card'),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: goods == null
                ? Text(
                    '先选要称的货品',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _titleOf(goods),
                        key: const Key('weigh-count-goods-title'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (goods.unitName?.trim().isNotEmpty == true)
                        Text(
                          '单位: ${goods.unitName}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            key: const Key('weigh-count-pick-goods'),
            type: goods == null
                ? UtenButtonType.primary
                : UtenButtonType.secondary,
            icon: Icons.search_rounded,
            onPressed: _pickGoods,
            child: Text(goods == null ? '选择货品' : '换一个'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goods = _goods;
    final canSample = ref.watch(weightSampleAllowedProvider);
    final latest = _latest;
    return Scaffold(
      appBar: UtenAppBar(
        title: '称重计数',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          if (goods != null)
            IconButton(
              key: const Key('weigh-count-open-learning'),
              icon: const Icon(Icons.scale_outlined),
              tooltip: '查看本货品的单重学习',
              onPressed: () => _openLearning(goods.id),
            ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            children: [
              _goodsCard(theme),
              if (!canSample) ...[
                const SizedBox(height: UtenSpacing.s12),
                const UtenInlineNotice(
                  key: Key('weigh-count-no-sample-permission'),
                  message: '你没有称样权限: 可以称重算数, 但抽样不会保存进单重学习',
                ),
              ],
              if (latest != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                UtenInlineNotice(
                  key: const Key('weigh-count-latest'),
                  message:
                      '已按刚保存的抽样重算: 当前单重 '
                      '${formatUnitWeight(latest.currentUnitWeightKg, unitName: goods?.unitName)} '
                      '(${latest.effectiveTier.label}; ${weightBasisText(latest)})',
                ),
              ],
              const SizedBox(height: UtenSpacing.s16),
              if (goods == null)
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s24),
                  child: Text(
                    '选好货品后: 把货放上秤输入毛重 (可以分几次称, 自动相加), 扣掉箱/袋皮重,'
                    ' 就按单重折算出大约多少件; 单重还没学准时, 数 10 件以上放秤录入本批抽样即可。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                UtenCard(
                  child: WeighCountPanel(
                    key: ValueKey('weigh-count-panel-${goods.id}-$_round'),
                    embedded: true,
                    request: WeighCountRequest(
                      mode: WeighCountContext.standalone,
                      goodsId: goods.id,
                      goodsTitle: _titleOf(goods),
                      baseUnitName: goods.unitName,
                      sampleRemark: '独立称重计数页抽样',
                      canSaveSample: canSample,
                    ),
                    onSubmit: _onSubmit,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
