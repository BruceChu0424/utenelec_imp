package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SourceWarehouseOption;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.access.prepost.PreAuthorize;

import java.sql.SQLException;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * ADR-147 发料来源仓滑窗的仓库层级 (真实迁移后的库): 先主仓、再子仓, 只有启用中的良品子仓能选;
 * 不良品仓列出但不能选, 内料仓、已删、不参与核算的不列; 只返回元数据 (不含库存、位置、备注)。
 * 开通设置或发料权限都能读, 只有查看权限的人读不到。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialSourceWarehousesPostgresTest {

    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static JdbcTemplate db;

    @BeforeAll
    static void open() throws SQLException {
        database = MigratedSchemaBaseline.openDatabase("workshop_source_warehouses");
        db = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(),
                database.getPassword()));
    }

    @AfterAll
    static void close() throws SQLException {
        if (database != null) database.close();
    }

    @Test
    void listsTheHierarchyButOnlyActiveGoodLeavesAreSelectable() {
        UUID root = warehouse("001", "仓库(14年版)", null, false);
        UUID plastic = warehouse("XW01", "塑胶仓库", root, false);
        UUID defective = warehouse("C0401", "成品不良品仓", root, true);
        UUID disabled = warehouse("OFF", "停用子仓", root, false);
        UUID deleted = warehouse("DEL", "已删子仓", root, false);
        UUID nonAccountable = warehouse("NON", "不核算子仓", root, false);
        db.update("UPDATE warehouses SET status='禁用' WHERE id=?", disabled);
        db.update("UPDATE warehouses SET is_deleted=true WHERE id=?", deleted);
        db.update("UPDATE warehouses SET is_accountable=false WHERE id=?", nonAccountable);

        var rows = service(WorkshopMaterialPermissions.SETUP).sourceWarehouses();
        assertThat(rows).extracting(SourceWarehouseOption::id)
                .contains(root, plastic, defective, disabled)
                .doesNotContain(deleted, nonAccountable);
        assertThat(rows.getFirst().id()).as("主仓在最前").isEqualTo(root);
        assertThat(rows).filteredOn(SourceWarehouseOption::selectable).extracting(SourceWarehouseOption::id)
                .containsExactly(plastic);
        assertThat(rows).filteredOn(row -> row.id().equals(defective)).singleElement()
                .satisfies(row -> assertThat(row.defective()).isTrue());
        assertThat(rows).filteredOn(row -> row.id().equals(plastic)).singleElement()
                .satisfies(row -> assertThat(row.parentId()).isEqualTo(root));
        assertThat(SourceWarehouseOption.class.getRecordComponents()).extracting(component -> component.getName())
                .containsExactly("id", "code", "name", "parentId", "status", "defective", "selectable",
                        "selectableDefective");

        // 发料人也要选出库仓; 只有查看权限的人读不到。
        assertThat(service(WorkshopMaterialPermissions.ISSUE).sourceWarehouses()).isNotEmpty();
        for (String permission : List.of("warehouse:view", WorkshopMaterialPermissions.VIEW, "stock:view")) {
            assertThatThrownBy(() -> service(permission).sourceWarehouses()).isInstanceOf(ApiException.class)
                    .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        }
    }

    @Test
    void controllerGrantsSetupOrIssueOnly() throws Exception {
        assertThat(WorkshopMaterialSettingsController.class.getMethod("sourceWarehouses")
                .getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAnyAuthority('workshop_material:setup','workshop_material:issue')");
        assertThat(WorkshopMaterialSettingsController.class.getMethod("batchEnable",
                        WorkshopMaterialDtos.BatchEnableRequest.class)
                .getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('workshop_material:setup')");
        assertThat(WorkshopMaterialSettingsController.class.getMethod("batchDisable",
                        WorkshopMaterialDtos.BatchDisableRequest.class)
                .getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('workshop_material:setup')");
    }

    private static WorkshopMaterialSettingsService service(String... permissions) {
        var user = mock(SecurityContextCurrentUser.class);
        when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "setup-only",
                Set.of(permissions), false, true, false)));
        var named = new NamedParameterJdbcTemplate(db);
        return new WorkshopMaterialSettingsService(named, mock(WorkshopMaterialBinSupport.class),
                mock(WorkshopMaterialCommandLedger.class), mock(WorkshopMaterialScope.class),
                new WorkshopMaterialPermissions(user), mock(WorkshopMaterialChoiceAdapter.class),
                new WorkshopBinService(named), user);
    }

    private static UUID warehouse(String code, String name, UUID parent, boolean defective) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective,parent_id)
                VALUES (?,?,?,'使用',true,?,?)
                """, id, code + "-" + id.toString().substring(0, 6), name + id.toString().substring(0, 6), defective,
                parent);
        return id;
    }
}
