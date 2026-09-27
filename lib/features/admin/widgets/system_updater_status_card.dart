import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../models/system_updater_status.dart';

/// Only renders server evidence. It does not poll or trigger an update check.
class SystemUpdaterStatusCard extends StatelessWidget {
  const SystemUpdaterStatusCard({
    super.key,
    required this.status,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final SystemUpdaterStatus? status;
  final bool loading;
  final String? error;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = status;
    final confirmed = error == null && !loading && current?.confirmed == true;
    final title = loading
        ? '正在读取服务器更新状态'
        : error != null
        ? '更新状态读取失败'
        : current == null
        ? '尚未获取服务器更新状态'
        : !current.available && current.checkedAt == null
        ? '更新调度尚未安装或未上报'
        : current.error?.isNotEmpty == true
        ? '服务器更新调度异常'
        : !current.available
        ? '更新调度尚未安装或未上报'
        : current.appliedIntervalDays != current.requestedIntervalDays
        ? '设置已保存，等待服务器应用'
        : current.stale
        ? '状态已过期或设置尚未确认'
        : '服务器已确认更新计划';
    final color = confirmed
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return Container(
      key: const ValueKey('system-updater-status'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                confirmed ? Icons.check_circle_outline : Icons.info_outline,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('system-updater-status-refresh'),
                tooltip: '刷新服务器更新状态',
                onPressed: loading ? null : onRefresh,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          if (error != null) Text(error!),
          if (current != null && !loading) ...[
            Text('已保存设置：${_interval(current.requestedIntervalDays)}'),
            Text('服务器已应用：${_interval(current.appliedIntervalDays)}'),
            Text('最后状态确认：${_date(current.checkedAt)}'),
            Text('上次自动检查：${_date(current.lastAttemptAt)}'),
            Text('上次检查结果：${_result(current.lastResult)}'),
            Text(
              '下次自动拉取：${confirmed && current.appliedIntervalDays == 0 ? '已关闭，仅手动更新' : _date(current.nextCheckAt, fallback: '尚未确认')}'
              '${!confirmed && current.nextCheckAt != null ? '（上次上报，当前未确认）' : ''}',
            ),
            if (current.error?.isNotEmpty == true)
              Text(
                current.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            '保存后需等待服务器确认。这里仅查看服务器状态，不会触发云端检查或下载。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _interval(int? days) => switch (days) {
    null => '尚未确认',
    0 => '仅手动更新',
    7 => '每周日 05:00（服务器当地时间）',
    _ => '每 $days 天 05:00（服务器当地时间）',
  };

  static String _date(String? value, {String fallback = '暂无记录'}) =>
      DisplayDateTime.beijing(value, fallback: fallback);

  static String _result(String result) => switch (result) {
    'NEVER' => '尚未执行自动检查',
    'RUNNING' => '正在检查',
    'SUCCESS' => '检查完成',
    'FAILED' => '检查失败',
    _ => '状态未知',
  };
}
