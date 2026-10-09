// 委外单据状态徽章（草稿/已审/红冲；已审·立应付 / 已审·结案 复合标签）。
// ADR-169 后渲染走共享 UtenStatusBadge 深色实底档位（原 UtenDocStatusPill +
// 裸 Colors.green 浅底胶囊已收编）：0/1/-1 语义不动，经 docStatusBadgeType
// 映射 草稿=灰 / 已审=绿 / 红冲=红。
import 'package:flutter/material.dart';

import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/uten_status_badge.dart';
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
    return UtenStatusBadge(label: label, type: docStatusBadgeType(status));
  }
}
