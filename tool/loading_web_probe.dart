// Local-only actual renderer/toolbar probe; never an application release entry.
import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

@JS('utenLoadingProbe')
external set _probeReader(JSFunction value);
@JS('utenLoadingAction')
external set _probeAction(JSFunction value);
void main() => runApp(
  ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          Dio(BaseOptions(baseUrl: 'https://loading-probe.invalid/api')),
        ),
      ),
    ],
    child: MaterialApp(theme: buildLightTheme(), home: const _Probe()),
  ),
);

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _LineMap extends MapBase<String, Object?> {
  _LineMap(this.facts);
  final Map<String, Object?> facts;
  int keyReads = 0;
  @override
  Object? operator [](Object? key) => facts[key];
  @override
  void operator []=(String key, Object? value) => facts[key] = value;
  @override
  void clear() => facts.clear();
  @override
  Iterable<String> get keys {
    keyReads++;
    return facts.keys;
  }

  @override
  Object? remove(Object? key) => facts.remove(key);
}

class _ProbeState extends State<_Probe> {
  final _key = GlobalKey(), _outputKey = GlobalKey();
  final _rows = MasterDataTableRowsController<Map<String, Object?>>();
  final _projection = TableColumnProjectionController();
  late List<Map<String, Object?>> _data = List.generate(
    36000,
    (index) => {
      'code': index < 3
          ? 'Equal duplicate'
          : 'HP-${index.toString().padLeft(5, '0')}',
      'name': index < 3 ? 'Same visible occurrence' : '滚动验证货品 $index',
    },
  );
  var _pageRequests = 0, _mounts = 0, _liveMounts = 0, _toolbarTaps = 0;
  var _mode = 'anonymous-duplicates';
  List<Map<String, String?>> _captured = const [];
  @override
  void initState() {
    super.initState();
    _probeReader = (() => jsonEncode(_state()).toJS).toJS;
    _probeAction = ((JSString command) {
      if (command.toDart == 'lineIds') {
        setState(() {
          _mode = 'line-identities';
          _captured = const [];
          _data = List.generate(
            36000,
            (index) => _LineMap({
              '__lineId': 'line-$index',
              'code': 'LINE-${index.toString().padLeft(5, '0')}',
              'name': '原始行 $index',
            }),
          );
        });
      }
    }).toJS;
  }

  List<double>? _rect(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final point = box.localToGlobal(Offset.zero);
    return [point.dx, point.dy, box.size.width, box.size.height];
  }

  Map<String, Object?> _state() {
    var placeholders = 0, checked = 0, bodyOwners = 0, bodyPositions = 0;
    int? header;
    double? pixels, maximum;
    final checkboxes = <List<double>>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is UtenRowMountPlaceholder) placeholders++;
      if (widget is Text && widget.data == '编号') {
        header ??= identityHashCode(element);
      }
      if (widget is Checkbox) {
        if (widget.value == true) checked++;
        final rect = _rect(element);
        if (rect != null && rect[1] >= 0 && rect[1] < 900) checkboxes.add(rect);
      }
      if (widget is UtenPageScrollbarSource &&
          widget.debugLabel == 'master-table-body') {
        bodyOwners++;
        final positions = widget.controller.positions.toList();
        bodyPositions += positions.length;
        if (positions.length == 1) {
          final position = positions.single;
          if (position.axis == Axis.vertical && position.hasContentDimensions) {
            pixels = position.pixels;
            maximum = position.maxScrollExtent;
          }
        }
      }
      element.visitChildren(visit);
    }

    final element = _key.currentContext;
    if (element is Element) visit(element);
    return {
      'mode': _mode,
      'loadedRows': _rows.items.length,
      'equalDuplicateOccurrences': _rows.items
          .where((row) => row['code'] == 'Equal duplicate')
          .length,
      'actualStateMounts': _mounts,
      'actualLiveStates': _liveMounts,
      'pageRequests': _pageRequests,
      'placeholders': placeholders,
      'headerElement': header,
      'scrollPixels': pixels,
      'maximumScroll': maximum,
      'bodyOwnerCount': bodyOwners,
      'bodyPositionCount': bodyPositions,
      'selectedOutputIds':
          _projection.resolve('loading-probe')?.outputSelection.ids.length ?? 0,
      'checkedMountedBoxes': checked,
      'checkboxRects': checkboxes,
      'toolbarRect': _rect(_outputKey.currentContext),
      'toolbarTaps': _toolbarTaps,
      'capturedRawRows': _captured,
      'lineMapKeyReads': _data.whereType<_LineMap>().fold<int>(
        0,
        (total, row) => total + row.keyReads,
      ),
      'mounted': mounted,
    };
  }

  Future<UtenExportSelection?> _captureToolbar() async {
    final frozen = await _projection
        .resolve('loading-probe')!
        .outputSelection
        .snapshot();
    _captured = frozen.rows;
    _toolbarTaps++;
    // End preparation before any file/network command.
    return null;
  }

  @override
  void dispose() {
    _projection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TableColumnProjectionScope(
      controller: _projection,
      child: MasterDataTableView<Map<String, Object?>>(
        key: _key,
        tableKey: 'loading-probe',
        rowsController: _rows,
        items: _data,
        // Default bounded admission: no business identity or virtualization opt-in.
        totalPages: 1800,
        onPageChange: (_) => _pageRequests++,
        toolbarActions: [
          UtenExportButton(
            key: _outputKey,
            endpoint: '/fixture/export',
            report: 'detail',
            queryParams: const {'keyword': 'current-scope'},
            tableKey: 'loading-probe',
            prepareExport: _captureToolbar,
          ),
        ],
        columns: [
          MasterColumnDef<Map<String, Object?>>(
            key: 'code',
            label: '编号',
            width: 220,
            value: (row) => '${row['code']}',
            cellBuilder: (_, row) => _MountedCell(
              value: '${row['code']}',
              onMount: () {
                _mounts++;
                _liveMounts++;
              },
              onDispose: () => _liveMounts--,
            ),
          ),
          MasterColumnDef<Map<String, Object?>>(
            key: 'name',
            label: '名称',
            width: 280,
            value: (row) => '${row['name']}',
          ),
        ],
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        showColumnChooser: false,
        showFullscreenToggle: false,
      ),
    ),
  );
}

class _MountedCell extends StatefulWidget {
  const _MountedCell({
    required this.value,
    required this.onMount,
    required this.onDispose,
  });
  final String value;
  final VoidCallback onMount, onDispose;
  @override
  State<_MountedCell> createState() => _MountedCellState();
}

class _MountedCellState extends State<_MountedCell> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.value);
}
