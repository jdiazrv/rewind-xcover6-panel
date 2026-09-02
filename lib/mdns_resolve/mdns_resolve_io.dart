import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

// Android's own libc/getaddrinfo does NOT resolve .local (mDNS) hostnames
// the way macOS/iOS/Linux-with-nss-mdns do — confirmed live 2026-09-02:
// `Failed host lookup: 'lysmarine.local' (OS Error: No address associated
// with hostname, errno = 7)`, even while sitting on the exact WiFi network
// that hostname is published on. This does the mDNS A-record query
// ourselves instead of relying on the OS resolver.
Future<String?> resolveMdnsHost(
  String hostname, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = MDnsClient();
  try {
    await client.start();
    final query = client
        .lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(hostname),
        )
        .timeout(timeout, onTimeout: (sink) => sink.close());
    await for (final record in query) {
      return record.address.address;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.stop();
  }
}
