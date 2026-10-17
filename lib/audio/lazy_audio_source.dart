// copy from just_audio source code
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

final _logger = LoggerUtils.getLogger('LazyAudioSource');

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

  int? qualityId;

  static bool liveStreamExperimentEnabled = false;
  static int liveStreamMaxBytes = 32 * 1024 * 1024;
  static int advertisedLengthCapBytes = 4 * 1024 * 1024;
  bool _serveAsLiveStream = false;

  static bool _shouldServeAsLiveStream(int? sourceLength) =>
      Platform.isIOS &&
      liveStreamExperimentEnabled &&
      (sourceLength == null || sourceLength <= liveStreamMaxBytes);

  final _downloadCompleteCompleter = Completer<void>();
  Future<void> get downloadComplete => _downloadCompleteCompleter.future;

  static final Map<String, Future<void>> _inflightDownloads = {};
  String get _downloadKey => '$bvid:$cid';

  StreamSubscription<List<int>>? _subscription;
  HttpClient? _httpClient;
  IOSink? _sink;
  final _inProgressResponses = <_InProgressCacheResponse>[];

  LazyAudioSource(
    this.bvid,
    this.cid, {
    File? localFile,
    super.tag,
  })  : localFile = localFile != null
            ? Future.value(localFile)
            : DatabaseManager.prepareFileForCaching(bvid, cid),
        isLocal = localFile != null {
    _downloadCompleteCompleter.future.ignore();
    _init();
  }

  Future<Uri> get uri async {
    return await _uriMemoizer.runOnce(() async {
      final service = await BilibiliService.instance;

      int actualCid = cid;
      // ✅ 如果 cid 传入了 0，说明是懒加载，需自动获取该视频的第一个分P的 cid
      if (cid == 0) {
        try {
          final srcs = await service.getAudios(bvid);
          if (srcs != null && srcs.isNotEmpty) {
            final firstTag = srcs.first.tag;
            if (firstTag is MediaItem) {
              final cidExtra = firstTag.extras?['cid'];
              if (cidExtra is int) {
                actualCid = cidExtra;
              }
            }
          }
        } catch (e) {
          _logger.warning(
              'LazyAudioSource: failed to get first cid for $bvid: $e');
        }
      }

      final audio = await service.getAudio(bvid, actualCid);
      qualityId = audio?.firstOrNull?.id;
      return Uri.parse(audio?.firstOrNull?.baseUrl ?? '');
    });
  }

  Future<void> _init() async {
    final file = await localFile;
    if (file.existsSync()) {
      _downloadProgressSubject.add(1.0);
      if (!_downloadCompleteCompleter.isCompleted) {
        _downloadCompleteCompleter.complete();
      }
    } else {
      _downloadProgressSubject.add(0.0);
    }
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
    await DatabaseManager.deleteCacheFiles((await localFile).path);
    _progress = 0;
    _downloadProgressSubject.add(0.0);
  }

  Future<void> cancelDownload() async {
    if (!_downloading) return;
    _downloading = false;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    try {
      _httpClient?.close(force: true);
    } catch (_) {}
    _httpClient = null;
    for (final req in _requests) {
      req.fail(Exception('download cancelled'));
    }
    _requests.clear();
    for (final res in _inProgressResponses) {
      if (!res.controller.isClosed) {
        res.controller.addError(Exception('download cancelled'));
        res.controller.close();
      }
    }
    _inProgressResponses.clear();
    try {
      final part = await _partialCacheFile;
      if (part.existsSync()) await part.delete();
    } catch (_) {}
    if (!_downloadCompleteCompleter.isCompleted) {
      _progress = 0;
      _downloadProgressSubject.add(0.0);
    }
    _response = null;
    if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
      _inflightDownloads.remove(_downloadKey);
    }
    if (!_downloadCompleteCompleter.isCompleted) {
      _downloadCompleteCompleter.completeError(Exception('download cancelled'));
    }
  }

  Future<File> get _partialCacheFile async =>
      File('${(await localFile).path}.part');

  Future<File> get _mimeFile async => File('${(await localFile).path}.mime');

  static String sniffMimeFromUri(Uri uri, [String fallback = 'audio/mpeg']) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m4s') ||
        path.endsWith('.m4a') ||
        path.endsWith('.mp4')) {
      return 'audio/mp4';
    }
    if (path.endsWith('.aac') || path.endsWith('.adts')) {
      return 'audio/aac';
    }
    if (path.endsWith('.flac')) {
      return 'audio/flac';
    }
    if (path.endsWith('.ogg') || path.endsWith('.oga')) {
      return 'audio/ogg';
    }
    if (path.endsWith('.wav')) {
      return 'audio/wav';
    }
    return fallback;
  }

  static String? sniffMimeFromBytes(List<int> header) {
    if (header.length < 12) return null;
    bool eq(int i, int c) => header[i] == c;
    if (eq(4, 0x66) && eq(5, 0x74) && eq(6, 0x79) && eq(7, 0x70)) {
      return 'audio/mp4';
    }
    if (eq(4, 0x73) && eq(5, 0x74) && eq(6, 0x79) && eq(7, 0x70)) {
      return 'audio/mp4';
    }
    if (eq(0, 0x49) && eq(1, 0x44) && eq(2, 0x33)) return 'audio/mpeg';
    if (eq(0, 0xFF) && (header[1] & 0xE0) == 0xE0) return 'audio/mpeg';
    if (eq(0, 0x4F) && eq(1, 0x67) && eq(2, 0x67) && eq(3, 0x53)) {
      return 'audio/ogg';
    }
    if (eq(0, 0x66) && eq(1, 0x4C) && eq(2, 0x61) && eq(3, 0x43)) {
      return 'audio/flac';
    }
    if (eq(0, 0x52) &&
        eq(1, 0x49) &&
        eq(2, 0x46) &&
        eq(3, 0x46) &&
        eq(8, 0x57) &&
        eq(9, 0x41) &&
        eq(10, 0x56) &&
        eq(11, 0x45)) {
      return 'audio/wav';
    }
    return null;
  }

  static String sanitizeMime(String mime, [String fallback = 'audio/mpeg']) {
    if (mime == 'application/octet-stream') {
      return fallback;
    }
    if (mime.isEmpty || !mime.contains('/')) {
      return fallback;
    }
    return mime;
  }

  Future<String> _readCachedMimeType() async {
    try {
      final raf = await (await localFile).open();
      final header = await raf.read(12);
      await raf.close();
      final sniffed = sniffMimeFromBytes(header);
      if (sniffed != null) return sniffed;
    } catch (_) {}
    final file = await _mimeFile;
    if (file.existsSync()) {
      return sanitizeMime(await file.readAsString());
    }
    return 'audio/mpeg';
  }

  Future<HttpClientResponse> _fetch() async {
    final sw = Stopwatch()..start();
    _logger.info('[$bvid:$cid] fetch: start');
    _downloading = true;
    final partialCacheFile = await _partialCacheFile;
    final localFile = await this.localFile;

    File getEffectiveCacheFile() =>
        partialCacheFile.existsSync() ? partialCacheFile : localFile;

    var uri = await this.uri;
    _logger.info('[$bvid:$cid] fetch: playurl resolved (${sw.elapsed})');
    final headers = (await BilibiliService.instance).headers;

    final httpClient = _httpClient = HttpClient();
    var httpRequest = await _getUrl(httpClient, uri, headers: headers);
    var response = await httpRequest.close();
    _logger.info(
        '[$bvid:$cid] fetch: CDN response ${response.statusCode} (${sw.elapsed})');

    if (response.statusCode == 403 || response.statusCode == 404) {
      await response.drain<void>();
      final service = await BilibiliService.instance;
      final audio = await service.getAudio(
          bvid, cid == 0 ? 1 : cid); // fallback, might fail if no real cid
      final candidates = audio ?? <dynamic>[];
      final retryCandidates = <({Uri url, int id})>[
        for (final a in candidates)
          if (a.baseUrl.isNotEmpty)
            (url: Uri.parse(a.baseUrl), id: a.id as int),
        for (final a in candidates)
          ...?a.backupUrl?.map((u) => (url: Uri.parse(u), id: a.id as int)),
      ];
      Uri? retried;
      for (final c in retryCandidates) {
        if (c.url == uri) continue;
        httpRequest = await _getUrl(httpClient, c.url, headers: headers);
        response = await httpRequest.close();
        if (response.statusCode == 200 || response.statusCode == 206) {
          retried = c.url;
          uri = c.url;
          qualityId = c.id;
          break;
        }
        await response.drain<void>();
      }
      if (retried == null && retryCandidates.isNotEmpty) {
        uri = retryCandidates.first.url;
        httpRequest = await _getUrl(httpClient, uri, headers: headers);
        response = await httpRequest.close();
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.drain<void>();
        }
      }
    }
    if (response.statusCode != 200) {
      httpClient.close();
      throw Exception('HTTP Status Error: ${response.statusCode}');
    }
    (await _partialCacheFile).createSync(recursive: true);

    final sink = _sink = (await _partialCacheFile).openWrite();
    final sourceLength =
        response.contentLength == -1 ? null : response.contentLength;
    _serveAsLiveStream = _shouldServeAsLiveStream(sourceLength);
    final rawMimeType = response.headers.contentType.toString();
    var mimeType = sanitizeMime(rawMimeType, sniffMimeFromUri(uri, ''));
    final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
    final originSupportsRangeRequests =
        acceptRanges != null && acceptRanges != 'none';
    final inProgressResponses = _inProgressResponses;
    late StreamSubscription<List<int>> subscription;
    var percentProgress = 0;
    void updateProgress(int newPercentProgress) {
      if (newPercentProgress != percentProgress) {
        percentProgress = newPercentProgress;
        _downloadProgressSubject.add(percentProgress / 100);
      }
    }

    _progress = 0;

    int advertisedLengthCap(int realLength) {
      var cap = advertisedLengthCapBytes;
      final t = tag;
      final duration = t is MediaItem ? t.duration : null;
      final seconds = duration?.inSeconds ?? 0;
      if (seconds > 45) {
        final bytesFor45s = realLength * 45 ~/ seconds;
        if (bytesFor45s > cap) cap = bytesFor45s;
      }
      return min(cap, realLength);
    }

    final moovProbe = BytesBuilder(copy: false);
    var moovFront = false;
    var moovTail = false;
    void probeMoovPosition(List<int> data) {
      if (moovFront || moovTail) return;
      moovProbe.add(data);
      final bytes = moovProbe.toBytes();
      final bd = ByteData.sublistView(bytes);
      var offset = 0;
      while (offset + 8 <= bytes.length) {
        final size32 = bd.getUint32(offset);
        final type =
            String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
        if (type == 'moov') {
          moovFront = true;
          final real = sourceLength;
          if (real != null && real > advertisedLengthCapBytes) {
            _logger.info(
                '[$bvid:$cid] moov front: advertising length cap ${advertisedLengthCap(real)}/$real');
          }
          return;
        }
        if (type == 'mdat') {
          moovTail = true;
          return;
        }
        int advance;
        if (size32 == 1) {
          if (offset + 16 > bytes.length) return;
          advance = bd.getUint64(offset + 8);
        } else if (size32 == 0) {
          return;
        } else {
          advance = size32;
        }
        if (advance < 8) return;
        offset += advance;
      }
      if (moovProbe.length > 1024 * 1024) moovTail = true;
    }

    int? advertisedSourceLength() {
      final real = sourceLength;
      if (Platform.isIOS &&
          moovFront &&
          real != null &&
          real > advertisedLengthCapBytes) {
        return advertisedLengthCap(real);
      }
      return real;
    }

    subscription = _subscription = response.listen((data) async {
      if (_progress == 0) {
        final sniffed = sniffMimeFromBytes(data);
        if (sniffed != null) {
          mimeType = sniffed;
        } else if (mimeType.isEmpty) {
          mimeType = 'audio/mpeg';
        }
        _logger.info(
            '[$bvid:$cid] fetch: first chunk ${data.length}B (${sw.elapsed}), mime=$mimeType, pendingRequests=${_requests.length}');
      }
      probeMoovPosition(data);
      _progress += data.length;
      final newPercentProgress = (sourceLength == null)
          ? 0
          : (sourceLength == 0)
              ? 100
              : min(100, 100 * _progress ~/ sourceLength);
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

      for (var cacheResponse in inProgressResponses) {
        final end = cacheResponse.end;
        if (end != null && _progress >= end) {
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

      subscription.pause();
      try {
        await sink.flush();
        for (var request in readyRequests) {
          _requests.remove(request);
          int? start, end;
          if (originSupportsRangeRequests) {
            start = request.start;
            end = request.end;
          }
          final effectiveStart = start ?? 0;
          final advertised = advertisedSourceLength();
          var effectiveEnd =
              _serveAsLiveStream ? sourceLength : (end ?? advertised);
          if (!_serveAsLiveStream &&
              effectiveEnd != null &&
              advertised != null &&
              effectiveEnd > advertised) {
            effectiveEnd = advertised;
          }
          Stream<List<int>> responseStream;
          if (effectiveEnd != null && effectiveEnd <= _progress) {
            responseStream =
                getEffectiveCacheFile().openRead(effectiveStart, effectiveEnd);
          } else {
            final cacheResponse = _InProgressCacheResponse(end: effectiveEnd);
            inProgressResponses.add(cacheResponse);
            responseStream = Rx.concatEager([
              getEffectiveCacheFile().openRead(effectiveStart, _progress),
              cacheResponse.controller.stream,
            ]);
          }
          if (_serveAsLiveStream) {
            request.complete(StreamAudioResponse(
              rangeRequestsSupported: false,
              sourceLength: null,
              contentLength: null,
              offset: null,
              contentType: mimeType,
              stream: responseStream.asBroadcastStream(),
            ));
          } else {
            request.complete(StreamAudioResponse(
              rangeRequestsSupported: originSupportsRangeRequests,
              sourceLength: start != null ? advertised : null,
              contentLength:
                  effectiveEnd != null ? effectiveEnd - effectiveStart : null,
              offset: start,
              contentType: mimeType,
              stream: responseStream.asBroadcastStream(),
            ));
          }
        }
      } finally {
        subscription.resume();
      }
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
    }, onDone: () async {
      _logger.info('[$bvid:$cid] fetch: download complete (${sw.elapsed})');

      try {
        await _sink?.flush();
        await _sink?.close();
      } catch (_) {}
      _sink = null;

      if (sourceLength == null) {
        updateProgress(100);
      }
      for (var cacheResponse in inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }

      try {
        final part = await _partialCacheFile;
        if (part.existsSync()) {
          bool renamed = false;
          for (int i = 0; i < 5; i++) {
            try {
              part.renameSync(localFile.path);
              renamed = true;
              break;
            } catch (e) {
              if (i == 4) {
                _logger.warning(
                    '[$bvid:$cid] rename partial cache failed after retries: $e');
                rethrow;
              }
              await Future.delayed(const Duration(milliseconds: 200));
            }
          }
          if (renamed) {
            _logger.info(
                '[$bvid:$cid] Successfully renamed .part to local cache file.');
          }
        }
      } catch (e) {
        _logger.warning('[$bvid:$cid] rename partial cache failed: $e');
      }

      if (!localFile.existsSync()) {
        _logger.severe('[$bvid:$cid] download artifact missing after done');
        _response = null;
        _downloading = false;
        if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
          _inflightDownloads.remove(_downloadKey);
        }
        if (!_downloadCompleteCompleter.isCompleted) {
          _downloadCompleteCompleter
              .completeError(StateError('download artifact missing'));
        }
        await subscription.cancel();
        httpClient.close();
        return;
      }

      await (await _mimeFile).writeAsString(mimeType);
      await subscription.cancel();
      httpClient.close();
      _downloading = false;

      await DatabaseManager.saveCacheMetadata(bvid, cid, localFile);

      if (!_downloadCompleteCompleter.isCompleted) {
        _downloadCompleteCompleter.complete();
      }
      if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
        _inflightDownloads.remove(_downloadKey);
      }

      await Future.delayed(const Duration(milliseconds: 100));
      DatabaseManager.cleanupCache(ignoreFile: localFile);
    }, onError: (Object e, StackTrace stackTrace) async {
      try {
        await _sink?.flush();
        await _sink?.close();
      } catch (_) {}
      _sink = null;

      try {
        (await _partialCacheFile).deleteSync();
      } catch (_) {}
      httpClient.close();
      _response = null;
      for (final req in _requests) {
        req.fail(e, stackTrace);
      }
      _requests.clear();
      for (final res in inProgressResponses) {
        res.controller.addError(e, stackTrace);
        res.controller.close();
      }
      _downloading = false;
      if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
        _inflightDownloads.remove(_downloadKey);
      }
      if (!_downloadCompleteCompleter.isCompleted) {
        _downloadCompleteCompleter.completeError(e, stackTrace);
      }
    }, cancelOnError: true);
    return response;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    _logger.info('[$bvid:$cid] proxy request: start=$start end=$end');
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
    if (!_downloading) {
      final inflight = _inflightDownloads[_downloadKey];
      if (inflight != null && !identical(inflight, downloadComplete)) {
        _logger.info('[$bvid:$cid] request: waiting for in-flight download');
        try {
          await inflight;
        } catch (_) {}
        if (file.existsSync()) {
          _logger.info('[$bvid:$cid] request: serving from in-flight result');
          _downloadProgressSubject.add(1.0);
          if (!_downloadCompleteCompleter.isCompleted) {
            _downloadCompleteCompleter.complete();
          }
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
      }
    }
    final byteRangeRequest = _StreamingByteRangeRequest(start, end);
    _requests.add(byteRangeRequest);
    if (_response == null) {
      _inflightDownloads[_downloadKey] ??= downloadComplete;
      _response =
          _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
        _response = null;
        for (final req in _requests) {
          req.fail(error, stackTrace);
        }
        _downloading = false;
        if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
          _inflightDownloads.remove(_downloadKey);
        }
        if (!_downloadCompleteCompleter.isCompleted) {
          _downloadCompleteCompleter.completeError(error, stackTrace);
        }
        return Future<HttpClientResponse>.error(error as Object, stackTrace);
      });
    }
    return byteRangeRequest.future.then((response) {
      response.stream.listen((event) {}, onError: (Object e, StackTrace st) {
        _response = null;
        for (final req in _requests) {
          req.fail(e, st);
        }
      });
      return response;
    });
  }
}

class _InProgressCacheResponse {
  final controller = ReplaySubject<List<int>>();
  final int? end;
  _InProgressCacheResponse({required this.end});
}

class _StreamingByteRangeRequest {
  final int? start;
  final int? end;
  final _completer = Completer<StreamAudioResponse>();
  _StreamingByteRangeRequest(this.start, this.end);
  Future<StreamAudioResponse> get future => _completer.future;
  void complete(StreamAudioResponse response) {
    if (_completer.isCompleted) return;
    _completer.complete(response);
  }

  void fail(dynamic error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) return;
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
  request.maxRedirects = 20;
  return request;
}

class _HttpRangeRequest {
  final int start;
  final int? end;
  int? get endEx => end == null ? null : end! + 1;
  _HttpRangeRequest(this.start, this.end);
  String get header =>
      'bytes=$start-${end != null ? (end! - 1).toString() : ""}';
}
