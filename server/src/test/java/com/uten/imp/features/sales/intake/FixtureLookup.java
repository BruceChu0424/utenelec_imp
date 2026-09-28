package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.EnumSet;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 用回归夹具模拟主档查询出口(与真实实现同口径: 只返回可见、使用中、未删除、非占位的货品; 名称按「去空白后包含」召回;
 * 型号按规范化后精确召回)。测试可以追加对照、近期单据, 或把可见客户数调成 0。
 */
final class FixtureLookup implements MasterIntakeLookupPort {

    final IntakeFixture fixture;
    final List<AliasRow> aliases = new ArrayList<>();
    final List<DuplicateDocRow> recentDocs = new ArrayList<>();
    final Map<UUID, ClientProfile> profileOverrides = new LinkedHashMap<>();
    final Set<UUID> hiddenClients = new HashSet<>();
    final List<String> calls = new ArrayList<>();
    Integer visibleOverride;

    FixtureLookup(IntakeFixture fixture) {
        this.fixture = fixture;
    }

    private List<IntakeFixture.FixtureClient> visibleClients() {
        return fixture.clients.values().stream().filter(c -> !hiddenClients.contains(c.id())).toList();
    }

    private IntakeFixture.FixtureClient clientById(UUID id) {
        return visibleClients().stream().filter(c -> c.id().equals(id)).findFirst().orElse(null);
    }

    private boolean visible(GoodsRow g) {
        return g != null && !fixture.invisibleGoods.contains(g.id());
    }

    @Override
    public List<ClientCandidate> clientCandidates(ClientCandidateQuery q) {
        calls.add("clientCandidates");
        List<ClientCandidate> out = new ArrayList<>();
        for (IntakeFixture.FixtureClient c : visibleClients()) {
            Set<ClientSignal> signals = EnumSet.noneOf(ClientSignal.class);
            Set<String> tokens = new LinkedHashSet<>();
            String hay = (nz(c.name()) + " " + nz(c.fullName()) + " " + nz(c.nameEn())).toUpperCase(Locale.ROOT);
            for (String t : q.distinctiveTokens()) {
                if (hay.contains(t)) {
                    signals.add(ClientSignal.TOKEN);
                    tokens.add(t);
                }
            }
            if (c.nameEn() != null && q.nameEnNorms().contains(IntakeTextNormalizer.normalizeDescription(c.nameEn()))) {
                signals.add(ClientSignal.NAME_EN_EXACT);
            }
            if (c.placeId() != null && q.placeIds().contains(c.placeId())) {
                signals.add(ClientSignal.PLACE);
            }
            double sim = 0;
            for (String name : q.nameTexts()) {
                sim = Math.max(sim, GoodsMatcher.trigramSimilarity(name.toLowerCase(Locale.ROOT), nz(c.name()).toLowerCase(Locale.ROOT)));
            }
            if (sim >= q.minNameSimilarity()) {
                signals.add(ClientSignal.NAME_SIMILARITY);
            }
            if (!signals.isEmpty()) {
                out.add(new ClientCandidate(c.id(), c.code(), c.name(), c.fullName(), c.nameEn(), c.placeId(), signals,
                        tokens, sim));
            }
        }
        return out;
    }

    @Override
    public int visibleActiveClientCount() {
        return visibleOverride != null ? visibleOverride : visibleClients().size();
    }

    @Override
    public ClientProfile clientProfile(UUID clientId) {
        calls.add("clientProfile");
        if (profileOverrides.containsKey(clientId)) {
            return profileOverrides.get(clientId);
        }
        IntakeFixture.FixtureClient c = clientById(clientId);
        if (c == null) {
            return null;
        }
        return new ClientProfile(c.id(), c.code(), c.name(), c.fullName(), c.nameEn(), null, null, null, null, null,
                null, null, c.placeId(), null, null, null, "使用", List.of(), List.of(), true);
    }

    @Override
    public Map<UUID, ClientGoodsHistory> clientHistory(UUID clientId, int months) {
        calls.add("clientHistory");
        IntakeFixture.FixtureClient c = clientById(clientId);
        Map<UUID, ClientGoodsHistory> out = new LinkedHashMap<>();
        if (c == null) {
            return out;
        }
        LocalDate since = fixture.asOf.minusMonths(months);
        for (IntakeFixture.HistoryItem h : fixture.history.getOrDefault(c.key(), List.of())) {
            if (!h.lastOrderDate().isBefore(since) && visible(fixture.goodsById.get(h.goodsId()))) {
                out.put(h.goodsId(), new ClientGoodsHistory(h.goodsId(), h.orderCount(), h.lastOrderDate()));
            }
        }
        return out;
    }

    @Override
    public Map<UUID, Set<UUID>> historyContains(Collection<UUID> clientIds, Collection<UUID> goodsIds) {
        calls.add("historyContains:" + clientIds.size());
        if (clientIds.isEmpty()) {
            // 与真实实现相同: 空客户集合返回空(不是「全部可见客户」)。
            return Map.of();
        }
        Set<UUID> wanted = new HashSet<>(goodsIds);
        Map<UUID, Set<UUID>> out = new LinkedHashMap<>();
        for (IntakeFixture.FixtureClient c : visibleClients()) {
            if (!clientIds.contains(c.id())) {
                continue;
            }
            Set<UUID> bought = new LinkedHashSet<>();
            for (IntakeFixture.HistoryItem h : fixture.history.getOrDefault(c.key(), List.of())) {
                if (wanted.contains(h.goodsId())) {
                    bought.add(h.goodsId());
                }
            }
            if (!bought.isEmpty()) {
                out.put(c.id(), bought);
            }
        }
        return out;
    }

    @Override
    public List<GoodsRow> goodsByModelNorm(Collection<String> modelNorms) {
        calls.add("goodsByModelNorm");
        Set<String> wanted = new HashSet<>(modelNorms);
        List<GoodsRow> out = new ArrayList<>();
        for (GoodsRow g : fixture.goods) {
            if (visible(g) && g.model() != null && wanted.contains(IntakeTextNormalizer.normalizePart(g.model()))) {
                out.add(g);
            }
        }
        return out;
    }

    @Override
    public List<GoodsRow> goodsByCode(Collection<String> codes) {
        calls.add("goodsByCode");
        Set<String> wanted = new HashSet<>();
        codes.forEach(c -> wanted.add(c.toUpperCase(Locale.ROOT)));
        return fixture.goods.stream().filter(this::visible)
                .filter(g -> g.code() != null && wanted.contains(g.code().toUpperCase(Locale.ROOT))).toList();
    }

    @Override
    public List<GoodsRow> goodsByNameCandidates(Collection<String> cnTexts, int limit) {
        calls.add("goodsByNameCandidates");
        List<String> needles = cnTexts.stream().map(t -> squash(t)).filter(t -> !t.isEmpty()).toList();
        List<GoodsRow> out = new ArrayList<>();
        for (GoodsRow g : fixture.goods) {
            if (out.size() >= limit) {
                break;
            }
            String name = squash(g.name());
            if (visible(g) && needles.stream().anyMatch(name::contains)) {
                out.add(g);
            }
        }
        return out;
    }

    @Override
    public List<GoodsRow> goodsByNameEn(Collection<String> texts, int limit) {
        calls.add("goodsByNameEn");
        List<GoodsRow> out = new ArrayList<>();
        for (GoodsRow g : fixture.goods) {
            if (out.size() >= limit || g.nameEn() == null || !visible(g)) {
                continue;
            }
            String en = IntakeTextNormalizer.normalizeDescription(g.nameEn());
            for (String t : texts) {
                String n = IntakeTextNormalizer.normalizeDescription(t);
                if (en.equals(n) || GoodsMatcher.trigramSimilarity(en, n) >= 0.3) {
                    out.add(g);
                    break;
                }
            }
        }
        return out;
    }

    @Override
    public List<GoodsRow> goodsByIds(Collection<UUID> ids) {
        calls.add("goodsByIds");
        List<GoodsRow> out = new ArrayList<>();
        for (UUID id : ids) {
            GoodsRow g = fixture.goodsById.get(id);
            if (visible(g)) {
                out.add(g);
            }
        }
        return out;
    }

    @Override
    public List<AliasRow> aliases(UUID clientIdOrNull, Collection<String> partNorms, Collection<String> descNorms) {
        calls.add("aliases");
        List<AliasRow> out = new ArrayList<>();
        for (AliasRow a : aliases) {
            boolean scopeOk = a.scope() == AliasScope.GLOBAL || (clientIdOrNull != null && clientIdOrNull.equals(a.clientId()));
            boolean textOk = a.kind() == AliasKind.PART_NO ? partNorms.contains(a.norm()) : descNorms.contains(a.norm());
            if (scopeOk && textOk && visible(fixture.goodsById.get(a.goodsId()))) {
                out.add(a);
            }
        }
        return out;
    }

    @Override
    public List<DuplicateDocRow> recentDocs(UUID clientId, int days) {
        calls.add("recentDocs");
        return List.copyOf(recentDocs);
    }

    @Override
    public CreatedClient createClientFromDocument(NewClientRequest req) {
        throw new UnsupportedOperationException("not used by intake");
    }

    private static String squash(String s) {
        return IntakeTextNormalizer.nfkc(s).replaceAll("\\s+", "").toLowerCase(Locale.ROOT);
    }

    private static String nz(String s) {
        return s == null ? "" : s;
    }
}
