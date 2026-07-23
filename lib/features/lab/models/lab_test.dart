// 检测记录 model（Phase 4）
// 文档：docs/04-数据模型/实体字典.md#LabTest

class LabTest {
  const LabTest({
    required this.id,
    required this.sampleCode,
    required this.sampleName,
    required this.project,
    required this.result,
    required this.standard,
    required this.qualified,
    required this.testDate,
    required this.testerName,
    this.equipment,
    this.source,
    this.remark,
  });

  final String id;
  final String sampleCode; // 样品编号
  final String sampleName; // 样品名称
  final String project; // 检测项目
  final String result; // 检测结果
  final String standard; // 标准值
  final bool qualified; // 是否合格
  final DateTime testDate;
  final String testerName;
  final String? equipment;
  final String? source; // 批次/来源
  final String? remark;
}
