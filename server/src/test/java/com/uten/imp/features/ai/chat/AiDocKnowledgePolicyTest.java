package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-153 the documents packaged by server/pom.xml (resource target path ai-knowledge) and the documents the
 * index accepts are the same lists; source code, governance, deployment and migration documents are never
 * packaged.
 */
class AiDocKnowledgePolicyTest {

    @Test void pomPackagesExactlyThePolicyLists() throws Exception {
        String pom = Files.readString(Path.of("pom.xml"), StandardCharsets.UTF_8);
        Matcher block = Pattern.compile("(?s)<resource>\\s*<directory>\\.\\./docs</directory>\\s*<targetPath>"
                + AiDocKnowledgePolicy.RESOURCE_ROOT + "</targetPath>(.*?)</resource>").matcher(pom);
        assertThat(block.find()).as("ai-knowledge resource block in pom.xml").isTrue();
        assertThat(tags(block.group(1), "include")).isEqualTo(AiDocKnowledgePolicy.INCLUDES);
        assertThat(tags(block.group(1), "exclude")).isEqualTo(AiDocKnowledgePolicy.EXCLUDES);
        assertThat(pom).doesNotContain("<directory>../docs</directory>\n                <targetPath>ai-knowledge</targetPath>\n"
                + "                <filtering>true");
    }

    @Test void onlyDesignDocumentsAreIncluded() {
        assertThat(AiDocKnowledgePolicy.included("99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md")).isTrue();
        assertThat(AiDocKnowledgePolicy.included("03-页面/库存盘点审核页.md")).isTrue();
        assertThat(AiDocKnowledgePolicy.included("07-业务链路/生产计量与来源守恒.md")).isTrue();
        assertThat(AiDocKnowledgePolicy.included("00-项目准则/14-徽章与计数口径.md")).isTrue();
        assertThat(AiDocKnowledgePolicy.included("03-页面/服务器状态页.md")).isTrue();
        // The business glossary and the assistant's own user guide (what it can and cannot do) are knowledge.
        assertThat(AiDocKnowledgePolicy.included(AiDocGlossary.PATH)).isTrue();
        assertThat(AiDocKnowledgePolicy.included("03-页面/AI工作助手使用说明.md")).isTrue();
        for (String path : List.of("99-决策记录-ADR/README.md", "99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md",
                "99-决策记录-ADR/ADR-158-AI文件理解一次作答与按权限给出去处.md",
                "99-决策记录-ADR/ADR-159-AI助手有据作答-检索门槛目录与单据进度工具.md",
                "99-决策记录-ADR/ADR-031-本地云端单主库部署架构.md", "99-决策记录-ADR/ADR-110-服务端会话与敏感操作再认证.md",
                "99-决策记录-ADR/ADR-157-服务器备份分故障域与密钥托管.md", "99-项目治理/2026-10-06-服务器安全整改.md",
                "03-页面/AI服务设置页.md", "03-页面/登录页.md", "03-页面/系统设置页.md", "05-架构/人事端代码总结.md",
                "00-项目准则/10-安全准则.md", "00-项目准则/12-后端编码规范.md", "99-项目治理/中国大陆部署与兼容性.md",
                "05-架构/AI平台接入指南.md", "数据迁移/README.md", "../server/src/main/resources/application.yml",
                "03-页面/../../server/.env")) {
            assertThat(AiDocKnowledgePolicy.included(path)).as(path).isFalse();
        }
    }

    @Test void administratorPagesAreAdminOnlyAndImplementationSectionsAreDropped() {
        assertThat(AiDocKnowledgePolicy.domains("03-页面/服务器状态页.md", "服务器状态")).containsExactly("ADMIN");
        assertThat(AiDocKnowledgePolicy.domains("99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md", "ADR-135 仓库重量账与单重自学习"))
                .contains("WAREHOUSE");
        assertThat(AiDocKnowledgePolicy.domains("00-项目准则/14-徽章与计数口径.md", "徽章与计数口径")).isEmpty();
        for (String heading : List.of("四、迁移与退役(V743)", "测试", "参考", "二、同行做法(调研)", "一、背景", "接口与端点", "安全与权限校验",
                "2026-08-08 设计快照(历史参考)", "六、函数、页面和验收入口")) {
            assertThat(AiDocKnowledgePolicy.droppedSection(heading)).as(heading).isTrue();
        }
        for (String heading : List.of("3.2 重量账规则", "三、决策", "安全库存与补库", "参考成本与实际成本", "审核归属", "明确不做")) {
            assertThat(AiDocKnowledgePolicy.droppedSection(heading)).as(heading).isFalse();
        }
    }

    /** P0-6 reviewed domains: by subject, not by a word that happens to be in the title. */
    @Test void reviewedDomainsOverrideTheTitleWords() {
        assertThat(AiDocKnowledgePolicy.domains("99-决策记录-ADR/ADR-090-到货先入库后质检.md",
                "ADR-090 「先入库后质检」：实物先上架落位，合格自动转正，不合格从库位退回"))
                .containsExactlyInAnyOrder("WAREHOUSE", "QUALITY", "PURCHASE", "PRODUCTION");
        assertThat(AiDocKnowledgePolicy.domains("99-决策记录-ADR/ADR-144-采购允许超收比例与超出部分财务审批.md", "ADR-144 采购允许超收比例"))
                .containsExactlyInAnyOrder("PURCHASE", "WAREHOUSE");
        assertThat(AiDocKnowledgePolicy.domains("99-决策记录-ADR/ADR-128-往来余额按单据币种显示与信用口径统一.md", "ADR-128"))
                .containsExactlyInAnyOrder("SALES", "FINANCE");
        assertThat(AiDocKnowledgePolicy.domains("03-页面/员工详情页.md", "员工详情页")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.domains("03-页面/员工编辑页.md", "员工编辑页")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.domains("99-决策记录-ADR/ADR-155-清空业务数据测试文件单一规则与幂等删除.md", "ADR-155"))
                .containsExactly("ADMIN");
        assertThat(AiDocKnowledgePolicy.domains(AiDocGlossary.PATH, "业务术语与状态总表")).isEmpty();
        assertThat(AiDocKnowledgePolicy.domains("03-页面/AI工作助手使用说明.md", "AI 工作助手使用说明")).isEmpty();
        // The reader's own access and how to ask for it: every chat user, although its title names 权限.
        assertThat(AiDocKnowledgePolicy.domains("03-页面/我的权限与申请开通.md", "权限与申请开通")).isEmpty();
        // 转正 or HR inside another title is not personnel; a personnel page's name still is.
        assertThat(AiDocKnowledgePolicy.domains("03-页面/库存转正说明.md", "库存转正说明")).doesNotContain("HR");
        assertThat(AiDocKnowledgePolicy.domains("03-页面/CHR对接页.md", "CHR 对接页")).doesNotContain("HR");
        assertThat(AiDocKnowledgePolicy.domains("03-页面/HR任务中心.md", "HR 任务中心")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.domains("99-决策记录-ADR/ADR-021-人事域完善-转正车辆多联系方式与任务软认领.md", "ADR-021"))
                .contains("HR");
    }

    /** P0-5 what is not a current rule: change logs, history kept for compatibility, unbuilt pages, replaced records. */
    @Test void historyPlansAndReplacedRecordsAreRecognized() {
        for (String heading : List.of("2026-08-29 页面演进记录(以下旧控件和齐套限制不作当前入口依据)",
                "2026-08-02 历史实现口径(V191-V211, 仅兼容)", "历史调度链路(仅兼容)", "二轮历史", "已由 ADR-143 覆盖的部分")) {
            assertThat(AiDocKnowledgePolicy.droppedSection(heading)).as(heading).isTrue();
        }
        assertThat(AiDocKnowledgePolicy.droppedSection("历史报价记录")).isFalse();
        // Live 2026-10-06: a dated design-and-evidence snapshot (M05) and an internal event catalog that described the
        // payroll approval chain to a sales reader from an unrestricted decision record (N2).
        assertThat(AiDocKnowledgePolicy.droppedSection("2026-08-28 设计与证据快照")).isTrue();
        assertThat(AiDocKnowledgePolicy.droppedSection("附：人事域事件目录(2026-09-09 接入，2026-09-10 补齐)")).isTrue();
        assertThat(AiDocKnowledgePolicy.unimplemented("产量录入页(未实施提案)")).isTrue();
        assertThat(AiDocKnowledgePolicy.unimplemented("产量录入")).isFalse();
        assertThat(AiDocKnowledgePolicy.documentPrior("07-业务链路/2026-09-07-客户零星发货统一审批与出库方案.md", "客户零星发货统一审批与出库方案"))
                .isEqualTo(AiDocKnowledgePolicy.PLAN_PRIOR);
        assertThat(AiDocKnowledgePolicy.documentPrior("99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md", "仓库重量账与单重自学习"))
                .isEqualTo(1.0);
        assertThat(AiDocKnowledgePolicy.whollySuperseded("> **2026-10-04 整份被 [ADR-143](ADR-143-x.md) 取代**：先自制后通知……")).isTrue();
        assertThat(AiDocKnowledgePolicy.whollySuperseded("> **2026-10-04 整份判据被 [ADR-143](ADR-143-x.md) 取代**：……")).isTrue();
        assertThat(AiDocKnowledgePolicy.whollySuperseded("- **状态**：**已被 [ADR-143](ADR-143-x.md) 整份取代(2026-10-04)**")).isTrue();
        // Partly replaced, or a list item naming another record, is not the whole document.
        assertThat(AiDocKnowledgePolicy.whollySuperseded("> **2026-10-04 被 [ADR-143](ADR-143-x.md) 取代(委外部分)**")).isFalse();
        assertThat(AiDocKnowledgePolicy.whollySuperseded("  - ADR-062 整份(先自制后通知)；取代")).isFalse();
    }

    /**
     * ADR-159 (live N2) a heading, or a list item's bold lead, that is clearly about personnel or finance: the words of
     * the document-level rules that only those departments use, never mixed with a shared business word or one topic of a
     * list.
     */
    @Test void sectionHeadingsAboutPersonnelOrFinanceAreRecognizedConservatively() {
        assertThat(AiDocKnowledgePolicy.sectionDomains("附：人事域事件目录(2026-09-09 接入，2026-09-10 补齐)")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.sectionDomains("人事办结缺口补齐")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.sectionDomains("5. 离职必须先完成真实交接")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.sectionDomains("3.2 工资条审核与发布")).containsExactly("HR");
        assertThat(AiDocKnowledgePolicy.sectionDomains("7. 成本")).containsExactly("FINANCE");
        assertThat(AiDocKnowledgePolicy.sectionDomains("7.1 期间分摊怎么进产品成本")).containsExactly("FINANCE");
        assertThat(AiDocKnowledgePolicy.sectionDomains("七、资金边界和已知实现差距")).containsExactly("FINANCE");
        // A shared business word in the same heading, or a list of topics only one of which is restricted: shared.
        for (String heading : List.of("五、发货与正式应收", "七、短交、损耗、成本、权限与通知", "4.2 采购应付与到货", "3. 车间报工与计件工资",
                "三、决策", "2026-09-10 生效修订", "登录弹窗口径", "人工通知登录弹窗与打卡", "财务审核与驳回", "收款与核价")) {
            assertThat(AiDocKnowledgePolicy.sectionDomains(heading)).as(heading).isEmpty();
        }
        // One's own matters are every employee's, whatever personnel word they hold.
        assertThat(AiDocKnowledgePolicy.selfServiceHeading("十、「我的部门」(2026-08-02 新增)")).isTrue();
        assertThat(AiDocKnowledgePolicy.selfServiceHeading("七、资金边界")).isFalse();
        // Only an everyone-readable document is scoped section by section: not a restricted one, a reviewed override or a
        // self-service document.
        assertThat(AiDocKnowledgePolicy.sectionScoped("99-决策记录-ADR/ADR-063-部门定向审核待办弹窗与通知办结撤回.md",
                "ADR-063：部门定向审核待办弹窗与通知办结撤回", java.util.Set.of())).isTrue();
        assertThat(AiDocKnowledgePolicy.sectionScoped("03-页面/钱流单据页.md", "钱流单据页", java.util.Set.of("FINANCE"))).isFalse();
        assertThat(AiDocKnowledgePolicy.sectionScoped(AiDocGlossary.PATH, "业务术语与状态总表", java.util.Set.of())).isFalse();
        assertThat(AiDocKnowledgePolicy.sectionScoped("03-页面/我的页.md", "我的页", java.util.Set.of())).isFalse();
        assertThat(AiDocKnowledgePolicy.listLead("4. **人事域接收池是「部门 ∧ 权限」总口径的明示例外**：六个事件"))
                .isEqualTo("人事域接收池是「部门 ∧ 权限」总口径的明示例外");
        assertThat(AiDocKnowledgePolicy.listLead("   4. **缩进的子项**：不是左边起头的条目")).isNull();
    }

    /** ADR-159 §十 6: a section of a partly replaced decision record marked as replaced is not a current rule. */
    @Test void sectionsMarkedAsReplacedAreDropped() {
        for (String heading : List.of("二、决策(已被 ADR-143 取代，不作当前规则)", "### 7.2 已下单子件(已被 ADR-099 取代)",
                "三、决策(已被 ADR-102、ADR-143 取代，不作当前规则)", "2.1 解锁点(本节被 ADR-143 取代)")) {
            assertThat(AiDocKnowledgePolicy.droppedSection(heading)).as(heading).isTrue();
        }
        for (String heading : List.of("2.3 可发数量(部分被 ADR-143 取代)", "3.1 本决策取代 ADR-101 的解锁点", "二、决策")) {
            assertThat(AiDocKnowledgePolicy.droppedSection(heading)).as(heading).isFalse();
        }
    }

    private static List<String> tags(String xml, String tag) {
        List<String> values = new ArrayList<>();
        Matcher matcher = Pattern.compile("<" + tag + ">([^<]+)</" + tag + ">").matcher(xml);
        while (matcher.find()) values.add(matcher.group(1).strip());
        return values;
    }
}
