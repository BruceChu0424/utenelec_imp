package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidate;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidateQuery;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientSignal;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 客户匹配(SPEC §5.6)。纯计算: 候选来自 {@code MasterIntakeLookupPort.clientCandidates}(只有当前用户看得到的启用客户)
 * 与「篮子重合度」(文件里的货品这个客户买过多少行)。
 *
 * <p>分数: 邮箱一致 98、外文名一致 95、电话一致 90、名称特征词 88、邮箱域名 85、名称相似 50+45×相似度、国家 55;
 * 篮子 50+45×重合比例(须比第二名高 0.25 以上, 只靠篮子不自动选定, 只预选待核对)。
 * 自动选定(MATCHED)要求最高 ≥ 85、比第二名高 ≥ 10、且不是只靠篮子。
 */
final class ClientMatcher {

    static final double MATCH_MIN = 85;
    static final double MATCH_MARGIN = 10;
    static final double REVIEW_MIN = 50;
    static final double BASKET_MARGIN = 0.25;
    static final double NAME_SIMILARITY_MIN = 0.5;
    static final int MAX_CANDIDATES = 5;

    static final Set<String> STOP_TOKENS = Set.of("ELECTRIC", "ELECTRICAL", "ELECTRICALS", "ELECTRONIC", "ELECTRONICS",
            "TRADING", "TRADE", "TRADERS", "INDUSTRIES", "INDUSTRIAL", "INDUSTRY", "LIMITED", "GROUP", "COMPANY", "INTERNATIONAL",
            "GENERAL", "ENTERPRISE", "ENTERPRISES", "IMPORT", "IMPORTS", "EXPORT", "EXPORTS", "CORP", "CORPORATION", "HOLDING",
            "HOLDINGS", "RESOURCE", "RESOURCES", "SOLUTION", "SOLUTIONS", "SERVICE", "SERVICES", "SUPPLY", "SUPPLIES",
            "SUPPLIER", "SUPPLIERS", "GLOBAL", "NATIONAL", "UNITED", "TECHNOLOGY", "TECHNOLOGIES", "ENGINEERING", "SYSTEMS",
            "POWER", "LIGHTING", "LIGHTS", "CABLE", "CABLES", "PRODUCTS", "MARKETING", "DISTRIBUTION", "DISTRIBUTORS",
            "AGENCY", "AGENCIES", "ESTABLISHMENT", "BROTHERS", "PARTNERS", "MATERIALS", "EQUIPMENT", "BUILDING",
            "CONSTRUCTION", "CONTRACTING", "COMMERCIAL", "STREET", "ROAD", "BUYER", "CUSTOMER", "ADDRESS");
    static final Set<String> FREE_MAIL_DOMAINS = Set.of("gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk",
            "hotmail.com", "outlook.com", "live.com", "msn.com", "icloud.com", "me.com", "aol.com", "mail.ru", "yandex.ru",
            "yandex.com", "protonmail.com", "proton.me", "gmx.com", "gmx.net", "163.com", "126.com", "yeah.net", "qq.com",
            "foxmail.com", "sina.com", "sina.cn", "sohu.com", "139.com", "189.cn", "ymail.com", "rocketmail.com",
            "zoho.com", "mail.com", "inbox.com");
    private static final Pattern LATIN_TOKEN = Pattern.compile("[A-Za-z][A-Za-z0-9&'\\-]*");

    private ClientMatcher() {
    }

    /** 由表头组装候选查询(邮箱/域名/电话后 8 位/外文名/特征词/国家)。 */
    static ClientCandidateQuery query(IntakeHeader header) {
        Set<String> emails = new LinkedHashSet<>();
        Set<String> domains = new LinkedHashSet<>();
        for (String e : header.emails) {
            String lower = e.toLowerCase(Locale.ROOT);
            emails.add(lower);
            int at = lower.lastIndexOf('@');
            if (at > 0 && at < lower.length() - 1) {
                String domain = lower.substring(at + 1);
                if (!FREE_MAIL_DOMAINS.contains(domain)) {
                    domains.add(domain);
                }
            }
        }
        Set<String> phones = new LinkedHashSet<>();
        for (String p : header.phones) {
            String digits = p.replaceAll("\\D", "");
            if (digits.length() >= 8) {
                phones.add(digits.substring(digits.length() - 8));
            }
        }
        Set<String> nameEn = new LinkedHashSet<>();
        List<String> names = new ArrayList<>();
        Set<String> tokens = new LinkedHashSet<>();
        if (header.buyerName != null) {
            String norm = IntakeTextNormalizer.normalizeDescription(header.buyerName);
            if (!norm.isEmpty()) {
                nameEn.add(norm);
            }
            names.add(header.buyerName);
            tokens.addAll(distinctiveTokens(header.buyerName));
        }
        Set<String> places = IntakeCountries.placeIds(header.country);
        return new ClientCandidateQuery(emails, domains, phones, nameEn, names, tokens, places, NAME_SIMILARITY_MIN, 20);
    }

    /** 买方名称里的拉丁特征词: 大写、≥ 4 个字符、去掉公司通用词。 */
    static Set<String> distinctiveTokens(String buyerName) {
        Set<String> out = new LinkedHashSet<>();
        if (buyerName == null) {
            return out;
        }
        Matcher m = LATIN_TOKEN.matcher(IntakeTextNormalizer.nfkc(buyerName));
        while (m.find()) {
            String t = m.group().toUpperCase(Locale.ROOT).replaceAll("[^A-Z0-9]", "");
            if (t.length() >= 4 && !STOP_TOKENS.contains(t) && !t.chars().allMatch(Character::isDigit)) {
                out.add(t);
            }
        }
        return out;
    }

    /** 一个客户候选的打分。 */
    static final class ScoredClient {
        final UUID clientId;
        ClientCandidate candidate;
        double signalScore;
        double basketScore;
        int basketLines;
        final List<String> reasons = new ArrayList<>();
        double score;

        ScoredClient(UUID clientId) {
            this.clientId = clientId;
        }

        boolean basketOnly() {
            return signalScore < MATCH_MIN;
        }
    }

    /**
     * 匹配结果。
     *
     * @param status            MATCHED / REVIEW / UNMATCHED / PRESET / NO_VISIBLE_CLIENTS
     * @param selectedClientId  选定或预选的客户
     * @param ranked            候选(分数从高到低, 最多 5 个)
     * @param strongOther       预选客户以外、线索很强(≥ 85)的客户(用于「文件上的买方像是 X」提醒); 没有为 null
     */
    record Result(String status, UUID selectedClientId, List<ScoredClient> ranked, ScoredClient strongOther) {
    }

    /**
     * @param candidates     按线索召回的候选
     * @param basket         客户 → 其买过的货品(只含本文件候选货品)
     * @param lineGoodsSets  每个文件行不看客户时的前 8 个候选货品
     * @param preselected    用户已经选的客户(可为空)
     * @param visibleClients 用户可见的启用客户数
     * @param country        文件上的国家主写法(理由里显示)
     */
    static Result match(List<ClientCandidate> candidates, Map<UUID, Set<UUID>> basket, List<Set<UUID>> lineGoodsSets,
                        UUID preselected, int visibleClients, String country) {
        if (visibleClients <= 0) {
            return new Result("NO_VISIBLE_CLIENTS", null, List.of(), null);
        }
        Map<UUID, ScoredClient> scored = new LinkedHashMap<>();
        for (ClientCandidate c : candidates) {
            ScoredClient s = scored.computeIfAbsent(c.clientId(), ScoredClient::new);
            s.candidate = c;
            double best = 0;
            int strong = 0;
            for (ClientSignal signal : c.signals()) {
                double v = switch (signal) {
                    case EMAIL -> 98;
                    case NAME_EN_EXACT -> 95;
                    case PHONE -> 90;
                    case TOKEN -> 88;
                    case EMAIL_DOMAIN -> 85;
                    case NAME_SIMILARITY -> c.nameSimilarity() >= NAME_SIMILARITY_MIN ? 50 + 45 * c.nameSimilarity() : 0;
                    case PLACE -> 55;
                };
                if (v <= 0) {
                    continue;
                }
                best = Math.max(best, v);
                if (signal != ClientSignal.PLACE && v >= MATCH_MIN) {
                    strong++;
                }
                s.reasons.add(reason(signal, c, country));
            }
            s.signalScore = strong >= 2 ? Math.min(99, best + 3) : best;
        }
        // 篮子重合度
        int lineCount = (int) lineGoodsSets.stream().filter(set -> !set.isEmpty()).count();
        if (lineCount > 0 && basket != null) {
            List<ScoredClient> byBasket = new ArrayList<>();
            for (Map.Entry<UUID, Set<UUID>> e : basket.entrySet()) {
                int n = 0;
                for (Set<UUID> goods : lineGoodsSets) {
                    if (!goods.isEmpty() && intersects(goods, e.getValue())) {
                        n++;
                    }
                }
                if (n > 0) {
                    ScoredClient s = scored.computeIfAbsent(e.getKey(), ScoredClient::new);
                    s.basketLines = n;
                    byBasket.add(s);
                }
            }
            byBasket.sort(Comparator.comparingInt((ScoredClient s) -> -s.basketLines));
            if (!byBasket.isEmpty()) {
                ScoredClient best = byBasket.getFirst();
                double bestShare = (double) best.basketLines / lineCount;
                double runnerShare = byBasket.size() > 1 ? (double) byBasket.get(1).basketLines / lineCount : 0;
                if (bestShare - runnerShare >= BASKET_MARGIN) {
                    best.basketScore = 50 + 45 * bestShare;
                }
            }
            for (ScoredClient s : byBasket) {
                s.reasons.add(s.basketLines == lineCount ? "文件里的货品该客户都买过"
                        : "文件里 " + s.basketLines + "/" + lineCount + " 个货品该客户买过");
            }
        }
        for (ScoredClient s : scored.values()) {
            double v = Math.max(s.signalScore, s.basketScore);
            if (s.signalScore >= MATCH_MIN && s.basketScore > 0) {
                v = Math.min(99, v + 3);
            }
            s.score = v;
        }
        List<ScoredClient> ranked = new ArrayList<>(scored.values());
        ranked.removeIf(s -> s.score <= 0 && !s.clientId.equals(preselected));
        ranked.sort(Comparator.comparingDouble((ScoredClient s) -> -s.score)
                .thenComparingInt(s -> -s.basketLines));
        if (preselected != null) {
            ScoredClient strongOther = null;
            ScoredClient self = scored.get(preselected);
            double selfSignal = self == null ? 0 : self.signalScore;
            for (ScoredClient s : ranked) {
                if (!s.clientId.equals(preselected) && s.signalScore >= MATCH_MIN && s.signalScore > selfSignal) {
                    strongOther = s;
                    break;
                }
            }
            return new Result("PRESET", preselected, limit(ranked), strongOther);
        }
        if (ranked.isEmpty()) {
            return new Result("UNMATCHED", null, List.of(), null);
        }
        ScoredClient best = ranked.getFirst();
        double second = ranked.size() > 1 ? ranked.get(1).score : 0;
        if (best.score >= MATCH_MIN && best.score - second >= MATCH_MARGIN && !best.basketOnly()) {
            return new Result("MATCHED", best.clientId, limit(ranked), null);
        }
        if (best.score >= REVIEW_MIN) {
            return new Result("REVIEW", best.clientId, limit(ranked), null);
        }
        return new Result("UNMATCHED", null, limit(ranked), null);
    }

    private static List<ScoredClient> limit(List<ScoredClient> ranked) {
        return List.copyOf(ranked.subList(0, Math.min(MAX_CANDIDATES, ranked.size())));
    }

    private static boolean intersects(Set<UUID> a, Collection<UUID> b) {
        for (UUID id : a) {
            if (b.contains(id)) {
                return true;
            }
        }
        return false;
    }

    private static String reason(ClientSignal signal, ClientCandidate c, String country) {
        return switch (signal) {
            case EMAIL -> "邮箱一致";
            case EMAIL_DOMAIN -> "邮箱域名一致";
            case NAME_EN_EXACT -> "外文名称一致";
            case PHONE -> "电话一致";
            case TOKEN -> c.matchedTokens().isEmpty() ? "名称里有文件上的买方名"
                    : "名称里有「" + String.join("、", c.matchedTokens()) + "」";
            case NAME_SIMILARITY -> "名称相似";
            case PLACE -> country == null ? "国家/地区一致" : "国家/地区一致(" + country + ")";
        };
    }

    /** 篮子查询用: 每行不看客户时的前 8 个候选货品 id。 */
    static List<Set<UUID>> lineGoodsSets(Map<String, List<GoodsMatcher.Scored>> freeRankings) {
        List<Set<UUID>> out = new ArrayList<>();
        for (List<GoodsMatcher.Scored> ranked : freeRankings.values()) {
            Set<UUID> ids = new LinkedHashSet<>();
            for (GoodsMatcher.Scored s : GoodsMatcher.top(ranked, GoodsMatcher.TOP_K)) {
                ids.add(s.goods.id());
            }
            out.add(ids);
        }
        return out;
    }

    /** 全部候选货品 id(篮子查询的货品范围)。 */
    static Set<UUID> allGoods(List<Set<UUID>> lineGoodsSets) {
        Set<UUID> out = new LinkedHashSet<>();
        lineGoodsSets.forEach(out::addAll);
        return out;
    }
}
