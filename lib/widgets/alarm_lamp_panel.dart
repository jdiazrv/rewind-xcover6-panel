part of '../main.dart';

// ─── Panel de alarmas con testigos ──────────────────────────────────────────
// Una plancha negra con las leyendas grabadas y un piloto por alarma, como el
// cuadro de un barco de verdad: se mira de lejos y se entiende sin leer.
//
// No enseña solo lo que está sonando (eso ya lo hace la campana de la
// cabecera) sino TODAS las alarmas configuradas y en qué estado está cada
// una, incluidas las zonas que define el propio Signal K.

enum LampState {
  /// Sin configurar o desactivada: piloto apagado.
  off,

  /// Configurada y en orden.
  ok,

  /// Configurada pero ahora mismo no se está vigilando (sin datos, motor
  /// parado, ancla sin armar), o disparada pero silenciada.
  warn,

  /// Disparada.
  alarm,
}

extension LampStateLook on LampState {
  Color get color => switch (this) {
    LampState.off => const Color(0xff2a3238),
    LampState.ok => const Color(0xff3ddc64),
    LampState.warn => const Color(0xffffa329),
    LampState.alarm => const Color(0xffff4242),
  };

  String get label => switch (this) {
    LampState.off => 'DESACTIVADA',
    LampState.ok => 'EN ORDEN',
    LampState.warn => 'SIN VIGILAR',
    LampState.alarm => 'ALARMA',
  };
}

/// Cómo se pinta un estado de Signal K. Lo que no se conoce va en naranja:
/// un estado raro no es "en orden".
LampState lampForSkState(String state) => switch (state) {
  'nominal' || 'normal' => LampState.ok,
  'alarm' || 'emergency' => LampState.alarm,
  _ => LampState.warn,
};

/// Una fila del panel.
class AlarmLamp {
  const AlarmLamp({
    required this.label,
    required this.state,
    this.detail = '',
    this.muted = false,
  });

  final String label;

  /// Lo que hay configurado o por qué está como está: "mín. 1,0 bar",
  /// "ancla sin armar", "CPA 0,3 NM".
  final String detail;
  final LampState state;
  final bool muted;
}

/// Piloto con aro cromado: un anillo metálico con brillo arriba y sombra
/// abajo, el pozo oscuro donde va el cristal, y el propio LED con su halo
/// cuando está encendido.
class ChromeLed extends StatelessWidget {
  const ChromeLed({super.key, required this.state, this.size = 26});

  final LampState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final on = state != LampState.off;
    final c = state.color;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        // El aro. Un degradado diagonal claro-oscuro-claro es lo que hace que
        // un círculo gris parezca metal pulido.
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xfff2f6f8),
              Color(0xff9aa7ae),
              Color(0xff44505a),
              Color(0xffc9d4da),
            ],
            stops: [0.0, 0.35, 0.65, 1.0],
          ),
          boxShadow: [
            const BoxShadow(
              color: Color(0xcc000000),
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
            if (on)
              BoxShadow(
                color: c.withValues(alpha: 0.55),
                blurRadius: size * 0.7,
                spreadRadius: size * 0.06,
              ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(size * 0.13),
          child: DecoratedBox(
            // El pozo negro bajo el cristal: sin él el LED apagado parece una
            // pegatina gris en vez de una bombilla que no luce.
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xff05080a),
            ),
            child: Padding(
              padding: EdgeInsets.all(size * 0.055),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.35, -0.4),
                    radius: 0.95,
                    colors: on
                        ? [
                            Color.lerp(c, Colors.white, 0.75)!,
                            c,
                            Color.lerp(c, Colors.black, 0.55)!,
                          ]
                        : const [
                            Color(0xff2f383e),
                            Color(0xff222a2f),
                            Color(0xff141a1e),
                          ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
                // El reflejo del cristal, arriba a la izquierda.
                child: Align(
                  alignment: const Alignment(-0.4, -0.55),
                  child: FractionallySizedBox(
                    widthFactor: 0.42,
                    heightFactor: 0.3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(size),
                        color: Colors.white.withValues(alpha: on ? 0.55 : 0.12),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Texto grabado en la plancha: una sombra oscura arriba y una clara abajo
/// hacen que la letra parezca hundida en el metal.
class EngravedText extends StatelessWidget {
  const EngravedText(
    this.text, {
    super.key,
    this.size = 14,
    this.weight = FontWeight.w700,
    this.color = const Color(0xffe8eef2),
    this.letterSpacing = 1.0,
    this.maxLines = 2,
  });

  final String text;
  final double size;
  final FontWeight weight;
  final Color color;
  final double letterSpacing;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      height: 1.15,
      shadows: const [
        Shadow(color: Color(0xdd000000), offset: Offset(0, -1), blurRadius: 1),
        Shadow(color: Color(0x40ffffff), offset: Offset(0, 1), blurRadius: 1),
      ],
    ),
  );
}

/// Placa negra sobre la que van los pilotos.
class AlarmPanelPlate extends StatelessWidget {
  const AlarmPanelPlate({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xff14191d), Color(0xff080b0d)],
      ),
      border: Border.all(color: const Color(0xff2b343a)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 8,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xff2b343a))),
          ),
          child: EngravedText(
            title,
            size: 12,
            weight: FontWeight.w800,
            letterSpacing: 2.2,
            color: const Color(0xffaebac2),
            maxLines: 1,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: child,
        ),
      ],
    ),
  );
}

/// Una fila: piloto y leyenda grabada.
///
/// Sin etiqueta de estado a la derecha ("EN ORDEN", "SIN VIGILAR",
/// "DESACTIVADA"): el piloto ya lo dice y en dos columnas ese texto se comía
/// el ancho de la leyenda (petición 2026-09-18). Solo se escribe cuando hay
/// que actuar: una alarma disparada, o silenciada.
class AlarmLampRow extends StatelessWidget {
  const AlarmLampRow({super.key, required this.lamp});

  final AlarmLamp lamp;

  @override
  Widget build(BuildContext context) {
    // Sin vigilar: la leyenda en gris, para que lo que sí protege destaque.
    final sinVigilar = lamp.state == LampState.warn;
    final labelColor = sinVigilar
        ? const Color(0xff7d8a93)
        : const Color(0xffe8eef2);
    final detailColor = sinVigilar
        ? const Color(0xff66737c)
        : const Color(0xff8c9aa3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ChromeLed(state: lamp.state, size: 24),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EngravedText(
                  lamp.label,
                  size: 13,
                  color: labelColor,
                  maxLines: 1,
                ),
                if (lamp.detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: EngravedText(
                      lamp.detail,
                      size: 11,
                      weight: FontWeight.w500,
                      letterSpacing: 0.2,
                      color: detailColor,
                      maxLines: 1,
                    ),
                  ),
              ],
            ),
          ),
          if (lamp.state == LampState.alarm) ...[
            const SizedBox(width: 8),
            EngravedText(
              lamp.muted ? 'SILENCIADA' : 'ALARMA',
              size: 10,
              weight: FontWeight.w800,
              letterSpacing: 1.1,
              color: lamp.muted ? LampState.warn.color : LampState.alarm.color,
              maxLines: 1,
            ),
          ],
        ],
      ),
    );
  }
}
