// 委外单据状态徽章（草稿/已审/红冲；已审·立应付 / 已审·结案 复合标签）。
// 复用 subcontractStatusColor/Label（providers），渲染走共享 UtenDocStatusPill。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_doc_status_pill.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';

class SubcontractStatusBadge extends StatelessWidget {
  const SubcontractStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
    this.apPosted = false,
  });
  final int? status;
  final bool closed;
  final bool apPosted;

  @override
  Widget build(BuildContext context) {
    var label = subcontractStatusLabel(status);
    if (status == kSubcontractStatusApproved) {
      if (apPosted && closed) {
        label = '已审·立账·结案';
      } else if (apPosted) {
        label = '已审·已立账';
      } else if (closed) {
        label = '已审·结案';
      }
    }
    return UtenDocStatusPill(
      label: label,
      color: subcontractStatusColor(status, Theme.of(context)),
    );
  }
}
