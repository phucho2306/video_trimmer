import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';
import 'package:video_trimmer/src/trim_viewer/trim_area_properties.dart';
import 'package:video_trimmer/src/trim_viewer/trim_editor_properties.dart';
import 'package:video_trimmer/src/trimmer.dart';
import 'package:video_trimmer/src/utils/duration_style.dart';
import 'package:video_trimmer/src/utils/trimmer_utils.dart';

import 'scrollable_thumbnail_viewer.dart';

enum _TrimInteractionMode {
  idle,
  hoverTrimStart,
  hoverMove,
  hoverTrimEnd,
  dragTrimStart,
  dragMove,
  dragTrimEnd,
}

enum _TrimHitZone {
  startHandle,
  body,
  endHandle,
}

/// Widget for displaying the video trimmer.
class ScrollableTrimViewer extends StatefulWidget {
  /// The Trimmer instance controlling the data.
  final Trimmer trimmer;

  /// For defining the total trimmer area width
  final double viewerWidth;

  /// For defining the total trimmer area height
  final double viewerHeight;

  /// For defining the maximum length of the output video.
  final Duration maxVideoLength;

  /// For showing the start and the end point of the
  /// video on top of the trimmer area.
  final bool showDuration;

  /// For providing a [TextStyle] to the duration text.
  final TextStyle durationTextStyle;

  /// For specifying a style of the duration.
  final DurationStyle durationStyle;

  /// Callback to the video start position in milliseconds.
  final Function(double startValue)? onChangeStart;

  /// Callback to the video end position in milliseconds.
  final Function(double endValue)? onChangeEnd;

  /// Callback to the video playback state.
  final Function(bool isPlaying)? onChangePlaybackState;

  /// This is the fraction of padding present beside the trimmer editor,
  /// calculated on the [maxVideoLength] value.
  final double paddingFraction;

  /// Scales the scrollable timeline width.
  final double timelineScale;

  /// Smallest allowed timeline scale.
  final double minTimelineScale;

  /// Largest allowed timeline scale.
  final double maxTimelineScale;

  /// Callback to the current timeline scale.
  final ValueChanged<double>? onChangeTimelineScale;

  /// Properties for customizing the trim editor.
  final TrimEditorProperties editorProperties;

  /// Properties for customizing the trim area.
  final TrimAreaProperties areaProperties;

  final VoidCallback onThumbnailLoadingComplete;

  /// This has frame wise preview of the video with a draggable trim clip.
  const ScrollableTrimViewer({
    super.key,
    required this.trimmer,
    required this.maxVideoLength,
    required this.onThumbnailLoadingComplete,
    this.viewerWidth = 50 * 8,
    this.viewerHeight = 50,
    this.showDuration = true,
    this.durationTextStyle = const TextStyle(color: Colors.white),
    this.durationStyle = DurationStyle.FORMAT_HH_MM_SS,
    this.onChangeStart,
    this.onChangeEnd,
    this.onChangePlaybackState,
    this.paddingFraction = 0.2,
    this.timelineScale = 1.0,
    this.minTimelineScale = 1.0,
    this.maxTimelineScale = 1.5,
    this.onChangeTimelineScale,
    this.editorProperties = const TrimEditorProperties(),
    this.areaProperties = const TrimAreaProperties(),
  })  : assert(minTimelineScale > 0),
        assert(maxTimelineScale >= minTimelineScale);

  @override
  State<ScrollableTrimViewer> createState() => _ScrollableTrimViewerState();
}

class _ScrollableTrimViewerState extends State<ScrollableTrimViewer> {
  static const double _desktopHandleHitWidth = 18.0;
  static const double _touchHandleHitWidth = 28.0;

  final _trimmerAreaKey = GlobalKey();
  late final ScrollController _scrollController;

  File? get _videoFile => widget.trimmer.currentVideoFile;

  VideoPlayerController get videoPlayerController => widget.trimmer.videoPlayerController!;

  int _videoDuration = 0;
  int _currentPosition = 0;

  double _viewportWidth = 0.0;
  double _contentWidth = 0.0;
  double _thumbnailWidth = 0.0;
  int _numberOfThumbnails = 0;
  ThumbnailDensityLevel _thumbnailDensityLevel = ThumbnailDensityLevel.low;

  double _videoStartPos = 0.0;
  double _videoEndPos = 0.0;

  late double _timelineScale;
  double _pinchStartTimelineScale = 1.0;
  double _pinchStartScroll = 0.0;
  double _pinchFocusRatio = 0.0;
  double _pinchFocalViewportDx = 0.0;
  double _pinchStartDistance = 0.0;
  bool _isPinchZooming = false;
  final Map<int, Offset> _pointerPositions = <int, Offset>{};
  Timer? _longPressTimer;
  int? _longPressPointer;
  Offset? _longPressDownGlobalPosition;
  bool _longPressMoveActive = false;

  _TrimInteractionMode _interactionMode = _TrimInteractionMode.idle;
  bool _isSelectionActive = false;
  bool _ignoreGestureUntilNextTouch = false;
  double? _longPressMoveGlobalDx;

  bool get _touchRequiresSelection => switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
        TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => false,
      };

  bool get _isDragging =>
      _interactionMode == _TrimInteractionMode.dragTrimStart ||
      _interactionMode == _TrimInteractionMode.dragMove ||
      _interactionMode == _TrimInteractionMode.dragTrimEnd;

  bool get _isZoomGestureActive => _isPinchZooming || _pointerPositions.length >= 2;

  double get _pixelsPerMillisecond {
    if (_videoDuration <= 0 || _contentWidth <= 0) return 0.0;
    return _contentWidth / _videoDuration;
  }

  double get _selectedDuration => math.max(1.0, _videoEndPos - _videoStartPos);

  double get _trimClipHeight => math.max(
        1.0,
        widget.viewerHeight - widget.editorProperties.borderWidth,
      );

  double _calculateThumbnailWidth() {
    final videoAspectRatio = videoPlayerController.value.aspectRatio;
    final safeAspectRatio = videoAspectRatio.isFinite && videoAspectRatio > 0 ? videoAspectRatio : 1.0;
    return math.max(1.0, widget.viewerHeight * safeAspectRatio);
  }

  bool get _hasScrollDimensions => _scrollController.hasClients && _scrollController.position.hasContentDimensions;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _timelineScale = _clampTimelineScale(widget.timelineScale);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = _trimmerAreaKey.currentContext?.findRenderObject() as RenderBox?;
      _viewportWidth = renderBox?.size.width ?? widget.viewerWidth;
      _initializeVideoController();
      _configureTimeline(preserveSelection: false);
      videoPlayerController.seekTo(const Duration(milliseconds: 0));
    });
  }

  @override
  void didUpdateWidget(covariant ScrollableTrimViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextScale = _clampTimelineScale(widget.timelineScale);
    if (nextScale == _timelineScale &&
        oldWidget.viewerWidth == widget.viewerWidth &&
        oldWidget.viewerHeight == widget.viewerHeight &&
        oldWidget.maxVideoLength == widget.maxVideoLength) {
      return;
    }
    _timelineScale = nextScale;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = _trimmerAreaKey.currentContext?.findRenderObject() as RenderBox?;
      _viewportWidth = renderBox?.size.width ?? widget.viewerWidth;
      if (oldWidget.viewerHeight != widget.viewerHeight) {
        _thumbnailWidth = _calculateThumbnailWidth();
        _numberOfThumbnails = 0;
      }
      _configureTimeline(refreshThumbnails: true);
    });
  }

  void _initializeVideoController() {
    if (_videoFile == null) return;
    _videoDuration = videoPlayerController.value.duration.inMilliseconds;
    _thumbnailWidth = _calculateThumbnailWidth();
    videoPlayerController.addListener(_videoPlayerListener);
    videoPlayerController.setVolume(1.0);
  }

  void _handleThumbnailWidthResolved(double width) {
    final nextWidth = math.max(1.0, width);
    if ((nextWidth - _thumbnailWidth).abs() < 0.5) return;
    _thumbnailWidth = nextWidth;
    _numberOfThumbnails = 0;
    _configureTimeline(refreshThumbnails: true);
  }

  void _videoPlayerListener() {
    if (!mounted || !videoPlayerController.value.isInitialized) return;
    final isPlaying = videoPlayerController.value.isPlaying;
    final position = videoPlayerController.value.position.inMilliseconds;

    if (isPlaying && position > _videoEndPos.toInt()) {
      videoPlayerController.pause();
      widget.onChangePlaybackState?.call(false);
      videoPlayerController.seekTo(
        Duration(milliseconds: _videoStartPos.toInt()),
      );
      return;
    }

    setState(() => _currentPosition = position);
    widget.onChangePlaybackState?.call(isPlaying);
  }

  void _configureTimeline({
    bool preserveSelection = true,
    bool refreshThumbnails = false,
  }) {
    if (_viewportWidth <= 0 || _videoDuration <= 0) return;

    final previousStart = _videoStartPos;
    final previousEnd = _videoEndPos;
    final defaultSelectionDuration = widget.maxVideoLength.inMilliseconds > 0
        ? math.min(widget.maxVideoLength.inMilliseconds, _videoDuration)
        : _videoDuration;

    final nextDensityLevel = _targetDensityLevel();
    final shouldRefreshThumbnails =
        _numberOfThumbnails == 0 || (refreshThumbnails && nextDensityLevel != _thumbnailDensityLevel);
    final nextThumbnailCount = shouldRefreshThumbnails ? _targetThumbnailCount(nextDensityLevel) : _numberOfThumbnails;
    final nextContentWidth = nextThumbnailCount * _thumbnailWidth;

    setState(() {
      _contentWidth = nextContentWidth;
      _numberOfThumbnails = nextThumbnailCount;
      _thumbnailDensityLevel = nextDensityLevel;

      if (preserveSelection && previousEnd > previousStart) {
        _videoStartPos = previousStart.clamp(0.0, _videoDuration.toDouble()).toDouble();
        _videoEndPos = previousEnd.clamp(_videoStartPos + 1, _videoDuration.toDouble()).toDouble();
      } else {
        _videoStartPos = 0.0;
        _videoEndPos = defaultSelectionDuration.toDouble();
      }
    });

    _notifyTrimChanged();
    _syncScrollAfterLayout();
  }

  ThumbnailDensityLevel _targetDensityLevel() {
    final zoomRange = widget.maxTimelineScale - widget.minTimelineScale;
    final zoomProgress =
        zoomRange <= 0 ? 0.0 : ((_timelineScale - widget.minTimelineScale) / zoomRange).clamp(0.0, 1.0).toDouble();

    if (zoomProgress < 0.25) return ThumbnailDensityLevel.low;
    if (zoomProgress < 0.5) return ThumbnailDensityLevel.medium;
    if (zoomProgress < 0.75) return ThumbnailDensityLevel.high;
    return ThumbnailDensityLevel.max;
  }

  int _targetThumbnailCount(ThumbnailDensityLevel level) {
    final durationSeconds = math.max(1.0, _videoDuration / 1000);
    final minFramesToFillViewport = math.max(
      1,
      ((_viewportWidth * 2) / _thumbnailWidth).ceil(),
    );
    final zoomFrames = math.max(
      minFramesToFillViewport,
      (minFramesToFillViewport * _timelineScale).ceil(),
    );
    final thumbnailsPerSecond = switch (level) {
      ThumbnailDensityLevel.low => 0.25,
      ThumbnailDensityLevel.medium => 0.5,
      ThumbnailDensityLevel.high => 1.0,
      ThumbnailDensityLevel.max => durationSeconds <= 30 ? 2.0 : 1.0,
    };

    return math.min(
      80,
      math.max(
        zoomFrames,
        (durationSeconds * thumbnailsPerSecond).ceil(),
      ),
    );
  }

  void _syncScrollAfterLayout() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasScrollDimensions) return;
      final maxScrollExtent = _scrollController.position.maxScrollExtent;
      final selectionLeft = _videoStartPos * _pixelsPerMillisecond;
      final selectionRight = _videoEndPos * _pixelsPerMillisecond;
      final current = _scrollController.offset;
      var target = current;

      if (selectionLeft < current) {
        target = selectionLeft;
      } else if (selectionRight > current + _viewportWidth) {
        target = selectionRight - _viewportWidth;
      }

      _scrollController.jumpTo(
        target.clamp(0.0, maxScrollExtent).toDouble(),
      );
    });
  }

  double _clampTimelineScale(double value) {
    return value.clamp(widget.minTimelineScale, widget.maxTimelineScale).toDouble();
  }

  void _applyTimelineScale(double value, {double? focalViewportDx}) {
    final nextScale = _clampTimelineScale(value);
    if ((nextScale - _timelineScale).abs() < 0.01) return;

    _pinchFocalViewportDx = focalViewportDx ?? _pinchFocalViewportDx;
    setState(() => _timelineScale = nextScale);
    widget.onChangeTimelineScale?.call(_timelineScale);
    videoPlayerController.pause();
    widget.onChangePlaybackState?.call(false);
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length == 2) {
      _cancelPendingLongPress();
      _cancelTrimInteractionForZoom();
      _beginPointerPinch();
    } else if (_pointerPositions.length == 1) {
      _scheduleLongPress(event);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerPositions.containsKey(event.pointer)) return;
    _pointerPositions[event.pointer] = event.localPosition;
    if (_isZoomGestureActive && _longPressMoveActive) {
      _cancelTrimInteractionForZoom();
    }
    if (_longPressMoveActive && event.pointer == _longPressPointer) {
      final previousDx = _longPressMoveGlobalDx;
      _longPressMoveGlobalDx = event.position.dx;
      if (previousDx != null) {
        _handleDragUpdate(
          _TrimHitZone.body,
          event.position.dx - previousDx,
        );
      }
      return;
    }
    final downPosition = _longPressDownGlobalPosition;
    if (event.pointer == _longPressPointer && downPosition != null && (event.position - downPosition).distance > 6) {
      _cancelPendingLongPress();
    }
    if (_pointerPositions.length < 2) return;
    if (!_isPinchZooming) _beginPointerPinch();
    if (_pinchStartDistance <= 0) return;

    final points = _pointerPositions.values.take(2).toList();
    final distance = (points[0] - points[1]).distance;
    final focalPoint = Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
    _applyTimelineScale(
      _pinchStartTimelineScale * (distance / _pinchStartDistance),
      focalViewportDx: focalPoint.dx,
    );
  }

  void _onPointerUp(PointerEvent event) {
    if (event.pointer == _longPressPointer) {
      if (_longPressMoveActive) {
        _endMoveFromLongPress();
      }
      _cancelPendingLongPress();
    }
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length < 2) {
      _endPointerPinch();
    }
  }

  void _scheduleLongPress(PointerDownEvent event) {
    if (_isZoomGestureActive) return;
    final renderBox = _trimmerAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final timelinePosition = renderBox.globalToLocal(event.position);
    if (timelinePosition.dx < 0 ||
        timelinePosition.dx > renderBox.size.width ||
        timelinePosition.dy < 0 ||
        timelinePosition.dy > renderBox.size.height) {
      return;
    }

    _cancelPendingLongPress();
    _longPressPointer = event.pointer;
    _longPressDownGlobalPosition = event.position;
    _longPressTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _pointerPositions.length != 1 || _longPressPointer != event.pointer || _isZoomGestureActive) {
        return;
      }
      final contentDx = timelinePosition.dx + (_hasScrollDimensions ? _scrollController.offset : 0.0);
      final selectionLeft = _videoStartPos * _pixelsPerMillisecond;
      final selectionRight = _videoEndPos * _pixelsPerMillisecond;
      final isInsideSelection = contentDx >= selectionLeft && contentDx <= selectionRight;

      if (!isInsideSelection) {
        final selectedDuration = _selectedDuration;
        final targetCenterMs = contentDx / _pixelsPerMillisecond;
        final maxStart = math.max(0.0, _videoDuration - selectedDuration);
        final nextStart = (targetCenterMs - selectedDuration / 2).clamp(0.0, maxStart).toDouble();
        setState(() {
          _videoStartPos = nextStart;
          _videoEndPos = nextStart + selectedDuration;
        });
        _notifyTrimChanged();
      }

      _longPressMoveGlobalDx = event.position.dx;
      _longPressMoveActive = true;
      videoPlayerController.pause();
      widget.onChangePlaybackState?.call(false);
      setState(() {
        _isSelectionActive = true;
        _interactionMode = _TrimInteractionMode.dragMove;
      });
    });
  }

  void _cancelPendingLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (!_longPressMoveActive) {
      _longPressPointer = null;
      _longPressDownGlobalPosition = null;
    }
  }

  void _beginPointerPinch() {
    final points = _pointerPositions.values.take(2).toList();
    if (points.length < 2) return;
    final focalPoint = Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );

    _pinchStartDistance = (points[0] - points[1]).distance;
    _pinchStartTimelineScale = _timelineScale;
    _pinchStartScroll = _hasScrollDimensions ? _scrollController.offset : 0.0;
    _pinchFocalViewportDx = focalPoint.dx;
    _pinchFocusRatio =
        _contentWidth <= 0 ? 0.0 : ((_pinchStartScroll + focalPoint.dx) / _contentWidth).clamp(0.0, 1.0).toDouble();
    videoPlayerController.pause();
    widget.onChangePlaybackState?.call(false);
    setState(() => _isPinchZooming = true);
  }

  void _endPointerPinch() {
    if (!_isPinchZooming) return;
    setState(() {
      _isPinchZooming = false;
      _pinchStartDistance = 0.0;
      _ignoreGestureUntilNextTouch = false;
      _interactionMode = _TrimInteractionMode.idle;
    });
    _configureTimeline(refreshThumbnails: true);
    _jumpToPinchFocusAfterLayout();
  }

  void _jumpToPinchFocusAfterLayout() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasScrollDimensions) return;
      final target = (_contentWidth * _pinchFocusRatio) - _pinchFocalViewportDx;
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent).toDouble(),
      );
    });
  }

  void _selectOnly() {
    if (_isZoomGestureActive) return;
    setState(() {
      _isSelectionActive = true;
      if (_interactionMode == _TrimInteractionMode.idle) {
        _interactionMode = _TrimInteractionMode.hoverMove;
      }
    });
  }

  void _beginDrag(_TrimInteractionMode dragMode) {
    if (_isZoomGestureActive) {
      _ignoreGestureUntilNextTouch = true;
      return;
    }
    final wasSelected = _isSelectionActive;
    setState(() => _isSelectionActive = true);

    if (_touchRequiresSelection && !wasSelected) {
      _ignoreGestureUntilNextTouch = true;
      return;
    }

    _ignoreGestureUntilNextTouch = false;
    videoPlayerController.pause();
    widget.onChangePlaybackState?.call(false);
    setState(() => _interactionMode = dragMode);
  }

  void _handleDragUpdate(_TrimHitZone zone, double deltaDx) {
    if (_isZoomGestureActive || _ignoreGestureUntilNextTouch || _pixelsPerMillisecond <= 0) {
      return;
    }
    final dragMode = switch (zone) {
      _TrimHitZone.startHandle => _TrimInteractionMode.dragTrimStart,
      _TrimHitZone.body => _TrimInteractionMode.dragMove,
      _TrimHitZone.endHandle => _TrimInteractionMode.dragTrimEnd,
    };
    if (_interactionMode != dragMode) {
      setState(() => _interactionMode = dragMode);
    }

    final deltaMs = deltaDx / _pixelsPerMillisecond;
    switch (zone) {
      case _TrimHitZone.startHandle:
        _trimStart(deltaMs);
      case _TrimHitZone.body:
        _moveSelection(deltaMs);
      case _TrimHitZone.endHandle:
        _trimEnd(deltaMs);
    }
  }

  void _endDrag() {
    if (_isZoomGestureActive) {
      _cancelTrimInteractionForZoom();
      return;
    }
    final seekTarget = switch (_interactionMode) {
      _TrimInteractionMode.dragTrimEnd => _videoEndPos,
      _ => _videoStartPos,
    };
    _ignoreGestureUntilNextTouch = false;
    videoPlayerController.seekTo(Duration(milliseconds: seekTarget.toInt()));
    if (!mounted) return;
    setState(() => _interactionMode = _TrimInteractionMode.idle);
  }

  void _cancelTrimInteractionForZoom() {
    _longPressMoveGlobalDx = null;
    _longPressMoveActive = false;
    _longPressPointer = null;
    _longPressDownGlobalPosition = null;
    _ignoreGestureUntilNextTouch = true;
    if (!mounted) return;
    setState(() => _interactionMode = _TrimInteractionMode.idle);
  }

  void _endMoveFromLongPress() {
    _longPressMoveGlobalDx = null;
    _longPressMoveActive = false;
    _longPressPointer = null;
    _longPressDownGlobalPosition = null;
    if (_interactionMode == _TrimInteractionMode.dragMove) {
      _endDrag();
    }
  }

  void _trimStart(double deltaMs) {
    final nextStart = (_videoStartPos + deltaMs).clamp(0.0, _videoEndPos - 1).toDouble();
    setState(() => _videoStartPos = nextStart);
    _notifyTrimChanged(startChanged: true);
  }

  void _trimEnd(double deltaMs) {
    final nextEnd = (_videoEndPos + deltaMs).clamp(_videoStartPos + 1, _videoDuration.toDouble()).toDouble();
    setState(() => _videoEndPos = nextEnd);
    _notifyTrimChanged(endChanged: true);
  }

  void _moveSelection(double deltaMs) {
    final selectedDuration = _selectedDuration;
    final maxStart = math.max(0.0, _videoDuration - selectedDuration);
    final nextStart = (_videoStartPos + deltaMs).clamp(0.0, maxStart).toDouble();
    setState(() {
      _videoStartPos = nextStart;
      _videoEndPos = nextStart + selectedDuration;
    });
    _notifyTrimChanged();
  }

  void _notifyTrimChanged({
    bool startChanged = true,
    bool endChanged = true,
  }) {
    if (startChanged) widget.onChangeStart?.call(_videoStartPos);
    if (endChanged) widget.onChangeEnd?.call(_videoEndPos);
  }

  void _setHoverMode(_TrimInteractionMode mode) {
    if (_isDragging || _interactionMode == mode) return;
    if (!mounted) return;
    setState(() => _interactionMode = mode);
  }

  void _clearHoverMode(_TrimInteractionMode mode) {
    if (_isDragging || _interactionMode != mode) return;
    if (!mounted) return;
    setState(() => _interactionMode = _TrimInteractionMode.idle);
  }

  Color _selectionColor() {
    return switch (_interactionMode) {
      _TrimInteractionMode.dragTrimStart || _TrimInteractionMode.dragTrimEnd => const Color(0xFFFFB703),
      _TrimInteractionMode.dragMove => const Color(0xFF93C5FD),
      _TrimInteractionMode.hoverTrimStart || _TrimInteractionMode.hoverTrimEnd => const Color(0xFFFFD166),
      _TrimInteractionMode.hoverMove => const Color(0xFFBFDBFE),
      _TrimInteractionMode.idle => _isSelectionActive ? const Color(0xFFFFB703) : Colors.transparent,
    };
  }

  String _interactionLabel(_TrimInteractionMode mode) {
    return switch (mode) {
      _TrimInteractionMode.hoverTrimStart || _TrimInteractionMode.dragTrimStart => 'Trim start',
      _TrimInteractionMode.hoverTrimEnd || _TrimInteractionMode.dragTrimEnd => 'Trim end',
      _TrimInteractionMode.hoverMove || _TrimInteractionMode.dragMove => 'Move',
      _TrimInteractionMode.idle => '',
    };
  }

  @override
  void dispose() {
    videoPlayerController.pause();
    videoPlayerController.removeListener(_videoPlayerListener);
    _longPressTimer?.cancel();
    _scrollController.dispose();
    widget.onChangePlaybackState?.call(false);
    if (_videoFile != null) {
      videoPlayerController.setVolume(0.0);
      videoPlayerController.dispose();
      widget.onChangePlaybackState?.call(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewportWidth = _viewportWidth == 0.0 ? widget.viewerWidth : math.min(widget.viewerWidth, _viewportWidth);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.showDuration)
            SizedBox(
              width: viewportWidth,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(
                      Duration(milliseconds: _videoStartPos.toInt()).format(widget.durationStyle),
                      style: widget.durationTextStyle,
                    ),
                    if (videoPlayerController.value.isPlaying)
                      Text(
                        Duration(milliseconds: _currentPosition).format(widget.durationStyle),
                        style: widget.durationTextStyle,
                      ),
                    Text(
                      Duration(milliseconds: _videoEndPos.toInt()).format(widget.durationStyle),
                      style: widget.durationTextStyle,
                    ),
                  ],
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(widget.areaProperties.borderRadius),
            child: Container(
              key: _trimmerAreaKey,
              width: widget.viewerWidth,
              height: widget.viewerHeight,
              decoration: BoxDecoration(
                color: const Color(0xFF0F141C),
                borderRadius: BorderRadius.circular(widget.areaProperties.borderRadius),
                border: Border.all(color: const Color(0xFF232B39)),
              ),
              child: Stack(
                children: [
                  SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    physics: _isPinchZooming || _longPressMoveActive ? const NeverScrollableScrollPhysics() : null,
                    clipBehavior: Clip.hardEdge,
                    child: _buildTimelineContent(),
                  ),
                  Positioned.fill(child: _buildEdgeFade()),
                  if (_isPinchZooming) _buildZoomOverlay(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineContent() {
    final contentWidth = _contentWidth <= 0 ? widget.viewerWidth : _contentWidth;
    final selectionLeft = _videoStartPos * _pixelsPerMillisecond;
    final selectionWidth = math.max(1.0, _selectedDuration * _pixelsPerMillisecond);
    final scrubberLeft =
        (_currentPosition * _pixelsPerMillisecond).clamp(0.0, math.max(0.0, contentWidth - 2)).toDouble();

    return SizedBox(
      width: contentWidth,
      height: widget.viewerHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _videoFile == null || _numberOfThumbnails == 0
                ? const ColoredBox(color: Color(0xFF0F141C))
                : ScrollableThumbnailViewer(
                    videoFile: _videoFile!,
                    videoDuration: _videoDuration,
                    fit: widget.areaProperties.thumbnailFit,
                    thumbnailHeight: widget.viewerHeight,
                    contentWidth: contentWidth,
                    thumbnailWidth: _thumbnailWidth,
                    numberOfThumbnails: _numberOfThumbnails,
                    densityLevel: _thumbnailDensityLevel,
                    quality: widget.areaProperties.thumbnailQuality,
                    onThumbnailWidthResolved: _handleThumbnailWidthResolved,
                    onThumbnailLoadingComplete: widget.onThumbnailLoadingComplete,
                  ),
          ),
          Positioned(
            left: selectionLeft.clamp(0.0, math.max(0.0, contentWidth - 1)),
            top: 0,
            width: math.min(selectionWidth, contentWidth - selectionLeft),
            height: _trimClipHeight,
            child: _buildTrimClip(selectionWidth),
          ),
          Positioned(
            left: scrubberLeft,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                width: widget.editorProperties.scrubberWidth,
                color: widget.editorProperties.scrubberPaintColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomOverlay() {
    return Center(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xEE0E131B),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFFFB703)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '${(_timelineScale * 100).round()}%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrimClip(double selectionWidth) {
    final selectionColor = _selectionColor();
    final handleHitWidth = _touchRequiresSelection ? _touchHandleHitWidth : _desktopHandleHitWidth;
    final visualHandleWidth = math
        .min(
          16.0,
          math.max(10.0, selectionWidth / (selectionWidth <= 72 ? 2.8 : 6)),
        )
        .toDouble();

    return MouseRegion(
      cursor: _interactionMode == _TrimInteractionMode.dragMove ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      onExit: (_) {
        if (!_isDragging) {
          setState(() => _interactionMode = _TrimInteractionMode.idle);
        }
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: const Color(0x552563EB),
                borderRadius: BorderRadius.circular(widget.editorProperties.borderRadius),
                border: Border.all(color: selectionColor, width: 2),
                boxShadow: _isDragging
                    ? const [
                        BoxShadow(
                          color: Color(0x33111418),
                          blurRadius: 14,
                          offset: Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
            ),
          ),
          Positioned.fill(
            child: Row(
              children: [
                _buildStartHandle(
                  visualHandleWidth: visualHandleWidth,
                  hitWidth: handleHitWidth,
                ),
                Expanded(child: _buildBodyZone()),
                _buildEndHandle(
                  visualHandleWidth: visualHandleWidth,
                  hitWidth: handleHitWidth,
                ),
              ],
            ),
          ),
          if (_interactionMode != _TrimInteractionMode.idle)
            Positioned(
              left: 10,
              top: -26,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xEE0E131B),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: selectionColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      _interactionLabel(_interactionMode),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStartHandle({
    required double visualHandleWidth,
    required double hitWidth,
  }) {
    final hovered = _interactionMode == _TrimInteractionMode.hoverTrimStart;
    final active = _interactionMode == _TrimInteractionMode.dragTrimStart;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => _setHoverMode(_TrimInteractionMode.hoverTrimStart),
      onHover: (_) => _setHoverMode(_TrimInteractionMode.hoverTrimStart),
      onExit: (_) => _clearHoverMode(_TrimInteractionMode.hoverTrimStart),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _selectOnly,
        onHorizontalDragStart: (_) => _beginDrag(_TrimInteractionMode.dragTrimStart),
        onHorizontalDragUpdate: (details) => _handleDragUpdate(_TrimHitZone.startHandle, details.delta.dx),
        onHorizontalDragEnd: (_) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        child: _TrimHandle(
          icon: Icons.keyboard_arrow_left_rounded,
          width: visualHandleWidth,
          hitWidth: hitWidth,
          active: active,
          hovered: hovered,
          cursor: SystemMouseCursors.resizeColumn,
        ),
      ),
    );
  }

  Widget _buildEndHandle({
    required double visualHandleWidth,
    required double hitWidth,
  }) {
    final hovered = _interactionMode == _TrimInteractionMode.hoverTrimEnd;
    final active = _interactionMode == _TrimInteractionMode.dragTrimEnd;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => _setHoverMode(_TrimInteractionMode.hoverTrimEnd),
      onHover: (_) => _setHoverMode(_TrimInteractionMode.hoverTrimEnd),
      onExit: (_) => _clearHoverMode(_TrimInteractionMode.hoverTrimEnd),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _selectOnly,
        onHorizontalDragStart: (_) => _beginDrag(_TrimInteractionMode.dragTrimEnd),
        onHorizontalDragUpdate: (details) => _handleDragUpdate(_TrimHitZone.endHandle, details.delta.dx),
        onHorizontalDragEnd: (_) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        child: _TrimHandle(
          icon: Icons.keyboard_arrow_right_rounded,
          width: visualHandleWidth,
          hitWidth: hitWidth,
          active: active,
          hovered: hovered,
          cursor: SystemMouseCursors.resizeColumn,
        ),
      ),
    );
  }

  Widget _buildBodyZone() {
    final hovered = _interactionMode == _TrimInteractionMode.hoverMove;
    final active = _interactionMode == _TrimInteractionMode.dragMove;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      onEnter: (_) => _setHoverMode(_TrimInteractionMode.hoverMove),
      onHover: (_) => _setHoverMode(_TrimInteractionMode.hoverMove),
      onExit: (_) => _clearHoverMode(_TrimInteractionMode.hoverMove),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _selectOnly,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: active
                ? Border.all(color: const Color(0xFFFFB703), width: 1.5)
                : hovered
                    ? Border.all(color: const Color(0x55FFFFFF))
                    : null,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildEdgeFade() {
    if (!widget.areaProperties.blurEdges) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _scrollController,
      builder: (context, child) {
        final hasDimensions = _hasScrollDimensions;
        final pixels = hasDimensions ? _scrollController.position.pixels : 0.0;
        final maxScroll = hasDimensions ? _scrollController.position.maxScrollExtent : 0.0;
        return IgnorePointer(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: const [0.0, 0.1, 0.9, 1.0],
                colors: [
                  pixels <= 0 ? Colors.transparent : widget.areaProperties.blurColor,
                  Colors.transparent,
                  Colors.transparent,
                  pixels >= maxScroll ? Colors.transparent : widget.areaProperties.blurColor,
                ],
              ),
            ),
            child: Row(
              children: [
                AnimatedOpacity(
                  opacity: pixels > 0 ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 120),
                  child: widget.areaProperties.startIcon,
                ),
                const Spacer(),
                AnimatedOpacity(
                  opacity: pixels < maxScroll ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 120),
                  child: widget.areaProperties.endIcon,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TrimHandle extends StatelessWidget {
  const _TrimHandle({
    required this.icon,
    this.width = 16,
    this.hitWidth = 16,
    this.active = false,
    this.hovered = false,
    this.cursor = SystemMouseCursors.resizeColumn,
  });

  final IconData icon;
  final double width;
  final double hitWidth;
  final bool active;
  final bool hovered;
  final MouseCursor cursor;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: SizedBox(
        width: hitWidth,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: width,
            decoration: BoxDecoration(
              color: active
                  ? const Color(0xFFFFB703)
                  : hovered
                      ? const Color(0xFF3C485E)
                      : const Color(0xFF2A3342),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(
              icon,
              size: 14,
              color: active ? const Color(0xFF141821) : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
