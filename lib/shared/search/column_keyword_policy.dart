/// Ordinary text identities support column keywords. Dates, measures, choices
/// and actions keep their business-specific controls. Explicit overrides are
/// for columns whose business meaning differs from the default convention.
bool supportsColumnKeywordSearch({
  required String key,
  required String label,
  String type = 'text',
  bool? override,
}) {
  if (override != null) return override;
  if (type != 'text') return false;
  if (RegExp(
    r'日期|时间|交期|交货期|到期|有效期|数量|金额|余额|单价|价格|税率|汇率|折扣|重量|单重|密度|件数|人数|天数|合计|比率|比例|损耗率|完成率|进度|状态|异常|是否|操作|序号|排序|币种|货币|单位|类型|阶段|性别|版本|次数|优先级',
  ).hasMatch(label)) {
    return false;
  }
  return !RegExp(
    r'(?:date|time|timestamp|qty|quantity|amount|price|weight|rate|percent|status|state|stage|type|origin|gender|approval|action|sequence|sortorder|currency|unitid|unitlegacyid|boolean|count|enabled|closed)$',
    caseSensitive: false,
  ).hasMatch(key);
}
