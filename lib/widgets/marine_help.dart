part of '../main.dart';

// "puedes poner un poco de teoria al pulsar la card de ola, mar de viento y
// swell... seria bueno un grafico explicativo" y "tambien la ayuda en estado
// de mar. que muestre la escala de douglas y como calcula lo de atencion o
// comodo" (2026-09-08). Las tres cards de olas comparten la misma ayuda,
// porque la duda de fondo es siempre la misma: si se suman o no.

/// Interrogación discreta en la esquina de una tarjeta.
class HelpDot extends StatelessWidget {
  const HelpDot({super.key, required this.onTap, required this.color});

  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: InkResponse(
      onTap: onTap,
      radius: 18,
      // Área táctil holgada: el icono es pequeño a propósito para no
      // competir con el dato, pero el dedo necesita margen.
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          Icons.help_outline,
          size: 17,
          color: color.withValues(alpha: 0.75),
        ),
      ),
    ),
  );
}

/// Marco común de las dos ayudas: título, cerrar, y contenido con scroll.
class _HelpSheet extends StatelessWidget {
  const _HelpSheet({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: cPanel,
    insetPadding: const EdgeInsets.all(20),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: cText,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: cMuted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _helpH(String text) => Padding(
  padding: const EdgeInsets.only(top: 14, bottom: 5),
  child: Text(
    text,
    style: const TextStyle(
      color: cText,
      fontSize: 15,
      fontWeight: FontWeight.w800,
    ),
  ),
);

Widget _helpP(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    text,
    style: const TextStyle(color: cMuted, fontSize: 13, height: 1.45),
  ),
);

/// Fila "punto de color + etiqueta + texto".
Widget _helpBullet(Color color, String label, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        margin: const EdgeInsets.only(top: 5, right: 9),
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      Expanded(
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1.45,
                ),
              ),
              TextSpan(
                text: text,
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  ),
);

const _cWindWave = Color(0xff69bdf7);
const _cSwell = Color(0xff9277ff);

/// Ayuda compartida por Ola significativa / Mar de viento / Swell.
class WaveTheoryDialog extends StatelessWidget {
  const WaveTheoryDialog({super.key, this.point});

  /// Si hay datos ahora mismo, el ejemplo numérico usa los reales en vez
  /// de unos inventados — se entiende mucho mejor con lo que se ve fuera.
  final MarinePoint? point;

  @override
  Widget build(BuildContext context) {
    final p = point;
    final ww = p?.windWaveM;
    final sw = p?.swellM;
    final hs = p?.waveM;
    return _HelpSheet(
      title: 'Olas: mar de viento, swell y altura significativa',
      children: [
        _helpP(
          'En el mar casi nunca hay un solo tren de olas. Los modelos '
          'separan dos y dan además la resultante de ambos.',
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 190,
          width: double.infinity,
          child: CustomPaint(painter: _WaveTheoryPainter()),
        ),
        const SizedBox(height: 12),
        _helpBullet(
          _cWindWave,
          'Mar de viento',
          'la que levanta el viento local en este momento. Periodo corto '
              '(3-6 s), cresta corta y picuda, y desaparece poco después de '
              'que amaine. Es la que hace incómoda la navegación.',
        ),
        _helpBullet(
          _cSwell,
          'Swell (mar de fondo)',
          'olas nacidas de un temporal lejano que ya han salido de su zona '
              'de generación. Periodo largo (8-20 s), lomo redondeado y '
              'regular. Puede llegar con el cielo despejado y sin viento.',
        ),
        _helpBullet(
          cCyan,
          'Altura significativa',
          'la mar total combinada, la suma de las dos anteriores. NO es un '
              'tercer tren de olas aparte.',
        ),
        _helpH('No se suman a pelo'),
        _helpP(
          'Lo que se suma es la energía, y la energía va con el cuadrado de '
          'la altura. Por eso la combinación es:',
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cPanel2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Hs ≈ √( mar de viento² + swell² )',
                style: TextStyle(
                  color: cCyan,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                (ww != null && sw != null && hs != null)
                    ? 'Ahora mismo: √(${ww.toStringAsFixed(1)}² + '
                          '${sw.toStringAsFixed(1)}²) ≈ '
                          '${math.sqrt(ww * ww + sw * sw).toStringAsFixed(1)} m, '
                          'y el modelo da ${hs.toStringAsFixed(1)} m.'
                    : 'Ejemplo: 1,5 m de mar de viento y 2,0 m de swell no '
                          'dan 3,5 m, sino unos 2,5 m.',
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        _helpH('Dos cosas que conviene no olvidar'),
        _helpP(
          'La altura significativa es la media del tercio de olas más '
          'altas, así que muchas olas serán mayores: la máxima esperable '
          'en unas horas ronda 1,8 veces la Hs. Con 2 m de Hs, una ola de '
          '3,5 m entra dentro de lo normal.',
        ),
        _helpP(
          'Y para la comodidad a bordo pesa tanto o más el periodo y la '
          'dirección que la altura: 2 m de swell largo por la aleta se '
          'llevan bien; 2 m de mar de viento corta por la amura, no.',
        ),
      ],
    );
  }
}

/// Diagrama: swell largo + mar de viento corta = mar real combinada.
class _WaveTheoryPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const rowH = 58.0;
    // La flecha de Hs vive en una franja propia a la derecha: si las ondas
    // llegan hasta el borde se le montan encima y no se lee.
    const gutter = 52.0;
    final w = size.width - gutter;
    if (w <= 40) return;

    void label(String text, double y, Color color) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y));
    }

    // Cada fila dibuja su onda; la tercera es la suma punto a punto de las
    // dos de arriba, que es exactamente lo que pasa en el mar real.
    double swellAt(double x) => math.sin(x / w * math.pi * 2.0) * 15;
    double windAt(double x) => math.sin(x / w * math.pi * 13.0) * 7;

    void wave(double baseY, double Function(double) fn, Color color, double sw) {
      final path = Path();
      for (var x = 0.0; x <= w; x += 1.5) {
        final y = baseY - fn(x);
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw
          ..strokeCap = StrokeCap.round,
      );
    }

    label('SWELL · periodo largo', 0, _cSwell);
    wave(rowH * 0.62, swellAt, _cSwell, 2.5);

    label('MAR DE VIENTO · periodo corto', rowH, _cWindWave);
    wave(rowH * 1.62, windAt, _cWindWave, 2.5);

    label('MAR REAL = las dos a la vez', rowH * 2, cCyan);
    wave(rowH * 2.62, (x) => swellAt(x) + windAt(x), cCyan, 3.0);

    // Flecha de altura significativa sobre la onda combinada.
    final arrowX = w + 34;
    final topY = rowH * 2.62 - 22;
    final botY = rowH * 2.62 + 22;
    final arrowPaint = Paint()
      ..color = cCyan.withValues(alpha: 0.7)
      ..strokeWidth = 1.4;
    canvas.drawLine(Offset(arrowX, topY), Offset(arrowX, botY), arrowPaint);
    for (final (y, dy) in [(topY, 5.0), (botY, -5.0)]) {
      canvas.drawLine(Offset(arrowX, y), Offset(arrowX - 4, y + dy), arrowPaint);
      canvas.drawLine(Offset(arrowX, y), Offset(arrowX + 4, y + dy), arrowPaint);
    }
    final tp = TextPainter(
      text: const TextSpan(
        text: 'Hs',
        style: TextStyle(
          color: cCyan,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(arrowX - 22, rowH * 2.62 - 7));
  }

  @override
  bool shouldRepaint(covariant _WaveTheoryPainter old) => false;
}

/// Ayuda de la tarjeta "Estado de mar": escala Douglas y el semáforo.
class SeaStateHelpDialog extends StatelessWidget {
  const SeaStateHelpDialog({super.key, this.waveM});

  final double? waveM;

  // Los mismos cortes que usa _douglasState, para que la tabla no pueda
  // desviarse de lo que la tarjeta enseña.
  static const _douglas = [
    (0, 'Calma (mar llana)', '0 m'),
    (1, 'Marejadilla (rizada)', '0 - 0,1 m'),
    (2, 'Marejadilla', '0,1 - 0,5 m'),
    (3, 'Marejada', '0,5 - 1,25 m'),
    (4, 'Fuerte marejada', '1,25 - 2,5 m'),
    (5, 'Gruesa', '2,5 - 4 m'),
    (6, 'Muy gruesa', '4 - 6 m'),
    (7, 'Arbolada', '6 - 9 m'),
    (8, 'Montañosa', '9 - 14 m'),
    (9, 'Enorme', 'más de 14 m'),
  ];

  int? get _currentGrade {
    final v = waveM;
    if (v == null) return null;
    if (v < 0.1) return 0;
    if (v < 0.5) return 2;
    if (v < 1.25) return 3;
    if (v < 2.5) return 4;
    if (v < 4) return 5;
    return 6;
  }

  @override
  Widget build(BuildContext context) {
    final here = _currentGrade;
    return _HelpSheet(
      title: 'Estado de mar',
      children: [
        _helpH('El semáforo'),
        _helpP(
          'Es una regla simple sobre la altura significativa (Hs), pensada '
          'para un velero de crucero. No mira el periodo ni la dirección, '
          'así que es una primera señal, no un veredicto.',
        ),
        _comfortRow(cGreen, 'Cómodo', 'Hs por debajo de 1 m'),
        _comfortRow(cOrange, 'Atención', 'Hs entre 1 y 2 m'),
        _comfortRow(cRed, 'Duro', 'Hs de 2 m en adelante'),
        _helpP(
          'Con "Atención" ya conviene amarrar lo suelto y pensar en el '
          'rizo; con "Duro", que la mar mande sobre el horario.',
        ),
        _helpH('Escala Douglas (estado de la mar)'),
        _helpP(
          'La Douglas clasifica la altura de las olas, no la fuerza del '
          'viento — eso es la escala Beaufort, que es otra cosa. Un mar de '
          'fondo puede dar Douglas 4 sin nada de viento.',
        ),
        for (final (grade, name, range) in _douglas)
          _douglasRow(grade, name, range, highlight: grade == here),
        if (here != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Ahora mismo: ${waveM!.toStringAsFixed(1)} m de altura '
              'significativa, resaltado arriba.',
              style: const TextStyle(color: cCyan, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _comfortRow(Color color, String label, String rule) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      children: [
        Container(
          width: 76,
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(rule, style: const TextStyle(color: cMuted, fontSize: 13)),
      ],
    ),
  );

  Widget _douglasRow(
    int grade,
    String name,
    String range, {
    required bool highlight,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 3),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: highlight ? cCyan.withValues(alpha: 0.16) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: highlight ? cCyan.withValues(alpha: 0.6) : Colors.transparent,
      ),
    ),
    child: Row(
      children: [
        SizedBox(
          width: 22,
          child: Text(
            '$grade',
            style: TextStyle(
              color: highlight ? cCyan : cMuted,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: Text(
            name,
            style: TextStyle(
              color: highlight ? cText : cMuted,
              fontSize: 13,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          range,
          style: TextStyle(
            color: highlight ? cCyan : cMuted,
            fontSize: 12,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
