import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

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
      return file.readAsStringSync();
    } else {
      return 'audio/mpeg';
    }
  }

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
    final mimeFile = await _mimeFile;
    await mimeFile.writeAsString(mimeType);

    final inProgressResponses = <_InProgressCacheResponse>[];
    late StreamSubscription<List<int>> subscription;
    var percentProgress = 0;
    void updateProgress(int newPercentProgress) {
      if (newPercentProgress != percentProgress) {
        percentProgress = newPercentProgress;
        _downloadProgressSubject.add(percentProgress / 100);
      }
    }

    _progress = 0;

    subscription = response.listen((data) async {
      _progress += data.length;
      final newPercentProgress = (sourceLength == null)
          ? 0
          : (sourceLength == 0)
              ? 100
              : (100 * _progress ~/ sourceLength);
      updateProgress(newPercentProgress);
      sink.add(data);

      // 处理 inProgressResponses 和 _requests（略，保持原逻辑）
    }, onDone: () async {
      if (sourceLength == null) updateProgress(100);

      for (var cacheResponse in inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }

      // 先 flush 并关闭 sink
      await sink.flush();
      await sink.close();
      await subscription.cancel();
      _downloading = false;

      // 使用 safeRename 避免 Windows 文件占用失败
      try {
        await safeRename(partialCacheFile, localFile.path);
      } catch (e, st) {
        print('Failed to rename cache file: $e');
        // 可选：标记下载失败或触发重试
      }

      // 保存缓存元数据
      await DatabaseManager.saveCacheMetadata(bvid, cid, localFile);

      // 延迟 100ms 避免数据库锁冲突
      await Future.delayed(const Duration(milliseconds: 100));

      // 清理旧缓存
      DatabaseManager.cleanupCache(ignoreFile: localFile);
    }, onError: (Object e, StackTrace stackTrace) async {
      await sink.close();
      partialCacheFile.deleteSync();
      httpClient.close();

      // Fail all pending requests
      for (final req in _requests) {
        req.fail(e, stackTrace);
      }
      _requests.clear();
      for (final res in inProgressResponses) {
        res.controller.addError(e, stackTrace);
        res.controller.close();
      }
      _downloading = false;
    }, cancelOnError: true);

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
    _response ??= _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
      _response = null;
      for (final req in _requests) req.fail(error, stackTrace);
      return Future<HttpClientResponse>.error(error as Object, stackTrace);
    });
    return byteRangeRequest.future.then((response) {
      response.stream.listen((event) {}, onError: (Object e, StackTrace st) {
        _response = null;
        for (final req in _requests) req.fail(e, st);
      });
      return response;
    });
  }
}

// 其他类 _InProgressCacheResponse 和 _StreamingByteRangeRequest 保持原样
