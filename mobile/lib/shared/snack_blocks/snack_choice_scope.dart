import 'package:flutter/widgets.dart';

/// Posts [option] as an answer to a `snack-choices` card that [authorPubkey]
/// posted; [rootId] is the thread the card sits in, if any.
typedef SnackChoiceSender =
    Future<void> Function({
      required String option,
      required String authorPubkey,
      String? rootId,
    });

/// Lets messages below a conversation answer `snack-choices` cards. A
/// conversation the user can't post in provides none, so cards only list
/// their options there.
class SnackChoiceScope extends InheritedWidget {
  const SnackChoiceScope({super.key, required this.send, required super.child});

  /// Null where the user can't post.
  final SnackChoiceSender? send;

  /// The nearest conversation's sender, or null.
  static SnackChoiceSender? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SnackChoiceScope>()?.send;

  @override
  bool updateShouldNotify(SnackChoiceScope old) => old.send != send;
}
