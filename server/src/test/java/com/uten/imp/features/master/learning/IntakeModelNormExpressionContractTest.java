package com.uten.imp.features.master.learning;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 型号召回的 SQL 必须与索引 idx_goods_model_norm 写成同一表达式, 否则 PostgreSQL 不走索引
 * (每次识别全表扫 3.5 万货品)。这里不连库, 直接比对迁移原文与查询常量。
 */
class IntakeModelNormExpressionContractTest {

    @Test
    void lookupQueryUsesExactlyTheIndexedExpression() {
        String migration = IntakeModelNormSqlSources.migrationText();
        String index = IntakeModelNormSqlSources.collapse(IntakeModelNormSqlSources.indexExpression(migration));
        String query = IntakeModelNormSqlSources.collapse(
                MasterIntakeLookupAdapter.MODEL_NORM_EXPR.replace("g.model", "model"));

        assertThat(query).isEqualTo(index);
    }

    @Test
    void seedExpressionIsTheSameNormalizationAppliedToTheTrimmedCustomerModel() {
        String migration = IntakeModelNormSqlSources.migrationText();
        String seed = IntakeModelNormSqlSources.collapse(IntakeModelNormSqlSources.seedExpression(migration));
        String index = IntakeModelNormSqlSources.collapse(IntakeModelNormSqlSources.indexExpression(migration))
                .replace("coalesce(model, '')", "btrim(CAST(? AS text))");

        assertThat(seed).isEqualTo(index);
    }
}
