import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// El fallo real de 2026-09-10: el Pi estaba caído y ANC decía "revisa
/// usuario/contraseña", mandando a corregir unas credenciales correctas.
void main() {
  group('SkLoginResult.fromStatus', () {
    test('200 es sesión iniciada', () {
      expect(SkLoginResult.fromStatus(200).outcome, SkLoginOutcome.ok);
      expect(SkLoginResult.fromStatus(200).ok, isTrue);
    });

    test('401 y 403 son las credenciales', () {
      for (final code in [401, 403]) {
        final r = SkLoginResult.fromStatus(code);
        expect(r.outcome, SkLoginOutcome.badCredentials);
        expect(r.isCredentialProblem, isTrue, reason: 'código $code');
        expect(r.ok, isFalse);
      }
    });

    test('otros códigos son problema del servidor, no de la contraseña', () {
      for (final code in [500, 502, 404]) {
        final r = SkLoginResult.fromStatus(code);
        expect(r.outcome, SkLoginOutcome.serverError);
        expect(
          r.isCredentialProblem,
          isFalse,
          reason: 'un $code no dice nada de la contraseña',
        );
        expect(r.statusCode, code);
      }
    });
  });

  group('skLoginErrorText', () {
    const target = '192.168.1.82:3000';

    test('el servidor inalcanzable NO culpa a la contraseña', () {
      final text = skLoginErrorText(
        const SkLoginResult(SkLoginOutcome.unreachable),
        target,
      );
      expect(text, contains(target), reason: 'dice a quién no se pudo llamar');
      expect(text.toLowerCase(), contains('no es necesariamente'));
      // Justo lo que hacía el mensaje viejo y no debe volver a hacer.
      expect(text.toLowerCase(), isNot(contains('revisa usuario')));
    });

    test('las credenciales rechazadas sí lo dicen claro', () {
      final text = skLoginErrorText(
        SkLoginResult.fromStatus(401),
        target,
      );
      expect(text.toLowerCase(), contains('rechazado'));
      expect(text.toLowerCase(), contains('contraseña'));
    });

    test('un error del servidor nombra el código y el destino', () {
      final text = skLoginErrorText(SkLoginResult.fromStatus(502), target);
      expect(text, contains('502'));
      expect(text, contains(target));
    });

    test('sesión iniciada no tiene texto de error', () {
      expect(
        skLoginErrorText(const SkLoginResult(SkLoginOutcome.ok), target),
        isEmpty,
      );
    });
  });

  group('a quién se le ofrece seguir sin sesión', () {
    // Reescribir la contraseña no levanta un Pi apagado: ahí quedarse sin
    // poder fondear es peor que fondear sin publicar al servidor.
    test('solo cuando el fallo no es de credenciales', () {
      expect(SkLoginResult.fromStatus(401).isCredentialProblem, isTrue);
      expect(
        const SkLoginResult(SkLoginOutcome.unreachable).isCredentialProblem,
        isFalse,
      );
      expect(SkLoginResult.fromStatus(500).isCredentialProblem, isFalse);
    });
  });
}
