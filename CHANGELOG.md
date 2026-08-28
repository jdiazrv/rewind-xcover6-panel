# Changelog

Todas las versiones notables de este proyecto se documentan aquí.

## [1.4.19] - 2026-08-28

### Cambiado
- **Gráficas → distribución**: barras verticales (antes horizontales), con los márgenes de cada franja siempre en números enteros.
- **Informe de rendimiento**: los márgenes de la distribución de viento también en números enteros.

### Añadido
- **Informe de rendimiento**: nueva tabla "Polar de datos reales" — velocidad media (STW) por ángulo de viento (TWA, en bandas de 30°) y franja de viento real (TWS, mismos márgenes que la distribución), calculada a partir del histórico real del periodo — sin curva de polar teórica con la que comparar, tal y como se pidió.

## [1.4.18] - 2026-08-28

### Añadido
- **Gráficas**: nuevos botones de rango 1h, 6h y 12h además de los ya existentes; barra de rangos ahora desplazable horizontalmente.
- **Gráficas**: nueva vista de distribución (icono de barras junto al título) que muestra, para el rango de tiempo elegido, el % de tiempo pasado en cada franja de valores — por ejemplo, qué porcentaje del tiempo el viento estuvo entre 6-8 nudos, entre 10-15, etc.
- **CFG → Diagnóstico**: nuevo botón "Informe de rendimiento" que genera un PDF (previsualizable, imprimible y compartible) con distancia navegada, tiempo navegando, SOG/STW/AWS/TWS medios y máximos, escora máxima, y la distribución de SOG y de viento real (TWS) del periodo elegido (24h / 7 días / 1 mes).

### Cambiado
- **NAV**: el catálogo de cartas no seleccionadas (al deslizar hacia abajo) pasa a ser una segunda pantalla propia con indicador de página, en vez de una lista que se desplazaba debajo — cíclica (de la última se vuelve a la primera) y con un indicador que distingue la pantalla de cartas elegidas de las de catálogo.
- **Viento aparente** (NAV): AWS y AWA se alinean a la izquierda en vez de centrarse cada línea por separado.

## [1.4.17] - 2026-08-28

### Arreglado
- **NAV → "Viento aparente"**: AWS y AWA ahora se alinean a la izquierda en vez de centrarse cada línea por separado.
- **NAV → catálogo de cartas no seleccionadas** (al desplazarse hacia abajo en NAV): ya no se recorta ninguna carta si no caben todas en la altura de una pantalla — ahora esa sección se puede desplazar.

## [1.4.16] - 2026-08-28

### Añadido
- **CFG → Diagnóstico**: añadidas las filas que faltaban (COG, TWD, VMG viento/ruta, satélites/HDOP/calidad de fix GNSS, altitud de antena, voltaje y temperatura del bowthruster).
- **Alarmas personalizadas de temperatura**: ahora se puede elegir cualquier sensor de temperatura descubierto en el barco (excepto exterior, interior y T. mar), no solo una lista fija de 5.
- **NAV**: nueva carta "Viento aparente" (AWS + AWA en dos líneas).
- **Alarma de corredera**: alarma independiente (con su propio interruptor, fuera de las personalizadas) que salta si SOG > 2 kt y STW = 0 durante al menos 3s — corredera fouled o parada.
- **AIS**: umbrales de CPA y TCPA "relevantes" (a partir de qué distancia/tiempo un objetivo deja de mostrarse como el más cercano) ahora configurables en CFG → Alarmas, en vez de fijos.

### Cambiado
- Todas las referencias a "Batería casa" pasan a llamarse "Batería de servicio".
- **Tarjeta AIS**: la primera línea grande ahora es TCPA y la segunda CPA (antes al revés).
- **Info ampliada de AIS** (al tocar la tarjeta AIS de NAV): ahora muestra la misma ficha completa que la pantalla AIS (foto del barco, MMSI, posición, COG, SOG, distancia, CPA, TCPA, cruce, última actualización), no solo un resumen.

## [1.4.15] - 2026-08-28

### Arreglado
- **Tarjeta AIS**: cuando hay objetivos AIS pero ninguno tiene un cruce previsto en los próximos 20 min, ahora dice "Sin cruce previsto" en vez de "Sin AIS" — ese mensaje se reserva para cuando de verdad no hay ningún objetivo.

## [1.4.14] - 2026-08-28

### Arreglado
- Una alarma de "nevera" guardada antes de la v1.4.13 se mostraba con el nombre interno roto en vez de una etiqueta legible, al haberse renombrado el tipo internamente. Ahora se migra automáticamente a "Nevera 1" al cargar.

## [1.4.13] - 2026-08-28

### Cambiado
- **Alarmas personalizadas**: etiquetas más claras ("Batería menor de", "Temperatura mayor de" en vez de "Nevera mayor de"), lista desplegable ordenada alfabéticamente, y la alarma de temperatura ahora deja elegir el sensor (nevera 1/2, batería, CPU, motor de proa) — no solo las neveras.
- **Tarjeta AIS**: rediseñada — CPA y TCPA como las dos líneas grandes de igual tamaño (los datos que de verdad importan de un vistazo), y nombre/distancia/demora debajo en gris.
- **MAR**: las tarjetas ya no se estiran verticalmente para ocupar toda la pantalla.

## [1.4.12] - 2026-08-27

### Añadido
- Más tipos de alarma personalizada: batería (casa) por debajo de X V, SOC por debajo de X%, nevera por encima de X°C, algún tanque por debajo de X%, viento previsto superior a X kt en las próximas 6 horas.

## [1.4.11] - 2026-08-27

### Añadido
- **Sistema de alarmas** (CFG → ALARMAS):
  - Zonas de Signal K (`notifications.*`): lista en vivo de las alarmas que reporta el servidor, con interruptor de activación y de aviso sonoro por cada una.
  - Alarmas personalizadas: profundidad menor de X, viento aparente mayor de Y (con decimales), cada una con su propio aviso sonoro.
  - Aviso sonoro (bucle) mientras haya alguna alarma activa con sonido habilitado, con opción de silenciar individualmente desde la lista de alarmas activas.
  - Pestaña de cabecera en rojo si esa pantalla tiene una alarma activa; icono de campana con contador visible desde cualquier pantalla; tarjeta de Profundidad en NAV se resalta en rojo si tiene una alarma activa.
  - La alarma de fondeo (plugin `hoekens-anchor-alarm`) queda cubierta automáticamente en cuanto se activan las zonas de Signal K, sin configuración aparte.
- **Profundidad con flecha de tendencia**: sube/baja solo cuando el cambio está confirmado (con histéresis), no por oscilaciones puntuales.

### Cambiado
- Bordes de las tarjetas más marcados.

## [1.4.10] - 2026-08-27

### Cambiado
- **Tarjeta AIS**: recupera los 5 datos pedidos (nombre, demora, distancia, CPA, TCPA) — el subtítulo ahora ocupa 2 líneas (nombre arriba, demora/distancia/TCPA abajo) en vez de cortarse con "...".
- **Bordes de las tarjetas** (NAV y el resto): más marcados/visibles que en la v1.4.5.

## [1.4.9] - 2026-08-27

### Cambiado
- **Tarjetas CPA + TCPA fusionadas en una sola "AIS"**: muestra CPA como valor principal, y nombre/demora/distancia/TCPA en la línea inferior; al tocarla se abre el detalle completo (objetivo, demora, distancia, CPA, TCPA, cruce por proa/popa).
- Los objetivos AIS con TCPA superior a 20 min ya no se muestran como "el" objetivo de aproximación más cercana — un CPA muy corto que todavía está a 40 min no es relevante ahora mismo.
- Se actualiza el icono web (mismo icono que Android/Play Store).

### Arreglado
- **Detalle de un barco AIS (pestaña AIS)**: si tocabas un objetivo justo cuando aparecía, antes de recibir todos sus datos, el panel se quedaba con "--" congelado hasta cerrarlo y volver a abrirlo. Ahora se refresca solo cada 2s con los datos que van llegando.

## [1.4.8] - 2026-08-27

### Arreglado
- **CFG → Conexión no guardaba bien la IP escrita a mano**: los campos de host/puerto/auth/InfluxDB se recreaban desde cero en cada actualización de datos de Signal K (varias veces por segundo), así que si escribías una IP nueva y llegaba un dato antes de pulsar "Guardar", el campo volvía a mostrar el valor guardado anterior. Ahora los controles de texto de CFG se crean una sola vez y persisten entre reconstrucciones.
- **Webapp de Signal K**: si un dispositivo había visitado antes la webapp de otro barco/servidor, seguía reconectando a ese host antiguo en vez de al servidor desde el que se está sirviendo ahora. La webapp siempre usa su propio origen, ignorando cualquier host guardado.

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
