package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** The frozen recipe identity used by both automatic UI grouping and command admission. */
final class AggregateMaterialProductionRules {
    private final Map<String,List<MaterialView>> children;
    private final Map<UUID,List<String>> recipes=new HashMap<>();
    private final Map<UUID,String> recipeKeys=new HashMap<>();
    private final Set<UUID> invalidRecipes=new HashSet<>();

    AggregateMaterialProductionRules(Map<String,List<MaterialView>> children) { this.children=children; }

    static Map<UUID,String> keys(AnalysisView view) {
        Map<UUID,MaterialView> materials=new HashMap<>();
        Map<String,List<MaterialView>> children=new HashMap<>();
        Map<UUID,ProductView> products=new HashMap<>();
        Map<UUID,SupplyActionView> actions=new HashMap<>();
        for(ProductView product:view.products())products.put(product.analysisLineId(),product);
        for(SupplyActionView action:view.supplyActions())actions.put(action.actionId(),action);
        for(MaterialView material:view.flatMaterials()) {
            materials.put(material.materialLineId(),material);
            if(material.parentNodeKey()!=null)children.computeIfAbsent(nodeRef(material.analysisLineId(),material.parentNodeKey()),ignored->new ArrayList<>()).add(material);
        }
        var rules=new AggregateMaterialProductionRules(children);
        Map<UUID,String> result=new LinkedHashMap<>();
        for(MaterialView original:view.flatMaterials()) {
            if(original.materialLineId()==null)continue;
            List<UUID> targets=original.aggregatePreparation()==null?List.of():original.aggregatePreparation().targetMaterialLineIds();
            boolean retainOriginal=targets.isEmpty()||positive(original.requiredQty())
                    ||AggregateMaterialSourceEligibility.hasIssuedSupply(original,products,actions);
            List<MaterialView> members=new ArrayList<>();
            if(retainOriginal)members.add(original);
            boolean missingTarget=false;
            for(UUID targetId:targets) {
                MaterialView target=materials.get(targetId);
                if(target==null){missingTarget=true;break;}
                members.add(target);
            }
            if(missingTarget)continue;
            boolean hasCurrentResponsibility=members.stream()
                    .anyMatch(member->AggregateMaterialSourceEligibility.hasOrderingContext(member,products,actions));
            String key=null;
            boolean compatible=true;
            for(MaterialView member:members) {
                if(member!=original&&hasCurrentResponsibility
                        &&AggregateMaterialSourceEligibility.isRetiredContext(member,products,actions))continue;
                try {
                    String candidate=rules.key(member);
                    if(key!=null&&!key.equals(candidate)){compatible=false;break;}
                    key=candidate;
                } catch(ApiException failure) {
                    // Keep a malformed/unresolved recipe visible in the analysis. The
                    // locked command still rejects it; it must never acquire a merge key.
                    compatible=false;break;
                }
            }
            // An original that resolves to conflicting frozen recipes needs explicit
            // source allocation, so never advertise that it is safe to merge.
            if(compatible&&key!=null)result.put(original.materialLineId(),key);
        }
        return Map.copyOf(result);
    }

    List<String> recipe(MaterialView parent) { return recipe(parent,new HashSet<>()); }

    private String key(MaterialView parent) {
        return recipeKeys.computeIfAbsent(parent.materialLineId(),ignored->CanonicalFingerprint.sha256(recipe(parent)));
    }

    /** Design usage is stable across learning; adopted usage still drives actual demand. */
    private List<String> recipe(MaterialView parent,Set<UUID> visiting) {
        UUID id=parent.materialLineId();
        if(id==null)throw invalidRecipe();
        List<String> cached=recipes.get(id);
        if(cached!=null)return cached;
        if(invalidRecipes.contains(id)||visiting.size()>=256||!visiting.add(id))throw invalidRecipe();
        try {
            List<String> result=new ArrayList<>();
            for(MaterialView child:children.getOrDefault(nodeRef(parent.analysisLineId(),parent.nodeKey()),List.of())) {
                List<String> fields=new ArrayList<>();
                add(fields,relativePath(parent.nodeKey(),child.nodeKey()),child.goodsId(),child.colorId(),child.unitId(),child.controlStage(),
                        child.consumptionBasis(),child.designBomQty()==null?child.bomQty():child.designBomQty(),
                        child.basisOutputQty(),child.allowPartialPackage(),child.hardGate(),child.sourceConfirmed(),child.routeConfirmed());
                fields.addAll(recipe(child,visiting));result.add(CanonicalFingerprint.sha256(fields));
            }
            result.sort(String::compareTo);
            List<String> frozen=List.copyOf(result);recipes.put(id,frozen);return frozen;
        } catch(ApiException failure) {
            invalidRecipes.add(id);throw failure;
        } finally { visiting.remove(id); }
    }

    private static boolean positive(BigDecimal quantity) { return quantity!=null&&quantity.signum()>0; }
    private static String relativePath(String parent,String child) {
        return parent!=null&&child!=null&&child.startsWith(parent)?child.substring(parent.length()):Objects.toString(child,"");
    }
    private static String nodeRef(UUID source,String key) { return source+"|"+key; }
    private static void add(List<String> target,Object... values) {
        for(Object value:values)target.add(value==null?"N":"V"+(value instanceof BigDecimal decimal?decimal.stripTrailingZeros().toPlainString():value.toString()));
    }
    private static ApiException invalidRecipe() {
        return new ApiException(ErrorCode.CONFLICT,"组件结构存在循环或超过支持层级，请先刷新并核对组件表");
    }
}
