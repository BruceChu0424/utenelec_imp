package com.uten.imp.features.warehouse.materialbin.report;

/** 只读派生盘点来源；仅当前已提交版本参与，期初沿上一期同料同色盘点继承。 */
final class WorkshopMaterialCountBasisQuery {
    private WorkshopMaterialCountBasisQuery() {}

    static final String WITH = """
            WITH submitted_counts AS MATERIALIZED (
                SELECT period.id AS period_id, period.period_no, counted.id AS count_id
                FROM workshop_material_periods period
                LEFT JOIN workshop_material_counts counted
                  ON counted.period_id = period.id AND counted.status = 'SUBMITTED'
                WHERE period.bin_warehouse_id = :bin
            ), count_sources AS (
                SELECT counted.period_id, line.goods_id, line.color_id,
                       CASE WHEN bool_or(line.line_kind = 'CONTAINER' AND line.fill_level <> 'WEIGHED')
                            THEN 'ESTIMATED'
                            WHEN bool_or(line.line_kind = 'FULL_BAGS') AND bool_or(line.line_kind <> 'FULL_BAGS')
                            THEN 'WEIGHED_AND_BAGS'
                            WHEN bool_or(line.line_kind = 'FULL_BAGS') THEN 'BAG_COUNT'
                            ELSE 'WEIGHED' END AS basis
                FROM submitted_counts counted
                JOIN workshop_material_count_lines line ON line.count_id = counted.count_id
                WHERE line.goods_id IS NOT NULL
                GROUP BY counted.period_id, line.goods_id, line.color_id
            )
            """;

    static String columns(String report) {
        return columns(report,report+".goods_id",report+".color_id");
    }

    static String columns(String report, String goods, String color) {
        return """
                , CASE WHEN %1$s.period_no = 1 AND EXISTS (
                           SELECT 1 FROM workshop_material_count_adjustment_postings approved_opening
                           WHERE approved_opening.period_id=%1$s.period_id
                             AND approved_opening.goods_id=%2$s
                             AND approved_opening.color_id IS NOT DISTINCT FROM %3$s
                             AND approved_opening.kind='OPENING') THEN 'APPROVED_OPENING'
                       WHEN %1$s.period_no = 1 THEN 'EMPTY_START'
                       WHEN opening_source.basis IS NOT NULL THEN opening_source.basis
                       WHEN previous_count.count_id IS NOT NULL AND previous_line.id IS NULL THEN 'NO_BALANCE'
                       ELSE 'UNKNOWN' END AS opening_count_basis,
                  COALESCE(closing_source.basis, 'UNKNOWN') AS closing_count_basis
                """.formatted(report,goods,color);
    }

    static String joins(String report, String goods, String color) {
        return """
                 LEFT JOIN submitted_counts previous_count ON previous_count.period_no = %1$s.period_no - 1
                 LEFT JOIN workshop_material_period_lines previous_line
                   ON previous_line.period_id = previous_count.period_id AND previous_line.goods_id = %2$s
                  AND previous_line.color_id IS NOT DISTINCT FROM %3$s
                 LEFT JOIN count_sources opening_source
                   ON opening_source.period_id = previous_count.period_id AND opening_source.goods_id = %2$s
                  AND opening_source.color_id IS NOT DISTINCT FROM %3$s
                 LEFT JOIN count_sources closing_source
                   ON closing_source.period_id = %1$s.period_id AND closing_source.goods_id = %2$s
                  AND closing_source.color_id IS NOT DISTINCT FROM %3$s
                """.formatted(report, goods, color);
    }
}
