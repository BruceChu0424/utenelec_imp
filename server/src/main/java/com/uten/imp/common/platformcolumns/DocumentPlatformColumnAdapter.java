package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;

import java.math.BigDecimal;
import java.util.*;
import java.util.function.BiPredicate;
import java.util.function.BiConsumer;
import java.util.function.Function;

/**
 * Shared document/line adapter. Domain registrations supply only fixed SQL and
 * their existing detail and owner policies. No identifier comes from a request.
 * Header locks are acquired in a deterministic order before state is inspected.
 */
public final class DocumentPlatformColumnAdapter implements PlatformColumnResourceAdapter {
    private final String scope;
    private final String label;
    private final SecurityContextCurrentUser current;
    private final EntityManager em;
    private final ObjectMapper json;
    private final Set<String> readers;
    private final Set<String> writers;
    private final Set<String> priceReaders;
    private final Class<?> headerEntity;
    private final String parentLookup;
    private final Function<UUID, Object> detail;
    private final BiPredicate<UUID, JsonNode> writable;
    private final List<FactDefinition> facts;
    private String documentRowsLookup;
    private Set<String> creators = Set.of();
    private BiConsumer<UUID,Object> documentSaveLocks = (id,request) -> { };
    private Function<UUID,Object> historyDetail;
    private String historicalParentLookup;

    public DocumentPlatformColumnAdapter(String scope, String label, SecurityContextCurrentUser current,
            EntityManager em, ObjectMapper json, Set<String> readers, Set<String> writers,
            Set<String> priceReaders, Class<?> headerEntity, String parentLookup,
            Function<UUID, Object> detail, BiPredicate<UUID, JsonNode> writable, List<FactDefinition> facts) {
        this.scope = scope; this.label = label; this.current = current; this.em = em; this.json = json;
        this.readers = Set.copyOf(readers); this.writers = Set.copyOf(writers);
        this.priceReaders = Set.copyOf(priceReaders); this.headerEntity = headerEntity;
        this.parentLookup = parentLookup; this.detail = detail; this.writable = writable;
        this.facts = List.copyOf(facts);
    }

    @Override public String scope() { return scope; }
    @Override public String label() { return label; }
    @Override public List<FactDefinition> facts() { return facts; }
    @Override public boolean canWrite() {
        return hasAny(writers) && current.get().map(user -> user.getImpersonatedBy() == null).orElse(false);
    }
    @Override public boolean canCreate() {
        return hasAny(creators) && current.get().map(user -> user.getImpersonatedBy() == null).orElse(false);
    }
    @Override public boolean canViewPrice() { return !priceReaders.isEmpty() && hasAny(priceReaders); }
    @Override public void requireDefinitionAccess(boolean write) {
        if (!hasAny(readers) || (write && !canWrite() && !canCreate())) throw new ApiException(ErrorCode.FORBIDDEN);
    }

    /** Fixed domain-owned lookup used by the atomic document-save bridge. */
    public DocumentPlatformColumnAdapter documentRows(String query) {
        if (documentRowsLookup != null || parentLookup == null) throw new IllegalStateException("Invalid document row registration");
        documentRowsLookup = Objects.requireNonNull(query);
        return this;
    }

    /** Fixed trusted domain registration, never caller-provided SQL or a fallback authorization rule. */
    public DocumentPlatformColumnAdapter history(Function<UUID,Object> nativeHistoryDetail,String fixedHistoricalParentLookup) {
        if(historyDetail!=null||(parentLookup!=null&&(fixedHistoricalParentLookup==null||fixedHistoricalParentLookup.isBlank()))
                ||(parentLookup==null&&fixedHistoricalParentLookup!=null))throw new IllegalStateException("Invalid document history registration");
        historyDetail=Objects.requireNonNull(nativeHistoryDetail);historicalParentLookup=fixedHistoricalParentLookup;return this;
    }

    @Override public Map<UUID,RecordAccess> authorizeHistory(Set<UUID> ids) {
        if(historyDetail==null)return PlatformColumnResourceAdapter.super.authorizeHistory(ids);
        requireDefinitionAccess(false);
        Map<UUID,UUID> parents=new LinkedHashMap<>();
        if(parentLookup==null)ids.forEach(id->parents.put(id,id));
        else {
            @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery(historicalParentLookup).setParameter("ids",ids).getResultList();
            for(Object[] row:rows){UUID id=(UUID)row[0],parent=(UUID)row[1];
                if(id==null||parent==null||!ids.contains(id))throw missing();
                UUID previous=parents.putIfAbsent(id,parent);if(previous!=null&&!previous.equals(parent))throw missing();}
            if(!parents.keySet().equals(ids))throw missing();
        }
        var headers=new HashMap<UUID,JsonNode>();var result=new LinkedHashMap<UUID,RecordAccess>();
        for(UUID id:ids) {
            JsonNode header=headers.computeIfAbsent(parents.get(id),key->json.valueToTree(historyDetail.apply(key)));
            if(header==null||header.isNull()||!parents.get(id).toString().equals(header.path("id").asText()))throw missing();
            boolean price=canViewPrice()&&header.path("priceVisible").asBoolean(true)
                && !header.path("priceMasked").asBoolean(false)&&!header.path("costMasked").asBoolean(false);
            // Historical formulas never silently calculate against today's mutable native quantities/prices.
            result.put(id,new RecordAccess(false,price,Map.of()));
        }
        return result;
    }

    public DocumentPlatformColumnAdapter documentCreateAuthorities(Set<String> permissions) {
        creators = Set.copyOf(permissions);
        return this;
    }

    /** Fixed domain registration; request types and lock plans never come from client-supplied metadata. */
    public <R> DocumentPlatformColumnAdapter documentSaveLocks(Class<R> requestType,BiConsumer<UUID,R> locks) {
        Objects.requireNonNull(requestType);Objects.requireNonNull(locks);
        documentSaveLocks = (id,request) -> locks.accept(id,requestType.cast(request));
        return this;
    }

    @Override public void lockDocumentSave(UUID documentId,Object request) {
        documentSaveLocks.accept(documentId,request);
    }

    @Override public void requireDocumentSaveAccess(boolean create) {
        if (create) {
            if (!hasAny(creators) || current.get().map(user -> user.getImpersonatedBy() != null).orElse(true))
                throw new ApiException(ErrorCode.FORBIDDEN);
        } else {
            requireDefinitionAccess(false);
            if (!canWrite()) throw new ApiException(ErrorCode.FORBIDDEN);
        }
    }

    @Override public Map<UUID, RecordAccess> authorizeCreated(Set<UUID> ids) {
        requireDocumentSaveAccess(true);
        return authorizeRecords(ids, true, true);
    }

    public Set<UUID> recordIdsForDocument(UUID documentId) {
        if (documentRowsLookup == null) throw new IllegalStateException("Document row lookup not registered for " + scope);
        JsonNode header = lockedDocument(documentId);
        @SuppressWarnings("unchecked") List<UUID> rows = em.createNativeQuery(documentRowsLookup)
                .setParameter("document", documentId).getResultList();
        Set<UUID> ids = new LinkedHashSet<>(rows);
        if (!ids.isEmpty()) {
            // The fixed lookup proves parent membership; the same locked domain detail proves
            // row visibility. Do not reload every parent/detail just to discard its write hints.
            JsonNode items = header.get("items");
            if (items == null || !items.isArray()) throw missing();
            Set<String> visible = new HashSet<>();
            for (JsonNode item : items) visible.add(item.path("id").asText());
            for (UUID id : ids) if (!visible.contains(id.toString())) throw missing();
        }
        return ids;
    }

    @Override public void requireDocumentFieldWrite(UUID documentId) {
        requireDocumentSaveAccess(false);
        if (!writable.test(documentId, lockedDocument(documentId)))
            throw new ApiException(ErrorCode.CONFLICT, "当前单据不允许修改扩展字段");
    }

    private JsonNode lockedDocument(UUID documentId) {
        requireDefinitionAccess(false);
        em.flush();
        Object entity = em.find(headerEntity, documentId, LockModeType.PESSIMISTIC_WRITE);
        if (entity == null) throw missing();
        em.refresh(entity, LockModeType.PESSIMISTIC_WRITE);
        // Reading the old row identities must not veto a legal domain edit that revokes approval.
        // Keep the parent lock and the domain detail loader's visibility check; actual field
        // changes still go through authorize(..., true) before the business save.
        Object detailResult = detail.apply(documentId);
        if (detailResult == null) throw missing();
        return json.valueToTree(detailResult);
    }

    private boolean hasAny(Set<String> authorities) {
        return current.get().filter(user -> !user.isVisitor()).map(user -> user.getPermissions() != null
                && authorities.stream().anyMatch(user.getPermissions()::contains)).orElse(false);
    }

    @Override
    public Map<UUID, RecordAccess> authorize(Set<UUID> ids, boolean write) {
        requireDefinitionAccess(false);
        if (write && !canWrite()) throw new ApiException(ErrorCode.FORBIDDEN);
        return authorizeRecords(ids, write, false);
    }

    private Map<UUID, RecordAccess> authorizeRecords(Set<UUID> ids, boolean write, boolean created) {
        if (ids.isEmpty()) return Map.of();
        Map<UUID, UUID> parents = parents(ids);
        if (created && parents.entrySet().stream().anyMatch(entry ->
                !PlatformColumnSaveLineage.wasPersisted(entry.getKey())
                || !PlatformColumnSaveLineage.wasPersisted(entry.getValue()))) {
            throw new ApiException(ErrorCode.CONFLICT, "只有本次业务创建的真实明细可以使用新建权限保存扩展字段");
        }
        List<UUID> ordered = parents.values().stream().distinct().sorted().toList();
        if (write) {
            // The save bridge may already have pending business changes in this
            // transaction; flush before refresh so reauthorization cannot undo them.
            em.flush();
            for (UUID id : ordered) {
                Object entity = em.find(headerEntity, id, LockModeType.PESSIMISTIC_WRITE);
                if (entity == null) throw missing();
                // Refresh also covers an entity already present in the request's persistence context.
                em.refresh(entity, LockModeType.PESSIMISTIC_WRITE);
            }
        }
        Map<UUID, JsonNode> documents = new HashMap<>();
        for (UUID id : ordered) documents.put(id, json.valueToTree(detail.apply(id)));
        Map<UUID, RecordAccess> access = new LinkedHashMap<>();
        for (UUID id : ids) {
            UUID parent = parents.get(id);
            JsonNode header = documents.get(parent);
            if (header == null || header.isNull()) throw missing();
            // The create bridge separately proves this row was inserted by the
            // authorized business command in this transaction. A create-only
            // user's detail DTO may correctly advertise canEdit=false.
            boolean allowed = created ? draft(header) && !header.hasNonNull("legacyId")
                    : canWrite() && writable.test(parent, header);
            if (write && !allowed) throw new ApiException(ErrorCode.CONFLICT, "已提交或无编辑范围的记录不能修改扩展信息");
            JsonNode row = parentLookup == null ? header : findItem(header, id);
            if (row == null) throw missing();
            boolean price = canViewPrice() && !header.path("priceMasked").asBoolean(false)
                    && !header.path("costMasked").asBoolean(false);
            Map<String, BigDecimal> numbers = new LinkedHashMap<>();
            for (FactDefinition fact : facts) {
                if (fact.priceProtected() && !price) continue;
                JsonNode value = row.get(fact.key() + "Exact");
                if (value == null || value.isNull()) value = row.get(fact.key());
                if (value == null || value.isNull() || !(value.isTextual() || value.isNumber())) continue;
                try { numbers.put(fact.key(), new BigDecimal(value.asText())); }
                catch (NumberFormatException ignored) { /* Missing/invalid facts are not zero. */ }
            }
            access.put(id, new RecordAccess(allowed, price, numbers));
        }
        return access;
    }

    @Override public Map<UUID, UUID> parentDocuments(Set<UUID> ids) { return parents(ids); }

    private Map<UUID, UUID> parents(Set<UUID> ids) {
        Map<UUID, UUID> result = new LinkedHashMap<>();
        if (parentLookup == null) { ids.forEach(id -> result.put(id, id)); return result; }
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery(parentLookup)
                .setParameter("ids", ids).getResultList();
        for (Object[] row : rows) result.put((UUID) row[0], (UUID) row[1]);
        if (!result.keySet().equals(ids)) throw missing();
        return result;
    }

    private static JsonNode findItem(JsonNode header, UUID id) {
        JsonNode rows = header.get("items");
        if (rows == null || !rows.isArray()) return null;
        for (JsonNode row : rows) if (id.toString().equals(row.path("id").asText())) return row;
        return null;
    }

    public static boolean draft(JsonNode header) {
        JsonNode status = header.get("status");
        return status != null && ((status.isIntegralNumber() && status.asInt() == 0)
                || (status.isTextual() && Set.of("DRAFT", "REJECTED").contains(status.asText())))
                && !header.path("closed").asBoolean(false) && !header.path("canceled").asBoolean(false)
                && !header.path("stopped").asBoolean(false);
    }

    public static UUID uuid(JsonNode node, String field) {
        String value = node.path(field).asText("");
        try { return UUID.fromString(value); } catch (IllegalArgumentException ignored) { return null; }
    }

    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "记录不存在或不在当前查看范围内"); }
}
