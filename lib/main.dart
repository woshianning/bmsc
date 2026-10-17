import 'dart:async';
import 'dart:io';

import 'package:bmsc/component/track_tile.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/vid.dart';
import 'package:bmsc/screen/dynamic_screen.dart';
import 'package:bmsc/screen/fav_screen.dart';
import 'package:bmsc/screen/local_history_screen.dart';
import 'package:bmsc/screen/recognition_screen.dart';
import 'package:bmsc/service/audio_service.dart' as app_audio;
import 'package:bmsc/audio/just_audio_background_custom.dart';
import 'package:bmsc/service/overlay_recognition.dart';
import 'package:bmsc/service/section_habit_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/service/stats_service.dart';
import 'package:bmsc/service/update_service.dart';
import 'package:bmsc/util/url.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/screen/search_screen.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'component/playing_card.dart';
import 'package:flutter/foundation.dart';
import 'util/error_handler.dart';
import 'screen/about_screen.dart';
import 'util/logger.dart';
import 'util/whats_new.dart';
import 'package:bmsc/screen/settings_screen.dart';
import 'package:bmsc/theme.dart';

import 'util/string.dart';
// ✅ 引入 sqflite 的 FFI 实现，用于 Windows/Linux/macOS 桌面端
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ✅ 引入 just_audio 平台接口，用于在 Windows 上绕过不支持的 API
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:just_audio_platform_interface/method_channel_just_audio.dart';

final _logger = LoggerUtils.getLogger('main');

/// ✅ 自定义的 AudioPlayerPlatform，继承自 MethodChannelAudioPlayer，
///    并重写 setAutomaticallyWaitsToMinimizeStalling 方法，使其在 Windows 上变为空操作。
class WindowsAudioPlayerPlatform extends MethodChannelAudioPlayer {
  WindowsAudioPlayerPlatform(String id) : super(id);

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    // 直接返回空响应，忽略该配置，防止在 Windows 上引发 MissingPluginException
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }
}

/// ✅ 自定义的 JustAudioPlatform 代理，委托给原始平台，
///    并在 init 中返回我们自定义的 WindowsAudioPlayerPlatform。
class WindowsJustAudioPlatform extends JustAudioPlatform {
  WindowsJustAudioPlatform(this._inner);
  final JustAudioPlatform _inner;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    // 仍然调用原始平台的 init 来注册插件通道
    await _inner.init(request);
    // 返回我们的自定义实现，它会拦截未支持的方法
    return WindowsAudioPlayerPlatform(request.id);
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) {
    return _inner.disposePlayer(request);
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) {
    return _inner.disposeAllPlayers(request);
  }
}

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await LoggerUtils.init();

      // ✅ 针对桌面端（Windows/Linux/macOS）初始化数据库工厂
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      // ✅ 在 Windows 上注入我们的代理平台，拦截未实现的 API
      if (Platform.isWindows) {
        JustAudioPlatform.instance =
            WindowsJustAudioPlatform(JustAudioPlatform.instance);
      }

      // 匿名使用统计每日心跳（默认开启，设置 → 隐私 可关），不阻塞启动
      unawaited(StatsService.maybePing());

      if (Platform.isAndroid || Platform.isIOS) {
        _logger.info('audio platform: ${Platform.operatingSystem}');

        await JustAudioBackground.init(
          androidNotificationChannelId: 'org.u2x1.bmsc.channel.audio',
          androidNotificationChannelName: 'Audio Playback',
          androidStopForegroundOnPause: true,
        );
      }

      // 悬浮窗识曲（Android）
      if (Platform.isAndroid) {
        OverlayRecognitionService.instance.init();
        OverlayRecognitionService.instance.onOpenSearch = (keyword) {
          ErrorHandler.navigatorKey.currentState?.push(
              MaterialPageRoute<Widget>(
                  builder: (_) => SearchScreen(initialKeyword: keyword)));
        };
      }

      // ✅ 仅 Linux 使用 media_kit 初始化，Windows 交给 just_audio_windows_plus
      if (Platform.isLinux) {
        JustAudioMediaKit.ensureInitialized();
      }

      await ThemeProvider.instance.init();
      unawaited(DatabaseManager.sweepOrphanCacheFiles());
      if (!kDebugMode) _setupErrorHandlers();
      runApp(const MyApp());
    },
    // ✅ 修复 1：用 Future.microtask 延迟处理致命错误，防止 Logger 重入死锁
    (error, stack) {
      Future.microtask(() => _logger.severe('zone error', error, stack));
    },
    // ✅ 修复 2：用 Future.microtask 延迟处理 print 拦截，防止 Logger 重入死锁
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        Future.microtask(() => _logger.info('[print] $line'));
      },
    ),
  );
}

void _setupErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    ErrorHandler.handleException(details.exception, details.stack);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorHandler.handleException(error, stack);
    return true;
  };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeProvider.instance,
      builder: (context, child) {
        return MaterialApp(
          navigatorKey: ErrorHandler.navigatorKey,
          theme: ThemeProvider.lightTheme,
          darkTheme: ThemeProvider.instance.activeDarkTheme,
          themeMode: ThemeProvider.instance.themeMode,
          home: Builder(builder: (context) {
            return Scaffold(
              body: MyHomePage(title: 'BiliMusic'),
              bottomNavigationBar: const PlayingCard(),
            );
          }),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  String? curVersion;
  bool hasNewVersion = false;
  FavScreenState? _favScreenState;
  String? _clipboardText;
  DateTime? _lastNavAt;

  final _appsButtonKey = GlobalKey();

  static const _appsMenuItems = [
    (icon: Icons.search, label: '搜索', value: 0),
    (icon: Icons.graphic_eq, label: '听歌识曲', value: 1),
    (icon: Icons.wind_power_outlined, label: '动态', value: 2),
    (icon: Icons.history_outlined, label: '历史', value: 3),
    (icon: Icons.settings_outlined, label: '设置', value: 4),
  ];

  Future<void> _openAppsMenu() async {
    final ctx = _appsButtonKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final v = await Navigator.of(context)
        .push(_AppsMenuRoute(anchorRect: rect, items: _appsMenuItems));
    if (v != null) _onMenuSelected(v);
  }

  void _onMenuSelected(int i) {
    switch (i) {
      case 0:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const SearchScreen()));
      case 1:
        _pushThrottled<Widget>(MaterialPageRoute<Widget>(
            builder: (_) => const RecognitionScreen()));
      case 2:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const DynamicScreen()));
      case 3:
        _pushThrottled<Widget>(MaterialPageRoute<Widget>(
            builder: (_) => const LocalHistoryScreen()));
      case 4:
        _pushThrottled<bool>(
          MaterialPageRoute<bool>(builder: (_) => const SettingsScreen()),
        )?.then((_) async {
          await _favScreenState?.refreshLoginState();
        });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ThemeProvider.instance.addListener(_updateSystemUiOverlay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSystemUiOverlay();
      WhatsNew.maybeShow(context);
    });
    UpdateService.instance.then((x) async {
      if (!mounted) return;
      setState(() {
        curVersion = x.curVersion;
        hasNewVersion = x.hasNewVersion;
      });
    });
  }

  @override
  void dispose() {
    ThemeProvider.instance.removeListener(_updateSystemUiOverlay);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SectionHabitService.onAppResumed();
      _checkClipboard();
    } else if (state == AppLifecycleState.paused) {
      SectionHabitService.onAppPaused();
    }
  }

  @override
  void didChangePlatformBrightness() {
    _updateSystemUiOverlay();
  }

  void _updateSystemUiOverlay() {
    if (!mounted) return;
    final themeMode = ThemeProvider.instance.themeMode;
    final isDarkMode = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      systemNavigationBarColor: isDarkMode
          ? ThemeProvider.instance.activeDarkTheme.colorScheme.surfaceContainer
          : ThemeProvider.lightTheme.colorScheme.surfaceContainer,
    ));
  }

  Future<T?>? _pushThrottled<T>(Route<T> route) {
    final now = DateTime.now();
    if (_lastNavAt != null &&
        now.difference(_lastNavAt!) < const Duration(milliseconds: 500)) {
      return null;
    }
    _lastNavAt = now;
    return Navigator.push<T>(context, route);
  }

  Future<void> _checkClipboard() async {
    if (!(await SharedPreferencesService.getReadFromClipboard())) return;
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData?.text == null) return;
    if (clipboardData?.text == _clipboardText) return;
    _clipboardText = clipboardData?.text;
    _logger.info('clipboard data detected: ${clipboardData?.text}');

    var text = _clipboardText!;

    VidResult? vidDetail = await getVidDetailFromUrl(text);
    if (vidDetail == null) return;

    final as = await app_audio.AudioService.instance;
    if (as.player.sequenceState.currentSource?.tag.extras?['bvid'] ==
        vidDetail.bvid) {
      _logger.info('clipboard detected, but already playing');
      return;
    }

    int min = vidDetail.duration ~/ 60;
    int sec = vidDetail.duration % 60;
    final duration = "$min:${sec.toString().padLeft(2, '0')}";

    if (!context.mounted) return;

    final dialogContext = context;
    showDialog(
      context: dialogContext,
      builder: (context) => AlertDialog(
          title: const Text('检测到剪贴板视频'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TrackTile(
                  title: vidDetail.title,
                  author: vidDetail.owner.name,
                  len: duration,
                  pic: vidDetail.pic,
                  view: unit(vidDetail.stat.view),
                  onTap: () {
                    Navigator.pop(context);
                    app_audio.AudioService.instance
                        .then((x) => x.playByBvid(vidDetail.bvid));
                  }),
            ],
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Tooltip(
          message: '关于',
          child: Semantics(
            button: true,
            label: '关于',
            child: GestureDetector(
              onTap: () => _pushThrottled<Widget>(
                MaterialPageRoute<Widget>(builder: (_) => const AboutScreen()),
              ),
              child: Row(
                children: [
                  const Text("BiliMusic"),
                  if (hasNewVersion)
                    Tooltip(
                      message: '有新版本',
                      child: Icon(Icons.arrow_circle_up_outlined,
                          color: Theme.of(context).colorScheme.error),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            key: _appsButtonKey,
            tooltip: '更多',
            icon: const Icon(Icons.apps),
            onPressed: _openAppsMenu,
          ),
        ],
      ),
      body: FavScreen(
        onInit: (state) => _favScreenState = state,
      ),
    );
  }
}

class _AppsMenuRoute extends PopupRoute<int> {
  _AppsMenuRoute({required this.anchorRect, required this.items});

  final Rect anchorRect;
  final List<({IconData icon, String label, int value})> items;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭';

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final top = anchorRect.bottom + 8;
    final right =
        (MediaQuery.sizeOf(context).width - anchorRect.right).clamp(8.0, 1e9);
    return Padding(
      padding: EdgeInsets.only(top: top, right: right),
      child: Align(
        alignment: Alignment.topRight,
        child: AnimatedBuilder(
          animation: animation,
          child: _buildCard(context, animation),
          builder: (context, card) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutBack,
              reverseCurve: Curves.easeIn,
            );
            return Opacity(
              opacity: animation.value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.88 + 0.12 * enter.value,
                alignment: Alignment.topRight,
                child: Transform.translate(
                  offset: Offset(0, -10 * (1 - enter.value)),
                  child: card,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, Animation<double> animation) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 232),
      child: Material(
        color: cs.surfaceContainerHigh,
        elevation: 8,
        shadowColor: Colors.black45,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < items.length; i++)
                _tile(context, animation, i),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Animation<double> animation, int i) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final item = items[i];
    final stagger = CurvedAnimation(
      parent: animation,
      curve: Interval(0.06 * i, (0.5 + 0.06 * i).clamp(0.0, 1.0),
          curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: stagger,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero)
            .animate(stagger),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.pop(context, item.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child:
                      Icon(item.icon, size: 22, color: cs.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(item.label, style: theme.textTheme.bodyLarge),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
