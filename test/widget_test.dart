import 'package:flutter_test/flutter_test.dart';

import 'package:bilibili_player_demo/src/services/bilibili_demo_service.dart';

void main() {
  test('parses BV ids from raw input and full urls', () {
    expect(
      ParsedVideoId.tryParse('BV1xx411c79H')?.bvid,
      'BV1xx411c79H',
    );
    expect(
      ParsedVideoId.tryParse('https://www.bilibili.com/video/BV1xx411c79H')?.bvid,
      'BV1xx411c79H',
    );
  });

  test('parses av ids from raw input and full urls', () {
    expect(ParsedVideoId.tryParse('av170001')?.aid, 170001);
    expect(
      ParsedVideoId.tryParse('https://www.bilibili.com/video/av170001')?.aid,
      170001,
    );
  });
}
