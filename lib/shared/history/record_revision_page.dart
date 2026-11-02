import 'record_history_area.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_back_button.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../features/basic_data/widgets/master_inline_edit.dart';
import 'record_revision_body.dart';

class RecordRevisionPage extends StatefulWidget {
  const RecordRevisionPage({
    super.key,
    this.area = RecordHistoryArea.master,
    required this.entityType,
    required this.id,
    this.changeSignal,
  });
  final RecordHistoryArea area;
  final String entityType;
  final String id;
  final ValueNotifier<bool>? changeSignal;
  @override
  State<RecordRevisionPage> createState() => _RevisionPageState();
}

class _RevisionPageState extends State<RecordRevisionPage> {
  bool _changed = false;
  bool _busy = false;
  @override
  void didUpdateWidget(covariant RecordRevisionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.area != widget.area ||
        oldWidget.entityType != widget.entityType ||
        oldWidget.id != widget.id) {
      _changed = false;
      _busy = false;
    }
  }

  void _back() {
    if (_busy) return;
    if (context.canPop()) {
      context.pop(_changed);
    } else {
      context.go(
        Uri(
          path: widget.area.routePath,
          queryParameters: {'entityType': widget.entityType},
        ).toString(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: UtenAppBar(
      title: masterEditText(context, '修改版本详情', 'Revision details', '변경 버전 상세'),
      // 忙时空回调挡住返回（传 null 会回落默认返回行为）；不包 AbsorbPointer，
      // 让 UtenAppBar 认出 UtenBackButton 以收紧 leading 槽。
      leading: UtenBackButton(onPressed: _busy ? () {} : _back),
    ),
    body: SafeArea(
      child: UtenContentContainer.wide(
        child: RecordRevisionBody(
          key: ValueKey((widget.area, widget.entityType, widget.id)),
          area: widget.area,
          entityType: widget.entityType,
          id: widget.id,
          onChanged: () {
            _changed = true;
            widget.changeSignal?.value = true;
          },
          onBusyChanged: (busy) {
            if (mounted && _busy != busy) setState(() => _busy = busy);
          },
        ),
      ),
    ),
  );
}
