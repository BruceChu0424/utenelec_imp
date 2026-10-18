import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/position.dart';

/// 岗位选择只展示定位所需信息；统一搜索由选择器保留，不重复添加列搜索。
List<MasterColumnDef<Position>> positionPickerTableColumns() => [
  MasterColumnDef<Position>(
    key: 'name',
    label: '岗位名称',
    width: 180,
    columnSearchEnabled: false,
    value: (position) => position.name,
  ),
  MasterColumnDef<Position>(
    key: 'code',
    label: '编号',
    width: 150,
    columnSearchEnabled: false,
    value: (position) => position.code,
  ),
  MasterColumnDef<Position>(
    key: 'level',
    label: '职级',
    width: 100,
    columnSearchEnabled: false,
    value: (position) => position.level,
  ),
];
