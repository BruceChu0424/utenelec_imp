// 业务时间固定为北京时间，保留原组件名以兼容设置页入口。
import 'package:flutter/material.dart';

class UtenTimeDisplaySwitcher extends StatelessWidget {
  const UtenTimeDisplaySwitcher({super.key});

  @override
  Widget build(BuildContext context) => const ListTile(
    title: Text('北京时间(UTC+8)'),
    subtitle: Text('所有业务时间统一显示，并标记(北京)'),
    contentPadding: EdgeInsets.symmetric(horizontal: 8),
    dense: true,
  );
}
