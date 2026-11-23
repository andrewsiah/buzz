import 'package:buzz/shared/snack_web/snack_web_launcher.dart';
import 'package:buzz/shared/snack_web/snack_web_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';

const _channel = '580ca78b-9dae-46f3-8854-bd671853ba32';
final _event = 'a' * 64;
const _relay = 'https://snack.wesnack.app';

void main() {
  test('Snack web links open in the browser sheet, others leave the app', () {
    const cases = {
      'https://wesnack.app': true,
      'https://wesnack.app/?channel=x': true,
      'http://WESNACK.APP/': true,
      'https://wesnack.app./': true,
      'https://snack.wesnack.app/join/x': true,
      'https://game.wesnack.site/': true,
      'https://wesnack.site/': true,
      'https://notwesnack.app/': false,
      'https://wesnack.app.example.org/': false,
      'https://example.org/?u=wesnack.app': false,
      'mailto:hi@wesnack.app': false,
      'buzz://channel/$_channel': false,
    };
    for (final MapEntry(key: url, value: snack) in cases.entries) {
      final uri = Uri.parse(url);
      expect(isSnackWebUrl(uri), snack, reason: url);
      expect(
        webLinkLaunchMode(uri),
        snack ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication,
        reason: url,
      );
    }
  });

  test('channel and message links for this community open natively', () {
    final cases = <String, String?>{
      'https://wesnack.app/?channel=$_channel': 'buzz://channel/$_channel',
      'https://wesnack.app?channel=$_channel': 'buzz://channel/$_channel',
      'https://wesnack.app/?community=https%3A%2F%2Fsnack.wesnack.app'
              '&channel=$_channel&message=$_event':
          'buzz://message?channel=$_channel&id=$_event',
      'https://wesnack.app/?community=wss://SNACK.wesnack.app/'
              '&channel=$_channel':
          'buzz://channel/$_channel',
      // Another community, a web-only panel, a fragment, other pages, bad ids
      // and other hosts stay on the web.
      'https://wesnack.app/?community=https://other.example.org'
              '&channel=$_channel':
          null,
      'https://wesnack.app/?channel=$_channel&panel=board': null,
      'https://wesnack.app/?channel=$_channel#x': null,
      'https://wesnack.app/c/general?channel=$_channel': null,
      'https://wesnack.app/?channel=general': null,
      'https://wesnack.app/?channel=$_channel&message=nothex': null,
      'https://wesnack.app/?channel=$_channel&channel=$_channel': null,
      'https://wesnack.app/': null,
      'https://wesnack.app/?channel=$_channel&message=': null,
      'https://wesnack.app/?channel=&message=$_event': null,
      'https://snack.wesnack.app/?channel=$_channel': null,
      'https://example.org/?channel=$_channel': null,
    };
    for (final MapEntry(key: url, value: expected) in cases.entries) {
      expect(
        snackWebNativeLink(Uri.parse(url), relayBaseUrl: _relay)?.toString(),
        expected,
        reason: url,
      );
    }
  });

  test('builds channel, feature and community pages', () {
    expect(
      snackWebChannelUrl(relayBaseUrl: _relay, channelId: _channel).toString(),
      'https://wesnack.app/?community=https%3A%2F%2Fsnack.wesnack.app'
      '&channel=$_channel',
    );
    for (final feature in SnackWebFeature.values) {
      final url = snackWebChannelUrl(
        relayBaseUrl: 'wss://snack.wesnack.app',
        channelId: _channel,
        feature: feature,
      );
      expect(url.queryParameters, {
        'community': _relay,
        'channel': _channel,
        'panel': feature.panel,
      });
      expect(isSnackWebUrl(url), isTrue);
      // The channel page opens natively only without the panel hint.
      expect(snackWebNativeLink(url, relayBaseUrl: _relay), isNull);
    }
    expect(
      snackWebChannelUrl(relayBaseUrl: 'http://localhost:3000').toString(),
      'https://wesnack.app/?community=http%3A%2F%2Flocalhost%3A3000',
    );
    expect(
      snackWebChannelUrl(relayBaseUrl: 'not a url').toString(),
      'https://wesnack.app/',
    );
  });

  test('labels Snack-only fenced blocks and leaves code alone', () {
    const cases = <(String, String), String?>{
      ('buzz-chart', '{"type":"bar","title":"Signups"}'): 'Chart: Signups',
      (' BUZZ-CHART ', '{"type":"bar"}'): 'Chart',
      ('buzz-chart', '{"type":'): 'Chart',
      ('buzz-chart', '[1, 2]'): 'Chart',
      ('json', '{"title":"Signups"}'): null,
      ('', 'plain'): null,
    };
    for (final MapEntry(key: (language, code), :value) in cases.entries) {
      expect(snackWebOnlyFenceLabel(language, code), value, reason: language);
    }
  });
}
