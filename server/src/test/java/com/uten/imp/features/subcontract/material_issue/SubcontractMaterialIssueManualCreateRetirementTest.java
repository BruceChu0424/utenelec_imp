package com.uten.imp.features.subcontract.material_issue;

import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.PostMapping;

import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 旧委外发料手工新建入口：V441 起固定返回 409 的兼容端点，V677 / ADR-109 起连同停用码
 * subcontract_material_issue:create 一并删除(平台未上线，不再为旧客户端保留路由)。
 * 委外发料只能由仓库委外出仓按系统任务执行。
 */
class SubcontractMaterialIssueManualCreateRetirementTest {

    @Test
    void manualCreateRouteNoLongerExists() {
        boolean collectionPost = Arrays.stream(SubcontractMaterialIssueController.class.getDeclaredMethods())
                .map(method -> method.getAnnotation(PostMapping.class))
                .filter(mapping -> mapping != null)
                .anyMatch(mapping -> mapping.value().length == 0 && mapping.path().length == 0);
        assertThat(collectionPost).isFalse();
        assertThat(Arrays.stream(SubcontractMaterialIssueService.class.getDeclaredMethods())
                .map(java.lang.reflect.Method::getName))
                .doesNotContain("create");
    }
}
