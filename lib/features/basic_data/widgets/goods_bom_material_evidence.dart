import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/goods_bom_item.dart';
import 'master_data_table_view.dart';

String bomMaterialEvidenceSource(GoodsBomMaterialEvidence row) =>
    switch (row.source) {
      'PERIODIC_CHOICE' => '车间认料',
      'DISCOVERY_REQUEST' => '车间领料申请',
      'DISCOVERY_CONFIGURED' => '仓库确认用料',
      _ => '用料记录',
    };

String bomMaterialEvidenceNextStep(GoodsBomMaterialEvidence row) {
  if (row.source == 'PERIODIC_CHOICE') {
    return row.inBom
        ? '按 BOM 单重计算；盘点耗用见内料仓用量报表'
        : '已记住用哪种料；在组装信息补设计单重后进入 BOM 计算';
  }
  if (row.source == 'DISCOVERY_REQUEST') {
    return '等待仓库核对实际材料；申请量不作为真实耗用';
  }
  return row.inBom
      ? '实发、报工审核及余料核清后，按有效样本累计真实用量'
      : '实发、报工审核及余料核清后学习；人工配方或删除记录会限制自动加料';
}

/// 结构证据保留颜色和基本单位，不把申请、认料或仓库配置当成实际消耗。
class GoodsBomMaterialEvidenceTable extends StatelessWidget {
  const GoodsBomMaterialEvidenceTable({super.key, required this.rows});

  final List<GoodsBomMaterialEvidence> rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '选料保存后就会显示在这里。认料只确定材料种类；按单材料要完成实际领退料和报工核清后才学习用量。'
        '整批领料的多产品分摊耗用不能当作逐件实测单耗。',
      ),
      const SizedBox(height: UtenSpacing.s8),
      Expanded(
        child: MasterDataTableView<GoodsBomMaterialEvidence>(
          tableKey: 'goods.bom.material-evidence',
          items: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          emptyMessage: '暂无车间认料或领料选料记录',
          columns: [
            MasterColumnDef(
              key: 'code',
              label: '编号',
              width: 110,
              value: (row) => row.componentCode,
            ),
            MasterColumnDef(
              key: 'material',
              label: '物料',
              width: 180,
              value: (row) => row.componentName,
            ),
            MasterColumnDef(
              key: 'color',
              label: '颜色',
              width: 90,
              value: (row) => row.colorName ?? '—',
            ),
            MasterColumnDef(
              key: 'unit',
              label: '基本单位',
              width: 85,
              value: (row) => row.unitName ?? '—',
            ),
            const MasterColumnDef(
              key: 'source',
              label: '来源',
              width: 120,
              value: bomMaterialEvidenceSource,
            ),
            MasterColumnDef(
              key: 'structure',
              label: 'BOM 结构',
              width: 130,
              value: (row) => row.inBom ? '已在 BOM 中' : '尚未加入 BOM',
            ),
            MasterColumnDef(
              key: 'count',
              label: '来源记录数',
              width: 100,
              type: 'number',
              value: (row) => row.sourceCount.toString(),
            ),
            const MasterColumnDef(
              key: 'next',
              label: '学习与下一步',
              width: 470,
              value: bomMaterialEvidenceNextStep,
            ),
            MasterColumnDef(
              key: 'updated',
              label: '最近记录',
              width: 160,
              value: (row) => row.updatedAt == null
                  ? '—'
                  : ChinaDateTime.formatInstant(row.updatedAt!),
            ),
          ],
        ),
      ),
    ],
  );
}
