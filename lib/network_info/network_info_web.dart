/// Browsers have no API to ask the OS whether a VPN is active — always
/// "unknown, assume no" here. CFG > Admin's per-server VPN gating simply
/// never disables a Tailscale-range entry on web because of this; the
/// reachability probe alone decides what's shown as connected.
Future<bool> isVpnActive() async => false;
