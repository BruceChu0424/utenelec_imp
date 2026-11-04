package com.uten.imp.common.finance;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** One explicit choice per calculation purpose and request; there is no global rounding default. */
public final class BusinessPrecisionContext {
    public static final String HEADER="X-Uten-Precision-Choices";
    private static final ThreadLocal<State> CURRENT=new ThreadLocal<>();
    private static final ObjectMapper JSON=new ObjectMapper();
    public record Choice(int scale,String rounding){
        public Choice{if(scale<0||scale>30||!Set.of("HALF_UP","DOWN").contains(rounding))throw invalid("数值处理选项无效，请明确保留0至30位及取舍方式");}
        RoundingMode mode(){return RoundingMode.valueOf(rounding);}
    }
    private record State(Map<String,Choice> choices,Set<String> used,
            java.util.concurrent.atomic.AtomicBoolean committedWrite,
            java.util.concurrent.atomic.AtomicReference<RuntimeException> bindingFailure,boolean metadataOnly) { }
    private BusinessPrecisionContext() { }
    public static AutoCloseable use(Map<String,Choice> choices){
        return use(choices,false);
    }
    /** Export lifecycle bookkeeping only; never place business facts in this scope. */
    public static AutoCloseable useMetadata(){return use(Map.of(),true);}
    private static AutoCloseable use(Map<String,Choice> choices,boolean metadataOnly){
        State prior=CURRENT.get();if(choices==null||choices.size()>32)throw invalid("本次数值选择过多，请按原操作分批核对");
        var copy=new TreeMap<String,Choice>();choices.forEach((key,value)->{if(key==null||key.isBlank()||key.length()>200||value==null)throw invalid("本次数值选择缺少明确计算用途");copy.put(key,value);});
        CURRENT.set(new State(Collections.unmodifiableMap(copy),new LinkedHashSet<>(),
                prior==null?new java.util.concurrent.atomic.AtomicBoolean():prior.committedWrite(),
                prior==null||metadataOnly?new java.util.concurrent.atomic.AtomicReference<>():prior.bindingFailure(),
                metadataOnly||prior!=null&&prior.metadataOnly()));
        return ()->{if(prior==null)CURRENT.remove();else CURRENT.set(prior);};
    }
    public static Map<String,Choice> parse(String header){
        if(header==null||header.isBlank())return Map.of();if(header.length()>16384)throw invalid("本次数值选择内容过长");
        try{
            var raw=JSON.readTree(Base64.getUrlDecoder().decode(header));if(raw.path("version").asInt()!=1||!raw.path("choices").isObject())throw invalid("数值选择版本无效，请重新核对");
            for(var property:raw.get("choices").properties())if(!property.getValue().path("scale").isIntegralNumber()||!property.getValue().path("rounding").isTextual())throw invalid("请明确选择整数小数位和取舍方式");
            Map<String,Choice> values=JSON.convertValue(raw.get("choices"),new TypeReference<Map<String,Choice>>(){});if(values.size()>32)throw invalid("本次数值选择过多");return values;
        }catch(ApiException e){throw e;}catch(Exception e){throw invalid("数值选择内容无效，请重新选择");}
    }
    public static void ensureReady(){var state=CURRENT.get();if(state!=null&&state.bindingFailure().get()!=null)throw new IllegalStateException("本次数值选择未能绑定，请保留输入并核对操作结果",state.bindingFailure().get());}
    static void bindingFailed(RuntimeException failure){var state=CURRENT.get();if(state!=null)state.bindingFailure().compareAndSet(null,failure);}
    static void writeCommitted(){var state=CURRENT.get();if(state!=null&&!state.metadataOnly())state.committedWrite().set(true);}
    public static boolean canProveUnwritten(){var state=CURRENT.get();return state==null||!state.committedWrite().get();}
    public static Map<String,Choice> choices(){ensureReady();var state=CURRENT.get();return state==null?Map.of():state.choices();}
    public static Map<String,Choice> usedChoices(){var state=CURRENT.get();if(state==null)return Map.of();var result=new TreeMap<String,Choice>();for(String key:state.used()){result.put(key,state.choices().get(key));}return Collections.unmodifiableMap(result);}
    public static String json(){try{return JSON.writeValueAsString(Map.of("version",1,"choices",choices()));}catch(Exception e){throw new IllegalStateException("数值选择无法编码",e);}}
    public static BigDecimal divide(BigDecimal numerator,BigDecimal denominator,String key,String label,int maximum){
        ensureReady();
        if(numerator==null||denominator==null)throw invalid(label+"缺少明确计算来源");if(denominator.signum()==0)throw invalid(label+"的分母不能为零");
        if(maximum<0||maximum>30)throw new IllegalArgumentException("Unsupported exact numeric field scale");
        String reason="NON_TERMINATING";
        try{BigDecimal exact=numerator.divide(denominator).stripTrailingZeros();if(exact.scale()<=maximum)return exact;reason="PRECISION_LIMIT";}
        catch(ArithmeticException nonTerminating){ }
        Choice choice=choices().get(key);if(choice==null)throw new BusinessPrecisionRequiredException(key,label,maximum,reason);
        if(choice.scale()>maximum)throw invalid(label+"的保留位数超出该字段可保存范围，请重新核对");
        CURRENT.get().used().add(key);return numerator.divide(denominator,choice.scale(),choice.mode());
    }
    public static BigDecimal limit(BigDecimal value,String key,String label,int maximum){ensureReady();if(value==null)return null;return value.stripTrailingZeros().scale()<=maximum?value:divide(value,BigDecimal.ONE,key,label,maximum);}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
}
