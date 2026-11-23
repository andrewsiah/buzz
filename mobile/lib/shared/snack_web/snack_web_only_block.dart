import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../relay/relay.dart';
import '../theme/buzz_icons.dart';
import '../theme/theme.dart';
import 'snack_web_launcher.dart';
import 'snack_web_links.dart';

/// A one-line stand-in for message content only Snack's web app draws (a
/// `buzz-chart` block), instead of its raw source: "[label] · Open in Snack",
/// which opens the community on Snack's web app in a browser sheet.
class SnackWebOnlyBlock extends ConsumerWidget {
  const SnackWebOnlyBlock({super.key, required this.label, this.ink});

  final String label;

  /// Text color on an accent bubble.
  final Color? ink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = ink ?? context.colors.onSurfaceVariant;
    final link = ink ?? context.colors.primary;
    final style = context.textTheme.bodyMedium;
    Future<void> open() async {
      final url = snackWebChannelUrl(
        relayBaseUrl: ref.read(relayConfigProvider).baseUrl,
      );
      try {
        await ref.read(webLinkLauncherProvider)(url);
      } catch (error) {
        debugPrint('Snack web link failed: $error');
      }
    }

    return Semantics(
      button: true,
      label: '$label, Open in Snack',
      excludeSemantics: true,
      onTap: open,
      child: GestureDetector(
        key: const ValueKey('snack-web-only-block'),
        behavior: HitTestBehavior.opaque,
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Grid.half),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(BuzzIcons.activity, size: 16, color: color),
              const SizedBox(width: Grid.half),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '$label · '),
                      TextSpan(
                        text: 'Open in Snack',
                        style: TextStyle(
                          color: link,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  style: style?.copyWith(color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
