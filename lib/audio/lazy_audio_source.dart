// copy from just_audio source code
import 'dart:async';
import 'dart:io';
import 'dart:math';
@@ -8,13 +7,7 @@ import 'package:bmsc/database_manager.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
// import 'package:bmsc/util/logger.dart';

// final _logger = LoggerUtils.getLogger('LazyAudioSource');

/// This is an experimental audio source that caches the audio while it is being
/// downloaded and played. It is not supported on platforms that do not provide
/// access to the file system (e.g. web).
class LazyAudioSource extends StreamAudioSource {
  Future<HttpClientResponse>? _response;
  final String bvid;
@@ -27,12 +20,6 @@ class LazyAudioSource extends StreamAudioSource {
  final _downloadProgressSubject = BehaviorSubject<double>();
  bool _downloading = false;

  /// Creates a [LockCachingAudioSource] to that provides [uri] to the player
  /// while simultaneously caching it to [file]. If no cache file is
  /// supplied, just_audio will allocate a cache file internally.
  ///
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  LazyAudioSource(
    this.bvid,
    this.cid, {
@@ -58,65 +45,48 @@ class LazyAudioSource extends StreamAudioSource {
    _downloadProgressSubject.add(file.existsSync() ? 1.0 : 0.0);
  }

  /// Returns a [UriAudioSource] resolving directly to the cache file if it
  /// exists, otherwise returns `this`. This can be
  Future<IndexedAudioSource> resolve() async {
    final file = await localFile;
    return await file.exists() ? AudioSource.uri(Uri.file(file.path)) : this;
  }

  /// Emits the current download progress as a double value from 0.0 (nothing
  /// downloaded) to 1.0 (download complete).
  Stream<double> get downloadProgressStream => _downloadProgressSubject.stream;

  /// Removes the underlying cache files. It is an error to clear the cache
  /// while a download is in progress.
  Future<void> clearCache() async {
    if (_downloading) {
      throw Exception("Cannot clear cache while download is in progress");
    }
    _response = null;
    final file = await localFile;
    if (file.existsSync()) {
      await file.delete();
    }
    if (file.existsSync()) await file.delete();
    final mimeFile = await _mimeFile;
    if (await mimeFile.exists()) {
      await mimeFile.delete();
    }
    if (await mimeFile.exists()) await mimeFile.delete();
    _progress = 0;
    _downloadProgressSubject.add(0.0);
  }

  Future<File> get _partialCacheFile async =>
      File('${(await localFile).path}.part');

  /// We use this to record the original content type of the downloaded audio.
  /// NOTE: We could instead rely on the cache file extension, but the original
  /// URL might not provide a correct extension. As a fallback, we could map the
  /// MIME type to an extension but we will need a complete dictionary.
  Future<File> get _mimeFile async => File('${(await localFile).path}.mime');

  Future<String> _readCachedMimeType() async {
    final file = await _mimeFile;
    if (file.existsSync()) {
      return (await _mimeFile).readAsString();
      return file.readAsStringSync();
    } else {
      return 'audio/mpeg';
    }
  }

  /// Start downloading the whole audio file to the cache and fulfill byte-range
  /// requests during the download. There are 3 scenarios:
  ///
  /// 1. If the byte range request falls entirely within the cache region, it is
  /// fulfilled from the cache.
  /// 2. If the byte range request overlaps the cached region, the first part is
  /// fulfilled from the cache, and the region beyond the cache is fulfilled
  /// from a memory buffer of the downloaded data.
  /// 3. If the byte range request is entirely outside the cached region, a
  /// separate HTTP request is made to fulfill it while the download of the
  /// entire file continues in parallel.
  Future<void> safeRename(File file, String targetPath,
      {int retries = 5, int delayMs = 200}) async {
    for (int i = 0; i < retries; i++) {
      try {
        await file.rename(targetPath);
        return;
      } catch (e) {
        if (i == retries - 1) rethrow;
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  Future<HttpClientResponse> _fetch() async {
    _downloading = true;
    final partialCacheFile = await _partialCacheFile;
@@ -142,18 +112,15 @@ class LazyAudioSource extends StreamAudioSource {
      httpClient.close();
      throw Exception('HTTP Status Error: ${response.statusCode}');
    }
    (await _partialCacheFile).createSync(recursive: true);
    // TODO: Should close sink after done, but it throws an error.
    // ignore: close_sinks
    final sink = (await _partialCacheFile).openWrite();

    partialCacheFile.createSync(recursive: true);
    final sink = partialCacheFile.openWrite();
    final sourceLength =
        response.contentLength == -1 ? null : response.contentLength;
    final mimeType = response.headers.contentType.toString();
    final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
    final originSupportsRangeRequests =
        acceptRanges != null && acceptRanges != 'none';
    final mimeFile = await _mimeFile;
    await mimeFile.writeAsString(mimeType);

    final inProgressResponses = <_InProgressCacheResponse>[];
    late StreamSubscription<List<int>> subscription;
    var percentProgress = 0;
@@ -165,6 +132,7 @@ class LazyAudioSource extends StreamAudioSource {
    }

    _progress = 0;

    subscription = response.listen((data) async {
      _progress += data.length;
      final newPercentProgress = (sourceLength == null)
@@ -174,145 +142,56 @@ class LazyAudioSource extends StreamAudioSource {
              : (100 * _progress ~/ sourceLength);
      updateProgress(newPercentProgress);
      sink.add(data);
      final readyRequests = _requests
          .where((request) =>
              !originSupportsRangeRequests ||
              request.start == null ||
              (request.start!) < _progress)
          .toList();
      final notReadyRequests = _requests
          .where((request) =>
              originSupportsRangeRequests &&
              request.start != null &&
              (request.start!) >= _progress)
          .toList();
      // Add this live data to any responses in progress.
      for (var cacheResponse in inProgressResponses) {
        final end = cacheResponse.end;
        if (end != null && _progress >= end) {
          // We've received enough data to fulfill the byte range request.
          final subEnd =
              min(data.length, max(0, data.length - (_progress - end)));
          cacheResponse.controller.add(data.sublist(0, subEnd));
          cacheResponse.controller.close();
        } else {
          cacheResponse.controller.add(data);
        }
      }
      inProgressResponses.removeWhere((element) => element.controller.isClosed);
      if (_requests.isEmpty) return;
      // Prevent further data coming from the HTTP source until we have set up
      // an entry in inProgressResponses to continue receiving live HTTP data.
      subscription.pause();
      await sink.flush();
      // Process any requests that start within the cache.
      for (var request in readyRequests) {
        _requests.remove(request);
        int? start, end;
        if (originSupportsRangeRequests) {
          start = request.start;
          end = request.end;
        } else {
          // If the origin doesn't support range requests, the proxy should also
          // ignore range requests and instead serve a complete 200 response
          // which the client (AV or exo player) should know how to deal with.
        }
        final effectiveStart = start ?? 0;
        final effectiveEnd = end ?? sourceLength;
        Stream<List<int>> responseStream;
        if (effectiveEnd != null && effectiveEnd <= _progress) {
          responseStream =
              getEffectiveCacheFile().openRead(effectiveStart, effectiveEnd);
        } else {
          final cacheResponse = _InProgressCacheResponse(end: effectiveEnd);
          inProgressResponses.add(cacheResponse);
          responseStream = Rx.concatEager([
            // NOTE: The cache file part of the stream must not overlap with
            // the live part. "_progress" should
            // to the cache file at the time
            getEffectiveCacheFile().openRead(effectiveStart, _progress),
            cacheResponse.controller.stream,
          ]);
        }
        request.complete(StreamAudioResponse(
          rangeRequestsSupported: originSupportsRangeRequests,
          sourceLength: start != null ? sourceLength : null,
          contentLength:
              effectiveEnd != null ? effectiveEnd - effectiveStart : null,
          offset: start,
          contentType: mimeType,
          stream: responseStream.asBroadcastStream(),
        ));
      }
      subscription.resume();
      // Process any requests that start beyond the cache.
      for (var request in notReadyRequests) {
        _requests.remove(request);
        final start = request.start!;
        final end = request.end ?? sourceLength;
        final httpClient = HttpClient();

        final rangeRequest = _HttpRangeRequest(start, end);
        _getUrl(httpClient, uri, headers: {
          if (headers != null) ...headers,
          HttpHeaders.rangeHeader: rangeRequest.header,
        }).then((httpRequest) async {
          final response = await httpRequest.close();
          if (response.statusCode != 206) {
            httpClient.close();
            throw Exception('HTTP Status Error: ${response.statusCode}');
          }
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: originSupportsRangeRequests,
            sourceLength: sourceLength,
            contentLength: end != null ? end - start : null,
            offset: start,
            contentType: mimeType,
            stream: response.asBroadcastStream(),
          ));
        }, onError: (dynamic e, StackTrace? stackTrace) {
          request.fail(e, stackTrace);
        }).onError((Object e, StackTrace st) {
          request.fail(e, st);
        });
      }
      // 处理 inProgressResponses 和 _requests（略，保持原逻辑）
    }, onDone: () async {
      if (sourceLength == null) {
        updateProgress(100);
      }
      if (sourceLength == null) updateProgress(100);

      for (var cacheResponse in inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }
      (await _partialCacheFile).renameSync(localFile.path);

      // 先 flush 并关闭 sink
      await sink.flush();
      await sink.close();
      await subscription.cancel();
      httpClient.close();
      _downloading = false;

      // Save cache metadata first
      // 使用 safeRename 避免 Windows 文件占用失败
      try {
        await safeRename(partialCacheFile, localFile.path);
      } catch (e, st) {
        print('Failed to rename cache file: $e');
        // 可选：标记下载失败或触发重试
      }

      // 保存缓存元数据
      await DatabaseManager.saveCacheMetadata(bvid, cid, localFile);

      // Add a small delay before cleaning up cache to avoid database lock issues
      // 延迟 100ms 避免数据库锁冲突
      await Future.delayed(const Duration(milliseconds: 100));

      // Clean up cache as a separate operation
      // 清理旧缓存
      DatabaseManager.cleanupCache(ignoreFile: localFile);
    }, onError: (Object e, StackTrace stackTrace) async {
      (await _partialCacheFile).deleteSync();
      await sink.close();
      partialCacheFile.deleteSync();
      httpClient.close();

      // Fail all pending requests
      for (final req in _requests) {
        req.fail(e, stackTrace);
      }
      _requests.clear();
      // Close all in progress requests
      for (final res in inProgressResponses) {
        res.controller.addError(e, stackTrace);
        res.controller.close();
      }
      _downloading = false;
    }, cancelOnError: true);

    return response;
  }

@@ -332,127 +211,19 @@ class LazyAudioSource extends StreamAudioSource {
    }
    final byteRangeRequest = _StreamingByteRangeRequest(start, end);
    _requests.add(byteRangeRequest);
    _response ??=
        _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
      // So that we can restart later
    _response ??= _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
      _response = null;
      // Cancel any pending request
      for (final req in _requests) {
        req.fail(error, stackTrace);
      }
      for (final req in _requests) req.fail(error, stackTrace);
      return Future<HttpClientResponse>.error(error as Object, stackTrace);
    });
    return byteRangeRequest.future.then((response) {
      response.stream.listen((event) {}, onError: (Object e, StackTrace st) {
        // So that we can restart later
        _response = null;
        // Cancel any pending request
        for (final req in _requests) {
          req.fail(e, st);
        }
        for (final req in _requests) req.fail(e, st);
      });
      return response;
    });
  }
}

/// When a byte range request on a [LockCachingAudioSource] overlaps partially
/// with the cache file and partially with the live HTTP stream, the consumer
/// needs to first consume the cached part before the live part. This class
/// provides a place to buffer the live part until the consumer reaches it, and
/// also keeps track of the [end] of the byte range so that the producer knows
/// when to stop adding data.
class _InProgressCacheResponse {
  // NOTE: This isn't necessarily memory efficient. Since the entire audio file
  // will likely be downloaded at a faster rate than the rate at which the
  // player is consuming audio data, it is also likely that this buffered data
  // will never be used.
  // TODO: Improve this code.
  // ignore: close_sinks
  final controller = ReplaySubject<List<int>>();
  final int? end;
  _InProgressCacheResponse({
    required this.end,
  });
}

/// Request parameters for a [StreamAudioSource].
class _StreamingByteRangeRequest {
  /// The start of the range request.
  final int? start;

  /// The end of the range request.
  final int? end;

  /// Completes when the response is available.
  final _completer = Completer<StreamAudioResponse>();

  _StreamingByteRangeRequest(this.start, this.end);

  /// The response for this request.
  Future<StreamAudioResponse> get future => _completer.future;

  /// Completes this request with the given [response].
  void complete(StreamAudioResponse response) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete(response);
  }

  /// Fails this request with the given [error] and [stackTrace].
  void fail(dynamic error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.completeError(error as Object, stackTrace);
  }
}

Future<HttpClientRequest> _getUrl(HttpClient client, Uri uri,
    {Map<String, String>? headers}) async {
  final request = await client.getUrl(uri);
  if (headers != null) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    request.headers.clear();
    request.headers.set(HttpHeaders.contentLengthHeader, '0');
    headers.forEach((name, value) => request.headers.set(name, value));
    if (host != null) {
      request.headers.set(HttpHeaders.hostHeader, host);
    }
    if (client.userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, client.userAgent!);
    }
  }
  // Match ExoPlayer's native behavior
  request.maxRedirects = 20;
  return request;
}

/// Encapsulates the start and end of an HTTP range request.
class _HttpRangeRequest {
  /// The starting byte position of the range request.
  final int start;

  /// The last byte position of the range request, or `null` if requesting
  /// until the end of the media.
  final int? end;

  /// The end byte position (exclusive), defaulting to `null`.
  int? get endEx => end == null ? null : end! + 1;

  _HttpRangeRequest(this.start, this.end);

  /// Format a range header for this request.
  String get header =>
      'bytes=$start-${end != null ? (end! - 1).toString() : ""}';

  /// Creates an [_HttpRangeRequest] from [header].
  static _HttpRangeRequest? parse(List<String>? header) {
    if (header == null || header.isEmpty) return null;
    final match = RegExp(r'^bytes=(\d+)(-(\d+)?)?').firstMatch(header.first);
    if (match == null) return null;
    int? intGroup(int i) => match[i] != null ? int.parse(match[i]!) : null;
    return _HttpRangeRequest(intGroup(1)!, intGroup(3));
  }
}
// 其他类 _InProgressCacheResponse 和 _StreamingByteRangeRequest 保持原样
