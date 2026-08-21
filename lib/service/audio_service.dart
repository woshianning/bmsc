import 'dart:math';
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/util/logger.dart';
import 'package:rxdart/rxdart.dart';

final _logger = LoggerUtils.getLogger('AudioService');

class AudioService {
  static final instance = _init();

  // ignore: deprecated_member_use
  final playlist = ConcatenatingAudioSource(
    useLazyPreparation: true,
    children: [],
  );
  final player = AudioPlayer(handleInterruptions: false);
  AudioSession? session;
  Timer? _historyReportTimer;
  Timer? _playPositionTimer;
  Timer? _sleepTimer;
  Timer? _fadeTimer;
  final _sleepTimerSubject = BehaviorSubject<int?>.seeded(null);
  final _fadeOutDuration = 15; // 15 seconds fade out
  final _speedSubject = BehaviorSubject<double>.seeded(1.0);
  static const _historyUpdateInterval = 5; // 5s
  int _historyUpdateCnt = 0;

  StreamSubscription<AudioInterruptionEvent>? _interruptionEventSubscription;
  bool _playInterrupted = false;
  bool _hijacking = false;

  // 获取定时停止播放的流
  Stream<int?> get sleepTimerStream => _sleepTimerSubject.stream;

  // 获取播放速度的流
  Stream<double> get speedStream => _speedSubject.stream;

  // 获取当前播放速度
  double get currentSpeed => _speedSubject.value;

  static Future<AudioService> _init() async {
    final x = AudioService();
    _logger.info('AudioService initialization started');
    try {
      final restored = await SharedPreferencesService.getPlaylist();
      _logger.info('AudioService playlist preferences loaded');
      if (restored != null) {
        await x.playlist.addAll(restored.$1);
      }
      if (x.playlist.children.isNotEmpty) {
        _logger.info('Setting restored audio source');
        await x.player.setAudioSource(x.playlist);
      }
      _logger.info('Audio source initialization finished');
      final position = await SharedPreferencesService.getPlayPosition();
      _logger.info('Restored play position: $position');
      if (restored != null && restored.$2 < x.playlist.length) {
        _logger.info('Restoring playlist index: ${restored.$2}');
        try {
          await x.player
              .seek(null, index: restored.$2)
              .timeout(const Duration(seconds: 3));
          await Future.delayed(const Duration(milliseconds: 100));
          await x.player
              .seek(Duration(seconds: position))
              .timeout(const Duration(seconds: 3));
          _logger.info('Restored playlist position');
        } on TimeoutException {
          _logger.warning('Skipping playlist position restore after timeout');
        }
      }
      _logger.info('Restoring play mode');
      await x.restorePlayMode();
      _logger.info('Restored play mode');

      // 恢复定时停止播放设置
      final sleepTimerMinutes =
          await SharedPreferencesService.getSleepTimerMinutes();
      if (sleepTimerMinutes != null && sleepTimerMinutes > 0) {
        _logger.info('Restoring sleep timer: $sleepTimerMinutes');
        await x.setSleepTimer(sleepTimerMinutes);
      }

      // 恢复播放速度设置
      final speed = await SharedPreferencesService.getPlaybackSpeed();
      if (speed != null) {
        _logger.info('Restoring playback speed: $speed');
        await x.setPlaybackSpeed(speed);
      }
      _logger.info('Playback preferences restored');
    } catch (e) {
      _logger.severe('Failed to restore playlist', e);
    }

    // 尝试初始化 AudioSession（macOS 不支持会抛异常，捕获后继续）
    try {
      _logger.info('Initializing AudioSession');
      x.session = await AudioSession.instance;
      await x.session!.configure(const AudioSessionConfiguration.music());
      _logger.info('AudioSession initialization finished');
    } catch (e) {
      _logger.warning('AudioSession not supported on this platform (skip).');
      // 保证 session 为 null 以便后续判空
    }

    // 无论 session 是否成功，都绑定事件（内部监听始终可用）
    _logger.info('Binding audio player events');
    await x.hookEvents();
    _logger.info('AudioService initialization finished');
    return x;
  }

  UriAudioSource getDummyAudioSource(Meta x) {
    final silenceUri = Uri(scheme: 'asset', path: '/assets/silent.m4a');
    return AudioSource.uri(silenceUri,
        tag: MediaItem(
            id: x.bvid,
            title: x.title,
            artUri: Uri.http(x.artUri.substring(7, 19), x.artUri.substring(19)),
            artist: x.artist,
            duration: Duration(seconds: x.duration),
            extras: {'dummy': true}));
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
      _interruptionEventSubscription =
          session!.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
                if (session!.androidAudioAttributes?.usage ==
                  AndroidAudioUsage.game) {
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
              player.setVolume(min(1.0, player.volume * 2));
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

  // 绑定所有事件（外部系统事件 + 播放器内部事件）
  Future<void> hookEvents() async {
    // 仅当 session 有效时绑定系统级事件（macOS 上 session 为 null 则跳过）
    if (session != null) {
      setInterrupHandler(await SharedPreferencesService.getReactToInterruption());

      session!.becomingNoisyEventStream.listen((_) {
        player.pause();
      });
    }

    // 播放器内部事件始终绑定（不依赖 session）
    _bindPlayerInternalEvents();
  }

  // 播放器内部状态监听（循环模式、当前索引、播放状态等）
  void _bindPlayerInternalEvents() {
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
      if (index != null) {
        final prefs = await SharedPreferencesService.instance;
        await prefs.setInt('currentIndex', index);
        await _hijackDummySource(index: index);
      }
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

      if (state.processingState == ProcessingState.ready) {
        final index = player.currentIndex;
        if (index == null) {
          return;
        }
        if (state.playing == false) {
          return;
        }
        _historyUpdateCnt = 0;
      }
    });

    player.errorStream.listen((error) {
      _logger.severe('Audio playback error: ${error.message}', error);
    });
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

      final extras = currentSource.tag.extras;
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

      final extras = currentSource.tag.extras;
      if (extras == null || extras['aid'] == null || extras['cid'] == null) {
        return;
      }

      _logger.info('saving play position: ${player.position.inSeconds}');

      _historyUpdateCnt++;
      DatabaseManager.updatePlayStat(extras['bvid'],
          _historyUpdateCnt == 1 ? 1 : 0, _historyUpdateInterval);
      await SharedPreferencesService.setPlayPosition(player.position.inSeconds);
    });
  }

  void _stopPlayPositionSaving() {
    _playPositionTimer?.cancel();
    _playPositionTimer = null;
  }

  // 设置定时停止播放
  Future<void> setSleepTimer(int? minutes, {DateTime? specificTime}) async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;

    await player.setVolume(1);

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

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remainingSeconds = durationInSeconds - timer.tick;

      if (remainingSeconds <= 0) {
        player.pause();
        _sleepTimer?.cancel();
        _sleepTimer = null;
        _fadeTimer?.cancel();
        _fadeTimer = null;
        _sleepTimerSubject.add(null);
        SharedPreferencesService.setSleepTimerMinutes(null);
        player.setVolume(1);
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

  Future<void> _hijackDummySource({int? index}) async {
    if (_hijacking) {
      return;
    }
    index ??= player.currentIndex;
    if (index == null) {
      _logger.warning('No current index available for hijacking');
      return;
    }
    final currentIndex = index;
    if (index >= playlist.length) {
      return;
    }

    final currentSource = playlist.sequence[index];

    final extras = currentSource.tag.extras;
    if (extras == null) {
      return;
    }
    if (extras['dummy'] != true) {
      if (extras['bvid'] != null && extras['cid'] != null) {
        await DatabaseManager.updatePlayStats(extras['bvid'], extras['cid']);
        _logger.info(
            'update play stats for bvid: ${extras['bvid']} cid: ${extras['cid']}');
      }
      return;
    }
    _logger.info('Hijacking dummy source for index: $index');
    _hijacking = true;

    List<IndexedAudioSource>? srcs;
    try {
      srcs = await (await BilibiliService.instance)
          .getAudios(currentSource.tag.id);
    } catch (e) {
      _logger.warning('Failed to get audio sources: $e');
      srcs = await DatabaseManager.getLocalAudioList(currentSource.tag.id);
    }
    final excludedCids =
        await DatabaseManager.getExcludedParts(currentSource.tag.id);
    for (var cid in excludedCids) {
      srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }
    if (srcs == null) {
      _logger
          .warning('No audio sources found for BVID: ${currentSource.tag.id}');
      if (player.loopMode != LoopMode.one &&
          player.currentIndex != null &&
          player.currentIndex! < playlist.length - 1) {
        await player.seekToNext();
        await player.play();
      }
      _hijacking = false;
      return;
    }
    await doAndSavePlaylist(() async {
      final isShuffle = player.shuffleModeEnabled;
      if (isShuffle) {
        await player.setShuffleModeEnabled(false);
      }
      await playlist.insertAll(currentIndex + 1, srcs!);
      if (player.loopMode == LoopMode.one) {
        await player.seek(Duration.zero, index: currentIndex + 1);
      }
      await playlist.removeAt(currentIndex);
      if (isShuffle) {
        await player.setShuffleModeEnabled(true);
      }
    });
    _hijacking = false;
  }

  Future<void> playByBvid(String bvid) async {
    _logger.info('Playing by BVID: $bvid');
    await player.pause();
    final srcs = await (await BilibiliService.instance).getAudios(bvid);
    if (srcs == null) {
      _logger.warning('No audio sources found for BVID: $bvid');
      return;
    }
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }

    final idx = await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: playlist.length == 0 ? 0 : player.currentIndex! + 1);
    if (idx != null) {
      await player.seek(Duration.zero, index: idx);
    }
    await player.play();
  }

  Future<void> playByBvids(List<String> bvids, {int index = 0}) async {
    if (bvids.isEmpty) {
      return;
    }
    try {
      _logger.info('Preparing ${bvids.length} tracks for index $index');
      final metas = await DatabaseManager.getMetas(bvids);
      final srcs = metas.map(getDummyAudioSource).toList();
      await player.pause();
      _hijacking = true;
      await doAndSavePlaylist(() async {
        await playlist.clear();
        await playlist.addAll(srcs);
      });
      _hijacking = false;
      await player.setAudioSource(playlist);
      await _hijackDummySource(index: index);
      await player.seek(Duration.zero, index: index);
      await player.play();
      _logger.info('playByBvids done');
    } catch (e, stackTrace) {
      _hijacking = false;
      _logger.severe('Failed to play track list', e, stackTrace);
    }
  }

  Future<void> playLocalAudio(String bvid, int cid) async {
    await player.pause();
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    final idx = await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: playlist.length == 0 ? 0 : player.currentIndex! + 1);

    if (idx != null) {
      await player.seek(Duration.zero, index: idx);
    }
    await player.play();
  }

  Future<void> addToPlaylistCachedAudio(String bvid, int cid) async {
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: playlist.length == 0 ? 0 : player.currentIndex! + 1);
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
    SharedPreferencesService.savePlaylist(playlist, player.currentIndex ?? 0);
  }

  Future<int?> _addUniqueSourcesToPlaylist(List<IndexedAudioSource> sources,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    int? ret;
    for (var source in sources) {
      if (source.tag is MediaItem) {
        var mediaItem = source.tag as MediaItem;
        var duplicatePos = playlist.children.indexWhere((child) {
          if (child is IndexedAudioSource && child.tag is MediaItem) {
            return (child.tag as MediaItem).id == mediaItem.id;
          }
          return false;
        });

        if (duplicatePos == -1) {
          if (extraExtras != null) {
            mediaItem.extras?.addAll(extraExtras);
          }
          if (insertIndex != null) {
            await doAndSavePlaylist(() async {
              await playlist.insert(insertIndex!, source);
            });
            ret ??= insertIndex;
            insertIndex++;
          } else {
            await doAndSavePlaylist(() async {
              await playlist.add(source);
            });
            ret ??= playlist.length - 1;
          }
        } else {
          ret = duplicatePos;
        }
      }
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