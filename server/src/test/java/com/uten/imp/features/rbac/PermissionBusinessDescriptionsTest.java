package com.uten.imp.features.rbac;

import com.uten.imp.features.admin.dto.PermissionCatalogDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionEmployeePermissionsDto.PermissionState;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class PermissionBusinessDescriptionsTest {
    @Test
    void fieldWriteExplanationsStateTheExistingActionAndReadCombinationsWithoutChangingCatalogData() {
        Permission price = permission("goods:price:edit", "旧价格说明");
        Permission compensation = permission("employee:compensation:edit", "旧薪酬说明");

        assertThat(PermissionBusinessDescriptions.descriptionFor(price))
                .contains("字段授权", "「新增货品资料」", "修改已有货品", "「编辑货品资料」",
                        "同时允许查看货品售价", "查看折扣须另行开启「查看货品折扣」")
                .doesNotContain("goods:", "employee:");
        assertThat(PermissionBusinessDescriptions.descriptionFor(compensation))
                .contains("字段写入授权", "「办理员工入职」和「编辑员工证件、联系方式与银行字段」", "「编辑员工」",
                        "查看已有薪酬须另行开启「查看员工薪资字段」")
                .doesNotContain("goods:", "employee:");
        assertThat(price.getDescription()).isEqualTo("旧价格说明");
        assertThat(compensation.getDescription()).isEqualTo("旧薪酬说明");
        assertThat(PermissionBusinessDescriptions.descriptionFor(permission("goods:cost:view", "成本可见范围")))
                .isEqualTo("成本可见范围");
        assertThat(PermissionBusinessDescriptions.descriptionFor("goods:view", null)).isNull();
    }

    @Test
    void centralPersonalAndPageCatalogOutputsShareTheSameFieldExplanation() {
        for (String code : List.of("goods:price:edit", "employee:compensation:edit", "employee:create")) {
            var centralAndPersonal = new PermissionCatalogDto.Item(UUID.randomUUID(), code, code, "EDIT",
                    "历史说明", List.of("NORMAL"), false, false, "NORMAL", List.of());
            var page = new PermissionState(code, code, "EDIT", "历史说明", List.of("NORMAL"), "NORMAL",
                    true, true, true, null, 0, true, null, List.of(), List.of(), true);

            assertThat(centralAndPersonal.description())
                    .isEqualTo(PermissionBusinessDescriptions.descriptionFor(code, null));
            assertThat(page.description()).isEqualTo(centralAndPersonal.description());
            assertThat(centralAndPersonal.requiredPermissions()).isEmpty();
            assertThat(page.effective()).isTrue();
            assertThat(page.missingDependencies()).isEmpty();
        }
    }

    @Test
    void onboardingNamesTheMandatorySensitiveWriteAndDepartmentSelectionPermissions() {
        assertThat(PermissionBusinessDescriptions.descriptionFor("employee:create", null))
                .contains("「编辑员工证件、联系方式与银行字段」", "「查看部门」",
                        "填写薪资", "「编辑员工薪资、社保、公积金与补贴字段」")
                .doesNotContain("employee:", "department:");
    }

    private static Permission permission(String code, String description) {
        Permission permission = new Permission();
        permission.setCode(code);
        permission.setDescription(description);
        return permission;
    }
}
