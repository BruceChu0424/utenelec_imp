import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/uten_tokens.dart';
import 'attachment_media_source.dart';

typedef AttachmentMediaSourceLoader =
    Future<AttachmentMediaSource> Function(Uint8List bytes, String contentType);

/// Shared bounded-file playback. The enclosing SensitiveContentBoundary removes
/// this widget on an identity/permission change, stopping sound and releasing bytes.
class AttachmentMediaPreview extends StatefulWidget {
  const AttachmentMediaPreview({
    super.key,
    required this.bytes,
    required this.contentType,
    this.audioOnly = false,
    this.sourceLoader,
  });

  final Uint8List bytes;
  final String contentType;
  final bool audioOnly;
  @visibleForTesting
  final AttachmentMediaSourceLoader? sourceLoader;

  @override
  State<AttachmentMediaPreview> createState() => _AttachmentMediaPreviewState();
}

class _AttachmentMediaPreviewState extends State<AttachmentMediaPreview> {
  AttachmentMediaSource? _source;
  String? _error;
  bool _ready = false;
  bool _retired = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    AttachmentMediaSource? source;
    try {
      source = await (widget.sourceLoader ?? createAttachmentMediaSource)(
        widget.bytes,
        widget.contentType,
      );
      if (_retired) {
        await source.dispose();
        return;
      }
      _source = source;
      source.controller.addListener(_onChanged);
      await source.controller.initialize().timeout(const Duration(seconds: 20));
      if (_retired) return;
      // Explicit play only: no autoplay or background playback.
      setState(() => _ready = true);
    } catch (_) {
      if (!_retired) {
        setState(() => _error = '当前设备无法播放此文件');
        _source = null;
        source?.controller.removeListener(_onChanged);
        if (source != null) unawaited(_release(source));
      }
    }
  }

  void _onChanged() {
    if (_retired) return;
    if (_source?.controller.value.hasError ?? false) {
      setState(() => _error = '当前设备无法播放此文件');
      final source = _source!;
      _source = null;
      source.controller.removeListener(_onChanged);
      unawaited(_release(source));
    }
  }

  // Cleanup failure must not surface private paths or escape an unmounted dialog.
  Future<void> _release(AttachmentMediaSource source) async {
    try {
      await source.dispose();
    } catch (_) {
      /* OS may finish releasing later. */
    }
  }

  @override
  void dispose() {
    _retired = true;
    final source = _source;
    _source = null;
    source?.controller.removeListener(_onChanged);
    if (source != null) unawaited(_release(source));
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!_retired) {
        setState(() => _error = '播放失败，请下载原件查看');
        final source = _source;
        _source = null;
        source?.controller.removeListener(_onChanged);
        if (source != null) unawaited(_release(source));
      }
    }
  }

  String _time(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _source?.controller;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_disabled_outlined,
                size: 44,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: UtenSpacing.s8),
              const Text('可用「下载原件」保存后用本机应用打开', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (!_ready || controller == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => Column(
        children: [
          Expanded(
            child: widget.audioOnly
                ? Center(
                    child: Icon(
                      Icons.audio_file_outlined,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: value.aspectRatio > 0
                            ? value.aspectRatio
                            : 16 / 9,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final progress = VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: VideoProgressColors(
                    playedColor: theme.colorScheme.primary,
                    bufferedColor: theme.colorScheme.outlineVariant,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                );
                final controls = Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying ? '暂停' : '播放',
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      onPressed: () => _act(
                        value.isPlaying ? controller.pause : controller.play,
                      ),
                    ),
                    IconButton(
                      tooltip: value.volume > 0 ? '静音' : '取消静音',
                      icon: Icon(
                        value.volume > 0
                            ? Icons.volume_up_outlined
                            : Icons.volume_off_outlined,
                      ),
                      onPressed: () => _act(
                        () => controller.setVolume(value.volume > 0 ? 0 : 1),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${_time(value.position)} / ${_time(value.duration)}',
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [progress, controls],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
