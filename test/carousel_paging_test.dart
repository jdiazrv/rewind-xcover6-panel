import 'package:flutter_test/flutter_test.dart';

/// Reproduce la lógica de paginación de los carruseles de NAV y VNT: un
/// gesto tiene que pasar UNA página, no las que quepan en su longitud.
///
/// El fallo original: al saltar se ponía el acumulado a cero pero el mismo
/// arrastre seguía sumando, así que un gesto largo encadenaba saltos y
/// había que hacerlos cortísimos.
class _Pager {
  _Pager(this.totalPages);
  final int totalPages;
  int index = 0;
  double _acc = 0;
  bool _lock = false;
  int flips = 0;

  void start() {
    _acc = 0;
    _lock = false;
  }

  void end() => _lock = false;

  void overscroll(double delta) {
    if (_lock) return;
    _acc += delta;
    if (_acc.abs() >= 60) {
      final forward = _acc > 0;
      _acc = 0;
      _lock = true;
      flips++;
      index = forward
          ? (index + 1) % totalPages
          : (index - 1 + totalPages) % totalPages;
    }
  }
}

void main() {
  test('un arrastre largo pasa una sola página', () {
    final p = _Pager(3);
    p.start();
    // 300 px de overscroll en trozos de 20: sin el bloqueo serían 5 saltos.
    for (var i = 0; i < 15; i++) {
      p.overscroll(20);
    }
    p.end();
    expect(p.flips, 1);
    expect(p.index, 1);
  });

  test('un arrastre corto no pasa ninguna', () {
    final p = _Pager(3)..start();
    p.overscroll(30);
    p.overscroll(20);
    p.end();
    expect(p.flips, 0);
    expect(p.index, 0);
  });

  test('dos gestos seguidos pasan dos páginas', () {
    final p = _Pager(3);
    for (var g = 0; g < 2; g++) {
      p.start();
      for (var i = 0; i < 10; i++) {
        p.overscroll(20);
      }
      p.end();
    }
    expect(p.flips, 2);
    expect(p.index, 2);
  });

  test('hacia atrás funciona igual y da la vuelta', () {
    final p = _Pager(3)..start();
    for (var i = 0; i < 10; i++) {
      p.overscroll(-20);
    }
    p.end();
    expect(p.flips, 1);
    expect(p.index, 2, reason: 'de la primera a la última');
  });
}
