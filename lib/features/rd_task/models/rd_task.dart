// 工程研发部任务模型（对应后端 RdTaskContracts.RdTaskRow / PageResponse）。
// 后端 status: OPEN/IN_PROGRESS/DONE/CANCELED；category: BOM/DESIGN/SAMPLE/TRIAL/ECN/OTHER。

class RdTaskRow {
  const RdTaskRow({
    required this.id,
    required this.taskNo,
    required this.title,
    required this.category,
    required this.status,
    required this.priority,
    required this.rowVersion,
    this.goodsId,
    this.goodsName,
    this.goodsCode,
    this.orderItemId,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceDocNo,
    this.assigneeEmployeeId,
    this.assigneeName,
    this.reporterEmployeeId,
    this.reporterName,
    this.dueDate,
    this.startedAt,
    this.completedAt,
    this.createdAt,
    this.closeNote,
    this.allowedActions = const [],
  });

  final String id;
  final String taskNo;
  final String title;
  final String category;
  final String status;
  final String priority;
  final int rowVersion;
  final String? goodsId;
  final String? goodsName;
  final String? goodsCode;
  final String? orderItemId;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? sourceDocNo;
  final String? assigneeEmployeeId;
  final String? assigneeName;
  final String? reporterEmployeeId;
  final String? reporterName;
  final String? dueDate;
  final String? startedAt;
  final String? completedAt;
  final String? createdAt;
  final String? closeNote;
  final List<String> allowedActions;

  bool get isOpen => status == 'OPEN' || status == 'IN_PROGRESS';

  factory RdTaskRow.fromJson(Map<String, dynamic> json) => RdTaskRow(
    id: json['id'] as String,
    taskNo: (json['taskNo'] ?? '') as String,
    title: (json['title'] ?? '') as String,
    category: (json['category'] ?? 'OTHER') as String,
    status: (json['status'] ?? 'OPEN') as String,
    priority: (json['priority'] ?? 'NORMAL') as String,
    rowVersion: (json['rowVersion'] as num?)?.toInt() ?? 1,
    goodsId: json['goodsId'] as String?,
    goodsName: json['goodsName'] as String?,
    goodsCode: json['goodsCode'] as String?,
    orderItemId: json['orderItemId'] as String?,
    sourceDocType: json['sourceDocType'] as String?,
    sourceDocId: json['sourceDocId'] as String?,
    sourceDocNo: json['sourceDocNo'] as String?,
    assigneeEmployeeId: json['assigneeEmployeeId'] as String?,
    assigneeName: json['assigneeName'] as String?,
    reporterEmployeeId: json['reporterEmployeeId'] as String?,
    reporterName: json['reporterName'] as String?,
    dueDate: json['dueDate'] as String?,
    startedAt: json['startedAt'] as String?,
    completedAt: json['completedAt'] as String?,
    createdAt: json['createdAt'] as String?,
    closeNote: json['closeNote'] as String?,
    allowedActions: (json['allowedActions'] as List? ?? const [])
        .map((e) => e as String)
        .toList(),
  );
}

/// 后端 PageResponse（rd_task 行分页）：{items, page, size, total, totalPages}。
class RdTaskData {
  const RdTaskData({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<RdTaskRow> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory RdTaskData.fromJson(Map<String, dynamic> json) => RdTaskData(
    items: (json['items'] as List? ?? const [])
        .map((e) => RdTaskRow.fromJson(e as Map<String, dynamic>))
        .toList(),
    page: (json['page'] as num?)?.toInt() ?? 1,
    size: (json['size'] as num?)?.toInt() ?? 20,
    total: (json['total'] as num?)?.toInt() ?? 0,
    totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
  );
}

String rdTaskStatusLabel(String status) {
  switch (status) {
    case 'OPEN':
      return '待处理';
    case 'IN_PROGRESS':
      return '进行中';
    case 'DONE':
      return '已完成';
    case 'CANCELED':
      return '已取消';
    default:
      return status;
  }
}

String rdTaskCategoryLabel(String category) {
  switch (category) {
    case 'BOM':
      return 'BOM维护';
    case 'DESIGN':
      return '设计';
    case 'SAMPLE':
      return '打样';
    case 'TRIAL':
      return '试产';
    case 'ECN':
      return 'ECN';
    case 'OTHER':
      return '其他';
    default:
      return category;
  }
}
