import '../deeplink/deep_link.dart';

/// Snack's web app, where the channel features this app leaves out (the
/// board, docs, The Matrix, poker and pinned apps) live.
///
/// `--dart-define=SNACK_WEB_URL=<https origin>` points a build elsewhere.
final Uri snackWebOrigin = Uri.parse(
  const String.fromEnvironment(
    'SNACK_WEB_URL',
    defaultValue: 'https://wesnack.app',
  ),
);

/// Registrable domains Snack serves pages from: the web app and its
/// communities (`*.wesnack.app`) and published channel apps (`*.wesnack.site`).
const snackWebDomains = ['wesnack.app', 'wesnack.site'];

/// A channel feature that only Snack's web app has.
///
/// [panel] names the feature in [snackWebChannelUrl]. The web app opens the
/// channel today and ignores the hint, so adding panel support there needs no
/// app change.
enum SnackWebFeature {
  board('Board', 'board'),
  docs('Docs', 'docs'),
  matrix('The Matrix', 'matrix'),
  poker('Poker', 'poker'),
  apps('Apps', 'apps');

  const SnackWebFeature(this.label, this.panel);

  final String label;
  final String panel;
}

String _host(String host) {
  final lower = host.toLowerCase();
  return lower.endsWith('.') ? lower.substring(0, lower.length - 1) : lower;
}

/// Whether [uri] is a Snack web page, which opens in an in-app browser sheet
/// rather than leaving the app.
bool isSnackWebUrl(Uri uri) {
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  final host = _host(uri.host);
  if (host.isEmpty) return false;
  if (host == _host(snackWebOrigin.host)) return true;
  return snackWebDomains.any((d) => host == d || host.endsWith('.$d'));
}

/// The community's address as Snack's web app names it: the relay's HTTPS
/// origin (`https://<relay host>`), or null for an unusable [relayBaseUrl].
String? snackWebCommunity(String relayBaseUrl) {
  final relay = Uri.tryParse(relayBaseUrl);
  if (relay == null || relay.host.isEmpty) return null;
  final scheme = switch (relay.scheme) {
    'https' || 'wss' => 'https',
    'http' || 'ws' => 'http',
    _ => null,
  };
  if (scheme == null) return null;
  return Uri(
    scheme: scheme,
    host: _host(relay.host),
    port: relay.hasPort ? relay.port : null,
  ).toString();
}

/// The Snack web page for a channel in the community at [relayBaseUrl]:
/// `https://wesnack.app/?community=<relay origin>&channel=<id>`, the link
/// shape Snack's own notifications use, plus `panel=<feature>` for [feature].
/// Without [channelId] it opens the community.
Uri snackWebChannelUrl({
  required String relayBaseUrl,
  String? channelId,
  SnackWebFeature? feature,
}) {
  final community = snackWebCommunity(relayBaseUrl);
  final params = <String, String>{
    'community': ?community,
    if (channelId != null && channelId.isNotEmpty) 'channel': channelId,
    if (feature != null && channelId != null && channelId.isNotEmpty)
      'panel': feature.panel,
  };
  return snackWebOrigin.replace(
    path: '/',
    queryParameters: params.isEmpty ? null : params,
  );
}

/// The `buzz://` link this app opens natively for a Snack web link to a
/// channel or message in the current community, or null when the link must
/// open in the browser.
///
/// Accepts `https://wesnack.app/?channel=<uuid>[&message=<event id>]` with an
/// optional `community=<origin>` naming the community at [relayBaseUrl].
/// Anything else (other paths, a fragment, another community, a `panel`
/// asking for a web-only feature, unknown parameters) stays a web link.
Uri? snackWebNativeLink(Uri uri, {required String relayBaseUrl}) {
  if (!isSnackWebUrl(uri) ||
      _host(uri.host) != _host(snackWebOrigin.host) ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  const allowed = {'community', 'channel', 'message'};
  final all = uri.queryParametersAll;
  if (all.keys.any((key) => !allowed.contains(key)) ||
      all.values.any((values) => values.length != 1)) {
    return null;
  }
  final community = uri.queryParameters['community'];
  if (community != null) {
    final here = snackWebCommunity(relayBaseUrl);
    if (here == null || snackWebCommunity(community) != here) return null;
  }
  final channel = uri.queryParameters['channel'];
  final message = uri.queryParameters['message'];
  if (channel == null || channel.isEmpty || message == '') return null;
  final link = message == null
      ? Uri(scheme: 'buzz', host: 'channel', path: '/$channel')
      : Uri.parse(buildMessageLink(channelId: channel, messageId: message));
  final valid = message == null
      ? parseChannelDeepLink(link) != null
      : parseMessageDeepLink(link) != null;
  return valid ? link : null;
}
