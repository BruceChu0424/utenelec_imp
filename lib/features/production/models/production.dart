// 生产 model（Phase 4）：产线 + 产量

enum LineStatus { running, changeover, stopped }
enum Shift { day, night }

extension LineStatusX on LineStatus {
  String get label => switch (this) {
        LineStatus.running => '运行中',
        LineStatus.changeover => '换模中',
        LineStatus.stopped => '已停机',
      };
}

/// 流水线（看板卡片）
class ProductionLine {
  const ProductionLine({
    required this.id,
    required this.name,
    required this.order,
    required this.progress, // 0~1
    required this.takt, // 节拍 秒，null=未运行
    required this.outputToday,
    required this.status,
    required this.alertCount,
  });
  final String id;
  final String name;
  final String order; // 当前工单
  final double progress;
  final int? takt;
  final int outputToday;
  final LineStatus status;
  final int alertCount;
}

/// 产量记录
class ProductionOutput {
  const ProductionOutput({
    required this.id,
    required this.line,
    required this.product,
    required this.shift,
    required this.qualified,
    required this.unqualified,
    required this.date,
    required this.operatorName,
  });
  final String id;
  final String line;
  final String product;
  final Shift shift;
  final int qualified;
  final int unqualified;
  final DateTime date;
  final String operatorName;
}
