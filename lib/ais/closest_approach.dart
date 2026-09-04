part of '../main.dart';

// Which AIS target is "the" collision risk right now (closest/soonest CPA
// within the configured thresholds) plus the geometry helpers it needs —
// split out of main.dart to shrink it. _s is the Dashboard State this
// reads live data from (own position/heading/speed, settings, the visible
// AIS target list) the same way every other part of the app does, just
// threaded in explicitly since this class isn't the State itself.
class _ClosestApproachService {
  _ClosestApproachService(this._s);
  final _DashboardState _s;

  ({
    AisTarget target,
    double? cpaNm,
    double? tcpaMin,
    double? bearingDeg,
    double? distNm,
    String? crossing,
  })?
  closestApproachTarget() {
    final ownLat = _s.signalK.latitude;
    final ownLon = _s.signalK.longitude;
    final ownHeading = _s._freshHeading;
    final ownCog = _s._freshCog ?? ownHeading;
    final ownSog = _s._freshSog ?? 0;
    ({
      AisTarget target,
      double? cpaNm,
      double? tcpaMin,
      double? bearingDeg,
      double? distNm,
      String? crossing,
    })?
    best;

    for (final target in _s._visibleAisTargets.values) {
      final last = target.lastUpdate;
      if (last != null && DateTime.now().difference(last).inMinutes > 10) {
        continue;
      }
      // Only trust the plugin's own CPA/TCPA while it's actually recent —
      // see pluginCpaUpdate's doc comment. A stopped-publishing plugin
      // means these fall through to null here, which the local geometry
      // calculation below fills in as normal (its own `??=`), rather than
      // an old prediction winning forever just because it's non-null.
      final pluginCpaFresh =
          target.pluginCpaUpdate != null &&
          DateTime.now().difference(target.pluginCpaUpdate!) <
              const Duration(seconds: 120);
      double? cpaNm = pluginCpaFresh ? target.pluginCpaNm : null;
      double? tcpaMin = pluginCpaFresh ? target.pluginTcpaMin : null;
      double? bearingDeg;
      double? distNm;
      String? crossing;

      if (ownLat != null &&
          ownLon != null &&
          target.lat != null &&
          target.lon != null) {
        final rel = _bearingDistanceNm(
          ownLat,
          ownLon,
          target.lat!,
          target.lon!,
        );
        bearingDeg = rel.bearingDeg;
        distNm = rel.distNm;

        if ((cpaNm == null || tcpaMin == null) &&
            ownCog != null &&
            target.cogDeg != null &&
            target.sogKn != null) {
          final brg = rel.bearingDeg * math.pi / 180;
          final rN = rel.distNm * math.cos(brg);
          final rE = rel.distNm * math.sin(brg);
          final ownCogRad = ownCog * math.pi / 180;
          final tgtCogRad = target.cogDeg! * math.pi / 180;
          final vN =
              target.sogKn! * math.cos(tgtCogRad) -
              ownSog * math.cos(ownCogRad);
          final vE =
              target.sogKn! * math.sin(tgtCogRad) -
              ownSog * math.sin(ownCogRad);
          final cpa = _cpa(rN, rE, vN, vE);
          cpaNm ??= cpa?.cpaNm;
          tcpaMin ??= cpa?.tcpaMin;
          // Same "worth calling proa/popa" gate as the AIS tab's own list
          // view (_aisShowsCrossing): only when the target is actually
          // moving and will pass close, so a stopped/anchored contact or a
          // wide-berth crossing doesn't get a misleading label.
          if (ownHeading != null &&
              (cpaNm ?? double.infinity) < 5 &&
              target.sogKn! > 0.2) {
            crossing = _crossingLabel(
              rN,
              rE,
              vN,
              vE,
              ownHeading * math.pi / 180,
            );
          }
        }
      }

      // Both CPA and TCPA must be known and within range at once — a
      // target with only one of the two computed (e.g. distance known but
      // no CPA yet) used to slip through on the other check alone, which
      // is how a contact 30 NM out with a stray CPA reading could show up
      // as "closest approach". Both thresholds are user-configurable
      // (CFG → Pantalla → AIS).
      if (cpaNm == null || tcpaMin == null) continue;
      // A target 40 minutes out at its current CPA isn't a collision risk
      // yet — don't let it steal the "closest approach" slot from something
      // that's actually about to happen.
      if (tcpaMin > _s.settings.aisTcpaMaxMin) continue;
      // A target that will pass 6 NM off isn't "the" closest approach either.
      if (cpaNm > _s.settings.aisCpaMaxNm) continue;
      final candidate = (
        target: target,
        cpaNm: cpaNm,
        tcpaMin: tcpaMin,
        bearingDeg: bearingDeg,
        distNm: distNm,
        crossing: crossing,
      );
      if (best == null) {
        best = candidate;
        continue;
      }
      // candidate.cpaNm/tcpaMin are non-null here (promoted by the early
      // `if (cpaNm == null || tcpaMin == null) continue;` above) — only
      // best's are still nullable (its declared type spans every
      // iteration, not just this one's promotion).
      final cpaCmp = candidate.cpaNm.compareTo(best.cpaNm ?? double.infinity);
      if (cpaCmp < 0 ||
          (cpaCmp == 0 &&
              candidate.tcpaMin < (best.tcpaMin ?? double.infinity))) {
        best = candidate;
      }
    }
    return best;
  }

  /// Where the relative track crosses our own heading line (dead ahead vs.
  /// astern) — same geometry as the AIS tab's own crossing label, so "por
  /// proa"/"por popa" means the same thing in both places.
  String? _crossingLabel(
    double relN,
    double relE,
    double vN,
    double vE,
    double headingRad,
  ) {
    final cosH = math.cos(headingRad), sinH = math.sin(headingRad);
    final fwd0 = relN * cosH + relE * sinH;
    final right0 = -relN * sinH + relE * cosH;
    final vFwd = vN * cosH + vE * sinH;
    final vRight = -vN * sinH + vE * cosH;
    if (vRight.abs() < 0.05) return null;
    final tStar = -right0 / vRight;
    if (tStar < 0) return null;
    return (fwd0 + vFwd * tStar) >= 0 ? 'POR PROA' : 'POR POPA';
  }

  ({double bearingDeg, double distNm}) _bearingDistanceNm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 3440.065; // nautical miles
    final lat1r = lat1 * math.pi / 180;
    final lat2r = lat2 * math.pi / 180;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1r) *
            math.cos(lat2r) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    final y = math.sin(dLon) * math.cos(lat2r);
    final x =
        math.cos(lat1r) * math.sin(lat2r) -
        math.sin(lat1r) * math.cos(lat2r) * math.cos(dLon);
    final brg = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    return (bearingDeg: brg, distNm: r * c);
  }

  ({double cpaNm, double tcpaMin})? _cpa(
    double rN,
    double rE,
    double vN,
    double vE,
  ) {
    final vv = vN * vN + vE * vE;
    if (vv < 1e-6) return null;
    final t = -(rN * vN + rE * vE) / vv;
    if (t < 0) return null;
    final cN = rN + vN * t;
    final cE = rE + vE * t;
    return (cpaNm: math.sqrt(cN * cN + cE * cE), tcpaMin: t * 60);
  }
}
