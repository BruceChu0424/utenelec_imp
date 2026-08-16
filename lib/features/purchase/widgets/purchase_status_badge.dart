// 采购单据状态徽章（草稿/已审/红冲）。渲染走共享 UtenDocStatusPill。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_doc_status_pill.dart';
import '../models/purchase_doc.dart';

class PurchaseStatusBadge extends StatelessWidget {
  const PurchaseStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
  });
  final int? status;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    return UtenDocStatusPill(
      label: closed && status == 1 ? '已审·结案' : purchaseStatusLabel(status),
      color: purchaseStatusColor(status, Theme.of(context)),
    );
  }
}
