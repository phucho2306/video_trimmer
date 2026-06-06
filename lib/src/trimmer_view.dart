import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_trimmer/src/trim_viewer/trim_area_properties.dart';
import 'package:video_trimmer/src/trim_viewer/trim_editor_properties.dart';
import 'package:video_trimmer/src/trim_viewer/trim_viewer.dart';
import 'package:video_trimmer/src/trimmer.dart';
import 'package:video_trimmer/src/utils/duration_style.dart';
import 'package:video_trimmer/src/video_viewer.dart';

enum _SaveType { device, server }

typedef DeviceTrimSavedCallback = void Function(
  BuildContext context,
  String? outputPath,
);
typedef ServerTrimRequestCallback = void Function(
  String sourcePath,
  double startValue,
  double endValue,
);

class VideoEditorController {
  const VideoEditorController({
    this.onDeviceTrimSaved,
    this.onServerTrimRequest,
  });

  final DeviceTrimSavedCallback? onDeviceTrimSaved;
  final ServerTrimRequestCallback? onServerTrimRequest;

  Future<T?> start<T>(
    BuildContext context,
    File file, {
    RouteSettings? routeSettings,
    bool rootNavigator = false,
  }) {
    return Navigator.of(context, rootNavigator: rootNavigator).push<T>(
      MaterialPageRoute(
        settings: routeSettings,
        builder: (_) => TrimmerView(file, controller: this),
      ),
    );
  }

  void handleDeviceTrimSaved(BuildContext context, String? outputPath) {
    onDeviceTrimSaved?.call(context, outputPath);
  }

  void handleServerTrimRequest(
    String sourcePath,
    double startValue,
    double endValue,
  ) {
    onServerTrimRequest?.call(sourcePath, startValue, endValue);
  }
}

typedef TrimmerViewController = VideoEditorController;

class TrimmerView extends StatefulWidget {
  final File file;
  final VideoEditorController? controller;
  final DeviceTrimSavedCallback? onDeviceTrimSaved;
  final ServerTrimRequestCallback? onServerTrimRequest;

  const TrimmerView(
    this.file, {
    super.key,
    this.controller,
    this.onDeviceTrimSaved,
    this.onServerTrimRequest,
  });

  @override
  State<TrimmerView> createState() => _TrimmerViewState();
}

class _TrimmerViewState extends State<TrimmerView> {
  static const double _minTimelineScale = 1.0;
  static const double _maxTimelineScale = 1.5;

  final Trimmer _trimmer = Trimmer();

  double _startValue = 0.0;
  double _endValue = 0.0;

  bool _isPlaying = false;
  bool _progressVisibility = false;
  double _timelineScale = 1.0;

  @override
  void initState() {
    super.initState();
    _trimmer.loadVideo(videoFile: widget.file);
  }

  Future<void> _saveVideo() async {
    final saveType = await showDialog<_SaveType>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Lưu video'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Chọn cách cắt video.'),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_SaveType.device),
                  child: const Text('Cắt bằng thiết bị'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(_SaveType.server),
                  child: const Text('Cắt bằng server'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Hủy'),
            ),
          ],
        );
      },
    );
    if (saveType == null) return;

    switch (saveType) {
      case _SaveType.device:
        _saveVideoOnDevice();
      case _SaveType.server:
        _requestServerTrim();
    }
  }

  void _saveVideoOnDevice() {
    setState(() {
      _progressVisibility = true;
    });

    _trimmer.saveTrimmedVideo(
      startValue: _startValue,
      endValue: _endValue,
      onSave: (outputPath) {
        if (!mounted) return;
        setState(() => _progressVisibility = false);
        debugPrint('OUTPUT PATH: $outputPath');
        widget.onDeviceTrimSaved?.call(context, outputPath);
        widget.controller?.handleDeviceTrimSaved(context, outputPath);
      },
    );
  }

  void _requestServerTrim() {
    final sourcePath = widget.file.path;
    widget.onServerTrimRequest?.call(sourcePath, _startValue, _endValue);
    widget.controller?.handleServerTrimRequest(
      sourcePath,
      _startValue,
      _endValue,
    );
    debugPrint(
      'SERVER TRIM REQUEST: path=$sourcePath, '
      'start=$_startValue, end=$_endValue',
    );
  }

  Future<void> _togglePlayback() async {
    final playbackState = await _trimmer.videoPlaybackControl(
      startValue: _startValue,
      endValue: _endValue,
    );
    setState(() => _isPlaying = playbackState);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !Navigator.of(context).userGestureInProgress,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('Video Trimmer'),
          actions: [
            TextButton(
              onPressed: _progressVisibility ? null : () => _saveVideo(),
              child: const Text('SAVE'),
            ),
          ],
        ),
        body: Center(
          child: Container(
            padding: const EdgeInsets.only(bottom: 30),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: <Widget>[
                Visibility(
                  visible: _progressVisibility,
                  child: const LinearProgressIndicator(
                    backgroundColor: Colors.red,
                  ),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoViewer(trimmer: _trimmer),
                      Material(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: const CircleBorder(),
                        child: IconButton(
                          iconSize: 56,
                          padding: const EdgeInsets.all(18),
                          color: Colors.white,
                          icon: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                          onPressed: _togglePlayback,
                        ),
                      ),
                    ],
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Container(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF121721),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: const Color(0xFF242D3D),
                                ),
                              ),
                              child: TrimViewer(
                                trimmer: _trimmer,
                                viewerHeight: 64,
                                viewerWidth: (constraints.maxWidth - 24).clamp(240, 900),
                                durationStyle: DurationStyle.FORMAT_MM_SS,
                                maxVideoLength: const Duration(seconds: 5),
                                timelineScale: _timelineScale,
                                minTimelineScale: _minTimelineScale,
                                maxTimelineScale: _maxTimelineScale,
                                onChangeTimelineScale: (value) {
                                  setState(() => _timelineScale = value);
                                },
                                editorProperties: TrimEditorProperties(
                                  borderPaintColor: const Color(0xFFFFB703),
                                  borderWidth: 3,
                                  borderRadius: 14,
                                  circlePaintColor: const Color(0xFFFFB703),
                                ),
                                areaProperties: TrimAreaProperties.edgeBlur(
                                  thumbnailQuality: 50,
                                  blurColor: const Color(0xCC0F141C),
                                  borderRadius: 14,
                                ),
                                onChangeStart: (value) => _startValue = value,
                                onChangeEnd: (value) => _endValue = value,
                                onChangePlaybackState: (value) => setState(() => _isPlaying = value),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
