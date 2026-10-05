// AiPageContextController - AI 助手的页面上下文登记表(ADR-150)。
// 文档：docs/02-组件库/AiPageContext.md
//
// 共享组件(MasterDataTableView / UtenEditableGrid / 输入组件 / 状态徽章 / 提示横幅 /
// 页面)在挂载时登记「取值回调」, 不在每帧计算任何东西; 只有用户在 AI 对话框里
// 发送问题(或确认一张卡片)时, 才按登记表计算一次有界快照。快照只取**顶层当前路由**:
// 被新页面或弹窗盖住的页面、Offstage/IndexedStack 里看不见的分页都不进来。
library;

import 'package:flutter/rendering.dart' show RenderOffstage;
import 'package:flutter/widgets.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import 'ai_page_snapshot.dart';

export 'ai_page_snapshot.dart';

/// Passed to every provider when a snapshot or an action list is computed.
class AiCaptureContext {
  AiCaptureContext(this.l10n);
  final AppLocalizations l10n;
}

AppLocalizations aiPageL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    AppLocalizationsZh();

/// What an action changes; the server derives the minimum risk from it.
enum AiActionKind {
  view('VIEW'),
  form('FORM'),
  save('SAVE'),
  submit('SUBMIT');

  const AiActionKind(this.wire);
  final String wire;
}

enum AiParamType { string, integer, number, boolean }

/// One closed, scalar parameter. Declaration order is the order of the lines
/// on the confirmation card.
class AiActionParam {
  const AiActionParam(
    this.name, {
    required this.type,
    required this.title,
    this.required = true,
    this.maxLength,
    this.minimum,
    this.maximum,
    this.options,
    this.description,
    this.rowRef = false,
  });
  final String name;
  final AiParamType type;
  final String title;
  final bool required;
  final int? maxLength;
  final num? minimum;
  final num? maximum;
  final List<Object>? options;
  final String? description;

  /// A screen row of the action's [AiPageAction.rowTable]: an integer row
  /// number, or a row list such as "1,3,5-8" (0 or empty = none). The card is
  /// bound to the records those rows held when the question was sent; the
  /// handler receives them through [AiActionCall.rows].
  final bool rowRef;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'title': aiSnapshotLabel(title, 20) ?? name,
    if (description != null) 'description': aiSnapshotValue(description, 120),
    if (type == AiParamType.string)
      'maxLength': (maxLength ?? AiSnapshotLimits.value).clamp(1, 200),
    if (type == AiParamType.integer || type == AiParamType.number) ...{
      'minimum': ?minimum,
      'maximum': ?maximum,
    },
    if (options != null && options!.isNotEmpty)
      'enum': [
        for (final option in options!.take(60))
          option is String ? (aiSnapshotLabel(option, 60) ?? '') : option,
      ].where((option) => option != '').toList(),
  };

  /// Defensive re-check of an argument the server already validated.
  Object? coerce(Object? raw) {
    if (raw == null) return null;
    switch (type) {
      case AiParamType.string:
        if (raw is! String) return null;
        if (raw.length > (maxLength ?? AiSnapshotLimits.value)) return null;
        if (options != null && !options!.contains(raw)) return null;
        return raw;
      case AiParamType.integer:
        final value = raw is int
            ? raw
            : raw is num && raw == raw.roundToDouble()
            ? raw.toInt()
            : null;
        if (value == null) return null;
        // A row number is checked against the rows bound when the question
        // was sent (AiPageContextController.run), not today's row count.
        if (rowRef) return value >= 1 ? value : null;
        if (minimum != null && value < minimum!) return null;
        if (maximum != null && value > maximum!) return null;
        return value;
      case AiParamType.number:
        if (raw is! num) return null;
        if (minimum != null && raw < minimum!) return null;
        if (maximum != null && raw > maximum!) return null;
        return raw;
      case AiParamType.boolean:
        return raw is bool ? raw : null;
    }
  }
}

/// One confirmed execution: the checked arguments, and for row parameters
/// ([AiActionParam.rowRef]) the records the user saw on those rows when the
/// question was sent (re-verified to still be on the same screen rows).
class AiActionCall {
  const AiActionCall(this.args, [this._rows = const {}]);
  final Map<String, Object?> args;
  final Map<String, List<Object>> _rows;

  /// Records bound to the row parameter [param], in the order given.
  List<Object> rows(String param) => _rows[param] ?? const [];

  /// The single record bound to the row parameter [param], or null.
  Object? row(String param) {
    final records = rows(param);
    return records.isEmpty ? null : records.first;
  }
}

/// A handler returns an optional short outcome message and throws
/// [AiActionFailure] (with a user-facing reason) when it cannot finish.
typedef AiActionHandler = Future<String?> Function(AiActionCall call);

class AiActionFailure implements Exception {
  const AiActionFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One entry of the page's closed action set (`pageActions[]`).
class AiPageAction {
  const AiPageAction({
    required this.name,
    required this.title,
    required this.kind,
    required this.handler,
    this.params = const [],
    this.risk,
    this.rowTable,
  });
  final String name;
  final String title;
  final AiActionKind kind;
  final String? risk;
  final List<AiActionParam> params;
  final AiActionHandler handler;

  /// The table whose screen rows the [AiActionParam.rowRef] parameters count
  /// (matched against [AiTableSource.owner]; UtenEditableGrid: its controller).
  final Object? rowTable;

  static final _name = RegExp(r'^[a-z][A-Za-z0-9_]{1,47}$');
  bool get valid =>
      _name.hasMatch(name) &&
      params.length <= 6 &&
      (rowTable != null || !params.any((param) => param.rowRef));

  Map<String, Object?> toJson() => {
    'name': name,
    'title': aiSnapshotLabel(title) ?? name,
    'kind': kind.wire,
    'risk': ?risk,
    'params': {
      'type': 'object',
      'additionalProperties': false,
      'properties': {for (final param in params) param.name: param.toJson()},
      'required': [
        for (final param in params)
          if (param.required) param.name,
      ],
    },
  };

  /// Arguments returned by the confirm endpoint, re-checked against this
  /// page's current declaration. Unknown or malformed arguments fail closed.
  Map<String, Object?> checkedArgs(Map<String, Object?> raw) {
    final result = <String, Object?>{};
    for (final key in raw.keys) {
      if (!params.any((param) => param.name == key)) {
        throw const AiActionFailure('');
      }
    }
    for (final param in params) {
      final value = param.coerce(raw[param.name]);
      if (value == null) {
        if (param.required || raw[param.name] != null) {
          throw const AiActionFailure('');
        }
        continue;
      }
      result[param.name] = value;
    }
    return result;
  }
}

/// Providers registered by components. Every callback runs only on demand.
sealed class AiPageSource {
  const AiPageSource();
}

/// A table (MasterDataTableView / UtenEditableGrid). [actions] gives the
/// table's generic view actions; [AiTableActionScope.suffix] keeps names unique
/// when one page shows several tables.
class AiTableSource extends AiPageSource {
  const AiTableSource({
    required this.capture,
    this.actions,
    this.owner,
    this.records,
    this.recordKey,
  });
  final AiTableSnapshot? Function(AiCaptureContext ctx) capture;
  final List<AiPageAction> Function(
    AiCaptureContext ctx,
    AiTableActionScope scope,
  )?
  actions;

  /// The object actions use as [AiPageAction.rowTable] for this table.
  final Object? Function()? owner;

  /// Current records in screen order: record N is the snapshot's row `no` N.
  final List<Object> Function()? records;

  /// Stable identity of a record across rebuilds and reloads (default: the
  /// record object itself).
  final Object Function(Object record)? recordKey;

  List<Object> _keys() => [
    for (final record in records?.call() ?? const <Object>[])
      recordKey?.call(record) ?? record,
  ];
}

class AiTableActionScope {
  const AiTableActionScope({required this.suffix, required this.index});
  final String suffix;
  final int index;
}

/// An input. [setValue] is the generic "set this field" action; components
/// mark what they changed with the yellow "AI filled, please review" frame.
class AiFieldSource extends AiPageSource {
  const AiFieldSource({required this.capture, this.setValue});
  final AiFieldSnapshot? Function(AiCaptureContext ctx) capture;
  final Future<void> Function(String value, AiCaptureContext ctx)? setValue;
}

class AiBadgeSource extends AiPageSource {
  const AiBadgeSource({required this.label, this.tone, this.color, this.count});
  final String label;
  final String? tone;
  final String? color;
  final int? count;
}

class AiNoticeSource extends AiPageSource {
  const AiNoticeSource({required this.kind, required this.text, this.title});
  final AiNoticeKind kind;
  final String? title;
  final String text;
}

/// Page-level contribution: title, page actions, extra notices.
class AiPageInfoSource extends AiPageSource {
  const AiPageInfoSource({this.title, this.actions, this.notices});
  final String? Function(AiCaptureContext ctx)? title;
  final List<AiPageAction> Function(AiCaptureContext ctx)? actions;
  final List<AiNoticeSnapshot> Function(AiCaptureContext ctx)? notices;
}

/// What a card proposed from one question is bound to: the page instance on
/// top when the question was sent, and the record identities of the tables
/// its row parameters count. A confirmed card runs only against those.
class AiCaptureBinding {
  const AiCaptureBinding._(this._page, this._rows);

  /// No capture (page awareness off): page cards cannot run.
  static const none = AiCaptureBinding._(null, {});
  final Object? _page;
  final Map<Object, List<Object>> _rows;

  bool get isNone => identical(this, none);
}

/// Result of one capture. [snapshot] is null when nothing on the top page is
/// registered (the request then carries the route only) or when the page is
/// one whose content is never read ([withheld]).
class AiPageCapture {
  const AiPageCapture({
    required this.snapshot,
    required this.rows,
    required this.fields,
    required this.flagged,
    required this.actions,
    this.binding = AiCaptureBinding.none,
    this.withheld = false,
    this.protectedPage = false,
  });
  static const empty = AiPageCapture(
    snapshot: null,
    rows: 0,
    fields: 0,
    flagged: 0,
    actions: {},
  );

  /// Payroll, HR and personal pages (aiPageContentWithheld).
  static const contentWithheld = AiPageCapture(
    snapshot: null,
    rows: 0,
    fields: 0,
    flagged: 0,
    actions: {},
    withheld: true,
  );

  /// ADR-153 system administration and security pages (aiPageProtected):
  /// nothing is captured and no page action is offered.
  static const systemPage = AiPageCapture(
    snapshot: null,
    rows: 0,
    fields: 0,
    flagged: 0,
    actions: {},
    withheld: true,
    protectedPage: true,
  );
  final Map<String, Object?>? snapshot;
  final int rows;
  final int fields;
  final int flagged;
  final Map<String, AiPageAction> actions;
  final AiCaptureBinding binding;
  final bool withheld;
  final bool protectedPage;
}

class _AiEntry {
  _AiEntry(this.element, this.source, this.order);
  Element element;
  AiPageSource source;
  final int order;
}

class _LiveEntry {
  _LiveEntry(this.entry, this.depth, this.layer, this.layerNode, this.position);
  final _AiEntry entry;
  final int depth;

  /// Paint order of the navigator overlay entry holding this element (a route
  /// pushed later paints above); -1 when it is not inside a navigator.
  final int layer;

  /// That overlay entry's render object: one per page instance.
  final RenderObject? layerNode;
  final Offset position;
}

/// Entries of the top page plus that page instance's identity.
typedef _TopPage = ({List<_AiEntry> entries, _PageToken page});

/// Identity of one page instance: the navigator overlay entry it is painted
/// in, plus the page-level registrations (AiPageInfoSource) of its State. A
/// new route, or the same route rebuilt with a new page State (another new
/// order opened after saving), is another page.
class _PageToken {
  _PageToken(this.layer, this.pages);
  final RenderObject? layer;
  final Set<_AiEntry> pages;

  @override
  bool operator ==(Object other) =>
      other is _PageToken &&
      identical(other.layer, layer) &&
      other.pages.length == pages.length &&
      other.pages.containsAll(pages);

  @override
  int get hashCode => Object.hash(identityHashCode(layer), pages.length);
}

class AiPageContextController {
  final _entries = <Object, _AiEntry>{};
  int _order = 0;
  bool _closed = false;

  /// Registers (or replaces) [owner]'s provider. Cheap: a map write, no
  /// notification and no computation.
  void register(Object owner, BuildContext context, AiPageSource source) {
    if (_closed) return;
    final existing = _entries[owner];
    if (existing != null) {
      existing
        ..element = context as Element
        ..source = source;
      return;
    }
    _entries[owner] = _AiEntry(context as Element, source, _order++);
  }

  void unregister(Object owner) => _entries.remove(owner);

  int get debugEntryCount => _entries.length;

  /// Entries of the top-most route, in screen order. A registered widget whose
  /// route is covered, or that sits in an offstage/inactive subtree, is not
  /// "on screen".
  ///
  /// Nothing here creates a dependency (no `ModalRoute.of`/`isCurrentOf`):
  /// a capture must not make tables and inputs rebuild on later push/pop.
  /// Covered opaque routes are already offstage with tickers off; for a
  /// translucent route (dialog, side sheet) in the same navigator, the overlay
  /// paint order decides which route is on top.
  _TopPage _topEntries() {
    final live = <_LiveEntry>[];
    final layerOrders = <RenderObject, Map<RenderObject, int>>{};
    for (final entry in _entries.values.toList(growable: false)) {
      final element = entry.element;
      try {
        if (!element.mounted) continue;
        if (!TickerMode.getValuesNotifier(element).value.enabled) continue;
        final render = element.renderObject;
        if (render == null || !render.attached) continue;
        if (render is RenderBox && !render.hasSize) continue;
        final navigator = element.findAncestorStateOfType<NavigatorState>();
        final theater = navigator?.overlay?.context.findRenderObject();
        var layer = -1;
        RenderObject? layerNode;
        var hidden = false;
        RenderObject? node = render;
        while (node != null) {
          if (node is RenderOffstage && node.offstage) {
            hidden = true;
            break;
          }
          final parent = node.parent;
          if (theater != null && identical(parent, theater)) {
            final order = layerOrders.putIfAbsent(theater, () {
              final indexes = <RenderObject, int>{};
              var i = 0;
              theater.visitChildren((child) => indexes[child] = i++);
              return indexes;
            });
            layer = order[node] ?? -1;
            layerNode = node;
            break;
          }
          node = parent;
        }
        if (hidden) continue;
        live.add(
          _LiveEntry(
            entry,
            navigator == null ? 0 : _navigatorDepth(element),
            layer,
            layerNode,
            render is RenderBox
                ? render.localToGlobal(Offset.zero)
                : Offset.zero,
          ),
        );
      } catch (_) {
        // An element in the middle of being moved is simply not captured.
      }
    }
    if (live.isEmpty) {
      return (entries: const <_AiEntry>[], page: _PageToken(null, const {}));
    }
    final deepest = live
        .map((item) => item.depth)
        .reduce((a, b) => a > b ? a : b);
    final sameNavigator = live.where((item) => item.depth == deepest);
    final topLayer = sameNavigator
        .map((item) => item.layer)
        .reduce((a, b) => a > b ? a : b);
    final top = sameNavigator.where((item) => item.layer == topLayer).toList()
      ..sort((a, b) {
        final dy = (a.position.dy / 8).floor().compareTo(
          (b.position.dy / 8).floor(),
        );
        if (dy != 0) return dy;
        final dx = a.position.dx.compareTo(b.position.dx);
        return dx != 0 ? dx : a.entry.order.compareTo(b.entry.order);
      });
    final entries = [for (final item in top) item.entry];
    return (
      entries: entries,
      page: _PageToken(top.first.layerNode, {
        for (final entry in entries)
          if (entry.source is AiPageInfoSource) entry,
      }),
    );
  }

  static int _navigatorDepth(Element element) {
    var depth = 0;
    NavigatorState? navigator = element
        .findAncestorStateOfType<NavigatorState>();
    while (navigator != null) {
      depth++;
      navigator = navigator.context.findAncestorStateOfType<NavigatorState>();
    }
    return depth;
  }

  /// Computes the snapshot of the top page. Called on send only.
  AiPageCapture capture(AppLocalizations l10n) {
    if (_closed) return AiPageCapture.empty;
    final ctx = AiCaptureContext(l10n);
    final top = _topEntries();
    final entries = top.entries;
    if (entries.isEmpty) return AiPageCapture.empty;
    final draft = AiSnapshotDraft();
    final badges = <(String, String?, String?), int?>{};
    // 1-based position in tables[] of each table that row actions refer to.
    final tableIndex = <Object, int>{};
    for (final entry in entries) {
      try {
        switch (entry.source) {
          case AiTableSource(:final capture, :final owner):
            if (draft.tables.length >= AiSnapshotLimits.tables) break;
            final table = capture(ctx);
            if (table != null &&
                (table.columns.isNotEmpty || table.rows.isNotEmpty)) {
              draft.tables.add(table);
              final key = owner?.call();
              if (key != null) tableIndex[key] = draft.tables.length;
            }
          case AiFieldSource(:final capture):
            if (draft.fields.length >= AiSnapshotLimits.fields) break;
            final field = capture(ctx);
            if (field != null) draft.fields.add(field);
          case AiBadgeSource(
            :final label,
            :final tone,
            :final color,
            :final count,
          ):
            // Same bounds as the server: an over-long, empty or identifier
            // label is skipped instead of making the whole snapshot invalid.
            final text = aiSnapshotLabel(label);
            if (text == null) break;
            final key = (
              text,
              aiSnapshotTones.contains(tone) ? tone : null,
              aiSnapshotLabel(color, 8),
            );
            badges[key] = (badges.containsKey(key) || count != null)
                ? (badges[key] ?? 0) + (count ?? 1)
                : 1;
          case AiNoticeSource(:final kind, :final title, :final text):
            final clean = aiSnapshotMultiline(text);
            if (clean != null && clean.isNotEmpty) {
              draft.notices.add(
                AiNoticeSnapshot(
                  kind: kind,
                  title: aiSnapshotValue(title),
                  text: clean,
                ),
              );
            }
          case AiPageInfoSource(:final title, :final notices):
            final pageTitle = aiSnapshotValue(title?.call(ctx));
            if (draft.title == null && pageTitle != null && pageTitle != '') {
              draft.title = pageTitle;
            }
            for (final notice
                in notices?.call(ctx) ?? const <AiNoticeSnapshot>[]) {
              draft.notices.add(notice);
            }
        }
      } catch (_) {
        // One broken provider must not block the question.
      }
    }
    for (final entry in badges.entries.take(AiSnapshotLimits.badges)) {
      draft.badges.add(
        AiBadgeSnapshot(
          label: entry.key.$1,
          tone: entry.key.$2,
          color: entry.key.$3,
          count: entry.value,
        ),
      );
    }
    final actions = _actions(entries, ctx);
    draft.actions.addAll([
      for (final action in actions.values)
        {
          ...action.toJson(),
          // The snapshot table the row parameters count, for the card text.
          'table': ?tableIndex[action.rowTable],
        },
    ]);
    // Record identities of the tables row actions count, as seen right now.
    final rows = <Object, List<Object>>{};
    for (final action in actions.values) {
      final key = action.rowTable;
      if (key == null || rows.containsKey(key)) continue;
      final table = _tableOf(entries, key);
      if (table != null) rows[key] = table._keys();
    }
    final binding = AiCaptureBinding._(top.page, rows);
    if (draft.isEmpty) {
      return AiPageCapture(
        snapshot: null,
        rows: 0,
        fields: 0,
        flagged: 0,
        actions: actions,
        binding: binding,
      );
    }
    final json = draft.toJson();
    return AiPageCapture(
      snapshot: json,
      rows: draft.attachedRows,
      fields: draft.attachedFields,
      flagged: draft.attachedFlagged,
      actions: actions,
      binding: binding,
    );
  }

  /// Current action set of the top page, recomputed at execution time so a
  /// confirmed card always runs against what is on screen now.
  Map<String, AiPageAction> actions(AppLocalizations l10n) {
    if (_closed) return const {};
    return _actions(_topEntries().entries, AiCaptureContext(l10n));
  }

  /// Runs the page action [name] of a confirmed card, fail-closed: the same
  /// page instance must still be on top, the arguments must fit the current
  /// declaration, and every row parameter must still name the record it named
  /// when the question was sent (no rows deleted, inserted, sorted or
  /// filtered in between). The handler receives those records.
  Future<String?> run(
    AppLocalizations l10n,
    AiCaptureBinding binding,
    String name,
    Map<String, Object?> rawArgs,
  ) async {
    if (_closed || binding.isNone) {
      throw AiActionFailure(l10n.aiChatCardPageChanged);
    }
    final top = _topEntries();
    if (top.page != binding._page) {
      throw AiActionFailure(l10n.aiChatCardPageChanged);
    }
    final action = _actions(top.entries, AiCaptureContext(l10n))[name];
    if (action == null) throw AiActionFailure(l10n.aiChatCardHandlerMissing);
    final args = action.checkedArgs(rawArgs);
    final bound = <String, List<Object>>{};
    for (final param in action.params.where((param) => param.rowRef)) {
      final raw = args[param.name];
      if (raw == null) continue;
      if (raw is String && (raw.trim().isEmpty || raw.trim() == '0')) {
        bound[param.name] = const [];
        continue;
      }
      final then = binding._rows[action.rowTable];
      final table = action.rowTable == null
          ? null
          : _tableOf(top.entries, action.rowTable!);
      if (then == null || table == null) {
        throw AiActionFailure(l10n.aiChatCardPageChanged);
      }
      final numbers = raw is int
          ? [raw]
          : [
              for (final index
                  in aiParseRowList(raw as String, then.length) ??
                      (throw AiActionFailure(l10n.aiActionRowsInvalid)))
                index + 1,
            ];
      final records = table.records?.call() ?? const <Object>[];
      final picked = <Object>[];
      for (final no in numbers) {
        if (no < 1 || no > then.length) {
          throw AiActionFailure(l10n.aiActionRowMissing(no));
        }
        if (no > records.length ||
            (table.recordKey?.call(records[no - 1]) ?? records[no - 1]) !=
                then[no - 1]) {
          throw AiActionFailure(l10n.aiActionRowChanged(no));
        }
        picked.add(records[no - 1]);
      }
      bound[param.name] = picked;
    }
    return action.handler(AiActionCall(args, bound));
  }

  AiTableSource? _tableOf(List<_AiEntry> entries, Object owner) {
    for (final entry in entries) {
      final source = entry.source;
      if (source is AiTableSource && source.owner?.call() == owner) {
        return source;
      }
    }
    return null;
  }

  Map<String, AiPageAction> _actions(
    List<_AiEntry> entries,
    AiCaptureContext ctx,
  ) {
    final result = <String, AiPageAction>{};
    void add(AiPageAction action) {
      if (result.length >= AiSnapshotLimits.actions ||
          !action.valid ||
          result.containsKey(action.name)) {
        return;
      }
      result[action.name] = action;
    }

    for (final entry in entries) {
      final source = entry.source;
      if (source is AiPageInfoSource) {
        try {
          for (final action
              in source.actions?.call(ctx) ?? const <AiPageAction>[]) {
            add(action);
          }
        } catch (_) {}
      }
    }
    final setters = <String, AiFieldSource>{};
    for (final entry in entries) {
      final source = entry.source;
      if (source is! AiFieldSource || source.setValue == null) continue;
      try {
        final field = source.capture(ctx);
        if (field == null ||
            field.sensitive ||
            aiIsSensitiveLabel(field.label)) {
          continue;
        }
        setters.putIfAbsent(field.label, () => source);
      } catch (_) {}
    }
    if (setters.isNotEmpty) {
      add(
        AiPageAction(
          name: 'setField',
          title: ctx.l10n.aiActionSetField,
          kind: AiActionKind.form,
          params: [
            AiActionParam(
              'field',
              type: AiParamType.string,
              title: ctx.l10n.aiActionParamField,
              maxLength: AiSnapshotLimits.label,
              options: setters.keys.take(60).toList(),
            ),
            AiActionParam(
              'value',
              type: AiParamType.string,
              title: ctx.l10n.aiActionParamValue,
              maxLength: AiSnapshotLimits.value,
            ),
          ],
          handler: (call) async {
            final label = call.args['field']! as String;
            final source = setters[label];
            if (source == null) {
              throw AiActionFailure(ctx.l10n.aiActionFieldMissing(label));
            }
            await source.setValue!(call.args['value']! as String, ctx);
            return null;
          },
        ),
      );
    }
    var tableIndex = 0;
    for (final entry in entries) {
      final source = entry.source;
      if (source is! AiTableSource || source.actions == null) continue;
      tableIndex++;
      try {
        final scope = AiTableActionScope(
          suffix: tableIndex == 1 ? '' : '$tableIndex',
          index: tableIndex,
        );
        for (final action in source.actions!(ctx, scope)) {
          add(action);
        }
      } catch (_) {}
    }
    return result;
  }

  void dispose() {
    _closed = true;
    _entries.clear();
  }
}

/// App-level scope (PlatformTablesHost). Lookups never create a dependency.
class AiPageContextScope extends InheritedWidget {
  const AiPageContextScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final AiPageContextController controller;

  static AiPageContextController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AiPageContextScope>()?.controller;

  @override
  bool updateShouldNotify(AiPageContextScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// Registration handle for a State: `attach` in didChangeDependencies (and
/// didUpdateWidget when the source changes), `detach` in dispose.
class AiPageSlot {
  AiPageContextController? _controller;

  void attach(BuildContext context, AiPageSource? source) {
    final controller = AiPageContextScope.maybeOf(context);
    if (!identical(controller, _controller)) {
      _controller?.unregister(this);
      _controller = controller;
    }
    if (source == null) {
      controller?.unregister(this);
    } else {
      controller?.register(this, context, source);
    }
  }

  void detach() {
    _controller?.unregister(this);
    _controller = null;
  }
}

/// Registers [source] while [child] is mounted (badges, notices, pages).
class AiPageRegistrar extends StatefulWidget {
  const AiPageRegistrar({super.key, required this.source, required this.child});
  final AiPageSource source;
  final Widget child;

  @override
  State<AiPageRegistrar> createState() => _AiPageRegistrarState();
}

class _AiPageRegistrarState extends State<AiPageRegistrar> {
  final _slot = AiPageSlot();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _slot.attach(context, widget.source);
  }

  @override
  void didUpdateWidget(covariant AiPageRegistrar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _slot.attach(context, widget.source);
    }
  }

  @override
  void dispose() {
    _slot.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Parses "1,3,5-8" (1-based screen rows) into indexes; null when malformed.
List<int>? aiParseRowList(String raw, int rowCount) {
  final result = <int>{};
  for (final part in raw.split(RegExp(r'[,，、\s]+'))) {
    if (part.isEmpty) continue;
    final range = RegExp(r'^(\d{1,6})(?:-(\d{1,6}))?$').firstMatch(part);
    if (range == null) return null;
    final from = int.parse(range.group(1)!);
    final to = int.parse(range.group(2) ?? range.group(1)!);
    if (from < 1 || to < from || to > rowCount || to - from > 500) return null;
    for (var i = from; i <= to; i++) {
      result.add(i - 1);
    }
  }
  return result.isEmpty ? null : (result.toList()..sort());
}

/// One fact a mounted table cell reports about itself (yellow review, error,
/// required-empty). The reason is the text the cell already shows the user.
class AiCellFact {
  const AiCellFact(this.state, [this.reason]);
  final AiCellState state;
  final String? reason;
}

/// Which table cell a [UtenTableCellHints] belongs to.
class AiCellIdentity {
  const AiCellIdentity({
    required this.registry,
    required this.row,
    required this.column,
  });
  final AiCellRegistry registry;
  final Object row;
  final String column;

  @override
  bool operator ==(Object other) =>
      other is AiCellIdentity &&
      identical(other.registry, registry) &&
      identical(other.row, row) &&
      other.column == column;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(registry), identityHashCode(row), column);
}

/// Per-table registry of mounted cells. Adding/removing is a map write; the
/// facts are read only during a capture.
class AiCellRegistry {
  final _cells = <Object, (AiCellIdentity, List<AiCellFact> Function())>{};

  void add(
    Object owner,
    AiCellIdentity identity,
    List<AiCellFact> Function() facts,
  ) => _cells[owner] = (identity, facts);

  void remove(Object owner) => _cells.remove(owner);

  /// Current facts of every mounted cell, grouped by row identity.
  Iterable<(Object row, String column, AiCellFact fact)> facts() sync* {
    for (final (identity, read) in _cells.values.toList(growable: false)) {
      List<AiCellFact> facts;
      try {
        facts = read();
      } catch (_) {
        continue;
      }
      for (final fact in facts) {
        yield (identity.row, identity.column, fact);
      }
    }
  }
}

/// Gives table cells the owning table's [AiCellRegistry] without creating a
/// rebuild dependency.
class AiCellRegistryScope extends InheritedWidget {
  const AiCellRegistryScope({
    super.key,
    required this.registry,
    required super.child,
  });
  final AiCellRegistry registry;

  static AiCellRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AiCellRegistryScope>()?.registry;

  @override
  bool updateShouldNotify(AiCellRegistryScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}
