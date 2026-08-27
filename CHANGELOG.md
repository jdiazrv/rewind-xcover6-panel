# Changelog

Todas las versiones notables de este proyecto se documentan aquí.

## [1.4.7] - 2026-08-27

### Cambiado
- **Detalle de CPA**: "Rumbo" ahora se llama "Demora" (el término correcto para el rumbo hacia el objetivo). Cuando el CPA es menor de 0,5 NM, las tarjetas CPA/TCPA y las filas de CPA/TCPA/Cruce en el detalle se resaltan en rojo.

## [1.4.6] - 2026-08-27

### Interno
- Solo cambio de versión (sin cambios funcionales): Play Console ya tenía usado el código de versión 16 de un intento de subida anterior, así que se sube a 17.

## [1.4.5] - 2026-08-27

### Cambiado
- **Estilo unificado de tarjetas**: NAV, VNT y el resto de pantallas ahora usan el mismo estilo — fondo transparente y borde fino, en vez de la mezcla de relleno sólido de NAV y relleno negro con borde de color de VNT.
- **Posición en grados/minutos**: la latitud y longitud ahora se muestran como `36°43.3'N` / `004°25.3'W` (grados, minutos y décimas) en vez de grados decimales.
- **CFG → Pantalla**: nueva opción para elegir el número de tarjetas de NAV, 3×2 (6, como hasta ahora) o 4×2 (8).

## [1.4.4] - 2026-08-27

### Añadido
- **Detalle de CPA**: al tocar la tarjeta CPA se abre un panel con objetivo, rumbo, distancia actual, CPA, TCPA y si el cruce es por proa o por popa (mismo criterio que la pestaña AIS: solo se etiqueta el cruce si el objetivo se mueve y pasará a menos de 5 NM). El panel se refresca cada 2s, así que si otro objetivo pasa a ser el más cercano, el panel salta a ese automáticamente.

### Interno
- Corregido un problema de build: Dropbox sobrescribía intermitentemente el APK/AAB recién compilados en `build/` con una copia antigua. Los artefactos de Android ahora se toman siempre de la salida real de Gradle fuera del árbol sincronizado.

## [1.4.3] - 2026-08-27

### Añadido
- **GPS con más datos**: la tarjeta GPS ahora muestra el nº de satélites y calidad de fix en la propia carta, y al tocarla abre el detalle completo (satélites, HDOP, tipo, calidad de fix, altitud de antena, posición, última actualización).
- **VMG viento** y **VMG ruta**: dos tarjetas NAV nuevas y separadas — VMG viento se calcula en la app (STW/SOG · cos(TWA)), VMG ruta viene del cálculo de ruta activa de Signal K (`navigation.course.calcValues.velocityMadeGood`).

### Arreglado
- **CPA/TCPA en NAV mostraban "Sin AIS" aunque hubiera tráfico**: la suscripción a objetivos AIS solo se activaba al entrar en la pantalla AIS. Ahora también se activa automáticamente si alguna tarjeta NAV usa CPA o TCPA, sin depender de qué pantalla estés mirando.
- El selector de tarjeta NAV (mantener pulsado) ya no ocupa toda la pantalla — ahora es un panel superpuesto más pequeño, para no confundirlo con una pantalla real de la app.

## [1.4.2] - 2026-08-27

### Añadido
- **NAV personalizable**: mantén pulsada (o doble toque / clic derecho) una tarjeta de la página NAV para cambiarla por otra métrica (SOG, STW, rumbo, COG, profundidad, escora, posición, GPS, CPA, TCPA, hora, VMG). La selección se guarda y persiste entre sesiones.

## [1.4.1] - 2026-08-27

### Arreglado
- **Webapp (MAP/ANC)**: el botón para restaurar la cabecera oculta no respondía al tocarlo, porque quedaba flotando sobre el `<iframe>` de Freeboard-SK/Anchor Alarm y el navegador entregaba el toque directamente al iframe. Ahora, en web, se usa una barra colapsada con espacio de layout propio (no superpuesta), con el mismo estilo visual que el tirador de Android.
- Etiquetas más claras en `CFG → Pantalla → MODO` (Tema claro / Auto (dispositivo) / Tema oscuro) — sigue siendo el filtro rojo de visión nocturna de siempre, no un tema claro real.

### Interno
- Limpieza de avisos del analizador (98 → 1, el restante es un falso positivo): `withOpacity` → `withValues`, llaves en `if`/`else`, cast e import innecesarios, migración de los últimos usos de `dart:html`/`dart:js` a `package:web`/`dart:js_interop`.
- Arreglados 2 tests de widgets que daban falsos positivos/negativos por no esperar la animación de cambio de página, y por comprobar textos de UI que ya no existían.

## [1.4.0] - 2026-08-27

Primera versión pública.

### Añadido
- **Navegación / Viento**: SOG, STW, rumbo, profundidad, escora, viento aparente/real con amortiguación tipo B&G, racha, tendencia y escala Beaufort.
- **Escora y cabeceo por acelerómetro** (CFG → Sensores): fuente alternativa para barcos sin sensor de actitud propio, con calibración pensada para un dispositivo montado en cualquier posición (nivelado + comparación de rumbo con Signal K, con calibración de brújula del dispositivo incluida, o comparación de aceleración lateral en un viraje real). Inclinómetro de doble escala estilo nivel náutico de plástico al tocar la tarjeta "Escora".
- **Energía / Tanques / Temperaturas**: configurables por barco desde `CFG → Configurar sensores` (descubre automáticamente los paths de Signal K disponibles).
- **AIS**: radar propio con vectores de movimiento **relativo** (no solo rumbo/velocidad real como Freeboard-SK), zoom por escala de millas, Rumbo/Norte arriba, track de 1 h, capa de mapa OpenStreetMap/OpenSeaMap opcional, lista ordenada por TCPA con aviso de cruce por proa/popa, y foto del barco por MMSI al tocar un target.
- **Meteorología**: pronóstico de Open-Meteo, mar (oleaje/corriente), y comparativa de modelos (GFS/ECMWF/ICON-EU/ARPEGE/GEM) en tabla horaria estilo Windguru con corrección de viento por altura de palo, exportable a PDF con mapa, alertas automáticas y desglose de resolución por modelo.
- **Histórico de gráficas**: InfluxDB, History API de Signal K (compatible con KIP/SQLite), o modo automático.
- **Fondeo**: alarma de fondeo (plugin Hoeken) y carta náutica (Freeboard-SK) embebidos vía WebView.
- **Modo DEMO**: simulador de datos completo para probar o demostrar la app sin estar conectado a un barco real.
- Instalable como app Android o como webapp de Signal K (detecta host/puerto solo si se sirve desde el propio servidor).

### Seguridad
- Sin credenciales hardcodeadas: InfluxDB y la autenticación de Signal K se configuran desde `CFG`, vacías por defecto.
