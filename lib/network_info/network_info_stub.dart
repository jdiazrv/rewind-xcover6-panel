/// Default target for the conditional import in main.dart — only actually
/// loads on a platform that is neither dart:io nor dart:html, which
/// doesn't happen in practice for this app's supported targets. Mirrors
/// network_info_web.dart's "no VPN detection possible" answer.
Future<bool> isVpnActive() async => false;
