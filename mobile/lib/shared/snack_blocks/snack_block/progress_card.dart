part of '../snack_block.dart';

int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A background job's card: status and time, title, step count and the
/// latest step (or the plan's current item).
class _ProgressCard extends HookWidget {
  const _ProgressCard({required this.progress, this.ink, this.now});

  final SnackProgress progress;
  final Color? ink;
  final int? now;

  @override
  Widget build(BuildContext context) {
    final running = progress.status == 'running';
    final clock = useState(now ?? _unixNow());
    final at = now ?? clock.value;
    // Seconds matter early on; past an hour, or once quiet, minutes do.
    final slow = at - progress.startedAt >= 3600 || progress.isStale(at);
    useEffect(() {
      if (now != null || !running) return null;
      final timer = Timer.periodic(
        Duration(seconds: slow ? 60 : 1),
        (_) => clock.value = _unixNow(),
      );
      return timer.cancel;
    }, [now, running, slow]);
    final stale = progress.isStale(at);
    final label = progress.label(at);
    final elapsed = progress.elapsed(at);
    final quiet = ink ?? context.colors.onSurfaceVariant;
    final tone =
        ink ??
        switch (progress.status) {
          _ when stale => context.appColors.warning,
          'done' => context.appColors.success,
          'failed' => context.colors.error,
          'stopped' => context.colors.onSurfaceVariant,
          _ => context.colors.primary,
        };
    final icon = switch (progress.status) {
      _ when stale => BuzzIcons.circleAlert,
      'done' => BuzzIcons.circleCheck,
      'failed' => BuzzIcons.circleX,
      'stopped' => BuzzIcons.circleX,
      _ => BuzzIcons.loaderCircle,
    };
    final last = progress.steps.isEmpty ? null : progress.steps.last;
    final detail = [
      progress.stepCount,
      if (progress.planTotal > 0)
        'plan ${progress.planDone}/${progress.planTotal}',
      if (progress.activePlan != null)
        'Now: ${progress.activePlan}'
      else if (last != null)
        'Last: ${last.text}',
    ].join(' · ');
    return Semantics(
      container: true,
      // The ticking time stays out, so a focused card isn't re-read.
      label: '${progress.title}: $label. $detail',
      excludeSemantics: true,
      child: _CardFrame(
        ink: ink,
        child: Column(
          key: const ValueKey('snack-progress-card'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: tone),
                const SizedBox(width: Grid.half),
                Flexible(
                  child: Text(
                    '$label · $elapsed',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.labelMedium?.copyWith(
                      color: tone,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Grid.half),
            Text(
              progress.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodyLarge?.copyWith(
                color: ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Grid.quarter),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(color: quiet),
            ),
          ],
        ),
      ),
    );
  }
}
