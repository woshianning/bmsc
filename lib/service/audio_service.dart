import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/local_track.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/model/track.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/local_music_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/silent_audio.dart';
import 'package:bmsc/util/weighted_shuffle.dart';
import 'package:rxdart/rxdart.dart';

final _logger = LoggerUtils.getLogger('AudioService');

class AnchoredShuffleOrder extends ShuffleOrder {
  @override
  final indices = <int>[];

  final Random _random;
  int? _anchorAfter;
  bool _anchorFirstOnly = false;

  AnchoredShuffleOrder({Random? random}) : _random = random ?? Random();

  int Function(int playlistIndex)? weightOfIndex;

  int _weightOf(int playlistIndex) => weightOfIndex?.call(playlistIndex) ?? 1;

  void anchorAfter(int playlistIndex) => _anchorAfter = playlistIndex;

  void anchorFirstAfter(int playlistIndex) {
    _anchorAfter = playlistIndex;
    _anchorFirstOnly = true;
  }

  @override
  void shuffle({int? initialIndex}) {
    if (indices.length <= 1) return;
    final shuffled = weightedPermutation(indices, _weightOf, _random,
        initialIndex: initialIndex);
    indices
      ..clear()
      ..addAll(shuffled);
  }

  @override
  void insert(int index, int count) {
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) {
        indices[i] += count;
      }
    }
    final newIndices = List.generate(count, (i) => index + i);
    final anchor = _anchorAfter;
    final anchorFirst = _anchorFirstOnly;
    _anchorAfter = null;
    _anchorFirstOnly = false;
    if (anchor != null) {
      final pos = indices.indexOf(anchor);
      if (pos >= 0) {
        if (anchorFirst) {
          indices.insert(pos + 1, newIndices.first);
          for (final newIndex in newIndices.skip(1)) {
            indices.insert(
                weightedInsertionIndex(
                    indices, _weightOf(newIndex), _weightOf, _random),
                newIndex);
          }
        } else {
          indices.insertAll(pos + 1, newIndices);
        }
        return;
      }
    }
    for (final newIndex in newIndices) {
      indices.insert(
          weightedInsertionIndex(
              indices, _weightOf(newIndex), _weightOf, _random),
          newIndex);
    }
  }

  @override
  void removeRange(int start, int end) {
    final count = end - start;
    final oldIndices = List.generate(count, (i) => start + i).toSet();
    indices.removeWhere(oldIndices.contains);
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) {
        indices[i] -= count;
      }
    }
  }

  @override
  void clear() {
    indices.clear();
    _anchorAfter = null;
    _anchorFirstOnly = false;
  }
}

class AudioQualityInfo {
  final int id;
  final String label;
  final int? sizeBytes;
  final bool isCurrent;

  const AudioQualityInfo({
    required this.id,
    required this.label,
    required this.sizeBytes,
    required this.isCurrent,
  });
}

class AudioService {
  static final instance = _init();

  final AnchoredShuffleOrder _playlistShuffleOrder = AnchoredShuffleOrder();

  // ignore: deprecated_member_use
  late final ConcatenatingAudioSource playlist = ConcatenatingAudioSource(
    useLazyPreparation: true,
    children: [],
    shuffleOrder: _playlistShuffleOrder,
  );
  final player = AudioPlayer(
    handleInterruptions: false,
    audioLoadConfiguration: AudioLoadConfiguration(
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: const Duration(seconds: 3),
      ),
    ),
  );
  late AudioSession session;
  Timer? _historyReportTimer;
  Timer? _playPositionTimer;
  Timer? _sleepTimer;
  Timer? _fadeTimer;
  final _sleepTimerSubject = BehaviorSubject<int?>.seeded(null);
  final _fadeOutDuration = 15;
  final _speedSubject = BehaviorSubject<double>.seeded(1.0);
  static const _historyUpdateInterval = 5;
  int _historyUpdateCnt = 0;

  StreamSubscription<AudioInterruptionEvent>? _interruptionEventSubscription;
  bool _playInterrupted = false;
  bool _hijacking = false;
  double? _volumeBeforeDuck;
  double? _userVolumeBeforeFade;

  final Set<AudioSource> _watchdogUnwedgedSources = {};
  bool _needsTrackResync = false;
  Timer? _trackResyncTimer;
  IndexedAudioSource? _lastHandledCurrentSource;
  int _watchdogStallTicks = 0;

  Stream<int?> get sleepTimerStream => _sleepTimerSubject.stream;
  Stream<double> get speedStream => _speedSubject.stream;
  double get currentSpeed => _speedSubject.value;

  static Future<AudioService> _init() async {
    final x = AudioService();
    x._playlistShuffleOrder.weightOfIndex = x._weightOfPlaylistIndex;
    try {
      final restored = await SharedPreferencesService.getPlaylist();
      if (restored != null) {
        await x.playlist.addAll(restored.$1);
      }
      try {
        await x.player
            .setAudioSource(x.playlist, preload: x.playlist.children.isNotEmpty)
            .timeout(const Duration(seconds: 5));
      } on UnimplementedError catch (e) {
        if (e.toString().contains('setAutomaticallyWaitsToMinimizeStalling')) {
          _logger.warning(
              'AudioService._init: Windows setAutomaticallyWaitsToMinimizeStalling '
              '未实现，忽略并重试加载');
          try {
            await x.player
                .setAudioSource(x.playlist,
                    preload: x.playlist.children.isNotEmpty)
                .timeout(const Duration(seconds: 5));
          } catch (e2) {
            _logger
                .severe('AudioService._init: retry setAudioSource failed: $e2');
          }
        } else {
          rethrow;
        }
      } catch (e) {
        _logger
            .warning('AudioService._init: setAudioSource failed/timeout: $e');
      }

      final position = await SharedPreferencesService.getPlayPosition();
      if (restored != null && restored.$2 < x.playlist.length) {
        try {
          await x.player
              .seek(null, index: restored.$2)
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          _logger
              .warning('AudioService._init: seek index failed, skip restore');
        }
        try {
          await x.player.processingStateStream
              .firstWhere((s) => s == ProcessingState.ready)
              .timeout(Duration(seconds: Platform.isIOS ? 1 : 3),
                  onTimeout: () => ProcessingState.ready);
        } catch (e) {
          _logger.warning('AudioService._init: wait ready failed');
        }
        try {
          await x.player
              .seek(Duration(seconds: position))
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          _logger.warning('AudioService._init: seek position failed');
        }
      }
      await x.restorePlayMode();

      final sleepTimerMinutes =
          await SharedPreferencesService.getSleepTimerMinutes();
      if (sleepTimerMinutes != null) {
        if (sleepTimerMinutes > 0) {
          await x.setSleepTimer(sleepTimerMinutes);
        }
      }

      final speed = await SharedPreferencesService.getPlaybackSpeed();
      if (speed != null) {
        await x.setPlaybackSpeed(speed);
      }
    } catch (e) {
      _logger.severe('Failed to restore playlist', e);
    }
    try {
      x.session = await AudioSession.instance;
      await x.session.configure(const AudioSessionConfiguration.music());
      await x.hookEvents();
    } catch (e) {
      _logger.severe('AudioService._init: session setup failed', e);
    }
    DatabaseManager.cacheFileGuard = () async {
      final source = x.player.sequenceState.currentSource;
      if (source is LazyAudioSource && source.isLocal) {
        return {(await source.localFile).path};
      }
      return <String>{};
    };
    return x;
  }

  Future<int?> _fetchExactSize(Uri url) async {
    final client = HttpClient();
    try {
      final headers = (await BilibiliService.instance).headers;
      final request = await client.getUrl(url);
      headers?.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      int? total;
      if (response.statusCode == HttpStatus.partialContent) {
        final contentRange =
            response.headers.value(HttpHeaders.contentRangeHeader);
        if (contentRange != null && contentRange.contains('/')) {
          total = int.tryParse(contentRange.split('/').last);
        }
      } else if (response.statusCode == HttpStatus.ok &&
          response.contentLength > 0) {
        total = response.contentLength;
      }
      await response.drain();
      return total;
    } catch (e) {
      _logger.warning('fetch exact audio size failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  Future<List<AudioQualityInfo>?> getCurrentTrackQualities() async {
    final source = player.sequenceState.currentSource;
    if (source == null) return null;
    final tag = source.tag as MediaItem?;
    final extras = tag?.extras;
    if (tag == null || extras == null) return null;
    final bvid = extras['bvid'];
    final cid = extras['cid'];
    if (bvid == null) return null;
    final audios = await (await BilibiliService.instance).getAudio(bvid, cid);
    if (audios == null || audios.isEmpty) return null;
    final currentId = source is LazyAudioSource
        ? source.qualityId
        : extras['qualityId'] as int?;
    final seen = <int>{};
    final uniqueAudios = [
      for (final Audio a in audios)
        if (seen.add(a.id)) a,
    ];
    final sizes = await Future.wait(uniqueAudios.map((a) => a.baseUrl.isNotEmpty
        ? _fetchExactSize(Uri.parse(a.baseUrl))
        : Future<int?>.value()));
    final infos = [
      for (var i = 0; i < uniqueAudios.length; i++)
        AudioQualityInfo(
          id: uniqueAudios[i].id,
          label:
              SharedPreferencesService.audioQualityLabels[uniqueAudios[i].id] ??
                  '未知音质 (${uniqueAudios[i].id})',
          sizeBytes: sizes[i],
          isCurrent: uniqueAudios[i].id == currentId,
        ),
    ];
    infos.sort((a, b) => (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1));
    return infos;
  }

  Future<bool> switchCurrentTrackQuality(int qualityId) async {
    final index = player.currentIndex;
    final source = player.sequenceState.currentSource;
    if (source == null || index == null) return false;

    final tag = source.tag as MediaItem?;
    final extras = tag?.extras;
    if (tag == null || extras == null) return false;
    final bvid = extras['bvid'];
    final cid = extras['cid'];
    if (bvid == null || cid == null) return false;
    if (_hijacking) {
      _logger.warning('quality switch: playlist mutation in progress, reject');
      return false;
    }

    _hijacking = true;
    try {
      await SharedPreferencesService.setAudioQuality(qualityId);

      final position = player.position;
      final wasPlaying = player.playing;
      await player.pause();

      if (source is LazyAudioSource) {
        await source.cancelDownload();
      }
      await DatabaseManager.removeCacheEntry(bvid, cid, force: true);

      final curIdx = _indexOfInPlaylist(source);
      if (curIdx == null ||
          !identical(player.sequenceState.currentSource, source)) {
        _logger.warning('quality switch: source no longer current, abort');
        return false;
      }

      final newSource = LazyAudioSource(
        bvid,
        cid,
        localFile: null,
        tag: MediaItem(
          id: tag.id,
          title: tag.title,
          artist: tag.artist,
          artUri: tag.artUri,
          duration: tag.duration,
          extras: {...extras, 'cached': false},
        ),
      );

      _playlistShuffleOrder.anchorAfter(curIdx);
      await doAndSavePlaylist(() async {
        await playlist.insertAll(curIdx + 1, [newSource]);
      });
      final insertIdx = _indexOfInPlaylist(newSource);
      if (insertIdx != null) {
        try {
          await player
              .seek(position, index: insertIdx)
              .timeout(const Duration(seconds: 5));
        } catch (e) {
          _logger.warning('quality switch seek failed: $e');
        }
        if (wasPlaying) await player.play();
      } else {
        _logger.warning('quality switch: new source vanished from playlist');
      }

      await doAndSavePlaylist(() async {
        final oldIdx = _indexOfInPlaylist(source);
        if (oldIdx != null) {
          await playlist.removeAt(oldIdx);
        }
      });
    } finally {
      _hijacking = false;
    }
    _logger.info('Switched quality to $qualityId for $bvid:$cid');
    return true;
  }

  int _weightOfPlaylistIndex(int playlistIndex) {
    final children = playlist.children;
    if (playlistIndex < 0 || playlistIndex >= children.length) return 1;
    return 1;
  }

  Future<void> restorePlayMode() async {
    final mode = await SharedPreferencesService.getPlayMode();
    if (mode == 3) {
      await player.setLoopMode(LoopMode.all);
      await player.setShuffleModeEnabled(true);
    } else {
      await player.setLoopMode(LoopMode.values[mode]);
      await player.setShuffleModeEnabled(false);
    }
  }

  Future<void> setInterrupHandler(bool value) async {
    if (value) {
      await _interruptionEventSubscription?.cancel();
      _interruptionEventSubscription =
          session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (session.androidAudioAttributes?.usage ==
                  AndroidAudioUsage.game) {
                _volumeBeforeDuck ??= player.volume;
                player.setVolume(player.volume / 2);
              }
              _playInterrupted = false;
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (player.playing) {
                player.pause();
                _playInterrupted = true;
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              final volumeBeforeDuck = _volumeBeforeDuck;
              _volumeBeforeDuck = null;
              if (volumeBeforeDuck != null) {
                player.setVolume(min(1.0, volumeBeforeDuck));
              }
              _playInterrupted = false;
              break;
            case AudioInterruptionType.pause:
              if (_playInterrupted) player.play();
              _playInterrupted = false;
              break;
            case AudioInterruptionType.unknown:
              _playInterrupted = false;
              break;
          }
        }
      });
    } else {
      await _interruptionEventSubscription?.cancel();
    }
  }

  Future<void> hookEvents() async {
    try {
      setInterrupHandler(
          await SharedPreferencesService.getReactToInterruption());
      session.becomingNoisyEventStream.listen((_) {
        player.pause();
      });
    } catch (e) {
      _logger.warning('session events not bound: $e');
    }

    player.playbackEventStream.listen((event) {
      if (event.errorCode != null || event.errorMessage != null) {
        _logger.severe(
            'player error: code=${event.errorCode}, message=${event.errorMessage}');
      }
    });

    Rx.combineLatest2(player.loopModeStream, player.shuffleModeEnabledStream,
        (a, b) => (a, b)).listen((data) async {
      final (loopMode, shuffleModeEnabled) = data;

      if (shuffleModeEnabled) {
        await SharedPreferencesService.setPlayMode(3);
      } else {
        await SharedPreferencesService.setPlayMode(
            LoopMode.values.indexOf(loopMode));
      }
    });

    player.currentIndexStream.listen((index) async {
      if (index == null) return;
      if (_hijacking) {
        _needsTrackResync = true;
        _scheduleTrackResync();
        return;
      }
      _onTrackIndexChanged(index);
      final prefs = await SharedPreferencesService.instance;
      await prefs.setInt('currentIndex', index);
    });

    player.playerStateStream.listen((state) async {
      final enableHistoryReport =
          await SharedPreferencesService.getHistoryReported();
      if (state.playing) {
        if (enableHistoryReport) {
          _startCloudHistoryReporting();
        }
        _startPlayPositionSaving();
      } else {
        _stopHistoryReporting();
        _stopPlayPositionSaving();
      }
    });

    if (Platform.isIOS) {
      Timer.periodic(const Duration(seconds: 5), (_) {
        if (_watchdogUnwedgedSources.isNotEmpty) {
          final seq = playlist.sequence;
          _watchdogUnwedgedSources
              .removeWhere((s) => !seq.any((e) => identical(e, s)));
        }
        if (!player.playing) {
          _watchdogStallTicks = 0;
          return;
        }
        final source = player.sequenceState.currentSource;
        final extras = (source?.tag as MediaItem?)?.extras;
        if (source == null || extras == null || source is! LazyAudioSource) {
          _watchdogStallTicks = 0;
          return;
        }
        if (player.position > Duration.zero) {
          _watchdogStallTicks = 0;
          _watchdogUnwedgedSources.remove(source);
          return;
        }
        _watchdogStallTicks++;
        if (_watchdogStallTicks >= 4 &&
            !_watchdogUnwedgedSources.contains(source)) {
          _watchdogStallTicks = 0;
          final idx = player.currentIndex;
          _logger.warning(
              'watchdog: playing but stuck at 0 for 20s, replace source at index=$idx');
          if (idx != null) {
            _unwedgeCurrentSourceIOS(idx, source);
          }
        }
      });
    }
  }

  void _scheduleTrackResync() {
    if (_trackResyncTimer?.isActive ?? false) return;
    _trackResyncTimer = Timer(const Duration(milliseconds: 200), () {
      _trackResyncTimer = null;
      if (_hijacking) {
        _scheduleTrackResync();
        return;
      }
      if (!_needsTrackResync) return;
      _needsTrackResync = false;
      final index = player.currentIndex;
      if (index == null) return;
      _logger.info('track resync after playlist mutation: index=$index');
      _onTrackIndexChanged(index);
      unawaited(SharedPreferencesService.instance
          .then((prefs) => prefs.setInt('currentIndex', index)));
    });
  }

  Future<void> _unwedgeCurrentSourceIOS(int index, AudioSource source) async {
    if (source is! LazyAudioSource) return;
    if (_hijacking) return;
    _hijacking = true;
    try {
      final tag = source.tag as MediaItem?;
      if (tag == null) return;
      final extras = tag.extras;
      final bvid = extras?['bvid'];
      final cid = extras?['cid'];
      if (bvid == null) return;
      final position = player.position;
      final wasPlaying = player.playing;
      await source.cancelDownload();
      final file = await source.localFile;
      final curIdx = _indexOfInPlaylist(source);
      if (curIdx == null ||
          !identical(player.sequenceState.currentSource, source)) {
        _logger.warning('watchdog: source no longer current, abort unwedge');
        return;
      }
      _watchdogUnwedgedSources.add(source);
      final fresh = LazyAudioSource(
        bvid,
        cid ?? 0,
        localFile: file.existsSync() ? file : null,
        tag: tag,
      );
      _watchdogUnwedgedSources.add(fresh);
      try {
        _playlistShuffleOrder.anchorAfter(curIdx);
        await doAndSavePlaylist(() async {
          await playlist.insertAll(curIdx + 1, [fresh]);
        });
        final insertIdx = _indexOfInPlaylist(fresh);
        if (insertIdx != null) {
          try {
            await player
                .seek(position, index: insertIdx)
                .timeout(const Duration(seconds: 5));
          } catch (e) {
            _logger.warning('watchdog unwedge seek failed: $e');
          }
          if (wasPlaying) await player.play();
        } else {
          _logger.warning('watchdog: fresh source vanished from playlist');
        }
        await doAndSavePlaylist(() async {
          final oldIdx = _indexOfInPlaylist(source);
          if (oldIdx != null) await playlist.removeAt(oldIdx);
        });
      } catch (e) {
        _logger.warning('watchdog unwedge failed: $e');
      }
    } finally {
      _hijacking = false;
    }
  }

  void _startCloudHistoryReporting() async {
    _historyReportTimer?.cancel();
    final interval = await SharedPreferencesService.getReportHistoryInterval();
    _historyReportTimer =
        Timer.periodic(Duration(seconds: interval), (timer) async {
      final currentSource = player.sequenceState.currentSource;
      if (currentSource == null || !player.playing) {
        return;
      }

      final extras = (currentSource.tag as MediaItem?)?.extras;
      if (extras == null || extras['aid'] == null || extras['cid'] == null) {
        return;
      }

      final length = currentSource.duration?.inSeconds;

      if (await SharedPreferencesService.getHistoryReported()) {
        await (await BilibiliService.instance).reportHistory(
            extras['aid'],
            extras['cid'],
            length != null && length - player.position.inSeconds <= interval
                ? length
                : player.position.inSeconds);
      }
    });
  }

  void _stopHistoryReporting() {
    _historyReportTimer?.cancel();
    _historyReportTimer = null;
  }

  void _startPlayPositionSaving() {
    _playPositionTimer?.cancel();
    _playPositionTimer = Timer.periodic(
        const Duration(seconds: _historyUpdateInterval), (timer) async {
      final currentSource = player.sequenceState.currentSource;
      if (currentSource == null || !player.playing) {
        return;
      }

      final extras = (currentSource.tag as MediaItem?)?.extras;
      if (extras == null) {
        return;
      }
      if (extras['local'] == true) {
        _historyUpdateCnt++;
        unawaited(DatabaseManager.updatePlayStat(currentSource.tag.id,
            _historyUpdateCnt == 1 ? 1 : 0, _historyUpdateInterval));
        await SharedPreferencesService.setPlayPosition(
            player.position.inSeconds);
        return;
      }
      if (extras['aid'] == null || extras['cid'] == null) {
        return;
      }

      _logger.info('saving play position: ${player.position.inSeconds}');

      _historyUpdateCnt++;
      DatabaseManager.updatePlayStat(extras['bvid'],
          _historyUpdateCnt == 1 ? 1 : 0, _historyUpdateInterval,
          cid: extras['cid'] as int?);
      await SharedPreferencesService.setPlayPosition(player.position.inSeconds);
    });
  }

  void _stopPlayPositionSaving() {
    _playPositionTimer?.cancel();
    _playPositionTimer = null;
  }

  Future<void> setSleepTimer(int? minutes, {DateTime? specificTime}) async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;

    final userVolume = _userVolumeBeforeFade;
    _userVolumeBeforeFade = null;
    if (userVolume != null) {
      await player.setVolume(userVolume);
    }

    await SharedPreferencesService.setSleepTimerMinutes(minutes);

    if (minutes == null && specificTime == null) {
      _sleepTimerSubject.add(null);
      return;
    }

    int durationInSeconds;

    if (specificTime != null) {
      final now = DateTime.now();
      final difference = specificTime.difference(now);

      if (difference.isNegative) {
        _sleepTimerSubject.add(null);
        return;
      }

      durationInSeconds = difference.inSeconds;
      await SharedPreferencesService.setSleepTimerMinutes(
          durationInSeconds ~/ 60);
    } else {
      durationInSeconds = minutes! * 60;
    }

    _sleepTimerSubject.add(durationInSeconds);
    _userVolumeBeforeFade = player.volume;
    final deadline = DateTime.now().add(Duration(seconds: durationInSeconds));

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remainingSeconds = deadline.difference(DateTime.now()).inSeconds;

      if (remainingSeconds <= 0) {
        player.pause();
        _sleepTimer?.cancel();
        _sleepTimer = null;
        _fadeTimer?.cancel();
        _fadeTimer = null;
        _sleepTimerSubject.add(null);
        SharedPreferencesService.setSleepTimerMinutes(null);
        final userVolume = _userVolumeBeforeFade;
        _userVolumeBeforeFade = null;
        player.setVolume(userVolume ?? 1.0);
      } else if (remainingSeconds <= _fadeOutDuration && _fadeTimer == null) {
        _startFadeOut(remainingSeconds);
      } else {
        _sleepTimerSubject.add(remainingSeconds);
      }
    });
  }

  void _startFadeOut(int remainingSeconds) {
    final startVolume = player.volume;
    final volumeStep = startVolume / remainingSeconds;

    _fadeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timer.tick >= remainingSeconds) {
        _fadeTimer?.cancel();
        _fadeTimer = null;
        return;
      }
      final newVolume = startVolume - (volumeStep * timer.tick);
      player.setVolume(newVolume.clamp(0.0, 1.0));
    });
  }

  int? get sleepTimerRemainingSeconds => _sleepTimerSubject.valueOrNull;

  int? _indexOfInPlaylist(Object? source) {
    if (source == null) return null;
    final seq = playlist.sequence;
    for (var i = 0; i < seq.length; i++) {
      if (identical(seq[i], source)) return i;
    }
    return null;
  }

  void _onTrackIndexChanged(int index) {
    final seq = playlist.sequence;
    if (index >= seq.length) return;
    final source = seq[index];
    final extras = (source.tag as MediaItem?)?.extras;
    if (extras == null) return;
    final isCurrentChanged = !identical(source, _lastHandledCurrentSource);
    if (extras['bvid'] != null && extras['cid'] != null) {
      if (isCurrentChanged) {
        _lastHandledCurrentSource = source;
        unawaited(
            DatabaseManager.updatePlayStats(extras['bvid'], extras['cid']));
        _logger.info(
            'update play stats for bvid: ${extras['bvid']} cid: ${extras['cid']}');
      }
    }
    if (isCurrentChanged) {
      _historyUpdateCnt = 0;
    }
  }

  Future<bool> _waitMutationFree(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_hijacking) {
      if (DateTime.now().isAfter(deadline)) {
        _logger.warning('wait for playlist mutation lock timed out');
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  Future<void> playByBvid(String bvid, {int? preferCid}) async {
    _logger.info('Playing by BVID: $bvid (preferCid: $preferCid)');
    await player.pause();
    List<IndexedAudioSource>? srcs;
    try {
      srcs = await (await BilibiliService.instance).getAudios(bvid);
    } catch (e) {
      _logger.warning('Failed to get audio sources: $e');
      srcs = await DatabaseManager.getLocalAudioList(bvid);
    }
    if (srcs == null) {
      _logger.warning('No audio sources found for BVID: $bvid');
      return;
    }
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }

    final idx = await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);
    if (idx != null) {
      if (!await _waitMutationFree()) return;
      _hijacking = true;
      try {
        int target = idx;
        if (preferCid != null) {
          final i = playlist.children.indexWhere((c) =>
              c is IndexedAudioSource &&
              c.tag is MediaItem &&
              (c.tag as MediaItem).extras?['bvid'] == bvid &&
              (c.tag as MediaItem).extras?['cid'] == preferCid);
          if (i >= 0) {
            target = i;
            _logger.info('Located to part cid=$preferCid at index $i');
          }
        }
        await player.seek(Duration.zero, index: target);
      } finally {
        _hijacking = false;
      }
    }
    await player.play();
  }

  Future<void> playByBvids(List<String> bvids, {int index = 0}) async {
    if (bvids.isEmpty) return;

    await player.pause();
    if (!await _waitMutationFree()) return;
    _hijacking = true;

    var targetIndex = 0;
    try {
      final metas = await DatabaseManager.getMetas(bvids);
      final srcs = <IndexedAudioSource>[];

      for (var i = 0; i < metas.length; i++) {
        if (i == index) targetIndex = srcs.length;
        final meta = metas[i];

        // ✅ 瞬间查询本地缓存，有缓存直接构建，无缓存生成 LazyAudioSource
        final cachedSrcs = await DatabaseManager.getLocalAudioList(meta.bvid);
        if (cachedSrcs != null && cachedSrcs.isNotEmpty) {
          srcs.addAll(cachedSrcs);
        } else {
          // ✅ 彻底废弃静音占位符，直接使用真实的网络流。这能保证自动切歌时直接边下边播，不会出现静音或卡顿。
          srcs.add(LazyAudioSource(
            meta.bvid,
            0, // 0 代表自动获取第一个音频源
            localFile: null,
            tag: MediaItem(
              id: meta.bvid,
              title: meta.title,
              artUri: Uri.tryParse(meta.artUri),
              artist: meta.artist,
              duration: Duration(seconds: meta.duration),
              extras: {'bvid': meta.bvid},
            ),
          ));
        }
      }

      if (targetIndex >= srcs.length) targetIndex = 0;

      await doAndSavePlaylist(() async {
        await playlist.clear();
        await playlist.addAll(srcs);
      });

      await player.seek(Duration.zero, index: targetIndex);
    } finally {
      _hijacking = false;
    }

    // ✅ 直接开始播放，不需要任何等待或特殊的 autoPlay 逻辑
    await player.play();
  }

  Future<void> playLocalAudio(String bvid, int cid) async {
    await player.pause();
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    final idx = await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);

    if (idx != null) {
      if (!await _waitMutationFree()) return;
      _hijacking = true;
      try {
        await player.seek(Duration.zero, index: idx);
      } finally {
        _hijacking = false;
      }
    }
    await player.play();
  }

  Future<void> addToPlaylistCachedAudio(String bvid, int cid) async {
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);
  }

  Future<void> playLocalTracks(List<LocalTrack> tracks,
      {int index = 0, bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    if (shuffle) {
      index = Random().nextInt(tracks.length);
    }
    _logger.info(
        'Playing ${tracks.length} local tracks from index $index (shuffle=$shuffle)');
    final srcs = tracks.map(LocalMusicService.buildSource).toList();
    await player.pause();
    if (!await _waitMutationFree()) return;
    _hijacking = true;
    try {
      await doAndSavePlaylist(() async {
        await playlist.clear();
        await playlist.addAll(srcs);
      });
      if (index >= srcs.length) index = 0;
      await player.seek(Duration.zero, index: index);
      if (index < srcs.length &&
          !identical(player.sequenceState.currentSource, srcs[index])) {
        try {
          await player.processingStateStream
              .firstWhere((s) => s == ProcessingState.ready)
              .timeout(const Duration(seconds: 5));
          await player.seek(Duration.zero, index: index);
        } catch (e) {
          _logger.warning('playLocalTracks retry seek failed: $e');
        }
      }
    } finally {
      _hijacking = false;
    }
    if (shuffle) {
      await player.setLoopMode(LoopMode.all);
      await player.setShuffleModeEnabled(true);
    }
    await player.play();
  }

  Future<void> playLocalTrackById(int localId) async {
    final track = await DatabaseManager.getLocalTrackById(localId);
    if (track == null) {
      _logger.warning('local track $localId missing, prune its play stat');
      await DatabaseManager.removePlayStat('local_$localId');
      return;
    }
    await playLocalTracks([track]);
  }

  Future<void> appendLocalTracks(List<LocalTrack> tracks) async {
    if (tracks.isEmpty) return;
    final srcs = tracks.map(LocalMusicService.buildSource).toList();
    await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);
  }

  Future<void> appendPlaylist(String bvid,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    final srcs = await (await BilibiliService.instance).getAudios(bvid);
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }
    if (srcs == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: insertIndex, extraExtras: extraExtras);
  }

  Future<void> appendCachedPlaylist(String bvid,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    final srcs = await DatabaseManager.getLocalAudioList(bvid);
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }
    if (srcs == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: insertIndex, extraExtras: extraExtras);
  }

  Future<void> doAndSavePlaylist(Future<void> Function() func) async {
    await func();
    await SharedPreferencesService.savePlaylist(
        playlist, player.currentIndex ?? 0);
  }

  Future<bool> mutatePlaylist(Future<void> Function() func) async {
    final lockAcquired = await _waitMutationFree();
    if (!lockAcquired) {
      _logger.warning('mutation timeout, aborting playlist mutation');
      return false;
    }
    _hijacking = true;
    try {
      await doAndSavePlaylist(func);
      return true;
    } finally {
      _hijacking = false;
    }
  }

  static bool _isSameMedia(MediaItem a, MediaItem b) {
    final aLocal = a.extras?['local'] == true;
    final bLocal = b.extras?['local'] == true;
    if (aLocal || bLocal) {
      return aLocal &&
          bLocal &&
          a.extras?['filePath'] != null &&
          a.extras?['filePath'] == b.extras?['filePath'];
    }
    return a.extras?['bvid'] != null &&
        a.extras?['bvid'] == b.extras?['bvid'] &&
        a.extras?['cid'] == b.extras?['cid'];
  }

  Future<int?> _addUniqueSourcesToPlaylist(List<IndexedAudioSource> sources,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    int? ret;
    final uniqueSources = <IndexedAudioSource>[];
    if (!await _waitMutationFree()) {
      _logger.warning('mutation timeout, aborting addUniqueSources');
      return null;
    }
    _hijacking = true;
    try {
      for (var source in sources) {
        if (source.tag is! MediaItem) {
          continue;
        }
        final mediaItem = source.tag as MediaItem;
        final duplicatePos = playlist.children.indexWhere((child) =>
            child is IndexedAudioSource &&
            child.tag is MediaItem &&
            _isSameMedia(child.tag as MediaItem, mediaItem));
        final pendingPos = uniqueSources.indexWhere((child) =>
            child.tag is MediaItem &&
            _isSameMedia(child.tag as MediaItem, mediaItem));

        if (duplicatePos == -1 && pendingPos == -1) {
          if (extraExtras != null) {
            mediaItem.extras?.addAll(extraExtras);
          }
          uniqueSources.add(source);
          ret ??= insertIndex != null
              ? insertIndex + uniqueSources.length - 1
              : playlist.length + uniqueSources.length - 1;
        } else if (duplicatePos != -1) {
          ret = duplicatePos;
        } else {
          ret ??= insertIndex != null
              ? insertIndex + pendingPos
              : playlist.length + pendingPos;
        }
      }
      if (uniqueSources.isNotEmpty) {
        final index = insertIndex;
        await doAndSavePlaylist(() async {
          if (index != null) {
            await playlist.insertAll(index, uniqueSources);
          } else {
            await playlist.addAll(uniqueSources);
          }
        });
      }
    } finally {
      _hijacking = false;
    }
    return ret;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (speed < 0.25 || speed > 3.0) {
      return;
    }

    await player.setSpeed(speed);
    _speedSubject.add(speed);
    await SharedPreferencesService.setPlaybackSpeed(speed);
    _logger.info('Playback speed set to: $speed');
  }
}
