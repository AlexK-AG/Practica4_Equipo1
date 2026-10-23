# Sector 07 · Web local conectada a SQLite

La página consulta la **misma base de datos del juego**. El juego escribe y
el servidor web lee el archivo `web/sector07.sqlite`; no se exporta al navegador.
No se necesita internet para usarla.

## Arranque rápido en Windows

1. Tener **Node.js 24 o superior**. En este equipo ya está instalado; se
   comprueba con `node --version`.
2. Hacer doble clic en **`iniciar_web.cmd`**, en la raíz del proyecto.
3. Se abrirá el navegador en **http://localhost:3000**. Mantener abierta la
   consola del servidor mientras se usa la web.
4. Jugar normalmente. En la página, pulsar **Actualizar** para volver a leer
   los datos guardados. El juego guarda eventos por lotes cada 2 segundos
   y también al guardar progreso; esperar ese guardado antes de actualizar.
5. Para detener el servidor, pulsar **Ctrl+C** en su consola. Cerrar solo la
   pestaña no detiene el servidor. Detener el servidor no afecta al juego.

La web funciona con el juego cerrado y también mientras está abierto. Si
no existe la base, abrir el juego y crear/seleccionar un perfil primero.
El siguiente Actualizar encontrará la base sin reiniciar el servidor.

También se puede iniciar desde PowerShell en la raíz del proyecto:

```powershell
node web/server.mjs
```

O desde la carpeta `web`:

```powershell
npm start
```

**No hace falta `npm install`**, Python, PostgreSQL ni instalar un servidor SQL.
Se utilizan HTTP y SQLite incluidos en Node.js. Referencia técnica:
[SQLite en Node.js 24](https://nodejs.org/download/release/latest-v24.x/docs/api/sqlite.html).

Abrir `index.html` con doble clic solo muestra la interfaz estática. Para
consultar datos reales hay que entrar a la dirección del servidor local.

## Qué hace cada sección

| Sección | Qué muestra y qué permite hacer |
|---|---|
| **Resumen** | Número de perfiles e intentos, tiempo activo registrado, mejor récord, misiones recientes, resultados y tiempo por nivel. Filtro por jugador. El porcentaje de victorias usa intentos con resultado conocido; excluye en curso e interrumpidos. |
| **Jugadores** | Buscar perfiles, consultar récord y progreso, abrir su ficha y acceder a sus partidas o descubrimientos. Son los mismos perfiles del juego; no es un registro de cuentas nuevo. |
| **Clasificación** | Leaderboard real, ordenable por récord, puntos actuales o niveles completados. El récord sobrevive al reiniciar campaña; los puntos actuales suman los mejores resultados de sus niveles. Buscar conserva el puesto global. Agrupa todas las dificultades. |
| **Historial** | Intentos ganados, perdidos, abandonados, en curso o interrumpidos. Filtros por jugador, nivel, dificultad, resultado y periodo; detalle del intento y exportación CSV de la selección filtrada. |
| **Descubrimientos** | Elegir un perfil para consultar armas, granadas, equipación, mejoras, niveles y 18 subtipos de enemigos con imágenes y alturas. Muestra qué está desbloqueado o pendiente. |
| **Registro de eventos** | Disparos, recargas, daño, recogidas, objetivos, oleadas, pausas, cambios de equipo y acciones del menú. Filtros por jugador, acción y texto; detalles y CSV. La opción «Configuración general» muestra cambios de opciones que no pertenecen a un jugador. |
| **Partidas y recorridos** | Lista los intentos y reproduce el jugador y los enemigos sobre un plano cenital dibujado desde las colisiones de cajas del nivel, con pausa, reinicio y control de tiempo. |
| **Análisis por sector** | Compara intentos, victorias, derrotas y tiempo activo para cada uno de los diez niveles; respeta el filtro de jugador. |

Al iniciar una misión, el juego registra la huella cenital de las colisiones estáticas en el evento `replay_map` y captura coordenadas X/Z cada medio segundo de tiempo activo como eventos `replay_sample`. Las pausas no avanzan la captura. La bitácora normal oculta estos datos técnicos. Las partidas anteriores a este cambio no tienen plano ni recorrido guardados. La demostración usa geometría y datos inventados, marcados como ficticios.

Las tablas se paginan de ocho en ocho. **Exportar CSV** incluye todos los
resultados de los filtros, no solo la página visible. El detalle de una partida
muestra sus últimas 100 acciones para mantener el diálogo manejable; el registro
de eventos permite consultar/exportar el conjunto completo.

**Ver demostración** carga datos ficticios identificados y separados de los
reales. No los mezcla ni los guarda en SQLite. Al salir de demostración desde el
servidor, intenta recuperar la conexión real. Las exportaciones de demostración
llevan `demostracion` en el nombre.

## Cómo funciona la conexión

```text
Godot (scripts/persistence/campaign_store.gd y game_events.gd)
  guarda perfiles, progreso, resultados y eventos en sector07.sqlite
    Node.js (web/server.mjs) lee SQLite y responde GET /api/dashboard
      Navegador (web/app.js) muestra y filtra la respuesta JSON
```

- **SQLite:** archivo local en `web/sector07.sqlite`, dentro de esta copia del proyecto.
  Godot lo resuelve como `res://web/sector07.sqlite`; esta copia queda separada de la base del proyecto principal.
- **`server.mjs`:** sirve archivos públicos y abre SQLite con `readOnly` y
  `query_only=ON`. Una transacción corta por solicitud da una lectura coherente
  y se cierra enseguida. No migra, crea, corrige ni escribe perfiles. Abre el
  archivo en cada actualización para reflejar cambios o recuperación del respaldo.
- **`GET /api/dashboard`:** convierte filas SQL en JSON. Une `run_history` con
  `run_sessions` por su ID para no contar dos veces un intento. Envía UUID de
  perfil estables. `profile_events` incluye acciones sin sesión; las opciones
  globales se presentan como «Configuración general».
- **`app.js`:** solicita ese JSON al cargar y al pulsar Actualizar, valida los
  datos y construye estadísticas, filtros, fichas y exportaciones. No accede al
  archivo SQLite. No hay actualización automática periódica.
- **`index.html` y `styles.css`:** estructura y apariencia existentes.
  `catalog.js` y `assets/` aportan nombres e imágenes, no estadísticas.
  `demo.js` solo se utiliza cuando se activa la demostración.
- **`iniciar_web.cmd`:** comprueba Node, inicia el servidor y abre el navegador.
  `package.json` ofrece `npm start` y `npm test`, sin dependencias adicionales.

El servidor escucha solo en `127.0.0.1`; `localhost` significa este equipo.
**3000** es el puerto elegido para esta aplicación. No publica la web en internet
ni crea una clasificación global entre equipos. Editar/eliminar perfiles sigue
correspondiendo al juego. La base y los archivos privados no se sirven como descargas.

## Otra ruta o puerto

Si el puerto está ocupado:

```powershell
node web/server.mjs --port 3001 --open
```

Para otra copia del juego o una base de pruebas:

```powershell
node web/server.mjs --db "C:/ruta/sector07.sqlite" --port 3001
```

Las rutas relativas de `--db` se resuelven desde la carpeta donde se inicia el
comando. Se admiten las variables `SECTOR07_DB_PATH` y `PORT`; los parámetros de
línea de comandos tienen prioridad. El lanzador admite los mismos argumentos:
`iniciar_web.cmd --port 3001`.

## Errores y alcance de los datos

- **Sin conexión:** comprobar que la consola esté abierta y la dirección use
  el puerto indicado; pulsar Actualizar.
- **Base no encontrada:** abrir el juego o indicar la ruta con `--db`. La web
  no crea una base vacía por accidente.
- **El juego está guardando:** esperar y volver a actualizar. Una lectura
  bloqueada informa un error y no sustituye los datos por una demo.
- **Versión incompatible/base incompleta:** usar las versiones correspondientes
  del juego y la web. El servidor no cambia el esquema del archivo.
- **Historial incompleto:** los eventos se registran desde que se añadió esa
  función. Perfiles antiguos pueden tener récords/desbloqueos sin historial
  anterior equivalente; no se reconstruyen acciones inventadas.
- **Partida en curso:** muestra el último estado confirmado en SQLite, no una
  comprobación en directo del proceso. Tras un cierre forzado, Godot marca la
  interrupción al arrancar nuevamente. No se inventan un resultado, puntuación
  ni hora de finalización para intentos sin cierre confirmado.

Esta versión lee el conjunto completo y pagina/filtra en el navegador, adecuada
para la consulta local actual. Si el archivo acumula muchísimos eventos, la
siguiente mejora sería paginar/filtrar mediante SQL en el servidor. No se limitan
ni eliminan silenciosamente eventos al cargar la página.

El código puede subirse a GitHub. `.gitignore` excluye la SQLite local y sus respaldos.
GitHub Pages sirve archivos estáticos: no ejecuta
este servidor ni accede al AppData del equipo.

## Contrato de datos

La API devuelve `schemaVersion: 2`, `databaseSchemaVersion`, `generatedAt`,
`capabilities`, `players`, `runs` y `events`. La interfaz sigue admitiendo el
contrato 1 para demostración y pruebas existentes.

- Niveles y etapas: **1–10** y **1–9**, respectivamente.
- Perfiles: `id` (UUID), `name`, `record`, `completedLevels`, `scores`,
  `weaponUnlocks`, `grenadeUnlocks`, `discoveredEnemies`, `upgrades`,
  `tutorialCompleted` y `loadout`. Proyecciones SQL más JSON de equipación;
  no se decodifican BLOB de Godot.
- Intentos: `id`, `playerId`, `level`, `difficulty`, `outcome`, `durationSeconds`,
  `score`, `kills`, `startedAt`, `endedAt`, `updatedAt`. Dificultad: 0 fácil,
  1 normal, 2 difícil. Resultados: `victory`, `defeat`, `abandoned`, `in_progress`,
  `interrupted`. Puntuación/final pueden ser nulos sin resultado confirmado.
- Eventos: `id`, `scope` (`game`, `profile`, `system`), `runId`, `playerId`,
  `level`, `type`, `occurredAt`, `payload`. Menú: `runId`/`level` nulos.
  Opciones generales: también `playerId` nulo. Juego: añade `sequence`,
  `missionSeconds` y `activeSeconds`.
- Base con esquema 1: perfiles e historial consultables, con
  `capabilities.events: false`. La migración al esquema 2 la hace Godot.
- Error: HTTP 503 y `{ "error": { "code": "...", "message": "..." } }`.
  No se presenta como una respuesta vacía exitosa.

## Pruebas

```powershell
node tests/web/web_server.mjs
```

Verifica SQLite privada, mapeo, unión de sesiones/resultados, cambios confirmados
mientras el servidor está abierto, archivos ausentes/corruptos, versiones,
bloqueos, lectura y rutas HTTP públicas/privadas. No requiere paquetes de pruebas.

Con Playwright y Edge para desarrollo:

```powershell
node tests/web/web_ui.cjs
node tests/web/web_connection.cjs
node tests/web/web_connection.cjs --real
```

`SECTOR07_PLAYWRIGHT_MODULE` permite una instalación existente de Playwright;
no se necesita para usar la web. `web_connection` prueba navegador → HTTP → SQLite
sin interceptar la API. `--real` consulta el guardado real y verifica que sus
bytes queden iguales. Capturas en `.godot/test-results/capturas/web-connected-*.png`.

La interfaz conserva filtros, CSV, datos escapados, navegación adaptable y
separación real/demo. `web/.gdignore` evita importaciones en Godot. No se
modifican scripts, escenas, estética ni mecánicas del juego.
