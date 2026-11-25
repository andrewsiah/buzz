part of '../message_content.dart';

class _MessageCodeBlock extends HookWidget {
  final String name;
  final String code;

  /// Whether the block sits inside a message bubble.
  final bool bubble;

  /// Text color on an accent bubble; null keeps the neutral highlighted card.
  final Color? ink;

  const _MessageCodeBlock({
    required this.name,
    required this.code,
    this.bubble = false,
    this.ink,
  });

  @override
  Widget build(BuildContext context) {
    final isCopied = useState(false);

    Future<void> handleCopy() async {
      await copyToClipboard(context, code, message: 'Code copied');
      if (!context.mounted) return;
      isCopied.value = true;
      Future.delayed(const Duration(seconds: 2), () {
        if (context.mounted) isCopied.value = false;
      });
    }

    final ink = this.ink;
    // A fence's closing newline would otherwise render as a blank last line.
    final shownCode = code.trimRight();
    final codeBaseStyle = TextStyle(
      fontFamily: CodeStyle.fontFamily,
      fontSize: CodeStyle.fontSize,
      height: CodeStyle.lineHeight,
      color: ink ?? context.colors.onSurface,
    );
    final isDark = context.theme.brightness == Brightness.dark;
    final codeTheme = isDark ? highlightDarkTheme : highlightLightTheme;
    // Syntax colors are tuned for neutral cards and lose contrast on accents.
    final codeSpans = useMemoized(
      () => ink == null
          ? highlightCode(shownCode, name, codeTheme, codeBaseStyle)
          : [TextSpan(text: shownCode)],
      [code, name, isDark, ink],
    );
    return Container(
      // In a bubble, the vertical margin brings the bubble's 8px vertical
      // padding up to its 16px side padding, so the block is inset evenly and
      // its corners stay concentric with the bubble's.
      margin: bubble
          ? const EdgeInsets.symmetric(vertical: Grid.xs - Grid.xxs)
          : const EdgeInsets.only(top: Grid.half),
      decoration: BoxDecoration(
        color: ink == null
            ? CodeStyle.background(context.colors)
            : chatCodeTint(ink, 0.14),
        borderRadius: BorderRadius.circular(
          bubble ? Radii.container - Grid.xs : 12,
        ),
        border: Border.all(
          color:
              ink?.withValues(alpha: 0.24) ?? CodeStyle.border(context.colors),
        ),
      ),
      child: Stack(
        children: [
          // Even 12px insets; the right side also reserves the copy button.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Grid.twelve,
              Grid.twelve,
              Grid.twelve + 28,
              Grid.twelve,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (name.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Grid.half),
                    child: Text(
                      name,
                      style: context.textTheme.labelSmall?.copyWith(
                        color: ink ?? context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: RichText(
                    softWrap: false,
                    text: TextSpan(style: codeBaseStyle, children: codeSpans),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: Grid.half + Grid.quarter,
            right: Grid.half + Grid.quarter,
            child: SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                onPressed: handleCopy,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  isCopied.value ? BuzzIcons.check : BuzzIcons.copy,
                  size: 14,
                  color:
                      ink ??
                      (isCopied.value
                          ? context.colors.primary
                          : context.colors.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
