// No raw UDP socket access in a browser — mDNS resolution isn't possible
// here. Returning null just means "couldn't do it ourselves", and the
// caller falls back to letting the browser/OS resolver try .local
// normally, which actually does work in some desktop browsers (unlike
// Android, which is the platform this exists for).
Future<String?> resolveMdnsHost(
  String hostname, {
  Duration timeout = const Duration(seconds: 4),
}) async => null;
