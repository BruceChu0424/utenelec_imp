# Ancestor row window 增量修复证据

源码：`uimp/table-read-performance-20261110` 未提交工作树；基线 `69e35d96`。本页只记本地结构与回归，不是实际浏览器/Windows时延验收。

## 结构与边界

- `immutablePagedRowsWithTail` 只接收私有封存根，复制调用方的小尾部；共同前缀证明不包括footer/summary，原严格append证明保持不变。
- rowwindow 对共同前缀只更新新增行和移动尾部。无证明、重复对象、估计/字体变化、较长尾部删除回退全量。不会根据可变List相同identity猜测未变。
- 私有 `src/RowExtentIndex` 使用估计高度加Fenwick measured delta；容量为当前owner最大行数的下一2次幂，通常小于2N_peak，完整reset释放旧容量。空间并非零成本；不另外保存N份行对象/完整高度数组。
- 测量更新、prefix和rowAt为O(log N)，容量倍增摊销O(N)。旧布局回调以measurement epoch退休，新位置按当前row identity查询；锚点、焦点、选区保活仍由原window维护。

## 保留的失败与修复

首次fractional测试真实失败：estimate=0.1，1000行全部测为0后rowAt(0)返回945而非999；estimate=10.1与52.3分别出现总高 `-3.213944665958479e-10`、`-1.1008154388036928e-9`，被当作负高拒绝。

仅加1e-7px容差后，100k、estimate=52.3全零仍留下 `0.0000073946506944366774` 正残差。最终改为每次setHeight后重新取一个O(log N)的总prefix，避免长期累计 `_total += difference`；近零computed几何和lookup边界使用1e-7px，原始负/NaN/Infinity输入仍严格拒绝。这是显示几何容差，不用于业务数量或金额。

## 已执行

1. `flutter test --no-pub test/components/row_extent_index_test.dart`：修复后7项通过。含三组小数估计、100k全部0与重复回调、三seed随机append/replaceTail/setHeight/reset对拍、0行/0高/大高度、100k实际节点访问计数。
2. 联合 `row_extent_index_test.dart`、`ancestor_row_window_append_test.dart`、`ancestor_row_window_mount_test.dart`、`immutable_paged_rows_test.dart`：26项通过。
3. Widget计数：35k逐千行追加+每批2尾slot，indexRows和offsetRows均为35,070；100k为100,200。最终去掉footer仅多处理1个summary。期间可见行测量没有再触发全N offset扫描。
4. Widget验证包括summary移位、首尾reveal、retain、估计变化全量回退、同mutableList原位换行全量回退，以及原有隐藏/路由退休/挂载预算/settled行为。

5. 新增负/NaN/Infinity输入断言后的pure最终7项通过，原始输出留在 `fenwick-final.log`。6个相关源/测试文件分析零问题，`git diff --check`通过。
6. 既有编辑列宽/锚点/完整刷新联合18过1失败：`master_data_table_view_read_window_refresh_test.dart:221` 打开denial详情后找不到 `denied`。数据退休断言已通过。已向表格owner定位：新缓存清理在空业务行时清空活notice slot，ModalRoute重建导致状态组件dispose并关闭它自己的详情。表格owner确认并修复该生命周期问题，最终结果由其回归记录补充；不删断言、不当作“旧测试”。

实际100k页面body-stage及完整可操作时延需root重新冻结候选后做安静A/B，不能由以上计数推算秒数。
