import 'package:flutter/material.dart';

import '../../../components/feedback/uten_inline_notice.dart';
import '../../../core/theme/uten_tokens.dart';

/// Shared guidance for manual outbounds and normal storage transfers.
class StockStorageTransferNotice extends StatelessWidget {
  const StockStorageTransferNotice({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: UtenSpacing.s8),
    child: UtenInlineNotice(
      message: '仓库之间搬货请使用「仓库调拨」：一次确认同时调出和调入，保留原订单、任务锁定和来源，到目标仓取货。',
    ),
  );
}
