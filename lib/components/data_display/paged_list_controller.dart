// 单据/档案列表页共享的分页状态机（审计 §4.1 第 2 批）。
//
// 收敛各 *_list_page 手写的 _page/_pageNum/_loading/_error/_keyword/_sortKey/
// _sortAsc + LatestRequestGuard 竞态防护样板：
//  - load(page)：代际守卫（旧响应不回写）、ApiException 优先展示、兜底文案；
//  - silent（返回即刷新）：不翻 loading、不弹错误，数据到达后静默换
//    （stale-while-revalidate，不抢返回转场帧）；
//  - 关键字/排序的常用归一（trim 空→null、sortKey 空→order null）。
//
// 页面专属筛选（状态/类型/日期等）留在页面本地状态，组装进 fetch 闭包；
// 控制器只拥有分页/加载/错误/排序与竞态语义。宿主在 build 里用
// ListenableBuilder(listenable: controller) 订阅重建，本地筛选仍走 setState。
import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/latest_request_guard.dart';
import '../../shared/models/paged_result.dart';

class PagedListController<T> extends ChangeNotifier {
  PagedResult<T>? page;
  int pageNum = 1;
  bool loading = false;
  String? error;
  String keyword = '';

  /// 列排序态：sortKey=null 不排序（走后端默认，如 billDate DESC）。
  String? sortKey;
  bool sortAsc = true;

  final LatestRequestGuard _requests = LatestRequestGuard();
  bool _disposed = false;

  /// 首屏加载（无数据时的转圈）与翻页/筛选加载（表格 loadingMore）区分。
  bool get isLoadingFirst => loading && page == null;
  bool get isLoadingMore => loading && page != null;
  int get currentPage => page?.page ?? 1;
  int get totalPages => page?.totalPages ?? 1;
  int get total => page?.total ?? 0;

  /// trim 后为空返回 null（后端空串/全空白等价不过滤）。
  String? get normalizedKeyword {
    final trimmed = keyword.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 未选排序列时不传 order；选了按升/降序映射后端参数。
  String? get sortOrder => sortKey == null ? null : (sortAsc ? 'asc' : 'desc');

  /// 表头排序回调：column=null 取消排序回后端默认。只更新状态不重查，
  /// 宿主随后自行 load(1)。
  void onSortChange(String? column, bool ascending) {
    sortKey = column;
    sortAsc = ascending;
  }

  /// 拉一页。[fetch] 由宿主用当前筛选组装（异步执行，读取的是调用时快照）；
  /// [silent] 见类注释。dispose 后静默忽略（页面已销毁）。
  Future<void> load(
    int page, {
    bool silent = false,
    required Future<PagedResult<T>> Function() fetch,
  }) async {
    final generation = _requests.begin();
    pageNum = page;
    if (!silent) {
      loading = true;
      error = null;
      _notify();
    }
    try {
      final r = await fetch();
      if (!_requests.isCurrent(generation)) return;
      this.page = r;
      loading = false;
      error = null;
      _notify();
    } on ApiException catch (e) {
      if (!_requests.isCurrent(generation)) return;
      if (silent) return;
      error = e.message;
      loading = false;
      _notify();
    } catch (_) {
      if (!_requests.isCurrent(generation)) return;
      if (silent) return;
      error = '加载列表失败'; // TODO(l10n): 补 arb
      loading = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
