package com.uten.imp.features.master.goods;

/** One eligibility/source definition for preparation summaries and original detail readers. */
public final class PeriodicPreparationReadSql {
    private PeriodicPreparationReadSql() { }
    public static final String UNIVERSE = """
WITH recent AS (
    SELECT segment.product_goods_id AS goods_id, count(*) AS runs
    FROM production_execution_segments segment
    WHERE segment.workshop_department_id = :workshop AND segment.is_deleted = FALSE
      AND segment.created_at >= CAST(:windowAsOf AS timestamptz) - interval '12 months'
    GROUP BY segment.product_goods_id
), products AS (
    SELECT source.goods_id, sum(source.runs) AS runs
    FROM (SELECT goods_id, runs FROM recent
          UNION ALL
          SELECT owned.id, 0 FROM goods owned
          WHERE owned.owning_workshop_department_id = :workshop AND owned.is_deleted = FALSE) source
    GROUP BY source.goods_id
)
            """;
    public static final String ELIGIBLE = """
            FROM products JOIN goods product ON product.id=products.goods_id
            WHERE NOT product.is_deleted AND NOT product.auto_created AND product.issue_method<>'PERIODIC'
            """;
}
