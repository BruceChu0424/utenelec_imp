package com.uten.imp.common.delivery;

import com.uten.imp.common.finance.BomConsumptionCurve;
import com.uten.imp.common.finance.CostFraction;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.*;

/** Actual processing subjects inside a whole delivery boundary. Reporting counts complete physical delivery units. */
public final class DeliveryProcessingTargets {
    private DeliveryProcessingTargets(){}
    public record Target(List<UUID> path,UUID goodsId,String code,String name,UUID unitId,String unitName,
            String quantityExact,String quantityNumerator,String quantityDenominator,List<String> operations){
        public Target{path=List.copyOf(path);operations=List.copyOf(operations);}
        @com.fasterxml.jackson.annotation.JsonIgnore
        public String getQuantityDisplay(){return quantityExact==null?quantityNumerator+"/"+quantityDenominator:quantityExact;}
    }
    public static List<Target> resolve(DeliveryBom.Node root,List<UUID> path,BigDecimal physicalQty,DeliveryPlan plan){
        return new Resolver(root,plan).resolve(path,physicalQty);
    }
    /** Index once per preview so a wide frontier does not rescan the full tree for every physical row. */
    public static final class Resolver {
        private final Map<List<UUID>,DeliveryBom.Node> nodes=new HashMap<>();
        private final Map<List<UUID>,Set<String>> requested=new HashMap<>();
        private final Set<List<UUID>> relevant=new HashSet<>();
        public Resolver(DeliveryBom.Node root,DeliveryPlan plan){
            for(var operation:plan.processes())if(Boolean.TRUE.equals(operation.required()))
                requested.computeIfAbsent(operation.path(),ignored->new TreeSet<>()).add(operation.operation().name());
            index(root);
        }
        private boolean index(DeliveryBom.Node node){
            nodes.put(node.path(),node);
            boolean active=!node.requiredOperations().isEmpty()||!requested.getOrDefault(node.path(),Set.of()).isEmpty();
            for(var child:node.children())active=index(child)||active;
            if(active)relevant.add(node.path());
            return active;
        }
        public List<Target> resolve(List<UUID> path,BigDecimal physicalQty){
            var boundary=nodes.get(path);
            if(boundary==null)throw new ApiException(ErrorCode.CONFLICT,"加工对象不在冻结的交付BOM路径中");
            if(!relevant.contains(path))return List.of();
            List<Target> result=new ArrayList<>();walk(boundary,CostFraction.of(physicalQty),requested,relevant,result);
            result.sort(Comparator.comparing(t->t.path().toString()));return List.copyOf(result);
        }
    }
    private static void walk(DeliveryBom.Node node,CostFraction quantity,Map<List<UUID>,Set<String>> requested,Set<List<UUID>> relevant,List<Target> result){
        if(!node.identityIssues().isEmpty())throw new ApiException(ErrorCode.CONFLICT,
                "必要加工路径的货品、颜色或基本单位身份未核对，不能用老系统引用猜测实际对象");
        Set<String> operations=new TreeSet<>(requested.getOrDefault(node.path(),Set.of()));
        node.requiredOperations().forEach(o->operations.add(o.name()));
        if(!operations.isEmpty())result.add(new Target(node.path(),node.goodsId(),node.code(),node.name(),node.unitId(),node.unitName(),
            exact(quantity),quantity.numerator().toString(),quantity.denominator().toString(),List.copyOf(operations)));
        for(var child:node.children()){
            if(!relevant.contains(child.path()))continue;
            CostFraction childQuantity;
            try{if(child.qtyExact()==null||child.basisOutputQtyExact()==null)throw new IllegalArgumentException();
                childQuantity=BomConsumptionCurve.exact(quantity,new BigDecimal(child.qtyExact()),child.consumptionBasis(),
                new BigDecimal(child.basisOutputQtyExact()),child.allowPartialPackage());}
            catch(IllegalArgumentException|ArithmeticException e){throw new ApiException(ErrorCode.CONFLICT,"必要加工路径的BOM用量或计量基准不完整，请先核对原资料");}
            walk(child,childQuantity,requested,relevant,result);
        }
    }
    private static String exact(CostFraction quantity){try{return new BigDecimal(quantity.numerator()).divide(new BigDecimal(quantity.denominator())).stripTrailingZeros().toPlainString();}
        catch(ArithmeticException e){return null;}}
    /** Labels may change without changing a physical requirement or reinterpreting historical names. */
    public static String fingerprint(List<Target> targets){return CanonicalFingerprint.sha256(targets.stream()
        .map(t->t.path()+"|"+t.goodsId()+"|"+t.unitId()+"|"+t.quantityNumerator()+"/"+t.quantityDenominator()+"|"+t.operations()).sorted().toList());}
}
