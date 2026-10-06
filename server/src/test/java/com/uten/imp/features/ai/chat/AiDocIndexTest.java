package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * P0-4 how a question is read: everyday filler words go, whole business words decide which bigrams are searched (a
 * bigram across a word and the stray words next to it is noise), everyday phrases are searched in the documents' words
 * and the glossary's everyday words find their terms.
 */
class AiDocIndexTest {

    @Test void spokenFillerAndBigramsAcrossWordsAreNotSearched() {
        List<String> terms = AiDocIndex.keyTerms("东西到了以后仓库那边要怎么收进去");
        assertThat(terms).contains("到货", "入库", "仓库", "以后")
                .doesNotContain("东西", "那边", "后仓", "库那", "边要", "收进", "进去");
        // Words of time are not filler: "审核之前" is a different question from "审核".
        assertThat(AiDocIndex.keyTerms("审核之前又出库了会怎样")).contains("审核", "之前", "出库");
        // Typed 得 for 的 is a particle, like 的.
        assertThat(AiDocIndex.keyTerms("计划产出量是咋算得")).doesNotContain("算得", "咋算");
    }

    @Test void twoKnownWordsSideBySideStayOnePhrase() {
        // 客户 + 退货: the joining bigram is kept, it is how the documents write the phrase.
        assertThat(AiDocIndex.keyTerms("客户退货回来的货")).contains("客户", "户退", "退货");
        // A document name ending in 单 is one word.
        assertThat(AiDocIndex.keyTerms("退货单审核完")).contains("退货", "货单", "审核");
    }

    @Test void everydayPhrasesAreSearchedInTheDocumentsWords() {
        assertThat(AiDocIndex.keyTerms("供应商多送了一些货 能收吗")).contains("超收", "供应", "应商").doesNotContain("多送");
        assertThat(AiDocIndex.keyTerms("为啥我下不了委外单 按钮是灰得")).contains("锁住", "解锁", "委外").doesNotContain("下不", "灰得");
        assertThat(AiDocIndex.keyTerms("字太小了看不清 怎么调大")).contains("字号", "缩放").doesNotContain("太小", "看不");
        assertThat(AiDocIndex.keyTerms("这个货品以前给客户报过什么价")).contains("报价", "历史", "记录");
        assertThat(AiDocIndex.keyTerms("订货单被财务退回来了")).contains("驳回", "财务", "订货", "货单");
        // The document words count as the question's own (weight 1), so the thresholds and the matched-term rule see them.
        assertThat(AiDocIndex.queryTerms("供应商多送了一些货")).containsEntry("超收", 1.0);
    }

    @Test void theGlossarysEverydayWordsFindTheirTermsWithoutReplacingTheUsersWords() {
        var glossary = List.of(
                new AiDocGlossary.Entry("车间内料仓", List.of("线边仓", "内料仓"), "放在车间里的料仓", "", ""),
                new AiDocGlossary.Entry("驳回", List.of("退回", "打回"), "审核人不同意", "", ""),
                new AiDocGlossary.Entry("余料退仓", List.of("退回", "退料"), "剩下的料退回仓库", "", ""));
        var vocabulary = AiDocIndex.Vocabulary.of(AiDocIndex.SYNONYMS, AiDocIndex.COLLOQUIAL, glossary, AiDocIndex.CORE_WORDS);
        Map<String, Double> terms = vocabulary.queryTerms("线边仓怎么开通", "");
        assertThat(terms).containsEntry("线边", 1.0).containsEntry("边仓", 1.0).containsEntry("开通", 1.0)
                .containsEntry("内料", AiDocIndex.ALIAS_WEIGHT).containsEntry("料仓", AiDocIndex.ALIAS_WEIGHT);
        assertThat(vocabulary.named("线边仓怎么开通")).containsExactly("车间内料仓");
        // One everyday word may name two terms: both are searched, neither replaces the user's own word.
        Map<String, Double> returned = vocabulary.queryTerms("客户退回来的货", "");
        assertThat(returned).containsEntry("退回", 1.0).containsEntry("驳回", AiDocIndex.ALIAS_WEIGHT)
                .containsEntry("余料", AiDocIndex.ALIAS_WEIGHT);
        assertThat(vocabulary.named("客户退回来的货")).containsExactlyInAnyOrder("驳回", "余料退仓");
        // Glossary terms and everyday words are whole words: no bigram across them.
        assertThat(vocabulary.keyTerms("以后线边仓那里")).contains("线边", "边仓", "以后").doesNotContain("后线");
        // Without a glossary nothing is named.
        assertThat(AiDocIndex.DEFAULT.named("线边仓怎么开通")).isEmpty();
    }

    @Test void aFollowUpsEarlierWordsAreContextNotTheQuestionsOwn() {
        Map<String, Double> terms = AiDocIndex.queryTerms("那出库呢", "盘点有差异谁来审核");
        assertThat(terms).containsEntry("出库", 1.0).containsEntry("盘点", AiDocIndex.CONTEXT_WEIGHT)
                .containsEntry("差异", AiDocIndex.CONTEXT_WEIGHT);
    }

    @Test void hitsCountTheQuestionsWordsInTheHeadingsAndTheEarlierQuestionsWords() {
        var index = new AiDocIndex(List.of("仓库重量账", "盘点审核"), List.of("仓库重量账 单重自学习", "盘点审核 审核归属"),
                List.of("入库未称时按库存均重估算重量。", "盘点有差异时整单送审核，审核前库存不变。"));
        var hits = index.search(AiDocIndex.queryTerms("审核之前库存会变吗", "盘点有差异"), chunk -> true, 10);
        var stocktake = hits.stream().filter(hit -> hit.chunk() == 1).findFirst().orElseThrow();
        assertThat(stocktake.inHeading()).isEqualTo(1);
        assertThat(stocktake.inContext()).isEqualTo(2);
        assertThat(stocktake.matched()).isGreaterThanOrEqualTo(2);
        assertThat(index.known("审核")).isTrue();
        assertThat(index.known("天气")).isFalse();
    }
}
