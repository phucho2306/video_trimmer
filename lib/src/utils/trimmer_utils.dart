import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';

final Map<_ThumbnailCacheKey, Uint8List?> _thumbnailCache = <_ThumbnailCacheKey, Uint8List?>{};
const int _thumbnailCacheLimit = 180;
const int _thumbnailBatchSize = 4;

enum ThumbnailDensityLevel {
  low,
  medium,
  high,
  max,
}

class _ThumbnailCacheKey {
  const _ThumbnailCacheKey({
    required this.videoPath,
    required this.timestamp,
    required this.maxHeight,
    required this.quality,
  });

  final String videoPath;
  final int timestamp;
  final int maxHeight;
  final int quality;

  @override
  bool operator ==(Object other) {
    return other is _ThumbnailCacheKey &&
        other.videoPath == videoPath &&
        other.timestamp == timestamp &&
        other.maxHeight == maxHeight &&
        other.quality == quality;
  }

  @override
  int get hashCode => Object.hash(
        videoPath,
        timestamp,
        maxHeight,
        quality,
      );
}

/// Generates a stream of thumbnails for a given video.
///
/// This function generates a specified number of thumbnails for a video at
/// different timestamps and yields them as a stream of lists of byte arrays.
///
/// Parameters:
/// - `videoPath` (required): The path to the video file.
/// - `videoDuration` (required): The duration of the video in milliseconds.
/// - `numberOfThumbnails` (required): The number of thumbnails to generate.
/// - `quality` (required): The quality of the thumbnails (percentage).
/// - `onThumbnailLoadingComplete` (required): A callback function that is
///   called when all thumbnails have been generated.
///
/// Returns:
/// A stream of lists of byte arrays, where each list contains the generated
/// thumbnails up to that point.
///
/// Example usage:
/// ```dart
/// final thumbnailStream = generateThumbnail(
///   videoPath: 'path/to/video.mp4',
///   videoDuration: 60000, // 1 minute
///   numberOfThumbnails: 10,
///   quality: 50,
///   onThumbnailLoadingComplete: () {
///     print('Thumbnails generated successfully!');
///   },
/// );
///
/// await for (final thumbnails in thumbnailStream) {
///   // Process the thumbnails
/// }
/// ```
///
/// Throws:
/// An error if the thumbnails could not be generated.
Stream<List<Uint8List?>> generateThumbnail({
  required String videoPath,
  required int videoDuration,
  required int numberOfThumbnails,
  required double thumbnailHeight,
  required int quality,
  required ThumbnailDensityLevel densityLevel,
  required VoidCallback onThumbnailLoadingComplete,
  bool Function()? isCancelled,
}) async* {
  final double eachPart = videoDuration / numberOfThumbnails;
  final List<Uint8List?> thumbnailBytes = List<Uint8List?>.filled(numberOfThumbnails, null);
  final maxHeight = thumbnailHeight.toInt();
  final pending = <int, Future<_IndexedThumbnail>>{};
  var nextIndex = 0;
  var loadedCount = 0;
  final timestampBucketMs = _timestampBucketForLevel(densityLevel);

  void enqueueNext() {
    while ((isCancelled?.call() ?? false) == false &&
        nextIndex < numberOfThumbnails &&
        pending.length < _thumbnailBatchSize) {
      final i = nextIndex++;
      final timestamp = _snapTimestamp(
        (eachPart * (i + 0.5)).round().clamp(0, math.max(0, videoDuration - 1)).toInt(),
        timestampBucketMs,
        videoDuration,
      );
      pending[i] = _loadThumbnail(
        index: i,
        videoPath: videoPath,
        timestamp: timestamp,
        maxHeight: maxHeight,
        quality: quality,
      );
    }
  }

  try {
    enqueueNext();
    while (pending.isNotEmpty) {
      final result = await Future.any(pending.values);
      if (isCancelled?.call() ?? false) return;
      pending.remove(result.index);
      thumbnailBytes[result.index] = result.bytes;
      loadedCount++;

      if (loadedCount == numberOfThumbnails) {
        onThumbnailLoadingComplete();
      }

      yield List<Uint8List?>.of(thumbnailBytes);
      if (isCancelled?.call() ?? false) return;
      enqueueNext();
    }
  } catch (_) {
    yield List<Uint8List?>.of(thumbnailBytes);
  }
}

class _IndexedThumbnail {
  const _IndexedThumbnail({
    required this.index,
    required this.bytes,
  });

  final int index;
  final Uint8List? bytes;
}

Future<_IndexedThumbnail> _loadThumbnail({
  required int index,
  required String videoPath,
  required int timestamp,
  required int maxHeight,
  required int quality,
}) async {
  final cacheKey = _ThumbnailCacheKey(
    videoPath: videoPath,
    timestamp: timestamp,
    maxHeight: maxHeight,
    quality: quality,
  );
  final cachedBytes = _thumbnailCache[cacheKey];
  if (cachedBytes != null || _thumbnailCache.containsKey(cacheKey)) {
    return _IndexedThumbnail(index: index, bytes: cachedBytes);
  }

  final bytes = await VideoThumbnail.thumbnailData(
    video: videoPath,
    imageFormat: ImageFormat.JPEG,
    timeMs: timestamp,
    maxHeight: maxHeight,
    quality: quality,
  );
  if (_thumbnailCache.length >= _thumbnailCacheLimit) {
    _thumbnailCache.clear();
  }
  _thumbnailCache[cacheKey] = bytes;

  return _IndexedThumbnail(index: index, bytes: bytes);
}

int _timestampBucketForLevel(ThumbnailDensityLevel level) {
  return switch (level) {
    ThumbnailDensityLevel.low => 1000,
    ThumbnailDensityLevel.medium => 500,
    ThumbnailDensityLevel.high => 250,
    ThumbnailDensityLevel.max => 250,
  };
}

int _snapTimestamp(int timestamp, int bucketMs, int videoDuration) {
  if (bucketMs <= 1) return timestamp;
  final snapped = (timestamp / bucketMs).round() * bucketMs;
  return snapped.clamp(0, math.max(0, videoDuration - 1)).toInt();
}
