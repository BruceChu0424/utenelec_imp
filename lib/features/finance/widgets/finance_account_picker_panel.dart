import 'package:flutter/material.dart';

import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../providers/finance_name_provider.dart';

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

  List<FinanceAccountReference> get _filtered {
    final keyword = _keyword.trim().toLowerCase();
    // 后端状态值为中文（使用/禁用）；字典端点返回全量，这里只列使用中账户。
    final usable = widget.accounts
        .where(
          (a) =>
              (a.status ?? '').trim() == '' || (a.status ?? '').trim() == '使用',
        )
        .toList();
    if (keyword.isEmpty) return usable;
    return usable
        .where(
          (a) =>
              (a.name ?? '').toLowerCase().contains(keyword) ||
              (a.code ?? '').toLowerCase().contains(keyword) ||
              (a.currencyName ?? '').toLowerCase().contains(keyword) ||
              (a.currencyCode ?? '').toLowerCase().contains(keyword),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            UtenSpacing.s8,
            UtenSpacing.s16,
            UtenSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: TextField(
            onChanged: (value) => setState(() => _keyword = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, size: 20),
              hintText: '搜索账户编号 / 名称 / 币种',
              isDense: true,
              border: OutlineInputBorder(),
            ),
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
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s8,
                    0,
                    UtenSpacing.s8,
                    UtenSpacing.s16,
                  ),
                  itemCount: accounts.length,
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final selected = account.id == widget.selectedId;
                    final currency = financeCurrencyDisplayLabel(
                      name: account.currencyName,
                      code: account.currencyCode,
                    );
                    return ListTile(
                      selected: selected,
                      dense: true,
                      title: Text(
                        [
                          if ((account.code ?? '').isNotEmpty) account.code!,
                          if ((account.name ?? '').isNotEmpty) account.name!,
                        ].join(' · '),
                      ),
                      subtitle: Text(
                        [
                          ?currency,
                          if (account.baseCurrency) '本位币账户',
                        ].join(' · '),
                      ),
                      trailing: selected
                          ? const Icon(Icons.check_circle_rounded)
                          : null,
                      onTap: () => Navigator.pop(context, account.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
