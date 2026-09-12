import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../polars.dart';
import '../theme.dart';

/// Página POLAR del carrusel de VNT: qué debería dar el barco con este
/// viento, qué está dando, y —si hay destino— cuánto se tarda de verdad
/// contando los bordos.
///
/// Regla de estilo que atraviesa todo el widget: **no da órdenes**. Ni
/// "orza" ni "vira". Enseña el hecho, la alternativa y lo que cuesta en
/// minutos, y deja decidir. Virar depende de la costa, del tráfico y de la
/// tripulación, cosas que la app no sabe; y "orza 9°" fingiría una
/// precisión que ni la polar de certificado ni una corredera calibrada al
/// 3 % pueden respaldar ("vira u orza es demasiado categórico y faltan
/// argumentos", 2026-09-12).
class PolarPanel extends StatelessWidget {
  const PolarPanel({
    super.key,
    required this.polar,
    required this.factorPercent,
    required this.twsKn,
    required this.twaDeg,
    required this.boatSpeedKn,
    required this.usingSog,
    required this.engineRunning,
    this.twdDeg,
    this.destinationDistanceNm,
    this.destinationBearingDeg,
    this.now,
  });

  final PolarTable polar;
  final double factorPercent;
  final double? twsKn;
  final double? twaDeg;

  /// Velocidad real del barco. La polar se mide por el agua; si solo hay
  /// GPS se usa, pero entonces la corriente se cuela en el resultado y hay
  /// que decirlo.
  final double? boatSpeedKn;
  final bool usingSog;
  final bool engineRunning;

  final double? twdDeg;
  final double? destinationDistanceNm;
  final double? destinationBearingDeg;
  final DateTime? now;

  double get _factor => factorPercent / 100;

  /// Velocidad objetivo ya ajustada al porcentaje del barco.
  double? get _target {
    final tws = twsKn, twa = twaDeg;
    if (tws == null || twa == null) return null;
    final v = polar.speedAt(tws, twa);
    return v == null ? null : v * _factor;
  }

  LegEstimate? get _leg {
    final d = destinationDistanceNm,
        b = destinationBearingDeg,
        twd = twdDeg,
        tws = twsKn;
    if (d == null || b == null || twd == null || tws == null) return null;
    return computeLegEstimate(
      polar: polar,
      distanceNm: d,
      bearingDeg: b,
      twdDeg: twd,
      twsKn: tws,
      factorPercent: factorPercent,
    );
  }

  static String _hm(double hours) {
    if (!hours.isFinite || hours < 0) return '--';
    final total = (hours * 60).round();
    final h = total ~/ 60, m = total % 60;
    return h == 0 ? '$m min' : '$h h $m min';
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 8),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _header() => Row(
    children: [
      Expanded(
        child: Text(
          polar.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: cText,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      Text(
        'al ${factorPercent.round()} %',
        style: const TextStyle(
          color: cMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  Widget _body() {
    if (engineRunning) {
      return _notice(
        Icons.settings,
        'A motor',
        'La polar solo dice algo navegando a vela. Con el motor en marcha '
            'el porcentaje no significa nada, así que no se calcula.',
        cOrange,
      );
    }
    final tws = twsKn, twa = twaDeg, speed = boatSpeedKn;
    if (tws == null || twa == null || speed == null) {
      return _notice(
        Icons.help_outline,
        'Faltan datos',
        'Hacen falta viento real (fuerza y ángulo) y velocidad del barco. '
            'Revisa la anemometría y la corredera.',
        cMuted,
      );
    }
    final target = _target;
    final leg = _leg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 4, child: _speedRow(target, speed)),
        const SizedBox(height: 8),
        Expanded(flex: 5, child: leg == null ? _noDestination(tws) : _legCard(leg, tws, twa)),
      ],
    );
  }

  // ── Objetivo contra real ──────────────────────────────────────────────
  Widget _speedRow(double? target, double speed) {
    final ratio = (target == null || target <= 0) ? null : speed / target;
    final color = ratio == null
        ? cMuted
        : ratio >= 0.95
        ? cGreen
        : ratio >= 0.85
        ? cCyan
        : cOrange;
    return Row(
      children: [
        Expanded(
          child: _card(
            'OBJETIVO',
            target == null ? '--' : target.toStringAsFixed(1),
            'kn',
            cMuted,
            note: target == null
                ? 'fuera del abanico navegable'
                : 'con ${twsKn!.toStringAsFixed(0)} kn a '
                      '${twaDeg!.abs().round()}°',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _card(
            usingSog ? 'REAL (GPS)' : 'REAL',
            speed.toStringAsFixed(1),
            'kn',
            cText,
            note: usingSog
                ? 'sin corredera: la corriente entra en el dato'
                : 'por el agua',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _card(
            'RENDIMIENTO',
            ratio == null ? '--' : (ratio * 100).round().toString(),
            '%',
            color,
            note: polar.twsOutOfRange(twsKn!)
                ? 'viento fuera de la tabla'
                : 'de lo que da esta polar',
          ),
        ),
      ],
    );
  }

  // ── Sin destino: ángulos óptimos, solo dentro de sus conos ────────────
  Widget _noDestination(double tws) {
    final twa = twaDeg!.abs();
    final beat = polar.beatFor(tws);
    final run = polar.runFor(tws);
    final lines = <String>[];
    if (beat != null && twa < 70) {
      lines.add(
        'Ciñendo, esta polar rinde más a ${beat.angle.round()}°: '
        '${beat.vmg.toStringAsFixed(1)} kn de avance contra el viento.',
      );
    } else if (run != null && twa > 140) {
      lines.add(
        'En popa, el mejor avance es a ${run.angle.round()}°: '
        '${run.vmg.toStringAsFixed(1)} kn.',
      );
    }
    return _panel(
      title: 'SIN DESTINO ACTIVO',
      children: [
        const Text(
          'Con un destino en el plóter esta página calcula además las millas '
          'y el tiempo reales, contando los bordos si hay que ceñir.',
          style: TextStyle(color: cMuted, fontSize: 12, height: 1.4),
        ),
        for (final l in lines) ...[
          const SizedBox(height: 8),
          Text(
            l,
            style: const TextStyle(color: cText, fontSize: 13, height: 1.4),
          ),
        ],
      ],
    );
  }

  // ── Con destino ───────────────────────────────────────────────────────
  Widget _legCard(LegEstimate leg, double tws, double twa) {
    final eta = now?.add(
      Duration(seconds: (leg.hours * 3600).round()),
    );
    final children = <Widget>[];

    if (leg.isZigzag) {
      final word = leg.mode == LegMode.beat ? 'ceñir' : 'trasluchar';
      children.add(
        _line(
          'El destino queda a '
          '${_alphaDeg(leg).round()}° del viento: no se puede apuntar, hay '
          'que $word.',
        ),
      );
      children.add(
        _big(
          '${leg.sailedNm.toStringAsFixed(1)} M reales',
          'en línea recta son ${leg.directNm.toStringAsFixed(1)} M',
        ),
      );
      children.add(
        _big(
          _hm(leg.hours),
          'a ${leg.sailAngle.round()}°, avanzando '
          '${leg.madeGoodKn.toStringAsFixed(1)} kn hacia el destino'
          '${eta == null ? '' : ' · llegada ${_clock(eta)}'}',
        ),
      );
      final cmp = _compareWithCurrent(leg, tws, twa);
      if (cmp != null) children.add(_line(cmp));
      children.add(_tackLine(leg, twa));
    } else {
      children.add(_line('Se puede apuntar al destino.'));
      children.add(
        _big(
          '${leg.directNm.toStringAsFixed(1)} M · ${_hm(leg.hours)}',
          'al objetivo de ${leg.madeGoodKn.toStringAsFixed(1)} kn'
          '${eta == null ? '' : ' · llegada ${_clock(eta)}'}',
        ),
      );
      final actual = boatSpeedKn!;
      if (actual > 0.2) {
        final hoursNow = leg.directNm / actual;
        children.add(
          _line(
            'Al ritmo de ahora (${actual.toStringAsFixed(1)} kn): '
            '${_hm(hoursNow)}.',
          ),
        );
      }
    }

    if (leg.twsOutOfRange) {
      children.add(
        _line(
          'El viento se sale de la tabla de la polar; el cálculo usa su '
          'extremo y se queda corto.',
        ),
      );
    }
    children.add(
      _line(
        'Supone viento constante y mar libre: no cuenta rolones, corriente, '
        'lo que cuesta cada virada ni si hay costa por medio.',
        dim: true,
      ),
    );

    return _panel(title: 'HASTA EL DESTINO', children: children);
  }

  double _alphaDeg(LegEstimate leg) {
    final b = destinationBearingDeg, twd = twdDeg;
    if (b == null || twd == null) return leg.sailAngle;
    var d = (b - twd) % 360;
    if (d > 180) d -= 360;
    return d.abs();
  }

  /// Compara el ángulo que se lleva con el óptimo, **en minutos** sobre
  /// este tramo, y se calla cuando la diferencia está por debajo del ruido
  /// del propio cálculo.
  String? _compareWithCurrent(LegEstimate leg, double tws, double twa) {
    final v = polar.speedAt(tws, twa);
    if (v == null) return null;
    final a = twa.abs() * math.pi / 180;
    final madeGood = (v * _factor) * (leg.mode == LegMode.beat ? math.cos(a) : -math.cos(a));
    if (madeGood <= 0.05) {
      return 'Al ángulo que llevas (${twa.abs().round()}°) no se avanza '
          'hacia el destino.';
    }
    final along = leg.hours * leg.madeGoodKn;
    final hoursNow = along / madeGood;
    final deltaMin = (hoursNow - leg.hours) * 60;
    final noiseMin = math.max(3.0, leg.hours * 60 * 0.04);
    if (deltaMin.abs() < noiseMin) {
      return 'A los ${twa.abs().round()}° que llevas sale prácticamente '
          'igual: la diferencia cabe dentro del margen del cálculo.';
    }
    return 'A los ${twa.abs().round()}° que llevas, '
        '${deltaMin.round()} min más que a ${leg.sailAngle.round()}°.';
  }

  /// Hecho comprobable, no instrucción: si este bordo acerca o aleja.
  Widget _tackLine(LegEstimate leg, double twa) {
    final b = destinationBearingDeg, twd = twdDeg;
    if (b == null || twd == null) return const SizedBox.shrink();
    // El rumbo que se lleva, reconstruido del viento y del ángulo.
    final heading = (twd + twa) % 360;
    var off = (b - heading) % 360;
    if (off > 180) off -= 360;
    final closing = off.abs() < 90;
    return _line(
      closing
          ? 'Este bordo te acerca: el destino queda ${off.abs().round()}° '
                'de tu rumbo.'
          : 'Este bordo te aleja: el destino queda ${off.abs().round()}° '
                'de tu rumbo, por detrás del través.',
    );
  }

  // ── Piezas ────────────────────────────────────────────────────────────
  Widget _card(
    String title,
    String value,
    String unit,
    Color color, {
    String? note,
  }) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
    decoration: BoxDecoration(
      color: cPanel,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cPanel2),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                ),
              ),
            ),
            Text(
              unit,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 52,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
        if (note != null)
          Text(
            note,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: cMuted, fontSize: 10, height: 1.25),
          ),
      ],
    ),
  );

  Widget _panel({required String title, required List<Widget> children}) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: cPanel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cPanel2),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 6),
              ...children,
            ],
          ),
        ),
      );

  Widget _line(String text, {bool dim = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      text,
      style: TextStyle(
        color: dim ? cMuted.withValues(alpha: 0.75) : cText,
        fontSize: dim ? 10.5 : 12.5,
        height: 1.35,
      ),
    ),
  );

  Widget _big(String value, String note) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: cCyan,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            height: 1.1,
          ),
        ),
        Text(
          note,
          style: const TextStyle(color: cMuted, fontSize: 11, height: 1.3),
        ),
      ],
    ),
  );

  Widget _notice(IconData icon, String title, String body, Color color) =>
      Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cPanel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cPanel2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
