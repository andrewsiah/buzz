import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The option this device picked on each `snack-choices` message, keyed by
/// message id, so the buttons settle after a tap. Like the web app, an
/// answer is a normal message: this only remembers which button to mark.
final snackChoicePicksProvider =
    NotifierProvider<SnackChoicePicks, Map<String, String>>(
      SnackChoicePicks.new,
    );

/// See [snackChoicePicksProvider].
class SnackChoicePicks extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Marks [option] as picked on [messageId].
  void pick(String messageId, String option) =>
      state = {...state, messageId: option};

  /// Clears a pick whose send failed, so the buttons come back.
  void clear(String messageId) => state = {...state}..remove(messageId);
}
