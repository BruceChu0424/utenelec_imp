package com.uten.imp.common.platformcolumns;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.springframework.beans.BeanWrapperImpl;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.util.*;

/** The entity save and extension re-keying either both commit or both roll back. */
@Aspect
@Component
@Order(Ordered.LOWEST_PRECEDENCE-100)
public class PlatformColumnDocumentSaveAspect {
    private final PlatformColumnService fields;
    private final TransactionTemplate transaction;
    @jakarta.persistence.PersistenceContext private jakarta.persistence.EntityManager entityManager;
    public PlatformColumnDocumentSaveAspect(PlatformColumnService fields,PlatformTransactionManager transactionManager) {
        this.fields=fields;this.transaction=new TransactionTemplate(transactionManager);
    }

    @Around("@annotation(configuration)")
    public Object save(ProceedingJoinPoint invocation,PlatformColumnDocumentSave configuration) throws Throwable {
        try {
            return transaction.execute(status->{
                try(var context=PlatformColumnSaveLineage.begin(Set.of())){return saveInTransaction(invocation,configuration);}
                catch(RuntimeException|Error failure){throw failure;}
                catch(Throwable failure){throw new BridgeFailure(failure);}
            });
        }catch(BridgeFailure failure){throw failure.getCause();}
    }

    private Object saveInTransaction(ProceedingJoinPoint invocation,PlatformColumnDocumentSave configuration) throws Throwable {
        Object[] args=invocation.getArgs();
        Object request=argument(args,configuration.requestArgument());
        List<?> requested=items(request);
        List<Object> identities=requested.stream().map(row->snapshotIdentity(row,configuration.quantityFields())).toList();
        UUID document=configuration.documentIdArgument()<0?null:uuid(argument(args,configuration.documentIdArgument()));
        Set<UUID> oldRecords=document==null?Set.of():fields.documentRecords(configuration.scope(),document);
        boolean hasStored=document!=null&&fields.hasStoredFields(configuration.scope(),oldRecords);
        boolean aware=requested.stream().allMatch(line->value(line,"platformFields")!=null);
        Set<UUID> sources=new HashSet<>();
        List<PlatformColumnService.PreparedFields> prepared=new ArrayList<>();
        for(Object line:requested) {
            Object supplied=value(line,"platformFields");
            if(supplied!=null&&!(supplied instanceof PlatformColumnLineInput.Fields))throw conflict("不支持的扩展字段保存格式");
            var input=(PlatformColumnLineInput.Fields)supplied;
            UUID source=input==null?optionalUuid(value(line,"id")):input.sourceRecordId();
            if(source!=null&&(!oldRecords.contains(source)||!sources.add(source)))throw conflict("扩展字段来源明细不存在、重复或不属于当前单据");
            if(input==null) {
                if(hasStored&&source==null)throw conflict("该单据已有扩展字段，请刷新页面后保存以保留原始明细关联");
                prepared.add(source==null?null:fields.prepareFields(configuration.scope(),source,0,null,true,false));
            }else prepared.add(fields.prepareFields(configuration.scope(),source,input.expectedVersion(),input.cells(),false,document==null));
        }
        if(hasStored&&!aware&&!sources.containsAll(oldRecords))throw conflict("当前客户端无法证明保留或删除了哪些扩展字段，请刷新页面后保存");
        if(configuration.mapping()==PlatformColumnDocumentSave.Mapping.DOMAIN_LINEAGE) {
            Set<UUID> tokens=new LinkedHashSet<>();
            List<UUID> lineTokens=new ArrayList<>();
            for(Object line:requested) {
                if(!(line instanceof PlatformColumnLineInput input))throw conflict("域拆分明细未接入扩展字段来源基类");
                UUID token=UUID.randomUUID();input.setPlatformSaveToken(token);tokens.add(token);lineTokens.add(token);
            }
            try(var lineage=PlatformColumnSaveLineage.begin(tokens)) {
                Object result=invocation.proceed();
                if(entityManager!=null)entityManager.flush();
                if(prepared.stream().noneMatch(PlatformColumnDocumentSaveAspect::hasFields))return result;
                UUID savedDocument=uuid(value(result,"id"));
                if(document!=null&&!document.equals(savedDocument))throw conflict("保存结果改变了来源单据编号");
                Map<UUID,Object> saved=new HashMap<>();
                for(Object item:items(result))if(saved.put(uuid(value(item,"id")),item)!=null)throw conflict("保存后的明细编号重复");
                for(int index=0;index<requested.size();index++) {
                    var proof=prepared.get(index);if(!hasFields(proof))continue;
                    proof=fields.bindFields(proof,savedDocument,index);
                    Object input=identities.get(index);
                    List<UUID> targets=lineage.targets(lineTokens.get(index));
                    if(targets.isEmpty()&&proof.documentCreate()&&!PlatformColumnSaveLineage.wasPersisted(savedDocument))
                        targets=fields.replayTargets(proof,saved.keySet());
                    if(targets.isEmpty())throw conflict("明细拆分缺少扩展字段来源映射，本次未保存");
                    BigDecimal total=BigDecimal.ZERO;String quantity=quantityField(input,configuration.quantityFields());
                    for(UUID target:targets) {
                        Object output=saved.get(target);if(output==null)throw conflict("拆分来源指向非本次保存的明细");
                        verifyIdentity(input,output,index);
                        if(quantity!=null){Object qty=value(output,quantity);if(!(qty instanceof Number number))throw conflict("拆分明细数量缺失");total=total.add(new BigDecimal(number.toString()));}
                    }
                    if(quantity!=null&&!same(total,value(input,quantity)))throw conflict("拆分前后数量不守恒，不能附加扩展字段");
                    for(UUID target:targets)if(!proof.cells().isEmpty()||proof.sourceVersion()>0)fields.applyFields(target,proof);
                }
                return result;
            }
        }
        Object result=invocation.proceed();
        if(entityManager!=null)entityManager.flush();
        if(prepared.stream().noneMatch(PlatformColumnDocumentSaveAspect::hasFields))return result;
        UUID savedDocument=uuid(value(result,"id"));
        if(document!=null&&!document.equals(savedDocument))throw conflict("保存结果改变了来源单据编号");
        List<?> saved=items(result);
        if(saved.size()!=requested.size())throw conflict("该保存操作拆分或合并了明细，需使用域专用的扩展字段映射");
        Set<UUID> targetIds=new HashSet<>();
        for(int index=0;index<saved.size();index++) {
            Object target=saved.get(index);UUID id=uuid(value(target,"id"));
            if(!targetIds.add(id))throw conflict("保存后的明细编号重复");
            verifyMapping(identities.get(index),target,index,configuration.quantityFields());
            var proof=prepared.get(index);
            if(hasFields(proof))fields.applyFields(id,fields.bindFields(proof,savedDocument,index));
        }
        return result;
    }

    static void verifyMapping(Object requested,Object saved,int index) {
        verifyMapping(requested,saved,index,new String[]{"qty"});
    }
    static void verifyMapping(Object requested,Object saved,int index,String[] quantityFields) {
        Object lineNo=value(requested,"lineNo"),savedNo=value(saved,"lineNo");
        if(lineNo!=null&&savedNo!=null&&!same(lineNo,savedNo))throw conflict("保存前后明细顺序不一致，未保存扩展字段");
        verifyIdentity(requested,saved,index);
        String quantity=quantityField(requested,quantityFields);
        if(quantity!=null&&!same(value(requested,quantity),value(saved,quantity)))throw conflict("保存前后数量不一致，不能自动附加扩展字段");
    }
    private static void verifyIdentity(Object requested,Object saved,int index) {
        for(String field:List.of("goodsId","colorId","unitId")) {
            // An omitted unit is resolved by the domain's own unit policy during save.
            if("unitId".equals(field)&&value(requested,field)==null)continue;
            if(hasProperty(requested,field)&&hasProperty(saved,field)&&!same(value(requested,field),value(saved,field)))
                throw conflict("第"+(index+1)+"行保存后的业务身份或数量变化，不能自动附加原扩展字段");
        }
    }
    private static boolean same(Object left,Object right) {
        if(left instanceof Number a&&right instanceof Number b)return new BigDecimal(a.toString()).compareTo(new BigDecimal(b.toString()))==0;
        return Objects.equals(left,right);
    }
    private static boolean hasFields(PlatformColumnService.PreparedFields fields) {
        return fields!=null&&(!fields.cells().isEmpty()||fields.sourceVersion()>0);
    }
    private static Object snapshotIdentity(Object row,String[] quantityFields) {
        Map<String,Object> values=new LinkedHashMap<>();
        List<String> fields=new ArrayList<>(List.of("lineNo","goodsId","colorId","unitId"));fields.addAll(List.of(quantityFields));
        for(String field:fields)if(hasProperty(row,field))values.put(field,value(row,field));
        return Collections.unmodifiableMap(values);
    }
    private static String quantityField(Object row,String[] quantityFields) {
        for(String field:quantityFields)if(hasProperty(row,field)&&value(row,field)!=null)return field;return null;
    }
    private static List<?> items(Object object) {Object rows=value(object,"items");if(!(rows instanceof List<?> list))throw conflict("保存桥仅支持显式的一对一items明细结构");return list;}
    private static boolean hasProperty(Object object,String key) {
        if(object==null)return false;if(object instanceof Map<?,?> map)return map.containsKey(key);
        return new BeanWrapperImpl(object).isReadableProperty(key)||org.springframework.util.ReflectionUtils.findMethod(object.getClass(),key)!=null;
    }
    private static Object value(Object object,String key) {
        if(object==null)return null;if(object instanceof Map<?,?> map)return map.get(key);
        var bean=new BeanWrapperImpl(object);if(bean.isReadableProperty(key))return bean.getPropertyValue(key);
        var method=org.springframework.util.ReflectionUtils.findMethod(object.getClass(),key);
        if(method==null)return null;org.springframework.util.ReflectionUtils.makeAccessible(method);return org.springframework.util.ReflectionUtils.invokeMethod(method,object);
    }
    private static Object argument(Object[] args,int index) {if(index<0||index>=args.length)throw conflict("扩展字段保存参数配置无效");return args[index];}
    private static UUID optionalUuid(Object value) {return value==null?null:uuid(value);}
    private static UUID uuid(Object value) {if(!(value instanceof UUID id))throw conflict("扩展字段必须使用真实明细UUID");return id;}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
    private static final class BridgeFailure extends RuntimeException {BridgeFailure(Throwable cause){super(cause);}}
}
