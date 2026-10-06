package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * P1-2 the business glossary (docs/07-业务链路/00-业务术语与状态总表.md): its rows are read as terms with their everyday
 * words, each row is a definition every chat user may read, and a question in everyday words is searched in the
 * documents' words.
 */
class AiDocGlossaryTest {
    private static final String FIXTURE = """
            # 业务术语与状态总表

            > 别名：术语表、名词解释

            本表把平时的说法对到平台里的正式叫法。

            ## 一、生产

            | 术语 | 俗称/也叫 | 含义 | 出现在哪 | 相关文档 |
            |---|---|---|---|---|
            | **让料** | 借料、跨计划让料 | 计划员把给计划 A 备好的料让给更急的计划 B；A 的需求不删除，后面再到的料优先补给 A。 | 物料分析 | [跨物料分析让料](../99-决策记录-ADR/ADR-049-跨物料分析让料与后续供给优先补齐.md) |
            | 车间内料仓 | 线边仓、车间料仓 | 放在车间里的料仓，接收车间直送的半成品。 | 车间内料仓 | [车间内料仓上线与使用说明](车间内料仓上线与使用说明.md) |
            | 超产 | — | 实际做出的数量超过计划数量。 | 报工 | |

            ## 二、别的表

            | 状态 | 含义 |
            |---|---|
            | 草稿 | 还没提交 |
            """;

    private static final String RULE_DOC = """
            # ADR-201 车间内料仓开通

            ## 决策

            车间内料仓由仓库在车间内料仓页开通，开通后车间直送的半成品放进车间内料仓，盘点后按报工量分摊用量。开通只做一次，撤销一次退一步。
            """;

    @Test void rowsAreTermsWithTheirEverydayWords() {
        List<AiDocGlossary.Entry> entries = AiDocGlossary.parse(FIXTURE);
        assertThat(entries).extracting(AiDocGlossary.Entry::term).containsExactly("让料", "车间内料仓", "超产");
        assertThat(entries.get(0).aliases()).containsExactly("借料", "跨计划让料");
        assertThat(entries.get(1).aliases()).containsExactly("线边仓", "车间料仓");
        // A dash means "no everyday word".
        assertThat(entries.get(2).aliases()).isEmpty();
        assertThat(entries.get(0).meaning()).startsWith("计划员把");
        // Only the glossary's own header counts: the second table (状态 | 含义) is not read as terms.
        assertThat(entries).extracting(AiDocGlossary.Entry::term).doesNotContain("状态", "草稿");
        assertThat(AiDocGlossary.parse("")).isEmpty();
        assertThat(AiDocGlossary.parse(null)).isEmpty();
    }

    @Test void eachRowIsADefinitionEveryChatUserMayRead() {
        List<AiDocChunker.Chunk> chunks = AiDocChunker.chunks(AiDocGlossary.PATH, FIXTURE);
        List<AiDocChunker.Chunk> definitions = chunks.stream().filter(chunk -> chunk.kind() == AiDocChunker.Kind.DEFINITION).toList();
        assertThat(definitions).extracting(AiDocChunker.Chunk::section).containsExactly("让料", "车间内料仓", "超产");
        assertThat(definitions.getFirst().text()).startsWith("让料：计划员把").contains("也叫：借料、跨计划让料", "跨物料分析让料")
                .doesNotContain("](", ".md", "**");
        assertThat(definitions.getFirst().label()).isEqualTo("业务术语与状态总表 / 让料");
        assertThat(chunks).allSatisfy(chunk -> assertThat(chunk.domains()).isEmpty());
        // The table rows are not repeated as one long table chunk; the introduction and the other table stay text.
        assertThat(chunks.stream().filter(chunk -> chunk.kind() == AiDocChunker.Kind.RULE).map(AiDocChunker.Chunk::text).toList())
                .noneMatch(text -> text.contains("计划员把"));
        assertThat(AiDocChunker.aliases(FIXTURE)).containsExactly("术语表", "名词解释");
    }

    /** The rule, the glossary when given, and unrelated documents so that word weights are like a real index's. */
    private static AiDocKnowledge index(boolean withGlossary) {
        Map<String, String> documents = new java.util.LinkedHashMap<>();
        if (withGlossary) documents.put(AiDocGlossary.PATH, FIXTURE);
        documents.put("99-决策记录-ADR/ADR-201-车间料仓开通.md", RULE_DOC);
        String[] topics = {"销售订单财务审核", "采购到货登记", "客户收款核销", "员工报销审批", "委外回厂登记", "成品质检放行"};
        for (int i = 0; i < 30; i++) {
            String topic = topics[i % topics.length];
            documents.put("03-页面/说明页" + i + ".md", "# " + topic + "说明" + i + "\n\n## 规则\n\n" + topic
                    + "按单据逐行处理，提交后由负责人审核，审核通过才生效；退回时写明原因，改完重新提交。"
                    + "同一张单据只能由一个人办理，办完自动通知下一步的人。第" + i + "页。\n");
        }
        return AiDocKnowledge.of(documents);
    }

    @Test void anEverydayWordFindsTheDocumentsTermAndItsDefinition() {
        AiDocKnowledge docs = index(true);
        // "线边仓" is nowhere in the rule; the glossary reads it as 车间内料仓.
        List<AiDocChunker.Chunk> found = docs.search("线边仓怎么开通", Set.of("SELF", "PRODUCTION"));
        assertThat(found).anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-201"));
        assertThat(found.getFirst().kind()).isEqualTo(AiDocChunker.Kind.DEFINITION);
        assertThat(found.getFirst().section()).isEqualTo("车间内料仓");
        // A one-word question about a defined term is answered from the definition.
        assertThat(docs.search("让料是什么意思", Set.of("SELF"))).extracting(AiDocChunker.Chunk::section).contains("让料");
        assertThat(docs.search("线边仓是什么", Set.of("SELF"))).extracting(AiDocChunker.Chunk::section).startsWith("车间内料仓");
    }

    @Test void withoutAGlossaryTheIndexStillWorks() {
        AiDocKnowledge docs = index(false);
        assertThat(docs.search("车间内料仓怎么开通", Set.of("SELF", "PRODUCTION")))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-201"));
        // An everyday word only the glossary knows finds nothing without it.
        assertThat(docs.search("线边仓是什么", Set.of("SELF", "PRODUCTION"))).isEmpty();
    }

    /** The real glossary: every row has a term and a meaning, and every related document it links exists. */
    @Test void theGlossarysRelatedDocumentsExist() throws Exception {
        Path glossary = Path.of("..", "docs").resolve(AiDocGlossary.PATH);
        assumeTrue(Files.exists(glossary), "glossary not written yet");
        String markdown = Files.readString(glossary, StandardCharsets.UTF_8);
        List<AiDocGlossary.Entry> entries = AiDocGlossary.parse(markdown);
        assertThat(entries).isNotEmpty().allSatisfy(entry -> assertThat(entry.meaning()).as(entry.term()).isNotBlank());
        assertThat(entries).extracting(AiDocGlossary.Entry::term).doesNotHaveDuplicates();
        List<String> missing = new ArrayList<>();
        Pattern link = Pattern.compile("\\]\\(([^)#\\s]+\\.md)(?:#[^)]*)?\\)");
        for (AiDocGlossary.Entry entry : entries) {
            Matcher matcher = link.matcher(entry.related());
            while (matcher.find()) {
                Path target = glossary.getParent().resolve(matcher.group(1)).normalize();
                if (!Files.exists(target)) missing.add(entry.term() + " -> " + matcher.group(1));
            }
        }
        assertThat(missing).as("related documents linked from the glossary").isEmpty();
        // The glossary is packaged and every chat user may read it.
        assertThat(AiDocKnowledgePolicy.included(AiDocGlossary.PATH)).isTrue();
        assertThat(AiDocKnowledgePolicy.domains(AiDocGlossary.PATH, "业务术语与状态总表")).isEmpty();
    }
}
