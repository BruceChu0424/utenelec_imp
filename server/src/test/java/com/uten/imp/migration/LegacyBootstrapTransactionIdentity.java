package com.uten.imp.migration;

/** Exact reconstruction only inside the persisted claim/current transaction interval. */
final class LegacyBootstrapTransactionIdentity {
    private static final long EPOCH=1L<<32;
    private LegacyBootstrapTransactionIdentity() { }
    static long full(long low,long claim,long current) {
        if(low<0||low>=EPOCH||claim<=0||current<claim)
            throw new IllegalArgumentException("Invalid bootstrap transaction interval");
        long candidate=Math.addExact(claim/EPOCH*EPOCH,low);
        if(candidate<claim)candidate=Math.addExact(candidate,EPOCH);
        if(candidate>current||current-candidate>=EPOCH)
            throw new IllegalArgumentException("Bootstrap row transaction cannot be proved uniquely inside its claim interval");
        return candidate;
    }
}
