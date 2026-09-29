package com.uten.imp.features.sales.intake;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** 销售侧参考数据的内存替身: 人民币为本位币、美金参考汇率 7.1。 */
final class FakeReferenceData implements IntakeReferenceData {

    static final UUID RMB = UUID.fromString("00000000-0000-0000-0000-00000000c001");
    static final UUID USD = UUID.fromString("00000000-0000-0000-0000-00000000c002");

    final List<CurrencyRow> currencies = new ArrayList<>(List.of(
            new CurrencyRow(RMB, "001", "人民币", BigDecimal.ONE, true),
            new CurrencyRow(USD, "002", "美金", new BigDecimal("7.1"), false),
            new CurrencyRow(UUID.fromString("00000000-0000-0000-0000-00000000c003"), "003", "港币", null, false)));
    final List<LearnedLayout> layouts = new ArrayList<>();
    final Map<UUID, String> sameFileDocs = new LinkedHashMap<>();
    final List<String> upserts = new ArrayList<>();

    @Override
    public List<CurrencyRow> currencies() {
        return currencies;
    }

    @Override
    public List<LearnedLayout> layouts(Collection<String> fingerprints, UUID clientIdOrNull) {
        // 与真实实现同口径: 已选客户 = 自己的 + 全局的; 没选客户 = 全部(全局的 + 各客户的)。
        return layouts.stream().filter(l -> fingerprints.contains(l.fingerprint()))
                .filter(l -> clientIdOrNull == null || l.clientId() == null || l.clientId().equals(clientIdOrNull))
                .toList();
    }

    @Override
    public Map<UUID, String> docsUsingSameFile(String sha256, UUID excludeJobId) {
        return sameFileDocs;
    }

    @Override
    public void upsertLayout(String fingerprint, UUID clientId, String headerTexts, Map<String, String> columnRoles,
                             int headerRowOffset) {
        upserts.add(fingerprint + "|" + clientId + "|" + columnRoles + "|" + headerRowOffset);
    }

    @Override
    public void touchLayout(String fingerprint, UUID clientId) {
        upserts.add("touch|" + fingerprint + "|" + clientId);
    }
}
