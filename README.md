# REWIND XCover6 Panel

Panel de instrumentos para veleros, hecho en Flutter, para un Samsung Galaxy XCover6 (u otro Android en horizontal) montado en el barco **REWIND**. Se conecta a un servidor **Signal K** por WebSocket y muestra navegación, viento, energía, tanques, temperaturas, meteorología, mar, fondeo, cartas náuticas y AIS.

## Características

- **Navegación / Viento**: SOG, STW, rumbo, profundidad, escora, viento aparente/real con amortiguación tipo B&G, racha, tendencia y escala Beaufort.
- **Energía / Tanques / Temperaturas**: configurables por barco desde `CFG → Configurar sensores` (descubre automáticamente los paths de Signal K disponibles).
- **AIS**: radar propio con vectores de movimiento **relativo** (no solo rumbo/velocidad real como Freeboard-SK), zoom por escala de millas, Rumbo/Norte arriba, track de 1 h, capa de mapa OpenStreetMap/OpenSeaMap opcional, y lista ordenada por TCPA con aviso de cruce por proa/popa.
- **Meteorología**: pronóstico de Open-Meteo, mar (oleaje/corriente), y una comparativa de modelos (GFS/ECMWF/ICON-EU/ARPEGE/GEM) en tabla horaria estilo Windguru con corrección de viento por altura de palo.
- **Fondeo**: alarma de fondeo (plugin Hoeken) y carta náutica (Freeboard-SK) embebidos vía WebView.
- **Modo DEMO**: simulador de datos completo para probar o demostrar la app sin estar conectado a un barco real.

## Requisitos

- Servidor [Signal K](https://signalk.org/) accesible por WiFi (host/puerto configurables en `CFG`).
- Opcional: [InfluxDB 2.x](https://www.influxdata.com/) para las gráficas históricas.
- Opcional: un plugin de alarma de fondeo y Freeboard-SK instalados en Signal K para esas pantallas.

## Entorno de desarrollo

Flutter stable está instalado localmente en:

```sh
/Users/juandiaz/Documents/Codex/tools/flutter
```

El proyecto usa el JDK incluido en Android Studio:

```sh
/Applications/Android Studio.app/Contents/jbr/Contents/Home
```

Carga el entorno antes de ejecutar comandos:

```sh
source tool/env.sh
```

## Comandos

```sh
flutter analyze
flutter test
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Configuración

Todo se ajusta desde la pantalla `CFG` dentro de la app:

- Host/puerto/autenticación de Signal K, bucket de InfluxDB.
- `Configurar sensores`: baterías, solar, neveras y tanques, descubiertos automáticamente desde el servidor.
- `Modo DEMO`: activa datos simulados.

## Instalar como webapp de Signal K

Además de la app Android, `flutter build web` genera una versión que puede
instalarse directamente en el servidor Signal K (aparece en `/apps` junto a
Freeboard-SK, el Anchor Alarm, etc.) y se sirve desde ahí — al abrirla así,
detecta sola el host/puerto del propio servidor Signal K, sin pedirlo en
`CFG`.

El repo ya incluye `public/` compilado (se regenera con `flutter build web
&& rm -rf public && cp -R build/web public` tras cualquier cambio). Formas
de instalarlo en el servidor:

**Desde la pantalla Appstore de Signal K** (más sencillo): Servidor →
Appstore → pega la URL `https://github.com/jdiazrv/rewind-xcover6-panel`
en la opción de instalar desde una URL/repositorio → instalar → reiniciar
el servidor.

**Por SSH**, en el servidor Signal K (necesita Node/npm):

```sh
npm install https://github.com/jdiazrv/rewind-xcover6-panel.git   # desde ~/.signalk
```

o simplemente copia/symlink toda la carpeta del proyecto dentro de
`~/.signalk/node_modules/rewind-xcover6-panel` y reinicia el servidor.

Para aparecer en el listado **público** del App Store de Signal K (visible
en cualquier servidor, buscable), hay que publicarlo en el registro npm
(`npm publish`, requiere cuenta de npm) — eso es un paso aparte, opcional.

Funciona igual que en Android salvo por: la escora/cabeceo por acelerómetro
(usa sensores del móvil/tablet) no está disponible en navegador, y las
pantallas con WebView (MAP, ANC) dependen de que el navegador permita
iframes hacia esas rutas del propio servidor.

## Estructura

Proyecto Flutter: `lib/main.dart` es el Dashboard y la mayoría de las
pantallas; `lib/models.dart`, `lib/theme.dart`, `lib/data_api.dart`,
`lib/geocode.dart` y `lib/pdf/` son los modelos de datos, clientes de API y
tema, separados de la UI; `lib/ais_view.dart` y `lib/model_comparison.dart`
son las dos funcionalidades más independientes (AIS relativo, comparativa
de modelos + PDF); `lib/fullscreen/` gestiona el modo pantalla completa
condicional para web.
