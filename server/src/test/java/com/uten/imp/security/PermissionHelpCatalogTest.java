package com.uten.imp.security;

import com.uten.imp.features.rbac.PermissionBusinessDescriptions;
import com.uten.imp.features.admin.dto.PermissionCatalogDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionEmployeePermissionsDto.PermissionState;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

class PermissionHelpCatalogTest {
    @Test void everyReviewedPermissionHasPlainNameBoundariesAndAnExampleOnBothSurfaces() {
        assertThat(PermissionBusinessDescriptions.catalog()).hasSizeGreaterThan(500);
        PermissionBusinessDescriptions.catalog().forEach((code,help)->{
            assertThat(help.name()).as(code).doesNotContain("反审","受控","快照","聚合","幂等","UUID",":");
            assertThat(help.description()).as(code).contains("能做什么：","范围与限制：","提醒和待办：","例如：");
            var central=new PermissionCatalogDto.Item(UUID.randomUUID(),code,"旧名称","VIEW","旧说明",List.of("NORMAL"),false,false,"NORMAL");
            var page=new PermissionState(code,"旧名称","VIEW","旧说明",List.of("NORMAL"),"NORMAL",false,false,false,null,0,false,null,List.of(),List.of(),false);
            assertThat(central.name()).isEqualTo(help.name());
            assertThat(page.name()).isEqualTo(central.name());
            assertThat(page.description()).isEqualTo(central.description()).isEqualTo(help.description());
            assertThat(page.effective()).isFalse();
        });
    }

    @Test
    @EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
    void migrationCoversTheWholeLiveCatalogAndChangesOnlyNamesAndHelp() throws Exception {
        var db=PermissionCatalogTestSupport.database();
        assertThat(PermissionBusinessDescriptions.catalog().keySet()).containsExactlyInAnyOrderElementsOf(PermissionCatalogTestSupport.catalogCodes());
        var before=db.queryForList("SELECT id,code,action_type,module,category,sort_order,grant_policy::text,high_risk,baseline,baseline_pinned,sensitivity,explicit_grant_required FROM permissions ORDER BY code");
        Path migration=Path.of("src/main/resources/db/migration/V979__plain_permission_names_and_examples.sql");
        db.execute(Files.readString(migration));
        assertThat(db.queryForList("SELECT id,code,action_type,module,category,sort_order,grant_policy::text,high_risk,baseline,baseline_pinned,sensitivity,explicit_grant_required FROM permissions ORDER BY code")).isEqualTo(before);
        db.queryForList("SELECT code,name,description FROM permissions").forEach(row->{
            var help=PermissionBusinessDescriptions.catalog().get(row.get("code"));
            assertThat(row.get("name")).isEqualTo(help.name());
            assertThat(row.get("description")).isEqualTo(help.description());
        });
    }
}
