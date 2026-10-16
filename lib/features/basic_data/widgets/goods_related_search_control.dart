import 'package:flutter/material.dart';

/// Related terms are an explicit server query mode, never a page-local filter.
class GoodsRelatedSearchControl extends StatelessWidget {
  const GoodsRelatedSearchControl({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    key: const ValueKey('goods-search-related'),
    value: value,
    onChanged: (value) => onChanged(value ?? false),
    title: Text('显示相关结果（含备注/要求）', style: Theme.of(context).textTheme.bodySmall),
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
  );
}
