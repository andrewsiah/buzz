import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/theme/buzz_icons.dart';
import '../../shared/theme/theme.dart';
import 'catch_up_sources.dart';

/// Home's "Catch up" row above the channel list, with the count of cards
/// waiting (web `CatchUpBadge`), laid out like the channel rows below it.
class CatchUpEntryRow extends ConsumerWidget {
  const CatchUpEntryRow({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(catchUpBadgeCountProvider);
    final foreground = navigationPrimaryForeground(context);
    return Semantics(
      label: count == 0 ? 'Catch up' : 'Catch up, $count waiting',
      button: true,
      onTap: onOpen,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('home-catch-up-row'),
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Grid.gutter,
            vertical: Grid.inventoryRowInset,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    BuzzIcons.checkCheck,
                    size: 20,
                    color: foreground,
                  ),
                ),
              ),
              const SizedBox(width: Grid.inventoryLabelGap),
              Expanded(
                child: Text(
                  'Catch up',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: navigationSectionTextStyle.copyWith(
                    fontSize: 17,
                    height: 22 / 17,
                    color: foreground,
                    fontWeight: count > 0 ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (count > 0)
                Container(
                  key: const Key('home-catch-up-badge'),
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Grid.half + Grid.quarter,
                    vertical: Grid.quarter,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.primary,
                    borderRadius: BorderRadius.circular(
                      Radii.navigationCapsule,
                    ),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    textAlign: TextAlign.center,
                    style: context.textTheme.labelSmall?.copyWith(
                      color: context.colors.onPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
