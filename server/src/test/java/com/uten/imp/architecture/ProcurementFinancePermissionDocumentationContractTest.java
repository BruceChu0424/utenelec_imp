package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementFinancePermissionDocumentationContractTest {

    private static final List<String> LIVING_DOCS = List.of(
            "docs/00-项目准则/00-准则索引与开发清单.md",
            "docs/03-页面/工作台首页.md",
            "docs/03-页面/页面总览.md",
            "docs/04-数据模型/ER草图.md",
            "docs/04-数据模型/生产履约V1实体关系.md",
            "docs/05-架构/路由设计.md",
            "docs/05-架构/安全策略.md",
            "docs/05-架构/全局机制.md",
            "docs/07-业务链路/04-生产订单排产与执行全链路需求.md",
            "docs/数据迁移/15-采购模块-新库与迁移.md",
            "docs/数据迁移/17-仓库管理-新库与迁移.md",
            "docs/数据迁移/22-委外管理-新库与迁移.md",
            "docs/数据迁移/28-Java后端契约.md",
            "docs/数据迁移/54-部门默认权限矩阵.md",
            "docs/数据迁移/55-权限模块分类.md");

    @Test
    void currentDocsNeverPresentLegacyReviewAsAnActivePermission()
            throws Exception {
        Path root = repositoryRoot();
        for (String relative : LIVING_DOCS) {
            Path path = root.resolve(relative);
            assertThat(path).exists();
            for (String line : Files.readAllLines(path)) {
                if (!line.contains("finance_order_approval:review")) {
                    continue;
                }
                assertThat(line)
                        .as(relative + " must label legacy review as inactive history")
                        .containsAnyOf("停用", "inactive", "历史");
            }
        }
    }

    @Test
    void adr027CarriesTheV328AndCaseBoundBatchOverride() throws Exception {
        String adr = Files.readString(repositoryRoot().resolve(
                "docs/99-决策记录-ADR/ADR-027-财务审批改为权限授权的审核组.md"));

        assertThat(adr)
                .contains("V328 / 2026-08-30")
                .contains("finance_order_approval:view")
                .contains("finance_order_approval:approve")
                .contains("finance_order_approval:reject")
                .contains("active=true")
                .contains("{caseId,expectedVersion}")
                .contains("旧单笔入口停用");
    }

    private static Path repositoryRoot() {
        Path cwd = Path.of("").toAbsolutePath().normalize();
        return Files.isDirectory(cwd.resolve("docs"))
                ? cwd
                : cwd.resolve("..").normalize();
    }
}
