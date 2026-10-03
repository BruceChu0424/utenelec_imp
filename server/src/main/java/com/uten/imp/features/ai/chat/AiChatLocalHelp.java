package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;

/** Explicit help is a local read of the authorized guide, not a probabilistic model decision. */
final class AiChatLocalHelp {
    private static final Set<String> PAGE_QUESTIONS = Set.of(
            "这个页面怎么填写请举个例子", "这个页面怎么填写请举例", "这个页面怎么填写",
            "这个页面怎么填", "当前页面怎么填写", "当前页面怎么填写请举例",
            "当前页面怎么填写请举个例子", "请解释当前页面", "这个页面怎么用",
            "howdoifilloutthispagegiveanexample", "howdoifilloutthispagepleasegiveanexample",
            "howdoifillinthispagepleasegiveanexample", "howdoifilloutthispage",
            "howdoifillinthispageshowanexample",
            "이페이지는어떻게입력하나요예를들어주세요", "이페이지는어떻게작성하나요예를보여주세요");
    private static final Set<String> FIELD_SUFFIXES = Set.of(
            "怎么填", "怎么填写", "怎么填写请举例", "怎么填写请举个例子",
            "应该怎么填", "应该怎么填写", "是什么意思", "怎么用", "请举例", "请举个例子");

    private AiChatLocalHelp() {}

    /** Empty field means the whole page; an absent selection means normal model routing. */
    static Optional<String> field(AiChatRequest request, Optional<AiChatPageGuideCatalog.PageGuide> page) {
        if ("PAGE_HELP".equals(request.intentHint())) {
            return Optional.of(request.pageContext().fieldKey() == null ? "" : request.pageContext().fieldKey());
        }
        String question = normalized(request.message());
        if (PAGE_QUESTIONS.contains(question)) return Optional.of("");
        if (page.isEmpty()) return Optional.empty();
        if (page.get().key().equals("sales_order")) {
            for (String name : Set.of("订货单", "销售订货单", "订货档案", "订单")) {
                if (Set.of("如何创建" + name, "如何新建" + name, "怎么创建" + name, "怎么新建" + name,
                        name + "怎么填写", name + "怎么填").contains(question)) return Optional.of("");
            }
        }
        // Full-question matching only. Mixed requests such as "数量怎么填，然后给我财务数据" are
        // not silently turned into a successful local answer or any executable operation.
        for (var field : page.get().fields()) {
            String label = normalized(field.label());
            for (String suffix : FIELD_SUFFIXES) {
                if (question.equals(label + suffix) || question.equals("请解释" + label + suffix)) {
                    return Optional.of(field.key());
                }
            }
        }
        return Optional.empty();
    }

    private static String normalized(String value) {
        return Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
                .replaceAll("[\\s\\p{P}]+", "");
    }
}
