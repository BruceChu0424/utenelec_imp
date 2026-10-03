package com.uten.imp.features.master.goods;

/** 完整 BOM 文件的统一资源边界；仅限制文件展开，不限制生产数量。 */
public final class GoodsBomFileLimits {
    public static final int MAX_ROWS = 2000;
    /** 根的直接组件算第 1 层，深度索引为 0..10。 */
    public static final int MAX_LEVELS = 11;
    private GoodsBomFileLimits() { }
}
