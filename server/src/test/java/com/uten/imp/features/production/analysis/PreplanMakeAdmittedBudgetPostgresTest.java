package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Runs the final shared SQL budget; full origin/receipt guards have separate end-to-end coverage. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PreplanMakeAdmittedBudgetPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private final UUID analysis=UUID.randomUUID(),material=UUID.randomUUID(),child=UUID.randomUUID();

    @BeforeAll static void schema() throws Exception {
        PG.start();
        db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        db.execute("""
            CREATE TABLE production_material_analysis_items(id uuid PRIMARY KEY,analysis_id uuid,
              parent_analysis_material_id uuid,source_type text,requested_qty numeric,is_deleted boolean DEFAULT false);
            CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY,analysis_id uuid,
              required_qty numeric,active boolean DEFAULT true);
            CREATE TABLE preplan_reallocation_make_supplements(child_analysis_item_id uuid,
              source_analysis_material_id uuid,qty numeric);
            """);
        String migration=Files.readString(Path.of("src/main/resources/db/migration/V568__preplan_reallocation_make_supplements.sql"));
        int start=migration.indexOf("CREATE FUNCTION fn_preplan_direct_make_admitted_qty(");
        assertThat(start).isGreaterThanOrEqualTo(0);
        db.execute(migration.substring(start,migration.indexOf("$$;",start)+3));
    }
    @BeforeEach void seed() {
        db.execute("TRUNCATE production_material_analysis_items,production_material_analysis_materials,preplan_reallocation_make_supplements");
        db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,required_qty) VALUES (?,?,10)",material,analysis);
        db.update("INSERT INTO production_material_analysis_items(id,analysis_id,parent_analysis_material_id,source_type,requested_qty) VALUES (?,?,?,'MAKE_COMPONENT',14)",child,analysis,material);
    }
    @Test void previousTenAndFourAttributedReplacementUnitsHaveFourteenAdmittedOutput() {
        assertThat(budget(child,material)).isEqualByComparingTo("10");
        supplement();
        assertThat(budget(child,material)).isEqualByComparingTo("14");
        db.update("INSERT INTO preplan_reallocation_make_supplements VALUES (?,?,100)",child,UUID.randomUUID());
        assertThat(budget(child,material)).isEqualByComparingTo("14");
        db.update("UPDATE production_material_analysis_items SET requested_qty=13 WHERE id=?",child);
        assertThat(budget(child,material)).isEqualByComparingTo("13");
        assertThat(db.queryForObject("SELECT required_qty FROM production_material_analysis_materials WHERE id=?",BigDecimal.class,material)).isEqualByComparingTo("10");
    }
    @Test void missingOrForeignSourceReturnsZeroRatherThanNull() {
        supplement();
        assertThat(budget(UUID.randomUUID(),material)).isEqualByComparingTo("0");
        assertThat(budget(child,UUID.randomUUID())).isEqualByComparingTo("0");
        db.update("UPDATE production_material_analysis_items SET analysis_id=? WHERE id=?",UUID.randomUUID(),child);
        assertThat(budget(child,material)).isEqualByComparingTo("0");
    }
    @Test void retiredMaterialDoesNotRewritePreviouslyAdmittedOutputHistory() {
        supplement();
        db.update("UPDATE production_material_analysis_materials SET active=false WHERE id=?",material);
        assertThat(budget(child,material)).isEqualByComparingTo("14");
    }
    private void supplement() { db.update("INSERT INTO preplan_reallocation_make_supplements VALUES (?,?,4)",child,material); }
    private BigDecimal budget(UUID childId,UUID materialId) {
        return db.queryForObject("SELECT fn_preplan_direct_make_admitted_qty(?,?)",BigDecimal.class,childId,materialId);
    }
    @AfterAll static void stop() { PG.stop(); }
}
