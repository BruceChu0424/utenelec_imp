package com.uten.imp.common.finance;

import java.util.Map;
import java.util.Optional;

/** A calculation cannot choose a loss of precision on the user's behalf. */
public final class BusinessPrecisionRequiredException extends RuntimeException {
    private final Map<String,Object> details;
    public BusinessPrecisionRequiredException(String key,String label,int maximum,String reason){
        this(key,label,maximum,reason,false);
    }
    /** An explicitly selected scale can still violate a source budget. Only a
     * proved-unwritten response permits the caller to explicitly replace it. */
    public BusinessPrecisionRequiredException(String key,String label,int maximum,String reason,boolean selectionRejected){
        super("请先选择本次计算保留的小数位及是否四舍五入；本次操作尚未完成");
        var fields=new java.util.LinkedHashMap<String,Object>();fields.put("calculationKey",key);fields.put("groupKey",key);fields.put("label",label);fields.put("maxScale",maximum);fields.put("reason",reason);fields.put("notWritten",BusinessPrecisionContext.canProveUnwritten());
        if(selectionRejected){fields.put("selectionRejected",true);}details=Map.copyOf(fields);
        // Explicitly mark the surrounding business transaction even when a caller
        // ordinarily preserves other validation failures for a draft preview.
        try{org.springframework.transaction.interceptor.TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();}
        catch(org.springframework.transaction.NoTransactionException ignored){ }
    }
    public Map<String,Object> details(){
        if(Boolean.TRUE.equals(details.get("notWritten"))&&!BusinessPrecisionContext.canProveUnwritten()){
            var safe=new java.util.LinkedHashMap<>(details);safe.put("notWritten",false);return Map.copyOf(safe);
        }
        return details;
    }
    private BusinessPrecisionRequiredException(Map<String,Object> details){super("请先选择本次计算保留的小数位及是否四舍五入；本次操作尚未完成");this.details=Map.copyOf(details);}
    public static Optional<BusinessPrecisionRequiredException> from(Throwable root){
        int depth=0;for(Throwable cause=root;cause!=null&&depth++<20;cause=cause.getCause()){
            if(cause instanceof BusinessPrecisionRequiredException precision)return Optional.of(precision);
            if(cause instanceof org.postgresql.util.PSQLException postgres&&"22023".equals(postgres.getSQLState())&&postgres.getServerErrorMessage()!=null){
                String text=postgres.getServerErrorMessage().getMessage(),prefix="UTEN_PRECISION_REQUIRED:";
                if(text!=null&&text.startsWith(prefix))try{
                    var raw=new com.fasterxml.jackson.databind.ObjectMapper().readTree(text.substring(prefix.length()));
                    if(raw.path("calculationKey").isTextual()&&raw.path("label").isTextual()&&raw.path("maxScale").isInt()&&raw.path("notWritten").asBoolean(false)
                            &&raw.path("maxScale").asInt()>=0&&raw.path("maxScale").asInt()<=30&&java.util.Set.of("NON_TERMINATING","PRECISION_LIMIT").contains(raw.path("reason").asText())){
                        String key=raw.path("calculationKey").asText();
                        var details=new java.util.LinkedHashMap<String,Object>();details.put("calculationKey",key);details.put("groupKey",key);details.put("label",raw.path("label").asText());details.put("maxScale",raw.path("maxScale").asInt());details.put("notWritten",BusinessPrecisionContext.canProveUnwritten());details.put("reason",raw.path("reason").asText());
                        if(raw.path("selectionRejected").isBoolean()&&raw.path("selectionRejected").asBoolean())details.put("selectionRejected",true);
                        return Optional.of(new BusinessPrecisionRequiredException(details));
                    }
                }catch(Exception ignored){ }
            }
        }return Optional.empty();
    }
}
