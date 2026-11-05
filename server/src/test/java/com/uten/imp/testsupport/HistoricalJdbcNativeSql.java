package com.uten.imp.testsupport;

import jakarta.persistence.EntityManager;
import jakarta.persistence.NoResultException;
import jakarta.persistence.NonUniqueResultException;
import jakarta.persistence.Query;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.LinkedHashMap;

/** Executes existing native-SQL helpers before current ORM mappings may boot.
 * No entity mapping, schema adjustment, factory or ORM operation is available. */
public final class HistoricalJdbcNativeSql {
    private HistoricalJdbcNativeSql() { }

    public static EntityManager statements(JdbcTemplate jdbc) {
        var database=new NamedParameterJdbcTemplate(jdbc);
        return (EntityManager)Proxy.newProxyInstance(EntityManager.class.getClassLoader(),new Class<?>[]{EntityManager.class},
                (proxy,method,args)->{
                    if(method.getDeclaringClass()==Object.class)return objectMethod(proxy,method,args);
                    if(method.getName().equals("createNativeQuery")&&args.length==1&&args[0] instanceof String sql) {
                        return statement(database,sql);
                    }
                    throw unsupported(method);
                });
    }

    private static Query statement(NamedParameterJdbcTemplate database,String sql) {
        var parameters=new LinkedHashMap<String,Object>();
        return (Query)Proxy.newProxyInstance(Query.class.getClassLoader(),new Class<?>[]{Query.class},(proxy,method,args)->{
            if(method.getDeclaringClass()==Object.class)return objectMethod(proxy,method,args);
            if(method.getName().equals("setParameter")&&args.length==2&&args[0] instanceof String key) {
                Object value=args[1];parameters.put(key,value instanceof Instant instant?Timestamp.from(instant):value);return proxy;
            }
            if(method.getName().equals("executeUpdate")&&method.getParameterCount()==0)return database.update(sql,parameters);
            if((method.getName().equals("getResultList")||method.getName().equals("getSingleResult"))&&method.getParameterCount()==0) {
                var rows=database.query(sql,parameters,(result,index)->{
                    int columns=result.getMetaData().getColumnCount();
                    if(columns==1)return result.getObject(1);
                    Object[] row=new Object[columns];
                    for(int column=0;column<columns;column++)row[column]=result.getObject(column+1);
                    return row;
                });
                if(method.getName().equals("getResultList"))return rows;
                if(rows.isEmpty())throw new NoResultException("Historical native SQL returned no row");
                if(rows.size()!=1)throw new NonUniqueResultException("Historical native SQL returned more than one row");
                return rows.getFirst();
            }
            throw unsupported(method);
        });
    }

    private static Object objectMethod(Object proxy,Method method,Object[] args) {
        return switch(method.getName()) {
            case "toString"->"Historical JDBC native SQL";
            case "hashCode"->System.identityHashCode(proxy);
            case "equals"->proxy==args[0];
            default->throw unsupported(method);
        };
    }

    private static UnsupportedOperationException unsupported(Method method) {
        return new UnsupportedOperationException("Historical JDBC cannot perform ORM operations: "+method.getName());
    }
}
