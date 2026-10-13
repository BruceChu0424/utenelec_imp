package com.uten.imp.features.master.goods.pricing;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;

/** Deterministic robust reference, not a claim to forecast a market price. */
final class GoodsPriceStatistics {
    static final String VERSION="PRICE_ROBUST_MEDIAN_V1";
    static final int MAX_ROWS=500, MIN_ORDERS=3, STALE_DAYS=90;
    static final double HALF_LIFE_DAYS=90, MIN_EFFECTIVE=2.5;
    record Result(String status,BigDecimal reference,BigDecimal average,BigDecimal lower,BigDecimal upper,
            BigDecimal last,LocalDate lastDate,int samples,int orders,double effective,List<String> reasons) {}
    private record Sample(BigDecimal price,BigDecimal amount,BigDecimal quantity,LocalDate date,double weight) {}
    private record Weighted(double value,double weight) {}
    static Result calculate(List<Observation> observations,LocalDate today,BigDecimal requestedQuantity,boolean complete) {
        if(!complete)return new Result("LIMIT_EXCEEDED",null,null,null,null,null,null,0,0,0,List.of("SOURCE_LIMIT_EXCEEDED"));
        var comparable=observations.stream().filter(Observation::comparable).toList();
        if(comparable.isEmpty())return new Result("INSUFFICIENT",null,null,null,null,null,null,0,0,0,List.of("NO_COMPARABLE_HISTORY"));
        // Split lines from one approved order are one independent commercial decision.
        Map<UUID,List<Observation>> documents=new LinkedHashMap<>();
        comparable.forEach(o->documents.computeIfAbsent(o.sourceId(),ignored->new ArrayList<>()).add(o));
        List<Sample> samples=new ArrayList<>();
        BigDecimal totalAmount=BigDecimal.ZERO,totalQuantity=BigDecimal.ZERO;
        double strongestQuantitySimilarity=0;
        for(var group:documents.values()) {
            BigDecimal amount=group.stream().map(o->new BigDecimal(o.amount())).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal quantity=group.stream().map(o->new BigDecimal(o.quantity())).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal price=amount.divide(quantity,java.math.MathContext.DECIMAL128);
            LocalDate date=group.getFirst().businessDate();
            double age=Math.max(0,ChronoUnit.DAYS.between(date,today));
            double similarity=requestedQuantity==null?1:Math.min(quantity.doubleValue()/requestedQuantity.doubleValue(),requestedQuantity.doubleValue()/quantity.doubleValue());
            strongestQuantitySimilarity=Math.max(strongestQuantitySimilarity,similarity);
            double weight=Math.pow(2,-age/HALF_LIFE_DAYS)*similarity;
            samples.add(new Sample(price,amount,quantity,date,weight));
            totalAmount=totalAmount.add(amount);totalQuantity=totalQuantity.add(quantity);
        }
        samples.sort(Comparator.comparing(Sample::price));
        double sum=samples.stream().mapToDouble(Sample::weight).sum();
        double squares=samples.stream().mapToDouble(s->s.weight()*s.weight()).sum();
        double effective=sum*sum/squares;
        BigDecimal median=samples.getLast().price();double cumulative=0;
        for(Sample sample:samples){cumulative+=sample.weight();if(cumulative>=sum/2){median=sample.price();break;}}
        double center=Math.log(median.doubleValue());
        List<Weighted> distances=samples.stream().map(s->new Weighted(Math.abs(Math.log(s.price().doubleValue())-center),s.weight()))
                .sorted(Comparator.comparingDouble(Weighted::value)).toList();
        double mad=weightedMedian(distances,sum);
        // Zero MAD is common with contract prices. A relative floor preserves sensitivity for tiny-priced bulk goods.
        double band=Math.max(Math.log(1.10),3*1.4826*mad);
        BigDecimal upper=median.multiply(BigDecimal.valueOf(Math.exp(Math.min(band,50))));
        BigDecimal lower=median.multiply(BigDecimal.valueOf(Math.exp(-Math.min(band,50))));
        Observation last=comparable.stream().max(Comparator.comparing(Observation::businessDate).thenComparing(o->o.sourceItemId().toString())).orElseThrow();
        List<String> reasons=new ArrayList<>();
        if(documents.size()<MIN_ORDERS)reasons.add("TOO_FEW_INDEPENDENT_ORDERS");
        if(effective<MIN_EFFECTIVE)reasons.add("LOW_EFFECTIVE_SAMPLE_SIZE");
        // Kish effective size measures concentration, not distance from this order's quantity.
        if(requestedQuantity!=null&&strongestQuantitySimilarity<0.1)reasons.add("QUANTITY_CONTEXT_WEAK");
        boolean stale=ChronoUnit.DAYS.between(last.businessDate(),today)>STALE_DAYS;
        if(stale)reasons.add("STALE_HISTORY");
        String status=stale?"STALE":reasons.isEmpty()?"READY":"INSUFFICIENT";
        return new Result(status,median,totalAmount.divide(totalQuantity,java.math.MathContext.DECIMAL128),lower,upper,
                new BigDecimal(last.unitPrice()),last.businessDate(),comparable.size(),documents.size(),effective,List.copyOf(reasons));
    }
    private static double weightedMedian(List<Weighted> values,double sum){double cumulative=0;for(var v:values){cumulative+=v.weight();if(cumulative>=sum/2)return v.value();}return values.getLast().value();}
}
