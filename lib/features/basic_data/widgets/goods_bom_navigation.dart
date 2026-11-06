import 'package:uten_imp/shared/paging/read_view_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../models/goods_detail_sequence.dart';
import '../repositories/goods_repository.dart';

final _categorySequenceActivityProvider = Provider.autoDispose
    .family<ReadViewActivity, String>((ref, _) {
      final activity = ReadViewActivity(onResume: ref.notifyListeners);
      ref.onDispose(activity.dispose);
      return activity;
    });

final _categorySequenceProvider = FutureProvider.autoDispose
    .family<GoodsDetailSequence, String>((ref, categoryId) async {
      final boundary = ref.watch(sensitiveReadBoundaryProvider);
      final repository = ref.watch(goodsRepositoryProvider);
      final activity = ref.watch(_categorySequenceActivityProvider(categoryId));
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final rows = await activity.runRead(
        () => !disposed && boundary == ref.read(sensitiveReadBoundaryProvider),
        () async {
          final gateway = repository is GoodsSummaryReadGateway
              ? repository as GoodsSummaryReadGateway
              : null;
          if (gateway?.supportsCompleteGoodsSummaries == true) {
            return (await gateway!.completeList(
              categoryId,
              sort: 'code',
              order: 'asc',
            )).items;
          }
          return loadCompletePagedSnapshot(
            loadPage: (page, size) => repository.list(
              categoryId,
              page: page,
              size: size,
              sort: 'code',
              order: 'asc',
            ),
            idOf: (row) => row.id,
            isCurrent: () =>
                !disposed &&
                boundary == ref.read(sensitiveReadBoundaryProvider),
          );
        },
      );
      return GoodsDetailSequence(rows.map((row) => row.id), label: '当前分类');
    });

class GoodsBomNavigation extends ConsumerWidget {
  const GoodsBomNavigation({
    super.key,
    required this.goodsId,
    required this.categoryId,
    required this.onSelected,
    required this.enabled,
    required this.builder,
    this.sequence,
  });

  final String goodsId;
  final String? categoryId;
  final GoodsDetailSequence? sequence;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final Widget Function(BuildContext context, List<Widget> actions) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplied = sequence;
    final category = categoryId;
    if (supplied == null && category != null) {
      ref.watch(_categorySequenceActivityProvider(category)).bindView(context);
    }
    final state = supplied != null || category == null
        ? AsyncData(supplied ?? GoodsDetailSequence([goodsId]))
        : ref.watch(_categorySequenceProvider(category));
    final data = state.value;
    final index = data?.ids.indexOf(goodsId) ?? -1;
    final scopeLabel = state.isLoading
        ? '正在读取浏览顺序…'
        : state.hasError
        ? '浏览顺序加载失败'
        : index < 0
        ? '当前货品已不在来源结果中'
        : '${data!.label} ${index + 1} / ${data.ids.length}';
    return builder(context, [
      UtenButton(
        key: const Key('goods-previous-bom'),
        closeBeforeAction: true,
        type: UtenButtonType.secondary,
        size: UtenButtonSize.large,
        onPressed: enabled && index > 0
            ? () => onSelected(data!.ids[index - 1])
            : null,
        child: const Text('上一个 BOM'),
      ),
      Tooltip(
        message: scopeLabel,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: UtenRadius.controlAll,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                data != null && index >= 0
                    ? '${index + 1} / ${data.ids.length}'
                    : scopeLabel,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ),
      if (state.hasError && category != null)
        TextButton(
          onPressed: () => ref.invalidate(_categorySequenceProvider(category)),
          child: const Text('重试'),
        ),
      UtenButton(
        key: const Key('goods-next-bom'),
        closeBeforeAction: true,
        type: UtenButtonType.secondary,
        size: UtenButtonSize.large,
        onPressed: enabled && index >= 0 && index < data!.ids.length - 1
            ? () => onSelected(data.ids[index + 1])
            : null,
        child: const Text('下一个 BOM'),
      ),
    ]);
  }
}
