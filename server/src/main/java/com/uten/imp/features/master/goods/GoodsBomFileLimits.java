package com.uten.imp.features.master.goods;

/** BOM 导入解析与源层级合同；导出行数不受导入行数限制。 */
public final class GoodsBomFileLimits {
    /** Import decoding remains bounded independently from complete export output. */
    public static final int MAX_ROWS = 2000;
    /** 根的直接组件算第 1 层，深度索引为 0..10。 */
    public static final int MAX_LEVELS = 11;
    private GoodsBomFileLimits() { }
}
