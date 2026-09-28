package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.features.master.goods.GoodsNameEn;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 一次保存要学什么(纯函数, 不碰数据库; ADR-134 学习规则的唯一实现处)。
 *
 * <ol>
 *   <li>只学「用户明确选择/改成」的行, 或识别结果里「已自动对应」且用户没改货品的行;</li>
 *   <li>客户型号(PART_NO)与客户品名(DESCRIPTION)都学成该客户的对照, 上下文取识别结果里该行的
 *       「系列|主色」; 手打的原文(与识别结果对不上)只学客户对照;</li>
 *   <li>与识别结果原文一致的才另学一份全局对照(不分客户; 可信度按确认过的不同客户数计, 用的时候要求至少
 *       2 个客户, 见 {@link ClientGoodsAliasLedger});</li>
 *   <li>同一张单据里同一个叫法(同上下文)对到不止一个货品时, 这个叫法这次不学(拆开的组合件、同号不同款);</li>
 *   <li>货品英文名称: 该行勾选了「设为货品英文名」, 保存的文件品名与识别结果里的英文描述一致, 文本是
 *       至少两个单词的英文; 同一张单据里同一段英文对到不止一个货品、或同一货品出现两段不同英文时都不学。</li>
 * </ol>
 * 权限、客户写范围、货品是否在用、与其它货品英文名是否重复等要查库的判断在应用阶段做。
 */
final class SalesLearningPlanner {

    /** client_goods_aliases.alias_text / alias_norm 的列宽。 */
    static final int MAX_ALIAS_LENGTH = 500;
    /** client_goods_aliases.context_norm 的列宽。 */
    static final int MAX_CONTEXT_LENGTH = 200;

    private static final Pattern WORD_SPLIT = Pattern.compile("[^\\p{L}\\p{N}]+");

    private SalesLearningPlanner() {
    }

    /** 一条对照写入(同一键在一次保存里只出现一次)。 */
    record AliasUpsert(AliasScope scope, UUID clientId, AliasKind kind, String text, String norm,
                       String context, UUID goodsId, boolean explicit) {

        AliasKey key() {
            return new AliasKey(scope == AliasScope.GLOBAL ? null : clientId, kind, norm, context);
        }
    }

    /** 对照键(不含货品): 客户(全局为空)、种类、规范化叫法、上下文。 */
    record AliasKey(UUID clientId, AliasKind kind, String norm, String context) {
    }

    /** 一条英文名称学习候选。 */
    record NameEnCandidate(UUID goodsId, String text) {
    }

    /** 学习计划。 */
    record Plan(List<AliasUpsert> aliases, List<NameEnCandidate> nameEn) {

        boolean isEmpty() {
            return aliases.isEmpty() && nameEn.isEmpty();
        }
    }

    static Plan plan(SalesLearningRequest request, IntakeJobLines jobLines) {
        IntakeJobLines job = jobLines == null ? IntakeJobLines.empty() : jobLines;
        Map<String, AliasUpsert> aliases = new LinkedHashMap<>();
        Map<AliasKey, Set<UUID>> goodsPerKey = new HashMap<>();
        List<NameEnCandidate> nameEnRaw = new ArrayList<>();
        UUID clientId = request.clientId();

        for (LearnedLine line : request.lines()) {
            if (line == null || line.goodsId() == null) continue;
            IntakeJobLines.JobLine jobLine = job.line(line.intakeLineKey());
            boolean learnable = line.userConfirmed()
                    || (jobLine != null && jobLine.matchedUnchanged(line.goodsId()));
            if (!learnable) continue;
            String context = context(jobLine);
            if (context == null) continue;

            // 客户型号 / 货号
            String model = ClientDocumentFields.clean(line.clientModel());
            String partNorm = model == null ? "" : IntakeTextNormalizer.normalizePart(model);
            if (usable(model, partNorm)) {
                boolean fromJob = jobLine != null && jobLine.partNo() != null
                        && partNorm.equals(IntakeTextNormalizer.normalizePart(jobLine.partNo()));
                addAlias(aliases, goodsPerKey, clientId, AliasKind.PART_NO, model, partNorm, context,
                        line.goodsId(), line.userConfirmed(), fromJob);
            }

            // 客户品名 / 描述
            String name = ClientDocumentFields.clean(line.clientGoodsName());
            String descNorm = name == null ? "" : IntakeTextNormalizer.normalizeDescription(name);
            if (usable(name, descNorm)) {
                boolean fromJob = jobLine != null
                        && (descNorm.equals(normDesc(jobLine.description()))
                        || descNorm.equals(normDesc(jobLine.descriptionAlt())));
                addAlias(aliases, goodsPerKey, clientId, AliasKind.DESCRIPTION, name, descNorm, context,
                        line.goodsId(), line.userConfirmed(), fromJob);
            }

            // 货品英文名称(只认识别结果里的英文描述)
            if (line.setNameEn() && jobLine != null && jobLine.description() != null
                    && !descNorm.isEmpty() && descNorm.equals(normDesc(jobLine.description()))) {
                String text = GoodsNameEn.normalize(
                        jobLine.nameEnText() != null && !jobLine.nameEnText().isBlank()
                                ? jobLine.nameEnText() : jobLine.description());
                if (distinctiveEnglish(text)) {
                    nameEnRaw.add(new NameEnCandidate(line.goodsId(), text));
                }
            }
        }

        // 同一张单据里同一个叫法对到不止一个货品: 这个叫法这次不学。
        List<AliasUpsert> resolved = new ArrayList<>();
        for (AliasUpsert alias : aliases.values()) {
            if (goodsPerKey.getOrDefault(alias.key(), Set.of()).size() == 1) resolved.add(alias);
        }
        resolved.sort(Comparator.comparing((AliasUpsert a) -> a.goodsId().toString())
                .thenComparing(a -> a.scope().name())
                .thenComparing(a -> a.kind().name())
                .thenComparing(AliasUpsert::norm)
                .thenComparing(AliasUpsert::context));

        return new Plan(List.copyOf(resolved), resolveNameEn(nameEnRaw));
    }

    /** 同一段英文对到多个货品、或同一货品两段不同英文: 都不学; 其余按货品 id 排序。 */
    private static List<NameEnCandidate> resolveNameEn(List<NameEnCandidate> raw) {
        Map<String, Set<UUID>> goodsPerText = new HashMap<>();
        Map<UUID, Set<String>> textsPerGoods = new HashMap<>();
        Map<UUID, String> firstText = new LinkedHashMap<>();
        for (NameEnCandidate candidate : raw) {
            String key = GoodsNameEn.matchKey(candidate.text());
            if (key == null) continue;
            goodsPerText.computeIfAbsent(key, ignored -> new HashSet<>()).add(candidate.goodsId());
            textsPerGoods.computeIfAbsent(candidate.goodsId(), ignored -> new HashSet<>()).add(key);
            firstText.putIfAbsent(candidate.goodsId(), candidate.text());
        }
        List<NameEnCandidate> out = new ArrayList<>();
        for (Map.Entry<UUID, String> entry : firstText.entrySet()) {
            Set<String> texts = textsPerGoods.get(entry.getKey());
            if (texts.size() != 1) continue;
            if (goodsPerText.get(texts.iterator().next()).size() != 1) continue;
            out.add(new NameEnCandidate(entry.getKey(), entry.getValue()));
        }
        out.sort(Comparator.comparing(candidate -> candidate.goodsId().toString()));
        return List.copyOf(out);
    }

    private static void addAlias(Map<String, AliasUpsert> aliases, Map<AliasKey, Set<UUID>> goodsPerKey,
                                 UUID clientId, AliasKind kind, String text, String norm, String context,
                                 UUID goodsId, boolean explicit, boolean fromJob) {
        if (clientId != null) {
            merge(aliases, goodsPerKey,
                    new AliasUpsert(AliasScope.CLIENT, clientId, kind, text, norm, context, goodsId, explicit));
        }
        if (fromJob) {
            merge(aliases, goodsPerKey,
                    new AliasUpsert(AliasScope.GLOBAL, null, kind, text, norm, context, goodsId, explicit));
        }
    }

    private static void merge(Map<String, AliasUpsert> aliases, Map<AliasKey, Set<UUID>> goodsPerKey,
                              AliasUpsert alias) {
        goodsPerKey.computeIfAbsent(alias.key(), ignored -> new HashSet<>()).add(alias.goodsId());
        String identity = alias.scope() + "|" + alias.clientId() + "|" + alias.kind() + "|" + alias.norm()
                + "|" + alias.context() + "|" + alias.goodsId();
        AliasUpsert existing = aliases.get(identity);
        if (existing == null) {
            aliases.put(identity, alias);
        } else if (alias.explicit() && !existing.explicit()) {
            // 同一键同一货品出现多行: 只计一次, 任一行是明确选择就算明确选择; 原文取最后一行。
            aliases.put(identity, alias);
        } else if (!Objects.equals(existing.text(), alias.text())) {
            aliases.put(identity, new AliasUpsert(existing.scope(), existing.clientId(), existing.kind(),
                    alias.text(), existing.norm(), existing.context(), existing.goodsId(),
                    existing.explicit() || alias.explicit()));
        }
    }

    private static boolean usable(String text, String norm) {
        return text != null && !norm.isEmpty()
                && text.length() <= MAX_ALIAS_LENGTH && norm.length() <= MAX_ALIAS_LENGTH;
    }

    /**
     * 上下文取识别结果里该行的「系列|主色」原样(识别与匹配同一口径); 没有识别行为空串;
     * 超长或含控制字符返回 null(不学)。
     */
    private static String context(IntakeJobLines.JobLine jobLine) {
        if (jobLine == null || jobLine.contextNorm() == null) return "";
        String context = jobLine.contextNorm().strip();
        if (context.chars().allMatch(ch -> ch == '|')) return "";
        if (context.chars().anyMatch(Character::isISOControl)) return null;
        return context.length() > MAX_CONTEXT_LENGTH ? null : context;
    }

    private static String normDesc(String text) {
        return text == null ? null : IntakeTextNormalizer.normalizeDescription(text);
    }

    /** 可学成英文名称的文本: 英文为主、不含汉字与控制字符、至少两个单词、不超过列宽。 */
    static boolean distinctiveEnglish(String text) {
        if (text == null || text.codePointCount(0, text.length()) > GoodsNameEn.MAX_LENGTH) return false;
        if (text.chars().anyMatch(Character::isISOControl)) return false;
        if (IntakeTextNormalizer.hasCjk(text) || !IntakeTextNormalizer.isLatinDominant(text)) return false;
        int words = 0;
        for (String token : WORD_SPLIT.split(text)) {
            if (!token.isEmpty() && token.chars().anyMatch(Character::isLetter)) words++;
        }
        return words >= 2;
    }
}
