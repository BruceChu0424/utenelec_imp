package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V587 货品主档「所属仓库」的迁移契约。
 *
 * <p>三条不能回退的口径：① 列可空、不带 DEFAULT 回填(存量货品没有这个归属)；
 * ② 外键先 NOT VALID 再 VALIDATE，且任何 ALTER TABLE 都排在 UPDATE 之前
 * (goods 带审计触发器，排队触发器事件之后 PostgreSQL 会拒绝 ALTER)；
 * ③ 迁移里**不得**出现名称对照回填——对照数据在 .gitignore 排除的
 * {@code product lists/} 里，回填只能走 legacy_migration 的导入脚本。
 */
class GoodsOwningWarehouseMigrationContractTest {

    private static final String MIGRATION =
            "db/migration/V587__goods_owning_warehouse.sql";

    @Test
    void v587AddsOneNullableWarehouseColumn() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("ALTER TABLE goods")
                .contains("ADD COLUMN IF NOT EXISTS owning_warehouse_id UUID")
                // 可空：不得 NOT NULL，也不得给存量行塞一个假的默认仓。
                .doesNotContain("owning_warehouse_id UUID NOT NULL")
                .doesNotContain("DEFAULT");
    }

    @Test
    void v587InstallsForeignKeyNotValidThenValidates() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("fk_goods_owning_warehouse")
                .contains("REFERENCES warehouses(id)")
                .contains("ON DELETE RESTRICT")
                .contains("NOT VALID")
                .contains("VALIDATE CONSTRAINT fk_goods_owning_warehouse");
        // 顺序：装外键必须排在校验之前(同一句 ADD ... NOT VALID 先出现)。
        assertThat(sql.indexOf("ADD CONSTRAINT fk_goods_owning_warehouse"))
                .isLessThan(sql.indexOf("VALIDATE CONSTRAINT fk_goods_owning_warehouse"));
    }

    @Test
    void v587CarriesNoNameKeyedBackfill() throws IOException {
        // 名称→仓库对照在 `product lists/` 三个 .xls 里，该目录被 .gitignore
        // 明确排除(真实业务数据绝不入库)。迁移一旦内嵌对照，等于把那批数据
        // 提交进仓库，同时让不同环境跑出不同结果。回填只走 legacy_migration。
        //
        // 断言只看**可执行 SQL**：注释里说明「源数据长什么样、五个取值是哪些」
        // 是正当文档，不是内嵌数据——第一版把整份原文拿来断言，结果被自己的
        // 背景注释绊倒(2026-09-15)。
        String executable = executableSql();

        assertThat(executable)
                .doesNotContain("UPDATE goods")
                .doesNotContain("INSERT INTO goods")
                .doesNotContain("INSERT INTO warehouses")
                // 任何形态的对照表/临时表都不许出现。
                .doesNotContain("CREATE TEMP")
                .doesNotContain("VALUES (")
                .doesNotContain("五金仓库")
                .doesNotContain("塑胶仓库")
                .doesNotContain("包材仓库");
    }

    @Test
    void v587IsColumnOnlyAndTouchesNoResetOrAuditTableAllowlist() throws IOException {
        String sql = resource(MIGRATION);

        // 只加列：没有新表 -> 审计触发器 allowlist 与清库 CLEAR/PRESERVE 名单都不用改。
        assertThat(sql)
                .doesNotContain("CREATE TABLE")
                .doesNotContain("INSERT INTO business_data_reset_policies")
                .doesNotContain("CREATE OR REPLACE FUNCTION business_data_reset")
                .doesNotContain("audit_trigger_coverage(")
                .doesNotContain("CREATE TRIGGER")
                .doesNotContain("CREATE RULE");
    }

    @Test
    void v587DocumentsTheColumnWithAPlainStringComment() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql).contains("COMMENT ON COLUMN goods.owning_warehouse_id IS");
        // PostgreSQL 的 COMMENT ON ... IS 只接受单个字符串字面量，不能拼接。
        assertThat(sql).doesNotContain("|| '");
    }

    /** 去掉整行 `--` 注释后的可执行 SQL(本迁移没有行尾注释，按整行剔除即可)。 */
    private static String executableSql() throws IOException {
        return resource(MIGRATION).lines()
                .filter(line -> !line.stripLeading().startsWith("--"))
                .reduce("", (acc, line) -> acc + line + "\n");
    }

    private static String resource(String path) throws IOException {
        try (var stream = GoodsOwningWarehouseMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
