/// Signals that work was cancelled because the active community changed while
/// it was in flight.
///
/// It is a [StateError] so existing invalid-state handling still applies, but
/// it is its own type so callers can tell a real community switch apart from
/// any other invalid-state failure (a dropped connection, an unverified chat).
class CommunityChangedError extends StateError {
  /// Creates an error for work invalidated by a community switch.
  CommunityChangedError(super.message);
}
