import 'dart:io';

// Resolves a hostname (e.g. an mDNS ".local" name) to a single IP once, so
// every query issued during one report generation targets the exact same
// server. mDNS resolution on Android (NSD) has been observed to flip
// mid-session, silently answering a fresh lookup with a stale/different
// device — a plain hostname passed straight to `http` re-resolves on every
// single request, so a handful of a report's dozen queries could each land
// on a different target. Falls back to the original hostname if the lookup
// fails or returns nothing, so callers always get a usable value.
Future<String> resolveHostOnce(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return host;
  try {
    // IPv4 only: an IPv6 literal contains colons itself, which breaks the
    // plain "$host:$port" authority string built downstream for Uri.http.
    final addrs = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 5));
    if (addrs.isNotEmpty) return addrs.first.address;
  } catch (_) {
    // Fall through to the original hostname below.
  }
  return host;
}
