package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V451 契约：IQC 仓库确认入库成为库位学习来源。
 *
 * 背景：V431 的 warehouse_goods_place_preferences 只有产成品到货登记能写，
 * 采购/委外材料入库确认从不回写，「上次库位」永远带不出来。V451 只泛化
 * 来源维度（source_kind + 互斥引用），不新增表、不回填历史。
 */
class WarehouseGoodsPlacePreferenceIqcSourceMigrationContractTest {

    private static final Path V431 = Path.of(
            "src/main/resources/db/migration/V431__warehouse_goods_place_preferences.sql");
    private static final Path V446 = Path.of(
            "src/main/resources/db/migration/V446__iqc_release_warehouse_stock_in.sql");
    private static final Path V451 = Path.of(
            "src/main/resources/db/migration/"
                    + "V451__warehouse_goods_place_preference_iqc_source.sql");
    private static final Path SERVICE = Path.of(
            "src/main/java/com/uten/imp/features/warehouse/inbound/"
                    + "ProcurementIqcStockInService.java");

    @Test
    void v451GeneralizesPlacePreferenceSourceWithoutNewTableOrBackfill()
            throws Exception {
        String sql = Files.readString(V451).toLowerCase();

        assertThat(sql)
                .contains("alter table warehouse_goods_place_preferences")
                .contains("alter column source_registration_id drop not null")
                .contains("add column source_kind text not null default 'finished_arrival'")
                .contains("source_kind in ('finished_arrival', 'iqc_stock_in')")
                .contains("add column source_iqc_batch_id uuid")
                .contains("references procurement_iqc_stock_in_batches(id)")
                .contains("on delete restrict")
                .contains("warehouse_goods_place_preference_source_chk")
                .contains("source_kind = 'finished_arrival'")
                .contains("source_kind = 'iqc_stock_in'")
                .contains("create index idx_warehouse_goods_place_preference_iqc_batch")
                .doesNotContain("create table")
                .doesNotContain("insert into")
                .doesNotContain("update warehouse_goods_place_preferences");
    }

    @Test
    void v431BaselineAndV446BatchTableArePresentForTheNewReference()
            throws Exception {
        assertThat(Files.readString(V431).toLowerCase())
                .contains("create table warehouse_goods_place_preferences")
                .contains("source_registration_id   uuid not null")
                .contains("warehouse_goods_place_preference_dimension_uk");
        assertThat(Files.readString(V446).toLowerCase())
                .contains("create table procurement_iqc_stock_in_batches");
    }

    @Test
    void confirmLearnsPlacesWithBoundParametersOnly() throws Exception {
        String service = Files.readString(SERVICE);

        // 学习 upsert 命中 V431 的维度唯一约束；来源时间 + 来源 UUID 阻止旧来源覆盖新偏好。
        assertThat(service)
                .contains("rememberConfirmedPlaces(")
                .contains("learnWarehousePreference(")
                .contains("learnGoodsMasterPlace(")
                .contains("ON CONFLICT ON CONSTRAINT")
                .contains("warehouse_goods_place_preference_dimension_uk")
                .contains("source_registered_at,")
                .contains("COALESCE(")
                .contains("UPDATE goods")
                .contains("stock_place = :place");
        // 学习只发生在新鲜确认路径：幂等重放提前 return，不进入 rememberConfirmedPlaces。
        int replayReturn = service.indexOf("existing.id(), true,");
        int learnCall = service.indexOf("rememberConfirmedPlaces(locked");
        assertThat(replayReturn).isGreaterThan(0);
        assertThat(learnCall).isGreaterThan(0);
        assertThat(replayReturn).isLessThan(learnCall);
        // Mimosa 约束：外部输入一律参数绑定，原生 SQL 不做字符串拼接。
        long boundParams = service.lines()
                .filter(line -> line.contains(".setParameter("))
                .count();
        assertThat(boundParams).isGreaterThanOrEqualTo(30);
        assertThat(service).doesNotContain("\" + place + \"");
        assertThat(service).doesNotContain("\" + confirmedAt + \"");
    }
}
