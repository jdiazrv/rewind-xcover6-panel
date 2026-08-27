# Changelog

Todas las versiones notables de este proyecto se documentan aquí.

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
