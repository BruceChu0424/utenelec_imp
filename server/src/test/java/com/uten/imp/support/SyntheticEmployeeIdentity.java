package com.uten.imp.support;

import com.uten.imp.common.util.IdCardUtil;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

/** Synthetic people are distinct identities, even when their test role has the same label. */
public final class SyntheticEmployeeIdentity {
    private static final AtomicLong DOCUMENT_SEQUENCE=new AtomicLong();
    private SyntheticEmployeeIdentity() { }

    public static String name(String role,UUID employee) {
        if(role==null||role.isBlank())throw new IllegalArgumentException("Synthetic employee role required");
        return role.strip()+" ["+Objects.requireNonNull(employee)+"]";
    }

    /** Reserved synthetic 99xxxx region; the production validator supplies the checksum contract. */
    public static String document() {
        long sequence=DOCUMENT_SEQUENCE.getAndIncrement();
        if(sequence>=9_990_000L)throw new IllegalStateException("Synthetic document namespace exhausted");
        String prefix=String.format(Locale.ROOT,"%06d20000101%03d",990000+sequence/999,sequence%999+1);
        for(char check:"0123456789X".toCharArray()) {
            String candidate=prefix+check;
            if(IdCardUtil.isValid(candidate))return candidate;
        }
        throw new IllegalStateException("Synthetic document does not satisfy the production grammar");
    }
}
