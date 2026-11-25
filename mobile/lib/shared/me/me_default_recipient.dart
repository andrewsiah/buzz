import 'me_sync.dart';

/// Who a new Solo chat goes to when the owner hasn't picked one: their main
/// agent, else the agent they last started a chat with, else their only agent.
/// Null only when several agents fit and none was ever chosen.
String? defaultMeRecipient({
  required Set<String> available,
  String? mainAgent,
  String? recent,
}) {
  if (mainAgent != null && available.contains(mainAgent)) return mainAgent;
  if (recent != null && available.contains(recent)) return recent;
  if (available.length == 1) return available.single;
  return null;
}

/// This device's memory of the agent the owner last started a Solo chat with.
String meRecentAgentKey(MeSync sync) =>
    'me-recent-agent:${sync.community}:${sync.pubkey}';

String? readMeRecentAgent(MeSync sync) =>
    sync.prefs?.getString(meRecentAgentKey(sync));

Future<void> rememberMeRecentAgent(MeSync sync, String agent) async {
  try {
    await sync.prefs?.setString(meRecentAgentKey(sync), agent);
  } catch (_) {
    // Only a convenience: the next chat falls back to the main agent.
  }
}
