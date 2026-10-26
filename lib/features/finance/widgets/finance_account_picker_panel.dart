import '../../../shared/search/keyword_search.dart';
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../providers/finance_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

/// 收款/付款账户侧滑选择面板（2026-09-14）：此前是平铺下拉，账户一多就难找。
/// 对齐全站侧滑面板范式：compact 底部抽屉、宽屏右侧滑入，支持编号/名称/币种搜索。
Future<String?> showFinanceAccountPickerPanel({
  required BuildContext context,
  required List<FinanceAccountReference> accounts,
  String? selectedId,
  String title = '选择收款账户',
}) => showUtenAdaptivePanel<String>(
  context: context,
  drawerWidth: 460,
  widthFraction: UtenPanelWidth.content,
  showDragHandle: true,
  builder: (_) => _FinanceAccountPickerPanel(
    accounts: accounts,
    selectedId: selectedId,
    title: title,
  ),
);

class _FinanceAccountPickerPanel extends StatefulWidget {
  const _FinanceAccountPickerPanel({
    required this.accounts,
    required this.selectedId,
    required this.title,
  });

  final List<FinanceAccountReference> accounts;
  final String? selectedId;
  final String title;

  @override
  State<_FinanceAccountPickerPanel> createState() =>
      _FinanceAccountPickerPanelState();
}

class _FinanceAccountPickerPanelState
    extends State<_FinanceAccountPickerPanel> {
  String _keyword = '';
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedId;
  }

  bool _isUsable(FinanceAccountReference account) =>
      account.id.isNotEmpty &&
      ((account.status ?? '').trim().isEmpty ||
          (account.status ?? '').trim() == '使用');

  FinanceAccountReference? get _selectedAccount => widget.accounts
      .where((account) => account.id == _selectedId && _isUsable(account))
      .firstOrNull;

  void _confirm() {
    if (!mounted) return;
    final account = _selectedAccount;
    if (account != null) Navigator.pop(context, account.id);
  }

  List<FinanceAccountReference> get _filtered {
    final keyword = _keyword.trim().toLowerCase();
    // 后端状态值为中文（使用/禁用）；字典端点返回全量，这里只列使用中账户。
    final usable = widget.accounts.where(_isUsable).toList();
    if (keyword.isEmpty) return usable;
    List<String?> fields(FinanceAccountReference account) => [
      account.name,
      account.code,
      account.currencyName,
      account.currencyCode,
    ];
    final result = usable
        .where((account) => matchesKeywordSearch(fields(account), keyword))
        .toList();
    final order = {
      for (var index = 0; index < usable.length; index++)
        usable[index].id: index,
    };
    result.sort((left, right) {
      final rankLeft = keywordSearchRankWithPrimary(
        [left.name],
        fields(left),
        keyword,
      )!;
      final rankRight = keywordSearchRankWithPrimary(
        [right.name],
        fields(right),
        keyword,
      )!;
      final rank = rankLeft.compareTo(rankRight);
      return rank != 0 ? rank : order[left.id]!.compareTo(order[right.id]!);
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = _filtered;
    final selectedAccount = _selectedAccount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenPanelHeader(
          title: widget.title,
          onClose: () => Navigator.pop(context),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: UtenSearchBar(
            hint: '搜索账户编号 / 名称 / 币种',
            // 纯本地过滤：输入即筛（onInputChanged 无防抖，组合期由组件挂起）。
            onInputChanged: (value) => setState(() => _keyword = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: accounts.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配的账户',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : MasterDataTableView<FinanceAccountReference>(
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: '账户名称',
                      width: 200,
                      value: (a) => a.name,
                      columnSearchEnabled: false,
                    ),
                    MasterColumnDef(
                      key: 'code',
                      label: '编号',
                      width: 130,
                      value: (a) => a.code,
                      columnSearchEnabled: false,
                    ),
                    MasterColumnDef(
                      key: 'currency',
                      label: '币种',
                      width: 140,
                      value: (a) => financeCurrencyDisplayLabel(
                        name: a.currencyName,
                        code: a.currencyCode,
                      ),
                      columnSearchEnabled: false,
                    ),
                    MasterColumnDef(
                      key: 'baseCurrency',
                      label: '本位币账户',
                      width: 110,
                      value: (a) => a.baseCurrency ? '是' : '否',
                      columnSearchEnabled: false,
                    ),
                  ],
                  items: accounts,
                  rowKeyOf: (a) => a.id,
                  rowWidgetKeyOf: (a) =>
                      ValueKey('finance-account-picker-${a.id}'),
                  singleTapRows: true,
                  isSelected: (a) => a.id == selectedAccount?.id,
                  onRowTap: (account) {
                    if (mounted &&
                        _isUsable(account) &&
                        widget.accounts.contains(account)) {
                      setState(() => _selectedId = account.id);
                    }
                  },
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  showFullscreenToggle: false,
                  showColumnChooser: false,
                  showPaginationControls: false,
                  enableTextSelection: false,
                ),
        ),
        UtenPickerConfirmBar(
          selectedCount: selectedAccount == null ? 0 : 1,
          selectedLabel: selectedAccount?.name ?? selectedAccount?.code,
          confirmButtonKey: const Key('finance-account-picker-confirm'),
          onConfirm: _confirm,
        ),
      ],
    );
  }
}
