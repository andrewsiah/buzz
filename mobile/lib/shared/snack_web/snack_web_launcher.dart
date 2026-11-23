import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../relay/relay.dart';
import '../widgets/feedback_snackbar.dart';
import 'snack_web_links.dart';

/// How a web link leaves the app: Snack's own pages in an in-app browser
/// sheet (Safari View Controller on iOS), everything else in the default
/// browser.
LaunchMode webLinkLaunchMode(Uri uri) => isSnackWebUrl(uri)
    ? LaunchMode.inAppBrowserView
    : LaunchMode.externalApplication;

/// Opens a web link the way [webLinkLaunchMode] chooses. Overridable in tests.
final webLinkLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: webLinkLaunchMode(uri)),
);

/// Opens [feature] (or, without one, the channel itself) for [channelId] on
/// Snack's web app, and says so when it can't.
Future<void> openSnackWebChannel(
  BuildContext context,
  WidgetRef ref, {
  required String channelId,
  SnackWebFeature? feature,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final url = snackWebChannelUrl(
    relayBaseUrl: ref.read(relayConfigProvider).baseUrl,
    channelId: channelId,
    feature: feature,
  );
  bool opened;
  try {
    opened = await ref.read(webLinkLauncherProvider)(url);
  } on PlatformException {
    // launchUrl throws instead of returning false on some failures.
    opened = false;
  }
  if (opened) return;
  messenger?.showFeedbackSnackBar(
    const SnackBar(content: Text('Couldn’t open Snack.')),
    kind: ToastKind.error,
  );
}
