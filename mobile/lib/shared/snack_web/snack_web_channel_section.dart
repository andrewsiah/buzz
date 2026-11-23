import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../theme/buzz_icons.dart';
import '../theme/theme.dart';
import '../widgets/app_list.dart';
import '../widgets/app_list_card.dart';
import 'snack_web_launcher.dart';
import 'snack_web_links.dart';

/// The icon for each web-only channel feature.
IconData snackWebFeatureIcon(SnackWebFeature feature) => switch (feature) {
  SnackWebFeature.board => BuzzIcons.pencil,
  SnackWebFeature.docs => BuzzIcons.fileText,
  SnackWebFeature.matrix => BuzzIcons.compass,
  SnackWebFeature.poker => BuzzIcons.heart,
  SnackWebFeature.apps => BuzzIcons.layoutGrid,
};

/// Channel details card that opens the channel's web-only features (board,
/// docs, The Matrix, poker, apps) on Snack's web app in a browser sheet.
class SnackWebChannelSection extends ConsumerWidget {
  const SnackWebChannelSection({
    super.key,
    required this.channelId,
    this.verticalPadding = 0,
  });

  final String channelId;
  final double verticalPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppListCard(
      key: const ValueKey('channel-details-snack-web-card'),
      label: 'Open in Snack web',
      verticalPadding: verticalPadding,
      children: [
        for (final feature in SnackWebFeature.values)
          AppListRow(
            key: ValueKey('snack-web-${feature.panel}'),
            icon: snackWebFeatureIcon(feature),
            title: feature.label,
            trailing: Icon(
              BuzzIcons.externalLink,
              size: 18,
              color: context.colors.onSurfaceVariant,
            ),
            onTap: () => openSnackWebChannel(
              context,
              ref,
              channelId: channelId,
              feature: feature,
            ),
          ),
      ],
    );
  }
}
