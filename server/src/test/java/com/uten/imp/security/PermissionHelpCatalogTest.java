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
    @Test void moneyDocumentApprovalHelpExplainsBookEffectsWithoutPromisingBankExecution() {
        var help=PermissionBusinessDescriptions.catalog();
        for(String code:List.of("finance_expense:approve","finance_other_income:approve","finance_payment:approve",
                "finance_receipt:approve","finance_bank_transfer:approve")) {
            assertThat(help.get(code).description()).as(code).contains("账面余额","流水","总账分录","不自动向银行发起转账","制单人与审核人分离");
        }
        assertThat(help.get("finance_expense:approve").description()).contains("扣减","不核销客户应收或供应商应付");
        assertThat(help.get("finance_other_income:approve").description()).contains("增加","按期间生成");
        assertThat(help.get("finance_payment:approve").description()).contains("核销对应应付","供应商预付禁止审核");
        assertThat(help.get("finance_receipt:approve").description()).contains("核销对应应收","客户预收");
        assertThat(help.get("finance_bank_transfer:approve").description()).contains("转出账户","各转入账户","按期间生成");
    }
    @Test void salesManagerHelpSeparatesReadingDecisionsAndFinanceResponsibilities() {
        var help=PermissionBusinessDescriptions.catalog();
        for (String kind : List.of("quote","order")) {
            String prefix="sales_"+kind+"_manager:";
            for (String action : List.of("view","confirm","reject","reverse")) {
                assertThat(help).containsKey(prefix+action);
            }
            assertThat(help.get(prefix+"view").description()).contains("仅查看不加入", "不能据此");
            assertThat(help.get(prefix+"confirm").description()).contains("查看权限", "本人的有效认领", "财务");
            assertThat(help.get(prefix+"reject").description()).contains("退回原因", "本人的有效认领", "重新提交");
            assertThat(help.get(prefix+"reverse").name()).startsWith("撤销销售负责人");
            assertThat(help.get(prefix+"reverse").description()).contains("仅有撤销批准权限不加入待审核接收池", "财务正在认领");
        }
        assertThat(help.get("sales_quote_manager:confirm").description())
                .contains("货品、数量和明细行身份不能在此修改", "不改写货品主档价格");
        assertThat(help.get("sales_order_manager:confirm").description()).contains("不允许改写订货商业明细");
        assertThat(help.get("sales_order_manager:reject").description()).contains("库存预留", "历史事实");
    }

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
        Path migration=Path.of("src/main/resources/db/migration/V983__task_read_all_permission_help.sql");
        db.execute(Files.readString(migration));
        assertThat(db.queryForList("SELECT id,code,action_type,module,category,sort_order,grant_policy::text,high_risk,baseline,baseline_pinned,sensitivity,explicit_grant_required FROM permissions ORDER BY code")).isEqualTo(before);
        db.queryForList("SELECT code,name,description FROM permissions").forEach(row->{
            var help=PermissionBusinessDescriptions.catalog().get(row.get("code"));
            assertThat(row.get("name")).isEqualTo(help.name());
            assertThat(row.get("description")).isEqualTo(help.description());
        });
    }
}
