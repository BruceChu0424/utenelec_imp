package com.uten.imp.features.master.platformcolumns;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;

import java.math.BigDecimal;
import java.util.*;
import java.util.function.Function;
import java.util.function.Predicate;

/** Fixed master registrations, using the same detail scope and object write capability as each master editor. */
public final class MasterPlatformColumnAdapter implements PlatformColumnResourceAdapter {
    private final String scope;
    private final String label;
    private final String reader;
    private final String writer;
    private final Set<String> priceReaders;
    private final Class<?> entityClass;
    private final Function<UUID, ?> detail;
    private final Predicate<JsonNode> writable;
    private final List<FactDefinition> facts;
    private final SecurityContextCurrentUser current;
    private final EntityManager em;
    private final ObjectMapper json;

    public MasterPlatformColumnAdapter(String scope, String label, String permission, Set<String> priceReaders,
            Class<?> entityClass, Function<UUID, ?> detail, Predicate<JsonNode> writable, List<FactDefinition> facts,
            SecurityContextCurrentUser current, EntityManager em, ObjectMapper json) {
        this.scope = scope; this.label = label; this.reader = permission + ":view"; this.writer = permission + ":edit";
        this.priceReaders = Set.copyOf(priceReaders); this.entityClass = entityClass; this.detail = detail;
        this.writable = writable; this.facts = List.copyOf(facts); this.current = current; this.em = em; this.json = json;
    }
    @Override public String scope() { return scope; }
    @Override public String label() { return label; }
    @Override public List<FactDefinition> facts() { return facts; }
    public boolean preserveValuesOnReset() { return true; }
    @Override public boolean canWrite() { return has(reader) && has(writer) && current.get().orElseThrow().getImpersonatedBy() == null; }
    @Override public boolean canViewPrice() { return priceReaders.stream().anyMatch(this::has); }
    @Override public void requireDefinitionAccess(boolean write) {
        if (!has(reader) || write && !canWrite()) throw new ApiException(ErrorCode.FORBIDDEN);
    }
    private boolean has(String authority) {
        return current.get().filter(user -> !user.isVisitor()).map(user -> user.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority()))).orElse(false);
    }
    @Override public Map<UUID, RecordAccess> authorize(Set<UUID> ids, boolean write) {
        requireDefinitionAccess(write);
        if (ids == null || ids.stream().anyMatch(Objects::isNull)) throw new ApiException(ErrorCode.VALIDATION_FAILED, "主档记录编号不能为空");
        Map<UUID, RecordAccess> result = new LinkedHashMap<>();
        for (UUID id : ids.stream().sorted().toList()) {
            if (write) {
                Object entity = em.find(entityClass, id, LockModeType.PESSIMISTIC_WRITE);
                if (entity == null) throw missing();
                em.refresh(entity, LockModeType.PESSIMISTIC_WRITE);
            }
            // This calls existing owner filtering; explicit customer shares remain read-only through writable.
            JsonNode record = json.valueToTree(detail.apply(id));
            if (record == null || record.isNull() || !id.toString().equals(record.path("id").asText())) throw missing();
            boolean allowed = canWrite() && writable.test(record);
            if (write && !allowed) throw new ApiException(ErrorCode.FORBIDDEN, "你无权修改这条主档的扩展信息");
            boolean price = canViewPrice() && !record.path("priceMasked").asBoolean(false);
            Map<String, BigDecimal> values = new LinkedHashMap<>();
            for (FactDefinition fact : facts) {
                if (fact.priceProtected() && !price) continue;
                JsonNode value = record.get(fact.key() + "Exact");
                if (value == null || value.isNull()) value = record.get(fact.key() + "Text");
                if (value == null || value.isNull()) value = record.get(fact.key());
                if (value == null || value.isNull() || !(value.isTextual() || value.isNumber())) continue;
                try { values.put(fact.key(), new BigDecimal(value.asText())); }
                catch (NumberFormatException ignored) { /* Unknown facts are absent, never zero. */ }
            }
            result.put(id, new RecordAccess(allowed, price, values));
        }
        return result;
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "主档记录不存在或不在查看范围内"); }
}
