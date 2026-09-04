/// Browsers have no API to ask the OS whether a VPN is active — null
/// ("can't tell"), not false ("definitely off"). CFG > Admin's per-server
/// row treats null the same as a real "yes" and just runs its reachability
/// probe — returning false here used to make it skip that probe and claim
/// "requiere VPN" unconditionally on web, contradicting this very comment.
/// Verified real via external audit, fixed 2026-09-04.
Future<bool?> isVpnActive() async => null;
