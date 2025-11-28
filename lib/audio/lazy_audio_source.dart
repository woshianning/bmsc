// copy from just_audio source code
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

/// 下载缓存过程中使用的内部类
class _InProgressCacheResponse {
  final controller = ReplaySubject<List<int>>();
  final int? end;
  _InProgressCacheResponse({required this.end});
}

/// 用于处理单个字节范围请求
class _StreamingByteRangeRequest {
  final int? start;
  final int? end;
  final _completer = Completer<StreamAudioResponse>();

  _StreamingByteRangeRequest(this.start, this.end);

  Future<StreamAudioResponse> get future => _completer.future;

  void complete(StreamAudioResponse response) {
    if (!_completer.isCompleted) _completer.complete(response);
  }

  void fail(dynamic error, [StackTrace? stackTrace]) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

/// 获取带 headers 的 HttpClientRequest
Future<HttpClientRequest> _getUrl(HttpClient client, Uri uri,
    {Map<String, String>? headers}) async {
  final request = await client.getUrl(uri);
  if (headers != null) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    request.headers.clear();
    request.headers.set(HttpHeaders.contentLengthHeader, '0');
    headers.forEach((name, value) => request.headers.set(name, value));
    if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
    if (client.userAgent != null)
      request.headers.set(HttpHeaders.userAgentHeader, client.userAgent!);
  }
  request.maxRedirects = 20;
  return request;
}

/// 实现 Lazy 下载缓存的 AudioSource
class LazyAudioSource extends StreamAudioSource {
  Future<HttpClientResponse>? _response;
  final String bvid;
  final int cid;
  final AsyncMemoizer<Uri> _uriMemoizer = AsyncMemoizer();
  final Future<File> localFile;
  int _progress = 0;
  final bool isLocal;
  final _requests = <_StreamingByteRangeRequest>[];
  final _downloadProgressSubject = BehaviorSubject<double>();
  bool _downloading = false;

  LazyAudioSource(
    this.bvid,
    this.cid, {
    File? localFile,
    super.tag,
  })  : localFile = localFile != null
            ? Future.value(localFile)
            : DatabaseManager.prepareFileForCaching(bvid, cid),
        isLocal = localFile != null {
    _init();
  }

  Future<Uri> get uri async {
    return await _uriMemoizer.runOnce(() async {
      final service = await BilibiliService.instance;
      final audio = await service.getAudio(bvid, cid);
      return Uri.parse(audio?.firstOrNull?.baseUrl ?? '');
    });
  }

  Future<void> _init() async {
    final file = await localFile;
    _downloadProgressSubject.add(file.existsSync() ? 1.0 : 0.0);
  }

  Future<IndexedAudioSource> resolve() async {
    final file = await localFile;
    return await file.exists() ? AudioSource.uri(Uri.file(file.path)) : this;
  }

  Stream<double> get downloadProgressStream => _downloadProgressSubject.stream;

  Future<void> clearCache() async {
    if (_downloading) {
      throw Exception("Cannot clear cache while download is in progress");
    }
    _response = null;
    final file = await localFile;
    if (file.existsSync()) await file.delete();
    final mimeFile = await _mimeFile;
    if (await mimeFile.exists()) await mimeFile.delete();
    _progress = 0;
    _downloadProgressSubject.add(0.0);
  }

  Future<File> get _partialCacheFile async =>
      File('${(await localFile).path}.part');

  Future<File> get _mimeFile async => File('${(await localFile).path}.mime');

  Future<String> _readCachedMimeType() async {
    final file = await _mimeFile;
    if (file.existsSync()) {
      return (await file.readAsString());
    } else {
      return 'audio/mpeg';
    }
  }

  Future<HttpClientResponse> _fetch() async {
    _downloading = true;
    final partialCacheFile = await _partialCacheFile;
    final localFile = await this.localFile;

    File getEffectiveCacheFile() =>
        partialCacheFile.existsSync() ? partialCacheFile : localFile;

    var uri = await this.uri;
    final headers = (await BilibiliService.instance).headers;
    final httpClient = HttpClient();
    var httpRequest = await _getUrl(httpClient, uri, headers: headers);
    var response = await httpRequest.close();

    if (response.statusCode == 403) {
      final service = await BilibiliService.instance;
      final audio = await service.getAudio(bvid, cid);
      uri = Uri.parse(audio?.firstOrNull?.baseUrl ?? '');
      httpRequest = await _getUrl(httpClient, uri, headers: headers);
      response = await httpRequest.close();
    }
    if (response.statusCode != 200) {
      httpClient.close();
      throw Exception('HTTP Status Error: ${response.statusCode}');
    }

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
    int percentProgress = 0;

    void updateProgress(int newPercentProgress) {
      if (newPercentProgress != percentProgress) {
        percentProgress = newPercentProgress;
        _downloadProgressSubject.add(percentProgress / 100);
      }
    }

    _progress = 0;
    subscription = response.listen(
      (data) async {
        _progress += data.length;
        final newPercentProgress = (sourceLength == null)
            ? 0
            : (sourceLength == 0)
                ? 100
                : (100 * _progress ~/ sourceLength); // 修复 num -> int
        updateProgress(newPercentProgress);
        sink.add(data);

        final readyRequests = _requests
            .where((r) =>
                !originSupportsRangeRequests ||
                r.start == null ||
                (r.start!) < _progress)
            .toList();
        final notReadyRequests = _requests
            .where((r) =>
                originSupportsRangeRequests &&
                r.start != null &&
                (r.start!) >= _progress)
            .toList();

        for (var cacheResponse in inProgressResponses) {
          final end = cacheResponse.end;
          if (end != null && _progress >= end) {
            final subEnd = min(data.length, max(0, data.length - (_progress - end)));
            cacheResponse.controller.add(data.sublist(0, subEnd));
            cacheResponse.controller.close();
          } else {
            cacheResponse.controller.add(data);
          }
        }

        inProgressResponses.removeWhere((e) => e.controller.isClosed);
        if (_requests.isEmpty) return;
        subscription.pause();
        await sink.flush();

        for (var request in readyRequests) {
          _requests.remove(request);
          final start = request.start ?? 0;
          final end = request.end ?? sourceLength;
          Stream<List<int>> responseStream;
          if (end != null && end <= _progress) {
            responseStream = getEffectiveCacheFile().openRead(start, end);
          } else {
            final cacheResponse = _InProgressCacheResponse(end: end);
            inProgressResponses.add(cacheResponse);
            responseStream = Rx.concatEager([
              getEffectiveCacheFile().openRead(start, _progress),
              cacheResponse.controller.stream,
            ]);
          }
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: originSupportsRangeRequests,
            sourceLength: start != null ? sourceLength : null,
            contentLength: end != null ? end - start : null,
            offset: start,
            contentType: mimeType,
            stream: responseStream.asBroadcastStream(),
          ));
        }

        subscription.resume();

        for (var request in notReadyRequests) {
          _requests.remove(request);
          final start = request.start!;
          final end = request.end ?? sourceLength;
          final rangeClient = HttpClient();

          final rangeRequest = _HttpRangeRequest(start, end);
          _getUrl(rangeClient, uri, headers: {
            if (headers != null) ...headers,
            HttpHeaders.rangeHeader: rangeRequest.header,
          }).then((req) async {
            final resp = await req.close();
            if (resp.statusCode != 206) {
              rangeClient.close();
              throw Exception('HTTP Status Error: ${resp.statusCode}');
            }
            request.complete(StreamAudioResponse(
              rangeRequestsSupported: originSupportsRangeRequests,
              sourceLength: sourceLength,
              contentLength: end != null ? end - start : null,
              offset: start,
              contentType: mimeType,
              stream: resp.asBroadcastStream(),
            ));
          }).onError((e, st) => request.fail(e, st));
        }
      },
      onDone: () async {
        if (sourceLength == null) updateProgress(100);
        for (var cacheResponse in inProgressResponses) {
          if (!cacheResponse.controller.isClosed) cacheResponse.controller.close();
        }
        partialCacheFile.renameSync(localFile.path);
        await subscription.cancel();
        httpClient.close();
        _downloading = false;
        await DatabaseManager.saveCacheMetadata(bvid, cid, localFile);
        await Future.delayed(const Duration(milliseconds: 100));
        DatabaseManager.cleanupCache(ignoreFile: localFile);
      },
      onError: (e, st) async {
        partialCacheFile.deleteSync();
        httpClient.close();
        for (final req in _requests) req.fail(e, st);
        _requests.clear();
        for (final res in inProgressResponses) {
          res.controller.addError(e, st);
          res.controller.close();
        }
        _downloading = false;
      },
      cancelOnError: true,
    );

    return response;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final file = await localFile;
    if (file.existsSync()) {
      final sourceLength = file.lengthSync();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: start != null ? sourceLength : null,
        contentLength: (end ?? sourceLength) - (start ?? 0),
        offset: start,
        contentType: await _readCachedMimeType(),
        stream: file.openRead(start, end).asBroadcastStream(),
      );
    }
    final byteRangeRequest = _StreamingByteRangeRequest(start, end);
    _requests.add(byteRangeRequest);
    _response ??= _fetch().catchError((error, stackTrace) {
      _response = null;
      for (final req in _requests) req.fail(error, stackTrace);
      return Future<HttpClientResponse>.error(error, stackTrace);
    });
    return byteRangeRequest.future.then((resp) {
      resp.stream.listen((_) {}, onError: (e, st) {
        _response = null;
        for (final req in _requests) req.fail(e, st);
      });
      return resp;
    });
  }
}

/// HTTP 字节范围封装
class _HttpRangeRequest {
  final int start;
  final int? end;
  int? get endEx => end == null ? null : end! + 1;
  _HttpRangeRequest(this.start, this.end);
  String get header => 'bytes=$start-${end != null ? (end! - 1).toString() : ""}';
}
