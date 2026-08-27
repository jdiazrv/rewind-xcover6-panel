import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Scans every host on the device's local /24 subnet(s) for a Signal K
/// server on [port] (default 3000), by requesting the standard discovery
/// document at `http://<ip>:<port>/signalk` and checking it looks like one.
/// Used as a fallback when `lysmarine.local` (mDNS) doesn't resolve on a
/// different boat's network — mDNS hostnames only work if that specific
/// router/network relays them, which isn't guaranteed away from the boat
/// they were set up on.
Future<List<String>> scanLanForSignalK(int port, {void Function(int checked, int total)? onProgress}) async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  final prefixes = <String>{};
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      final parts = addr.address.split('.');
      if (parts.length == 4) prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
  }
  if (prefixes.isEmpty) return const [];

  final found = <String>[];
  final total = prefixes.length * 254;
  var checked = 0;
  const batchSize = 32;

  for (final prefix in prefixes) {
    var i = 1;
    while (i <= 254) {
      final batch = <Future<void>>[];
      for (var j = 0; j < batchSize && i <= 254; j++, i++) {
        final ip = '$prefix.$i';
        batch.add(() async {
          try {
            final res = await http
                .get(Uri.http('$ip:$port', '/signalk'))
                .timeout(const Duration(milliseconds: 700));
            if (res.statusCode == 200 && (res.body.contains('"endpoints"') || res.body.contains('signalk'))) {
              found.add(ip);
            }
          } catch (_) {
            // unreachable / no server on this host — expected for most of the subnet
          } finally {
            checked++;
            onProgress?.call(checked, total);
          }
        }());
      }
      await Future.wait(batch);
    }
  }
  return found;
}
