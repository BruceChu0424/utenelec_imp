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
        for (String path : List.of("99-决策记录-ADR/README.md", "99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md",
                "99-决策记录-ADR/ADR-031-本地云端单主库部署架构.md", "99-决策记录-ADR/ADR-110-服务端会话与敏感操作再认证.md",
                "03-页面/AI服务设置页.md", "03-页面/登录页.md", "03-页面/系统设置页.md", "98-模块总结/01-人事端代码总结.md",
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

    private static List<String> tags(String xml, String tag) {
        List<String> values = new ArrayList<>();
        Matcher matcher = Pattern.compile("<" + tag + ">([^<]+)</" + tag + ">").matcher(xml);
        while (matcher.find()) values.add(matcher.group(1).strip());
        return values;
    }
}
