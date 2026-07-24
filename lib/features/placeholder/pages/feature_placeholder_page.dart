// 功能占位页：权限点已种子化、页面尚未接入的模块统一由它承接路由。
// 风格对齐现有简单页面（UtenAppBar + UtenEmpty），不加花哨装饰。
//
// 用法见 app_router.dart 中 /finance/purchase 等四条路由。

import 'package:flutter/material.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';

class FeaturePlaceholderPage extends StatelessWidget {
  const FeaturePlaceholderPage({
    super.key,
    required this.title,
    this.icon = Icons.construction_outlined,
  });

  /// 页面标题（顶栏 + 空状态主文案）
  final String title;

  /// 空状态图标
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(title: title, showBackButton: true),
      body: Center(
        child: UtenEmpty(
          icon: icon,
          message: title,
          description: '该功能正在规划接入，权限已可配置。',
        ),
      ),
    );
  }
}
