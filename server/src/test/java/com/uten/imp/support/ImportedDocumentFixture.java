package com.uten.imp.support;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.history.RetainedRecordReader;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.persistence.Table;
import org.springframework.test.util.ReflectionTestUtils;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.regex.Pattern;

/** Unit-fixture database facts, not a production fallback. All origin/hold IDs
 * must be registered. Other business queries still use the fixture's original
 * EntityManager and its strict SQL/locking assertions. No Mockito leniency. */
public final class ImportedDocumentFixture {
    private static final String MUTABLE="SELECT fn_imported_business_document(:table,:id)";
    private static final Pattern METADATA=Pattern.compile("SELECT id, fn_imported_business_document\\(:table,id\\) FROM public\\.([a-z][a-z0-9_]*) WHERE id IN \\(:ids\\)");
    private static final Pattern SOURCES=Pattern.compile("SELECT id FROM public\\.([a-z][a-z0-9_]*) WHERE id IN \\(:ids\\) AND fn_imported_business_document\\(:table,id\\)");
    private static final String DELETIONS="SELECT DISTINCT ON (source_id) source_id, recorded_at, actor_name, payload->>'deleted_reason' FROM business_record_history WHERE source_table=:table AND source_id IN (:ids) AND operation='SOFT_DELETE' ORDER BY source_id,id DESC";
    private static final String MEASUREMENT="SELECT b.id,(h.id IS NOT NULL OR u.id IS NULL) AS measurement_pending, CASE WHEN h.id IS NOT NULL THEN h.reason WHEN u.id IS NULL THEN 'MISSING_BASE_UNIT' END AS measurement_hold_reason FROM stock_balances b JOIN goods g ON g.id=b.goods_id LEFT JOIN stock_measurement_holds h ON h.stock_balance_id=b.id AND h.released_at IS NULL LEFT JOIN units u ON NOT u.is_deleted AND NULLIF(btrim(u.name),'') IS NOT NULL AND (u.id=g.unit_id OR (g.unit_id IS NULL AND u.legacy_id=NULLIF(g.unit_legacy_id,0))) WHERE b.id IN (:ids)";

    private record Key(String table,UUID id) { }
    private final Map<Key,Boolean> explicit=new LinkedHashMap<>();
    private final Map<String,List<Supplier<? extends Iterable<?>>>> records=new LinkedHashMap<>();
    private final Map<UUID,Object[]> measurements=new LinkedHashMap<>();
    private final Map<Key,List<Object[]>> deletions=new LinkedHashMap<>();
    private final Map<EntityManager,EntityManager> managers=new IdentityHashMap<>();
    private final List<Key> originReads=new ArrayList<>();

    /** Retrieve this particular service fixture's adapter without process-wide
     * registries or ThreadLocals. Useful for static factories and per-test rows. */
    public static ImportedDocumentFixture forService(Object service) {
        Field field=field(service.getClass(),EntityManager.class);
        require(field!=null,"Service fixture has no EntityManager field");
        EntityManager manager=(EntityManager)ReflectionTestUtils.getField(service,field.getName());
        require(manager!=null,"Service fixture needs its backing EntityManager");
        if(Proxy.isProxyClass(manager.getClass())&&Proxy.getInvocationHandler(manager) instanceof ManagerAdapter adapter)
            return adapter.owner();
        var result=new ImportedDocumentFixture();
        result.wire(service,manager);
        return result;
    }

    public static <T> T prepared(T service) {
        forService(service);
        return service;
    }

    public ImportedDocumentFixture nativeId(String table,UUID id) { return origin(table,id,false); }
    public ImportedDocumentFixture importedId(String table,UUID id) { return origin(table,id,true); }

    private ImportedDocumentFixture origin(String table,UUID id,boolean imported) {
        Key key=key(table,id);
        Boolean previous=explicit.putIfAbsent(key,imported);
        require(previous==null||previous==imported,"Contradictory explicit origin: "+key);
        return this;
    }

    /** The actual fixture entity is retained, so later setId/legacy flags are
     * observed rather than copied as an inaccurate initial native default. */
    public <T> T document(String table,T entity) {
        Objects.requireNonNull(entity,"fixture document");
        documents(table,()->List.of(entity));
        return entity;
    }

    /** Explicit table plus this fixture's actual in-memory repository rows. */
    public ImportedDocumentFixture documents(String table,Supplier<? extends Iterable<?>> rows) {
        table(table);
        records.computeIfAbsent(table,ignored->new ArrayList<>()).add(Objects.requireNonNull(rows));
        return this;
    }

    public ImportedDocumentFixture measurement(UUID balance,boolean pending,String reason) {
        require(balance!=null,"Missing measurement fixture ID");
        require(pending?reason!=null&&!reason.isBlank():reason==null,"Contradictory measurement fixture");
        Object[] previous=measurements.putIfAbsent(balance,new Object[]{balance,pending,reason});
        require(previous==null,"Duplicate measurement fixture ID: "+balance);
        return this;
    }

    public ImportedDocumentFixture noDeletionHistory(String table,UUID id) {
        deletions.put(key(table,id),List.of());
        return this;
    }

    public ImportedDocumentFixture deletionHistory(String table,UUID id,Instant at,String actor,String reason) {
        deletions.put(key(table,id),List.<Object[]>of(new Object[]{id.toString(),at,actor,reason}));
        return this;
    }

    public boolean imported(String table,UUID id) {
        Key key=key(table,id);
        Boolean declared=explicit.get(key);
        Boolean observed=null;
        for(Supplier<? extends Iterable<?>> source:records.getOrDefault(table,List.of())) {
            for(Object row:source.get()) {
                if(row==null) continue;
                require(table.equals(entityTable(row)),"Fixture entity/table mismatch: "+table);
                Object identity=get(row,"getId",false);
                require(identity instanceof UUID,"Fixture entity needs a real UUID: "+table);
                if(!id.equals(identity)) continue;
                boolean legacy=get(row,"getLegacyId",true)!=null||get(row,"getLegacyImportRunId",true)!=null;
                require(observed==null||observed==legacy,"Contradictory fixture rows: "+key);
                observed=legacy;
            }
        }
        require(declared!=null||observed!=null,"Unregistered document origin: "+key);
        require(!Boolean.FALSE.equals(declared)||!Boolean.TRUE.equals(observed),
                "An archived fixture cannot be declared native: "+key);
        originReads.add(key);
        return Boolean.TRUE.equals(declared)||Boolean.TRUE.equals(observed);
    }

    public long originReadCount(String table,UUID id) {
        return originReads.stream().filter(key(table,id)::equals).count();
    }

    public RetainedRecordReader reader(EntityManager backing) {
        return new RetainedRecordReader(entityManager(backing),new ObjectMapper());
    }

    /** Wire only test collaborators; no production field gets an optional/null path. */
    public <T> T wire(T service,EntityManager backing) {
        EntityManager adapter=entityManager(backing);
        Field em=field(service.getClass(),EntityManager.class);
        require(em!=null,"Service fixture has no EntityManager field");
        ReflectionTestUtils.setField(service,em.getName(),adapter);
        Field retained=field(service.getClass(),RetainedRecordReader.class);
        if(retained!=null) ReflectionTestUtils.setField(service,retained.getName(),new RetainedRecordReader(adapter,new ObjectMapper()));
        return service;
    }

    public EntityManager entityManager(EntityManager backing) {
        Objects.requireNonNull(backing,"backing fixture EntityManager");
        return managers.computeIfAbsent(backing,base->(EntityManager)Proxy.newProxyInstance(
                EntityManager.class.getClassLoader(),new Class<?>[]{EntityManager.class},new ManagerAdapter(this,base)));
    }

    private record ManagerAdapter(ImportedDocumentFixture owner,EntityManager base) implements InvocationHandler {
        @Override public Object invoke(Object proxy,Method method,Object[] args) throws Throwable {
            if(method.getDeclaringClass()==Object.class) return objectMethod(proxy,method,args);
            if(method.getName().equals("createNativeQuery")&&args!=null&&args.length==1&&args[0] instanceof String sql) {
                String normalized=normalize(sql);
                if(supported(normalized)) return owner.query(normalized);
                require(!originControlQuery(normalized),"Unmodelled origin-control query: "+sql);
            }
            try { return method.invoke(base,args); }
            catch(InvocationTargetException failure) { throw failure.getCause(); }
        }
    }

    /** Public for focused fixture-contract tests. Unknown queries never return false/empty. */
    public Query query(String raw) {
        String sql=normalize(raw);
        require(supported(sql),"Unknown fixture query: "+raw);
        Map<String,Object> parameters=new LinkedHashMap<>();
        return (Query)Proxy.newProxyInstance(Query.class.getClassLoader(),new Class<?>[]{Query.class},(proxy,method,args)->{
            if(method.getDeclaringClass()==Object.class) return objectMethod(proxy,method,args);
            if(method.getName().equals("setParameter")) {
                if(args==null||args.length!=2||!(args[0] instanceof String))
                    throw new AssertionError("Unknown fixture parameter form");
                parameters.put((String)args[0],args[1]);
                return proxy;
            }
            if(method.getName().equals("getSingleResult")) {
                require(sql.equals(MUTABLE)&&parameters.keySet().equals(java.util.Set.of("table","id")),
                        "Unexpected single-result query/parameters");
                return imported((String)parameters.get("table"),(UUID)parameters.get("id"));
            }
            if(method.getName().equals("getResultList")) return rows(sql,parameters);
            throw new AssertionError("Unsupported read-only fixture query method: "+method.getName());
        });
    }

    private List<?> rows(String sql,Map<String,Object> parameters) {
        var metadata=METADATA.matcher(sql);
        var sources=SOURCES.matcher(sql);
        if(metadata.matches()||sources.matches()) {
            String from=metadata.matches()?metadata.group(1):sources.group(1);
            require(parameters.keySet().equals(java.util.Set.of("table","ids"))&&from.equals(parameters.get("table")),
                    "Origin query table/parameters differ");
            List<Object> result=new ArrayList<>();
            for(UUID id:ids(parameters.get("ids"))) {
                boolean imported=imported(from,id);
                if(metadata.matches()) result.add(new Object[]{id,imported});
                else if(imported) result.add(id);
            }
            return result;
        }
        if(sql.equals(MEASUREMENT)) {
            require(parameters.keySet().equals(java.util.Set.of("ids")),"Measurement query needs exact balance IDs");
            List<Object[]> result=new ArrayList<>();
            for(UUID id:ids(parameters.get("ids"))) {
                require(measurements.containsKey(id),"Unregistered measurement facts: "+id);
                result.add(measurements.get(id).clone());
            }
            return result;
        }
        require(sql.equals(DELETIONS)&&parameters.keySet().equals(java.util.Set.of("table","ids")),"Unknown history fixture query");
        List<Object[]> result=new ArrayList<>();
        for(UUID id:ids(parameters.get("ids"))) {
            Key key=key((String)parameters.get("table"),id);
            imported(key.table(),id);
            require(deletions.containsKey(key),"Unregistered deletion history: "+key);
            result.addAll(deletions.get(key));
        }
        return result;
    }

    private static List<UUID> ids(Object values) {
        require(values instanceof Collection<?>,"Fixture IDs must be a collection");
        LinkedHashSet<UUID> ids=new LinkedHashSet<>();
        for(Object value:(Collection<?>)values) {
            require(value instanceof UUID||value instanceof String,"Fixture ID must be a UUID");
            ids.add(value instanceof UUID uuid?uuid:UUID.fromString((String)value));
        }
        return List.copyOf(ids);
    }

    private static boolean supported(String sql) {
        return sql.equals(MUTABLE)||METADATA.matcher(sql).matches()||SOURCES.matcher(sql).matches()
                ||sql.equals(DELETIONS)||sql.equals(MEASUREMENT);
    }

    private static boolean originControlQuery(String sql) {
        return sql.startsWith("SELECT fn_imported_business_document(")
                ||sql.startsWith("SELECT id, fn_imported_business_document(")
                ||sql.startsWith("SELECT id FROM public.")&&sql.contains("fn_imported_business_document(");
    }

    private static String normalize(String sql) { return sql.strip().replaceAll("\\s+"," "); }
    private static Key key(String table,UUID id) { table(table);require(id!=null,"Missing fixture UUID");return new Key(table,id); }
    private static void table(String table) { require(table!=null&&table.matches("[a-z][a-z0-9_]*"),"Invalid fixture table"); }
    private static void require(boolean valid,String message) { if(!valid) throw new AssertionError(message); }

    private static String entityTable(Object row) {
        for(Class<?> type=row.getClass();type!=null;type=type.getSuperclass()) {
            Table mapped=type.getAnnotation(Table.class);
            if(mapped!=null) return mapped.name();
        }
        throw new AssertionError("Fixture row is not a mapped entity: "+row.getClass().getName());
    }

    private static Object get(Object row,String name,boolean optional) {
        try { return row.getClass().getMethod(name).invoke(row); }
        catch(NoSuchMethodException absent) {
            if(optional) return null;
            throw new AssertionError("Fixture row has no identity getter",absent);
        } catch(ReflectiveOperationException failure) { throw new AssertionError("Cannot read fixture origin",failure); }
    }

    private static Field field(Class<?> type,Class<?> wanted) {
        for(Class<?> cursor=type;cursor!=null;cursor=cursor.getSuperclass()) {
            for(Field field:cursor.getDeclaredFields()) if(field.getType()==wanted) return field;
        }
        return null;
    }

    private static Object objectMethod(Object proxy,Method method,Object[] args) {
        return switch(method.getName()) {
            case "equals" -> {
                if(args==null||args.length!=1) throw new AssertionError("Invalid fixture equality arguments");
                yield proxy==args[0];
            }
            case "hashCode" -> System.identityHashCode(proxy);
            case "toString" -> "RegisteredImportedDocumentFixture";
            default -> throw new AssertionError("Unsupported fixture Object method");
        };
    }
}
