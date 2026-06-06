import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:video_trimmer/src/utils/trimmer_utils.dart';

/// For showing the thumbnails generated from the video in a scrollable view,
/// like a frame by frame preview.
class ScrollableThumbnailViewer extends StatefulWidget {
  /// Creates a [ScrollableThumbnailViewer] widget.
  ///
  /// - [videoFile] is the video file from which thumbnails are generated.
  /// - [videoDuration] is the total duration of the video in milliseconds.
  /// - [thumbnailHeight] is the height of each thumbnail.
  /// - [contentWidth] is the exact width of the thumbnail strip.
  /// - [thumbnailWidth] is the fixed width of each thumbnail.
  /// - [numberOfThumbnails] is the number of thumbnails to generate.
  /// - [densityLevel] is the discrete zoom density used for cache grouping.
  /// - [fit] is how the thumbnails should be inscribed into the allocated space.
  /// - [onThumbnailLoadingComplete] is the callback function that is called when thumbnail loading is complete.
  /// - [quality] is the quality of the generated thumbnails, ranging from 0 to 100. Defaults to 75.
  const ScrollableThumbnailViewer({
    super.key,
    required this.videoFile,
    required this.videoDuration,
    required this.thumbnailHeight,
    required this.contentWidth,
    required this.thumbnailWidth,
    required this.numberOfThumbnails,
    required this.densityLevel,
    required this.fit,
    required this.onThumbnailLoadingComplete,
    this.onThumbnailWidthResolved,
    this.quality = 75,
  });

  /// The video file from which thumbnails are generated.
  final File videoFile;

  /// The total duration of the video in milliseconds.
  final int videoDuration;

  /// The height of each thumbnail.
  final double thumbnailHeight;

  /// Exact width occupied by the complete thumbnail strip.
  final double contentWidth;

  /// Fixed width of each thumbnail.
  final double thumbnailWidth;

  /// The number of thumbnails to generate.
  final int numberOfThumbnails;

  /// Discrete zoom density used for cache grouping.
  final ThumbnailDensityLevel densityLevel;

  /// How the thumbnails should be inscribed into the allocated space.
  final BoxFit fit;

  /// Callback function that is called when thumbnail loading is complete.
  final VoidCallback onThumbnailLoadingComplete;

  /// Callback to report the real thumbnail width from decoded image bytes.
  final ValueChanged<double>? onThumbnailWidthResolved;

  /// The quality of the generated thumbnails, ranging from 0 to 100.
  /// Defaults to 75.
  final int quality;

  @override
  State<ScrollableThumbnailViewer> createState() =>
      _ScrollableThumbnailViewerState();
}

class _ScrollableThumbnailViewerState extends State<ScrollableThumbnailViewer> {
  late Stream<List<Uint8List?>> _thumbnailStream;
  int _thumbnailRequestId = 0;
  Uint8List? _resolvedWidthBytes;
  bool _isResolvingWidth = false;

  @override
  void initState() {
    super.initState();
    _thumbnailStream = _createThumbnailStream();
  }

  @override
  void didUpdateWidget(covariant ScrollableThumbnailViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoFile.path != widget.videoFile.path ||
        oldWidget.videoDuration != widget.videoDuration ||
        oldWidget.numberOfThumbnails != widget.numberOfThumbnails ||
        oldWidget.densityLevel != widget.densityLevel ||
        oldWidget.thumbnailHeight != widget.thumbnailHeight ||
        oldWidget.quality != widget.quality) {
      _thumbnailStream = _createThumbnailStream();
    }
  }

  Stream<List<Uint8List?>> _createThumbnailStream() {
    final requestId = ++_thumbnailRequestId;
    return generateThumbnail(
      videoPath: widget.videoFile.path,
      videoDuration: widget.videoDuration,
      numberOfThumbnails: widget.numberOfThumbnails,
      thumbnailHeight: widget.thumbnailHeight,
      quality: widget.quality,
      densityLevel: widget.densityLevel,
      onThumbnailLoadingComplete: widget.onThumbnailLoadingComplete,
      isCancelled: () => !mounted || requestId != _thumbnailRequestId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: widget.contentWidth,
        height: widget.thumbnailHeight,
        child: StreamBuilder<List<Uint8List?>>(
          stream: _thumbnailStream,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              List<Uint8List?> imageBytes = snapshot.data!;
              final firstFrameBytes =
                  imageBytes.whereType<Uint8List>().firstOrNull;
              if (firstFrameBytes != null) {
                _resolveThumbnailWidth(firstFrameBytes);
              }
              return Row(
                mainAxisSize: MainAxisSize.max,
                children: List.generate(
                  widget.numberOfThumbnails,
                  (index) => SizedBox(
                    height: widget.thumbnailHeight,
                    width: widget.thumbnailWidth,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(
                          opacity: 0.2,
                          child: Image.memory(
                            imageBytes[0] ?? kTransparentImage,
                            fit: widget.fit,
                          ),
                        ),
                        index < imageBytes.length && imageBytes[index] != null
                            ? FadeInImage(
                                placeholder: MemoryImage(kTransparentImage),
                                image: MemoryImage(imageBytes[index]!),
                                fit: widget.fit,
                              )
                            : const SizedBox(),
                      ],
                    ),
                  ),
                ),
              );
            } else {
              return Container(
                color: Colors.grey[900],
                height: widget.thumbnailHeight,
                width: double.maxFinite,
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _resolveThumbnailWidth(Uint8List bytes) async {
    if (_isResolvingWidth || identical(_resolvedWidthBytes, bytes)) return;
    _isResolvingWidth = true;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final imageWidth = descriptor.width;
      final imageHeight = descriptor.height;
      descriptor.dispose();
      buffer.dispose();

      if (imageHeight > 0) {
        widget.onThumbnailWidthResolved?.call(
          widget.thumbnailHeight * (imageWidth / imageHeight),
        );
      }
      _resolvedWidthBytes = bytes;
    } finally {
      _isResolvingWidth = false;
    }
  }
}
