import 'dart:async';
import 'dart:math' as math;

import 'package:bilibili_api/bilibili_api.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ns_danmaku/ns_danmaku.dart';

import 'src/services/bilibili_demo_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const BilibiliPlayerDemoApp());
}

class BilibiliPlayerDemoApp extends StatelessWidget {
  const BilibiliPlayerDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFB7299),
      brightness: Brightness.dark,
      surface: const Color(0xFF15171C),
    );

    return MaterialApp(
      title: 'B 站播放器 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
          filled: true,
          fillColor: Color(0xFF11141A),
        ),
      ),
      home: const BilibiliPlayerHomePage(),
    );
  }
}

class BilibiliPlayerHomePage extends StatefulWidget {
  const BilibiliPlayerHomePage({super.key});

  @override
  State<BilibiliPlayerHomePage> createState() => _BilibiliPlayerHomePageState();
}

class _BilibiliPlayerHomePageState extends State<BilibiliPlayerHomePage> {
  static const _exampleVideoId = 'BV1xx411c79H';

  final _service = BilibiliDemoService();
  final _player = Player(
    configuration: const PlayerConfiguration(title: 'Bilibili Player Demo'),
  );
  final _videoIdController = TextEditingController(text: _exampleVideoId);

  late final VideoController _videoController = VideoController(_player);

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;

  DanmakuController? _danmakuController;
  DanmakuOption _danmakuOption = DanmakuOption(
    fontSize: 18,
    duration: 12,
    opacity: 0.95,
    borderText: true,
  );

  ParsedVideoId? _currentVideoId;
  VideoInfo? _videoInfo;
  int _selectedPageIndex = 0;
  bool _loading = false;
  String? _errorMessage;
  String? _sourceLabel;
  String? _qualityText;
  int _lastDanmakuSecond = -1;
  Map<int, List<DanmakuItem>> _timeline = const {};

  @override
  void initState() {
    super.initState();
    _bindPlayerStreams();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _playingSubscription?.cancel();
    _videoIdController.dispose();
    unawaited(_player.dispose());
    _service.dispose();
    super.dispose();
  }

  void _bindPlayerStreams() {
    _positionSubscription = _player.stream.position.listen(_syncDanmaku);
    _playingSubscription = _player.stream.playing.listen((playing) {
      final controller = _danmakuController;
      if (controller == null) {
        return;
      }
      if (playing) {
        if (!controller.running) {
          controller.resume();
        }
      } else if (controller.running) {
        controller.pause();
      }
    });
  }

  Future<void> _loadVideo({
    ParsedVideoId? parsedVideoId,
    int pageIndex = 0,
    VideoInfo? existingInfo,
  }) async {
    final parsed =
        parsedVideoId ?? ParsedVideoId.tryParse(_videoIdController.text);
    if (parsed == null) {
      setState(() {
        _errorMessage = '请输入有效的 BV 号、av 号，或完整的 B 站视频链接。';
      });
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      _loading = true;
      _errorMessage = null;
      if (existingInfo == null) {
        _sourceLabel = null;
        _qualityText = null;
      }
    });

    try {
      final info = existingInfo ?? await _service.fetchVideoInfo(parsed);
      final bundle = await _service.loadPage(
        id: parsed,
        videoInfo: info,
        pageIndex: pageIndex,
      );

      _resetDanmaku(bundle.danmakuItems);
      await _player.open(bundle.media);

      if (!mounted) {
        return;
      }

      setState(() {
        _currentVideoId = parsed;
        _videoInfo = info;
        _selectedPageIndex = pageIndex.clamp(0, info.pages.length - 1);
        _sourceLabel = bundle.sourceLabel;
        _qualityText = bundle.stream.acceptDescription.join(' / ');
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _describeLoadError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _resetDanmaku(List<DanmakuItem> items) {
    _lastDanmakuSecond = -1;
    _danmakuController?.clear();

    final timeline = <int, List<DanmakuItem>>{};
    for (final item in items) {
      timeline.putIfAbsent(item.time, () => <DanmakuItem>[]).add(item);
    }

    _timeline = timeline;
  }

  void _syncDanmaku(Duration position) {
    final controller = _danmakuController;
    if (controller == null || _timeline.isEmpty) {
      return;
    }

    final second = position.inSeconds;
    if (second < 0) {
      return;
    }

    final jumpedBackward = second < _lastDanmakuSecond;
    final jumpedForward =
        _lastDanmakuSecond >= 0 && second - _lastDanmakuSecond > 3;
    if (jumpedBackward || jumpedForward) {
      controller.clear();
      _lastDanmakuSecond = second - 1;
    }

    final startSecond = _lastDanmakuSecond + 1;
    if (second < startSecond) {
      return;
    }

    for (var current = startSecond; current <= second; current++) {
      final items = _timeline[current];
      if (items != null && items.isNotEmpty) {
        controller.addItems(items);
      }
    }
    _lastDanmakuSecond = second;
  }

  void _updateDanmakuOption(DanmakuOption next) {
    setState(() {
      _danmakuOption = next;
    });
    _danmakuController?.updateOption(next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF090B0E), Color(0xFF13161C), Color(0xFF1F1117)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 1040;
              final playerPanel = _buildPlayerPanel(context);
              final controlPanel = _buildControlPanel(context);

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 20),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 7, child: playerPanel),
                          const SizedBox(width: 20),
                          Expanded(flex: 4, child: controlPanel),
                        ],
                      )
                    else ...[
                      playerPanel,
                      const SizedBox(height: 20),
                      controlPanel,
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: const [
              _InfoChip(label: 'bilibili_api', value: '视频信息与取流'),
              _InfoChip(label: 'media_kit', value: '高性能视频播放'),
              _InfoChip(label: 'ns_danmaku', value: '弹幕覆盖层'),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'B 站播放器 Demo',
            style: textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '输入 BV 号、av 号或完整 B 站视频链接，演示视频取流、播放器渲染和弹幕同步。',
            style: textTheme.bodyLarge?.copyWith(
              color: Colors.white70,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerPanel(BuildContext context) {
    final info = _videoInfo;
    final imageUrl = _normalizeImageUrl(info?.pic);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: const Color(0xFF020406)),
                      if (info == null)
                        _buildEmptyPlayerPlaceholder()
                      else
                        Video(
                          controller: _videoController,
                          subtitleViewConfiguration:
                              const SubtitleViewConfiguration(visible: false),
                        ),
                      IgnorePointer(
                        child: DanmakuView(
                          createdController: (controller) {
                            _danmakuController = controller;
                            controller.updateOption(_danmakuOption);
                            if (!_player.state.playing && controller.running) {
                              controller.pause();
                            }
                          },
                          option: _danmakuOption,
                        ),
                      ),
                      Positioned(
                        left: 14,
                        top: 14,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (_sourceLabel != null)
                              _OverlayTag(text: _sourceLabel!),
                            if (_timeline.isNotEmpty)
                              _OverlayTag(text: '弹幕 ${_timeline.length} 秒分桶'),
                          ],
                        ),
                      ),
                      if (_loading)
                        Container(
                          color: Colors.black.withValues(alpha: 0.38),
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_errorMessage != null) ...[
                _ErrorBanner(message: _errorMessage!),
                const SizedBox(height: 18),
              ],
              if (info != null)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 132,
                        height: 82,
                        color: Colors.white.withValues(alpha: 0.05),
                        child: imageUrl == null
                            ? const Icon(Icons.movie_creation_outlined)
                            : Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) {
                                  return const Icon(
                                    Icons.broken_image_outlined,
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            info.title,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  height: 1.25,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'UP 主：${info.owner.name} · ${_formatDuration(info.duration)}',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.white70),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _StatPill(
                                icon: Icons.play_circle_outline,
                                text: _formatCount(info.stat.view),
                              ),
                              _StatPill(
                                icon: Icons.chat_bubble_outline,
                                text: _formatCount(info.stat.danmaku),
                              ),
                              _StatPill(
                                icon: Icons.thumb_up_alt_outlined,
                                text: _formatCount(info.stat.like),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (info != null && info.desc.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  info.desc,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    height: 1.55,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel(BuildContext context) {
    final info = _videoInfo;
    final pages = info?.pages ?? const <VideoPage>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: _panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '加载视频',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _videoIdController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _loadVideo(),
                decoration: const InputDecoration(
                  labelText: 'BV / av / 完整链接',
                  hintText: '例如 BV1xx411c79H',
                  prefixIcon: Icon(Icons.video_library_outlined),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _loadVideo,
                      icon: const Icon(Icons.play_circle_fill_outlined),
                      label: const Text('加载并播放'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _loading
                        ? null
                        : () {
                            _videoIdController.text = _exampleVideoId;
                            _loadVideo();
                          },
                    child: const Text('示例'),
                  ),
                ],
              ),
              if (_qualityText != null) ...[
                const SizedBox(height: 14),
                Text(
                  '可用清晰度：$_qualityText',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (pages.length > 1)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: _panelDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '分 P 选择',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: ValueKey(_selectedPageIndex),
                  initialValue: _selectedPageIndex.clamp(0, pages.length - 1),
                  items: [
                    for (var index = 0; index < pages.length; index++)
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          'P${pages[index].page} · ${pages[index].part}',
                        ),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          if (value == null ||
                              _currentVideoId == null ||
                              info == null) {
                            return;
                          }
                          _loadVideo(
                            parsedVideoId: _currentVideoId,
                            pageIndex: value,
                            existingInfo: info,
                          );
                        },
                  decoration: const InputDecoration(labelText: '当前播放分 P'),
                ),
              ],
            ),
          ),
        if (pages.length > 1) const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: _panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '弹幕设置',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              _LabeledSlider(
                label: '透明度',
                valueLabel: _danmakuOption.opacity.toStringAsFixed(2),
                value: _danmakuOption.opacity,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                onChanged: (value) {
                  _updateDanmakuOption(_danmakuOption.copyWith(opacity: value));
                },
              ),
              _LabeledSlider(
                label: '字号',
                valueLabel: _danmakuOption.fontSize.toStringAsFixed(0),
                value: _danmakuOption.fontSize,
                min: 12,
                max: 28,
                divisions: 8,
                onChanged: (value) {
                  _updateDanmakuOption(
                    _danmakuOption.copyWith(fontSize: value),
                  );
                },
              ),
              _LabeledSlider(
                label: '滚动时长',
                valueLabel: '${_danmakuOption.duration.toStringAsFixed(0)}s',
                value: _danmakuOption.duration,
                min: 6,
                max: 18,
                divisions: 12,
                onChanged: (value) {
                  _updateDanmakuOption(
                    _danmakuOption.copyWith(duration: value),
                  );
                },
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('隐藏滚动弹幕'),
                value: _danmakuOption.hideScroll,
                onChanged: (value) {
                  _updateDanmakuOption(
                    _danmakuOption.copyWith(hideScroll: value),
                  );
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('隐藏顶部弹幕'),
                value: _danmakuOption.hideTop,
                onChanged: (value) {
                  _updateDanmakuOption(_danmakuOption.copyWith(hideTop: value));
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('隐藏底部弹幕'),
                value: _danmakuOption.hideBottom,
                onChanged: (value) {
                  _updateDanmakuOption(
                    _danmakuOption.copyWith(hideBottom: value),
                  );
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('文字描边'),
                value: _danmakuOption.borderText,
                onChanged: (value) {
                  _updateDanmakuOption(
                    _danmakuOption.copyWith(borderText: value),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyPlayerPlaceholder() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight < 190 || constraints.maxWidth < 360;
        final padding = compact ? 18.0 : 28.0;
        final iconSize = compact ? 52.0 : 72.0;
        final titleFontSize = compact ? 16.0 : 20.0;
        final bodyFontSize = compact ? 12.0 : 14.0;
        final titleGap = compact ? 12.0 : 16.0;
        final bodyGap = compact ? 8.0 : 10.0;
        final contentWidth = math.max(0.0, constraints.maxWidth - padding * 2);

        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF141820), Color(0xFF29131B)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: EdgeInsets.all(padding),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentWidth),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.ondemand_video_outlined,
                      size: iconSize,
                      color: const Color(0xFFFFB7CC),
                    ),
                    SizedBox(height: titleGap),
                    SizedBox(
                      width: contentWidth,
                      child: Text(
                        '输入一个 B 站视频并点击“加载并播放”',
                        style: TextStyle(
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: bodyGap),
                    SizedBox(
                      width: contentWidth,
                      child: Text(
                        '播放器会自动获取视频地址，并叠加官方 XML 弹幕。',
                        style: TextStyle(
                          color: Colors.white70,
                          height: 1.5,
                          fontSize: bodyFontSize,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  BoxDecoration _panelDecoration() {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: 0.045),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22000000),
          blurRadius: 30,
          offset: Offset(0, 18),
        ),
      ],
    );
  }

  String? _normalizeImageUrl(String? url) {
    if (url == null || url.isEmpty) {
      return null;
    }
    if (url.startsWith('//')) {
      return 'https:$url';
    }
    return url;
  }

  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _describeLoadError(Object error) {
    if (error is BiliException) {
      if (error.code == BiliException.codeUnauthorized) {
        return 'B 站当前返回了登录态校验，未能获取播放地址。已改为免登录获取 WBI 参数，但该视频或当前接口仍可能要求登录。';
      }
      return 'B 站接口异常（code: ${error.code}）：${error.message}';
    }

    return error.toString();
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: Colors.white70),
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(
                color: Color(0xFFFFA8C0),
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFFFFB5C7)),
          const SizedBox(width: 6),
          Text(text),
        ],
      ),
    );
  }
}

class _OverlayTag extends StatelessWidget {
  const _OverlayTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(label),
            const Spacer(),
            Text(
              valueLabel,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE2E7).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFFFA5B8).withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline, color: Color(0xFFFFB6C7)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
