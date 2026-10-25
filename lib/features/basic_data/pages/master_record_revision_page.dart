import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/route_names.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_record_revision_body.dart';

class MasterRecordRevisionPage extends StatefulWidget {
  const MasterRecordRevisionPage({
    super.key,
    required this.entityType,
    required this.id,
    this.changeSignal,
  });
  final String entityType;
  final String id;
  final ValueNotifier<bool>? changeSignal;
  @override
  State<MasterRecordRevisionPage> createState() => _RevisionPageState();
}

class _RevisionPageState extends State<MasterRecordRevisionPage> {
  bool _changed = false;
  bool _busy = false;
  @override
  void didUpdateWidget(covariant MasterRecordRevisionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entityType != widget.entityType ||
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
          path: RouteName.basicinfoHistory,
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
        child: MasterRecordRevisionBody(
          key: ValueKey((widget.entityType, widget.id)),
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
