import '../repositories/public_settings_repository.dart';

/// Human-readable consequences of the server's read-only archive capability.
abstract final class AuditRetentionPresentation {
  static const localReceiptPolicy =
      '本机设备回执单独保存，按同步期限清理，最多保留 300 条。'
      '清理本机回执不会改变服务器日志。修改月数仅调整留存时间，日志保护由服务器管理。';

  static String modeLabel(AuditArchivePurgeMode mode) => switch (mode) {
    AuditArchivePurgeMode.preserveUnclassified => '服务器历史日志保护已启用',
    AuditArchivePurgeMode.legacyPurge => '服务器仍按旧规则清理历史日志',
    AuditArchivePurgeMode.unknown => '历史日志保护状态尚未确认',
  };

  static String modeConsequence(AuditArchivePurgeMode mode) => switch (mode) {
    AuditArchivePurgeMode.preserveUnclassified =>
      '日志仍按设置归档，到期后继续保留，等待分类核查。请继续做好备份与恢复检查。',
    AuditArchivePurgeMode.legacyPurge =>
      '到期日志可能会永久删除。调整期限前请核对保留要求，并检查备份是否能够恢复。',
    AuditArchivePurgeMode.unknown => '暂时无法确认到期日志是否会自动删除，请核实服务器状态后再调整期限。',
  };

  static String configuredPeriods(int? hot, int? archive) {
    if (hot == null || archive == null || hot < 1 || archive < 0) {
      return '请输入有效月份。日志保护状态请看上方说明。';
    }
    final total = hot + archive;
    return '当前填写：在线 $hot 个月，随后归档保存 $archive 个月，合计 $total 个月。'
        '实际期限还需满足服务器的最低保留要求。';
  }

  static String confirmation(AuditArchivePurgeMode mode) =>
      '${modeLabel(mode)}。${modeConsequence(mode)}\n\n'
      '本次仅调整在线与归档月数。$localReceiptPolicy';

  static String historyHint(AuditArchivePurgeMode mode) =>
      '本页面显示在线日志。已归档的更早记录，请按历史调查或恢复流程查询。'
      '${modeLabel(mode)}。${modeConsequence(mode)}$localReceiptPolicy';
}
