import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
    required this.sources,
    required this.page,
    required this.danmakuItems,
  });

  final List<PlaybackSource> sources;
  final VideoPage page;
  final List<DanmakuItem> danmakuItems;
}

class PlaybackSource {
  const PlaybackSource({
    required this.media,
    required this.stream,
    required this.sourceLabel,
  });

  final Media media;
  final VideoStreamUrl stream;
  final String sourceLabel;
}

class BilibiliDemoService {
  BilibiliDemoService({BiliHttpClient? client, http.Client? httpClient})
    : _client = client ?? BiliHttpClient(),
      _httpClient = httpClient ?? http.Client();

  final BiliHttpClient _client;
  final http.Client _httpClient;

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

    await _ensureWbiKeys();

    final playbackFuture = _resolvePlaybackSources(id: id, cid: page.cid);
    final danmakuFuture = _loadDanmaku(page.cid);

    final sources = await playbackFuture;
    final danmakuItems = await danmakuFuture.catchError((_) {
      return <DanmakuItem>[];
    });

    return PlaybackBundle(
      sources: sources,
      page: page,
      danmakuItems: danmakuItems,
    );
  }

  void dispose() {
    _client.close();
    _httpClient.close();
  }

  Future<void> _ensureWbiKeys() async {
    final signer = _client.wbiSigner;
    if (!signer.needsRefresh && signer.mixinKey != null) {
      return;
    }

    final response = await _httpClient.get(
      Uri.parse('https://api.bilibili.com/x/web-interface/nav'),
      headers: playbackHeaders,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('获取 WBI 签名参数失败: ${response.statusCode}');
    }

    final raw = json.decode(_decodeResponseText(response));
    if (raw is! Map) {
      throw const FormatException('WBI 接口返回格式无效。');
    }

    final data = raw['data'];
    if (data is! Map) {
      throw StateError('WBI 接口缺少 data 字段。');
    }

    final wbiImg = data['wbi_img'];
    if (wbiImg is! Map) {
      throw StateError('WBI 接口缺少 wbi_img 字段。');
    }

    final imgUrl = wbiImg['img_url'] as String?;
    final subUrl = wbiImg['sub_url'] as String?;
    if (imgUrl == null || imgUrl.isEmpty || subUrl == null || subUrl.isEmpty) {
      throw StateError('WBI 接口返回的签名参数不完整。');
    }

    signer.updateKeys(imgUrl, subUrl);
  }

  Future<List<PlaybackSource>> _resolvePlaybackSources({
    required ParsedVideoId id,
    required int cid,
  }) async {
    Object? lastError;
    final sources = <PlaybackSource>[];
    final seenLabels = <String>{};

    void addSource(PlaybackSource source) {
      if (seenLabels.add(source.sourceLabel)) {
        sources.add(source);
      }
    }

    for (final qn in const [32, 16]) {
      try {
        final raw = await _getPlayUrlRaw(id: id, cid: cid, qn: qn, fnval: 4048);
        final stream = VideoStreamUrl.fromJson(raw);
        final media = await _buildDashMedia(raw);
        if (media != null) {
          addSource(
            PlaybackSource(
              media: media,
              stream: stream,
              sourceLabel: 'DASH · ${_describeQuality(stream)}',
            ),
          );
        }
      } catch (error) {
        lastError = error;
      }

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
        addSource(
          PlaybackSource(
            media: Media(firstUrl, httpHeaders: playbackHeaders),
            stream: stream,
            sourceLabel: 'MP4 · ${_describeQuality(stream)}',
          ),
        );
      } catch (error) {
        lastError = error;
      }
    }

    if (sources.isNotEmpty) {
      return sources;
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
    final preferredQuality =
        (raw['quality'] as num?)?.toInt() ??
        (dashMap['quality'] as num?)?.toInt();
    final videoStreams = _readDashCandidates(_readMapList(dashMap['video']));
    final audioStreams = _readDashCandidates(_readMapList(dashMap['audio']));
    if (videoStreams.isEmpty || audioStreams.isEmpty) {
      return null;
    }

    final video = _selectVideoCandidate(
      videoStreams,
      preferredQuality: preferredQuality,
    );
    final audio = _selectAudioCandidate(audioStreams);
    if (video == null || audio == null) {
      return null;
    }

    final durationSeconds =
        (dashMap['duration'] as num?)?.toDouble() ??
        ((raw['timelength'] as num?)?.toDouble() ?? 0) / 1000;
    final mpd = _buildMpd(
      durationSeconds: durationSeconds,
      video: video.data,
      audio: audio.data,
      videoSegment: video.segmentBase,
      audioSegment: audio.segmentBase,
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

    final document = _parseDanmakuDocument(response);
    if (document == null) {
      return const [];
    }
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

  XmlDocument? _parseDanmakuDocument(http.Response response) {
    try {
      final xmlText = _sanitizeXml(_decodeResponseText(response));
      return XmlDocument.parse(xmlText);
    } on XmlParserException {
      return null;
    } on FormatException {
      return null;
    }
  }

  String _decodeResponseText(http.Response response) {
    final encodings =
        response.headers['content-encoding']
            ?.split(',')
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];

    var bytes = response.bodyBytes;
    for (final encoding in encodings.reversed) {
      bytes = _decodeBodyBytes(bytes, encoding);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Uint8List _decodeBodyBytes(Uint8List bytes, String encoding) {
    try {
      switch (encoding) {
        case 'gzip':
        case 'x-gzip':
          return Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
        case 'deflate':
          return Uint8List.fromList(_decodeDeflate(bytes));
        default:
          return bytes;
      }
    } catch (_) {
      return bytes;
    }
  }

  List<int> _decodeDeflate(List<int> bytes) {
    try {
      return ZLibDecoder().decodeBytes(bytes);
    } catch (_) {
      return ZLibDecoder().decodeBytes(bytes, raw: true);
    }
  }

  String _sanitizeXml(String value) {
    return value.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
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

  List<_DashStreamCandidate> _readDashCandidates(
    List<Map<String, dynamic>> streams,
  ) {
    return streams
        .map((data) {
          final segmentBase = _parseSegmentBase(data);
          if (segmentBase == null) {
            return null;
          }
          return _DashStreamCandidate(data: data, segmentBase: segmentBase);
        })
        .whereType<_DashStreamCandidate>()
        .toList(growable: false);
  }

  _DashStreamCandidate? _selectVideoCandidate(
    List<_DashStreamCandidate> candidates, {
    required int? preferredQuality,
  }) {
    if (candidates.isEmpty) {
      return null;
    }

    final sorted = [...candidates]
      ..sort((left, right) {
        final qualityRank = _videoQualityRank(
          left.data,
          preferredQuality,
        ).compareTo(_videoQualityRank(right.data, preferredQuality));
        if (qualityRank != 0) {
          return qualityRank;
        }

        final codecRank = _videoCodecRank(
          left.data,
        ).compareTo(_videoCodecRank(right.data));
        if (codecRank != 0) {
          return codecRank;
        }

        return _readInt(
          right.data['bandwidth'],
        ).compareTo(_readInt(left.data['bandwidth']));
      });
    return sorted.first;
  }

  _DashStreamCandidate? _selectAudioCandidate(
    List<_DashStreamCandidate> candidates,
  ) {
    if (candidates.isEmpty) {
      return null;
    }

    final sorted = [...candidates]
      ..sort((left, right) {
        final codecRank = _audioCodecRank(
          left.data,
        ).compareTo(_audioCodecRank(right.data));
        if (codecRank != 0) {
          return codecRank;
        }

        return _readInt(
          right.data['bandwidth'],
        ).compareTo(_readInt(left.data['bandwidth']));
      });
    return sorted.first;
  }

  int _videoQualityRank(Map<String, dynamic> data, int? preferredQuality) {
    if (preferredQuality == null) {
      return 0;
    }

    final quality = _readInt(data['id']);
    if (quality == preferredQuality) {
      return 0;
    }
    if (quality < preferredQuality) {
      return (preferredQuality - quality) * 2 - 1;
    }
    return (quality - preferredQuality) * 2;
  }

  int _videoCodecRank(Map<String, dynamic> data) {
    final codecid = _readInt(data['codecid']);
    if (codecid == 7) {
      return 0;
    }
    if (codecid == 12) {
      return 1;
    }
    if (codecid == 13) {
      return 2;
    }

    final codecs = _readLowerString(data['codecs']);
    if (codecs.contains('avc1')) {
      return 0;
    }
    if (codecs.contains('hev1') || codecs.contains('hvc1')) {
      return 1;
    }
    if (codecs.contains('av01') || codecs.contains('av1')) {
      return 2;
    }
    return 3;
  }

  int _audioCodecRank(Map<String, dynamic> data) {
    final codecs = _readLowerString(data['codecs']);
    if (codecs.contains('mp4a') || codecs.contains('aac')) {
      return 0;
    }
    return 1;
  }

  int _readInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _readLowerString(dynamic value) {
    return value?.toString().toLowerCase() ?? '';
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

class _DashSegmentBase {
  const _DashSegmentBase({
    required this.initialization,
    required this.indexRange,
  });

  final String initialization;
  final String indexRange;
}

class _DashStreamCandidate {
  const _DashStreamCandidate({required this.data, required this.segmentBase});

  final Map<String, dynamic> data;
  final _DashSegmentBase segmentBase;
}

extension _NullableFirst<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
