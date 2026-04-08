import 'dart:convert';
import 'dart:typed_data';

import 'package:bilibili_api/bilibili_api.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:ns_danmaku/ns_danmaku.dart';
import 'package:xml/xml.dart';

class ParsedVideoId {
  const ParsedVideoId._({this.bvid, this.aid, required this.displayValue});

  final String? bvid;
  final int? aid;
  final String displayValue;

  bool get isBvid => bvid != null;

  static ParsedVideoId? tryParse(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return null;
    }

    final bvidMatch = RegExp(
      r'(BV[0-9A-Za-z]{10})',
      caseSensitive: false,
    ).firstMatch(input);
    if (bvidMatch != null) {
      final value = bvidMatch.group(1)!;
      return ParsedVideoId._(
        bvid: 'BV${value.substring(2)}',
        displayValue: 'BV${value.substring(2)}',
      );
    }

    final aidMatch = RegExp(
      r'(?:^|[^0-9])(?:av)?([0-9]{5,})(?:[^0-9]|$)',
      caseSensitive: false,
    ).firstMatch(' $input ');
    if (aidMatch != null) {
      final aid = int.tryParse(aidMatch.group(1)!);
      if (aid != null) {
        return ParsedVideoId._(aid: aid, displayValue: 'av$aid');
      }
    }

    return null;
  }
}

class PlaybackBundle {
  const PlaybackBundle({
    required this.media,
    required this.page,
    required this.stream,
    required this.sourceLabel,
    required this.danmakuItems,
  });

  final Media media;
  final VideoPage page;
  final VideoStreamUrl stream;
  final String sourceLabel;
  final List<DanmakuItem> danmakuItems;
}

class BilibiliDemoService {
  BilibiliDemoService({BiliHttpClient? client, http.Client? httpClient})
    : _client = client ?? BiliHttpClient(),
      _httpClient = httpClient ?? http.Client();

  final BiliHttpClient _client;
  final http.Client _httpClient;

  late final LoginInfoApi _loginInfoApi = LoginInfoApi(_client);
  late final VideoApi _videoApi = VideoApi(_client);
  late final VideoStreamApi _streamApi = VideoStreamApi(_client);

  static const Map<String, String> playbackHeaders = {
    'User-Agent': BiliHttpClient.userAgent,
    'Referer': BiliHttpClient.referer,
    'Origin': 'https://www.bilibili.com',
  };

  Future<VideoInfo> fetchVideoInfo(ParsedVideoId id) {
    if (id.isBvid) {
      return _videoApi.getVideoInfoByBvid(id.bvid!);
    }
    return _videoApi.getVideoInfoByAid(id.aid!);
  }

  Future<PlaybackBundle> loadPage({
    required ParsedVideoId id,
    required VideoInfo videoInfo,
    required int pageIndex,
  }) async {
    if (videoInfo.pages.isEmpty) {
      throw StateError('该视频没有可播放的分 P 信息。');
    }

    final safeIndex = pageIndex.clamp(0, videoInfo.pages.length - 1);
    final page = videoInfo.pages[safeIndex];

    await _loginInfoApi.refreshWbiKeys();

    final playbackFuture = _resolvePlaybackSource(id: id, cid: page.cid);
    final danmakuFuture = _loadDanmaku(page.cid);

    final playback = await playbackFuture;
    final danmakuItems = await danmakuFuture.catchError((_) {
      return <DanmakuItem>[];
    });

    return PlaybackBundle(
      media: playback.media,
      page: page,
      stream: playback.stream,
      sourceLabel: playback.sourceLabel,
      danmakuItems: danmakuItems,
    );
  }

  void dispose() {
    _client.close();
    _httpClient.close();
  }

  Future<_ResolvedPlayback> _resolvePlaybackSource({
    required ParsedVideoId id,
    required int cid,
  }) async {
    Object? lastError;

    for (final qn in const [32, 16]) {
      try {
        final raw = await _getPlayUrlRaw(id: id, cid: cid, qn: qn, fnval: 4048);
        final stream = VideoStreamUrl.fromJson(raw);
        final media = await _buildDashMedia(raw);
        if (media != null) {
          return _ResolvedPlayback(
            media: media,
            stream: stream,
            sourceLabel: 'DASH · ${_describeQuality(stream)}',
          );
        }
      } catch (error) {
        lastError = error;
      }
    }

    for (final qn in const [32, 16]) {
      try {
        final stream = await _streamApi.getMp4Stream(
          bvid: id.bvid,
          aid: id.aid,
          cid: cid,
          qn: qn,
        );
        final firstUrl = stream.durl?.firstOrNull?.url;
        if (firstUrl == null || firstUrl.isEmpty) {
          continue;
        }
        return _ResolvedPlayback(
          media: Media(firstUrl, httpHeaders: playbackHeaders),
          stream: stream,
          sourceLabel: 'MP4 · ${_describeQuality(stream)}',
        );
      } catch (error) {
        lastError = error;
      }
    }

    throw StateError('未获取到可播放地址: ${lastError ?? '未知错误'}');
  }

  Future<Map<String, dynamic>> _getPlayUrlRaw({
    required ParsedVideoId id,
    required int cid,
    required int qn,
    required int fnval,
  }) async {
    final response = await _client.get<Map<String, dynamic>>(
      'https://api.bilibili.com/x/player/wbi/playurl',
      params: {
        if (id.bvid != null) 'bvid': id.bvid,
        if (id.aid != null) 'avid': id.aid,
        'cid': cid,
        'qn': qn,
        'fnval': fnval,
        'fnver': 0,
      },
      useWbiSign: true,
      dataParser: (data) => Map<String, dynamic>.from(data as Map),
    );

    if (response.data == null) {
      throw StateError('播放地址接口返回为空。');
    }
    return response.data!;
  }

  Future<Media?> _buildDashMedia(Map<String, dynamic> raw) async {
    final dash = raw['dash'];
    if (dash is! Map) {
      return null;
    }

    final dashMap = Map<String, dynamic>.from(dash);
    final videoStreams = _readMapList(dashMap['video']);
    final audioStreams = _readMapList(dashMap['audio']);
    if (videoStreams.isEmpty || audioStreams.isEmpty) {
      return null;
    }

    final video = videoStreams.first;
    final audio = audioStreams.first;
    final videoSegment = _parseSegmentBase(video);
    final audioSegment = _parseSegmentBase(audio);
    if (videoSegment == null || audioSegment == null) {
      return null;
    }

    final durationSeconds =
        (dashMap['duration'] as num?)?.toDouble() ??
        ((raw['timelength'] as num?)?.toDouble() ?? 0) / 1000;
    final mpd = _buildMpd(
      durationSeconds: durationSeconds,
      video: video,
      audio: audio,
      videoSegment: videoSegment,
      audioSegment: audioSegment,
    );

    final manifest = await Media.memory(
      Uint8List.fromList(utf8.encode(mpd)),
      type: 'application/dash+xml',
    );

    return manifest.copyWith(httpHeaders: playbackHeaders);
  }

  Future<List<DanmakuItem>> _loadDanmaku(int cid) async {
    final response = await _httpClient.get(
      Uri.parse('https://comment.bilibili.com/$cid.xml'),
      headers: playbackHeaders,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('弹幕接口返回异常: ${response.statusCode}');
    }

    final document = XmlDocument.parse(utf8.decode(response.bodyBytes));
    final items = <DanmakuItem>[];

    for (final node in document.findAllElements('d')) {
      final rawAttribute = node.getAttribute('p');
      if (rawAttribute == null || rawAttribute.isEmpty) {
        continue;
      }

      final parts = rawAttribute.split(',');
      if (parts.length < 3) {
        continue;
      }

      final time = double.tryParse(parts[0])?.floor() ?? 0;
      final mode = int.tryParse(parts[1]) ?? 1;
      final colorValue = int.tryParse(parts[2]) ?? 0xFFFFFF;
      final text = node.innerText.trim();
      if (text.isEmpty) {
        continue;
      }

      items.add(
        DanmakuItem(
          text,
          time: time,
          color: _argbFromRgb(colorValue),
          type: _modeToItemType(mode),
        ),
      );
    }

    items.sort((left, right) => left.time.compareTo(right.time));
    return items;
  }

  List<Map<String, dynamic>> _readMapList(dynamic value) {
    if (value is! List) {
      return const [];
    }

    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  _DashSegmentBase? _parseSegmentBase(Map<String, dynamic> data) {
    final raw = data['SegmentBase'] ?? data['segment_base'];
    if (raw is! Map) {
      return null;
    }

    final map = Map<String, dynamic>.from(raw);
    final initialization =
        map['Initialization'] as String? ?? map['initialization'] as String?;
    final indexRange =
        map['indexRange'] as String? ?? map['index_range'] as String?;
    if (initialization == null || indexRange == null) {
      return null;
    }

    return _DashSegmentBase(
      initialization: initialization,
      indexRange: indexRange,
    );
  }

  String _buildMpd({
    required double durationSeconds,
    required Map<String, dynamic> video,
    required Map<String, dynamic> audio,
    required _DashSegmentBase videoSegment,
    required _DashSegmentBase audioSegment,
  }) {
    final safeDuration = durationSeconds <= 0 ? 1.0 : durationSeconds;
    final videoMimeType =
        video['mimeType'] as String? ??
        video['mime_type'] as String? ??
        'video/mp4';
    final audioMimeType =
        audio['mimeType'] as String? ??
        audio['mime_type'] as String? ??
        'audio/mp4';

    return '''
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" mediaPresentationDuration="PT${safeDuration.toStringAsFixed(3)}S" minBufferTime="PT1.500S">
  <Period duration="PT${safeDuration.toStringAsFixed(3)}S">
    <AdaptationSet mimeType="${_escapeXml(videoMimeType)}" segmentAlignment="true" startWithSAP="1">
      <Representation id="${video['id']}" bandwidth="${video['bandwidth']}" codecs="${_escapeXml(video['codecs']?.toString() ?? '')}" width="${video['width'] ?? 0}" height="${video['height'] ?? 0}" frameRate="${_escapeXml(video['frameRate']?.toString() ?? video['frame_rate']?.toString() ?? '0')}">
        <BaseURL>${_escapeXml(video['baseUrl'] as String? ?? video['base_url'] as String? ?? '')}</BaseURL>
        <SegmentBase indexRange="${_escapeXml(videoSegment.indexRange)}">
          <Initialization range="${_escapeXml(videoSegment.initialization)}" />
        </SegmentBase>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="${_escapeXml(audioMimeType)}" segmentAlignment="true" startWithSAP="1">
      <Representation id="${audio['id']}" bandwidth="${audio['bandwidth']}" codecs="${_escapeXml(audio['codecs']?.toString() ?? '')}">
        <BaseURL>${_escapeXml(audio['baseUrl'] as String? ?? audio['base_url'] as String? ?? '')}</BaseURL>
        <SegmentBase indexRange="${_escapeXml(audioSegment.indexRange)}">
          <Initialization range="${_escapeXml(audioSegment.initialization)}" />
        </SegmentBase>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';
  }

  String _describeQuality(VideoStreamUrl stream) {
    final descriptions = stream.acceptDescription;
    if (descriptions.isEmpty) {
      return '${stream.quality}P';
    }
    return descriptions.first;
  }

  DanmakuItemType _modeToItemType(int mode) {
    if (mode == 4) {
      return DanmakuItemType.bottom;
    }
    if (mode == 5) {
      return DanmakuItemType.top;
    }
    return DanmakuItemType.scroll;
  }

  Color _argbFromRgb(int value) {
    return Color((0xFF << 24) | value);
  }

  String _escapeXml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

class _ResolvedPlayback {
  const _ResolvedPlayback({
    required this.media,
    required this.stream,
    required this.sourceLabel,
  });

  final Media media;
  final VideoStreamUrl stream;
  final String sourceLabel;
}

class _DashSegmentBase {
  const _DashSegmentBase({
    required this.initialization,
    required this.indexRange,
  });

  final String initialization;
  final String indexRange;
}

extension _NullableFirst<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
