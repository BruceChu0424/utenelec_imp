package com.uten.imp.application.port;

import java.lang.reflect.RecordComponent;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

/**
 * 工作台徽章计数来源(ADR-108)。
 *
 * <p>每个业务模块登记自己入口的计数来源: 一个来源 = 原来前端单独轮询的一个计数端点。
 * 来源的读取函数**直接调用该端点的控制器方法**(经 Spring 代理), 因此资格判定就是端点上
 * 的 {@code @PreAuthorize}、数字就是端点返回的数字, 聚合端点不另写一套口径。
 *
 * <p>无权访问时控制器代理抛出 {@code AccessDeniedException}, 聚合端点据此把该来源视为
 * 「不可见」, 相关入口不出现在汇总里; 其它异常视为「本次没算出来」, 前端保留上一次的数。
 */
public interface WorkbenchBadgeSources {

    /** 本模块登记的计数来源(声明顺序即执行顺序)。 */
    List<Source> sources();

    /**
     * 一个计数来源。
     *
     * @param key    来源键, 汇总里事实数的前缀(如 {@code workshopTask} → {@code workshopTask.preparing})
     * @param reader 按当前主体读一次; 返回 字段名 → 数
     */
    record Source(String key, Supplier<Map<String, Long>> reader) {
        public Source {
            if (key == null || key.isBlank() || key.contains(".")) {
                throw new IllegalArgumentException("徽章来源键不能为空且不能含点号: " + key);
            }
            if (reader == null) {
                throw new IllegalArgumentException("徽章来源缺少读取函数: " + key);
            }
        }
    }

    /**
     * 把端点返回值摊平成 字段名 → 数: 支持 {@code Map<String, Number>}、只含数字/嵌套
     * Map 的 record; 嵌套一层用点号连接(如 {@code actionable.PURCHASE})。非数字字段忽略。
     */
    static Map<String, Long> numbers(Object value) {
        Map<String, Long> out = new LinkedHashMap<>();
        flatten("", value, out);
        return out;
    }

    private static void flatten(String prefix, Object value, Map<String, Long> out) {
        if (value instanceof Number number) {
            if (!prefix.isEmpty()) out.put(prefix, number.longValue());
            return;
        }
        if (value instanceof Map<?, ?> map) {
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (entry.getKey() == null) continue;
                flatten(join(prefix, entry.getKey().toString()), entry.getValue(), out);
            }
            return;
        }
        if (value != null && value.getClass().isRecord()) {
            for (RecordComponent component : value.getClass().getRecordComponents()) {
                try {
                    var accessor = component.getAccessor();
                    // 包内可见的 record(如控制器内嵌的计数结构)也要能读。
                    accessor.setAccessible(true);
                    flatten(join(prefix, component.getName()), accessor.invoke(value), out);
                } catch (ReflectiveOperationException ex) {
                    throw new IllegalStateException("读取徽章计数字段失败: " + component.getName(), ex);
                }
            }
        }
    }

    private static String join(String prefix, String name) {
        return prefix.isEmpty() ? name : prefix + "." + name;
    }
}
