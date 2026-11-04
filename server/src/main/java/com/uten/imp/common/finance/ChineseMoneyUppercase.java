package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;

/** Exact display text for RMB statements. Returns null when an exact cent text cannot be represented. */
public final class ChineseMoneyUppercase {
    private ChineseMoneyUppercase() { }
    private static final String DIGITS="零壹贰叁肆伍陆柒捌玖";
    private static final String[] FOUR={"","拾","佰","仟"};
    private static final String[] GROUP={"","万","亿","万亿","亿亿","万亿亿","亿亿亿"};
    public static String format(BigDecimal value){
        if(value==null||value.stripTrailingZeros().scale()>2||value.abs().compareTo(BigDecimal.TEN.pow(28))>=0)return null;
        BigInteger cents=value.abs().movePointRight(2).setScale(0,RoundingMode.UNNECESSARY).toBigIntegerExact();
        BigInteger[] parts=cents.divideAndRemainder(BigInteger.valueOf(100));int fraction=parts[1].intValueExact(),jiao=fraction/10,fen=fraction%10;
        var out=new StringBuilder("人民币");if(value.signum()<0)out.append("负");
        if(parts[0].signum()>0)out.append(yuan(parts[0])).append('元');else if(fraction==0)out.append("零元");
        if(fraction==0)return out.append('整').toString();
        if(jiao>0)out.append(DIGITS.charAt(jiao)).append('角');else if(parts[0].signum()>0)out.append('零');
        if(fen>0)out.append(DIGITS.charAt(fen)).append('分');
        return out.toString();
    }
    private static String yuan(BigInteger value){
        var groups=new ArrayList<Integer>();while(value.signum()>0){var part=value.divideAndRemainder(BigInteger.valueOf(10000));groups.add(part[1].intValueExact());value=part[0];}
        var out=new StringBuilder();boolean skipped=false;
        for(int i=groups.size()-1;i>=0;i--){int group=groups.get(i);if(group==0){skipped=true;continue;}if(!out.isEmpty()&&(group<1000||skipped)){out.append('零');}out.append(four(group)).append(GROUP[i]);skipped=false;}return out.toString();
    }
    private static String four(int value){var out=new StringBuilder();boolean zero=false;int divisor=1000;for(int i=3;i>=0;i--){int digit=value/divisor%10;divisor/=10;if(digit==0){if(!out.isEmpty()){zero=true;}continue;}if(zero){out.append('零');}out.append(DIGITS.charAt(digit)).append(FOUR[i]);zero=false;}return out.toString();}
}
