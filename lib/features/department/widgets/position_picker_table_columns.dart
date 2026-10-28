import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/position.dart';

/// 两种岗位选择器均加载完整部门候选；表头检索只改变展示，不改变确认规则。
List<MasterColumnDef<Position>> positionPickerTableColumns() => [
  MasterColumnDef<Position>(
    key: 'name',
    label: '岗位名称',
    width: 180,
    value: (position) => position.name,
  ),
  MasterColumnDef<Position>(
    key: 'code',
    label: '编号',
    width: 150,
    value: (position) => position.code,
  ),
  MasterColumnDef<Position>(
    key: 'level',
    label: '职级',
    width: 100,
    filterFromRows: true,
    facetSearchEnabled: true,
    value: (position) => position.level,
  ),
];
