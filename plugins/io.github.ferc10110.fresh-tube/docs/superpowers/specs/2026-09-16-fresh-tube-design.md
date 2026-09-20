# Fresh Tube: diseño

Fecha: 2026-09-16
Estado: aprobado en conversación, pendiente de revisión escrita

## Propósito

Un plugin de la barra de Omarchy (`omarchy-shell`, Quickshell) que muestra el
último video de un puñado de canales de YouTube elegidos a mano. El objetivo es
dejar de entrar a YouTube y buscar entre decenas de suscripciones: un icono en
la barra dice cuántos videos nuevos hay, un click despliega la lista, un click
en un video lo reproduce en `mpv`. Lo ya visto desaparece.

Decisiones tomadas con el usuario:

- Reproducción en `mpv` (usa `yt-dlp` por debajo). No en el navegador.
- Solo el último video de cada canal. Un canal aparece en la lista únicamente si
  su video más reciente no fue visto.
- Un video visto desaparece de la lista. No hay vista de "ya vistos".
- El código vive directamente en `~/.config/omarchy/plugins/io.github.ferc10110.fresh-tube/`
  como repo git, igual que `readily` y `save-them-all`.
- Backend en Python (solo stdlib) + QML como cara, mismo patrón que `readily`.
- Textos de la UI en inglés, como en los otros plugins publicados del usuario.

## Identidad

| Campo | Valor |
|---|---|
| Nombre | Fresh Tube |
| Id | `io.github.ferc10110.fresh-tube` |
| Repo | `omarchy-fresh-tube` |
| Kind | `bar-widget` |
| Sección por defecto | `left` |
| Licencia | MIT, autor Fernando Cancro |
| Target IPC | `io.github.ferc10110.fresh-tube` |

Settings inline en la entrada de `shell.json` (declarados en `barWidget.schema`
del manifest):

| Key | Tipo | Default | Uso |
|---|---|---|---|
| `playerCommand` | string | `"mpv"` | Comando que recibe la URL del video como último argumento. Se separa por espacios. |
| `refreshMinutes` | number | `15` | Intervalo del refresco automático. Mínimo 1. |

## Estructura de archivos

```
io.github.ferc10110.fresh-tube/
  manifest.json
  BarWidget.qml            icono + contador; carga Panel.qml; timer de refresco
  Panel.qml                estado, comandos al backend, IPC, las dos vistas
  FeedPopup.qml            popup layer-shell con pin y resize
  VideosView.qml           lista de videos nuevos
  ChannelsView.qml         alta y baja de canales
  FreshTubeCommand.qml     runner de un proceso a la vez con timeout
  FreshTubeModel.js        helpers puros (tiempo relativo, validación)
  bin/fresh-tube           entry point Python (sys.dont_write_bytecode, sys.path a lib/)
  lib/fresh_tube/
    __init__.py
    cli.py                 parseo de argumentos, exit codes, salida JSON
    resolve.py             URL o handle -> channel_id + nombre
    feed.py                descarga y parseo del RSS de un canal
    store.py               channels.json y state.json, escritura atómica
    errors.py              excepciones con exit code
  tests/
    fixtures/              feed.xml, channel_page.html, watch_page.html
    test_resolve.py test_feed.py test_store.py test_cli.py
    model.test.js          tests Node de FreshTubeModel.js
  docs/superpowers/specs/  este documento
  README.md  LICENSE  THIRD_PARTY_NOTICES.md  .gitignore
```

`FeedPopup.qml` adapta `Ui/KeyboardPanel.qml` del shell (MIT, David Heinemeier
Hansson) y el modo pinned de `CameraPopup.qml` del plugin `yani.camera` (MIT,
Yani). `THIRD_PARTY_NOTICES.md` lo declara.

## Backend: `bin/fresh-tube`

Todo comando imprime JSON en stdout. Los errores van a stderr con el prefijo
`fresh-tube: ` y la última línea es el mensaje para el usuario (patrón de
readily). Exit codes:

| Código | Significado |
|---|---|
| 0 | ok |
| 1 | error inesperado |
| 2 | uso o entrada inválida (URL que no parece de YouTube, prefs con valor inválido) |
| 3 | red o resolución (no se pudo bajar la página o el feed, canal no encontrado) |
| 4 | duplicado (el canal ya estaba) |
| 5 | id desconocido (remove de un canal que no existe, pin de un video que no es el último de ningún canal, unpin de uno que no está pineado) |
| 6 | límite de pins (ya hay 3 videos pineados) |

### Comandos

`add <url>`
Resuelve el canal, baja su feed una vez, lo guarda en `channels.json` y su
caché en `state.json`. Imprime el objeto canal. Acepta:

- `https://www.youtube.com/@handle`, con o sin `/videos` u otra subruta
- `https://www.youtube.com/c/Nombre`, `/user/Nombre`
- `https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxx`
- `@handle` a secas, o un id `UC…` de 24 caracteres a secas
- una URL de video (`watch?v=`, `youtu.be/`, `/shorts/`): se agrega el canal del video

Resolución (`resolve.py`):

1. Si la entrada ya contiene un id `UC…` de 24 caracteres, se usa directo.
2. Si no, GET de la página con `User-Agent` de navegador y
   `Accept-Language: en`, timeout 20 s. Se busca, en este orden:
   `<link rel="canonical" href="https://www.youtube.com/channel/UC…">`,
   `<meta itemprop="identifier" content="UC…">`,
   `<meta itemprop="channelId" content="UC…">`.
   No se usa el primer `"channelId":"UC…"` del HTML: en un canal aparecen ids
   de otros canales antes que el propio.
3. Si la página no dio id, fallback:
   `yt-dlp --flat-playlist -I 0 --print playlist:channel_id <url>` con
   timeout 20 s.
4. El nombre del canal sale del `<title>` del feed RSS, que se baja de todos
   modos para cachear el último video.

`remove <channel_id>`
Quita el canal de `channels.json` y su entrada de `state.json.feeds`. Los
videos pineados de ese canal se conservan (se despinean a mano). Imprime
`{"removed": "<id>"}`.

`channels --json`
```json
{"channels": [
  {"id": "UC…", "name": "Linus Tech Tips",
   "url": "https://www.youtube.com/channel/UC…",
   "addedAt": "2026-09-16T14:00:00+00:00",
   "lastError": ""}
]}
```
`lastError` no vive en `channels.json`: el CLI lo toma de `state.json.feeds[id].lastError`
al armar la salida.

`refresh --json [--cached]`
Sin `--cached`: baja el RSS de cada canal en paralelo (`ThreadPoolExecutor`,
máximo 6 a la vez, timeout 10 s por canal), actualiza `state.json.feeds`,
guarda `fetchedAt` global si al menos un canal respondió, y poda `seen`. Un
canal que falla conserva su caché anterior y registra `lastError`.
Con `--cached`: no toca la red, devuelve lo que hay en `state.json`.

```json
{"videos": [
  {"videoId": "3xngArcFpek",
   "title": "I Promise you this is NOT Stupid",
   "channelId": "UC…", "channel": "Linus Tech Tips",
   "published": "2026-09-15T17:00:03+00:00",
   "thumbnail": "https://i4.ytimg.com/vi/3xngArcFpek/hqdefault.jpg",
   "url": "https://www.youtube.com/watch?v=3xngArcFpek"}
 ],
 "pinned": [
  {"videoId": "…", "title": "…", "channelId": "UC…", "channel": "…",
   "published": "…", "thumbnail": "…", "url": "…"}
 ],
 "fetchedAt": "2026-09-16T14:05:00+00:00",
 "offline": false,
 "channelCount": 5,
 "errors": [{"channelId": "UC…", "channel": "…", "message": "timed out"}]}
```

`videos` contiene, por cada canal, su video más reciente si su id no está en
`seen` ni en `pins`, ordenados por `published` descendente. `pinned` son los
videos pineados en el orden en que se pinearon, con la misma forma que
`videos`, estén vistos o no. `offline` es `true` con
`--cached` o cuando todos los canales fallaron por red. `fetchedAt` es el
último refresco de red exitoso (puede ser viejo si estamos offline).

`seen <video_id>`
Agrega el id al set `seen`. Imprime `{"seen": "<id>"}`. Idempotente.

`pin <video_id>` y `unpin <video_id>`
`pin` guarda en `state.json.pins` el registro completo del video (el que hoy
es el más reciente de algún canal, o uno ya pineado), así sigue existiendo
aunque el canal publique otro. Máximo 3: con la lista llena responde exit 6
"Pin limit reached (3)"; un id que no es el último de ningún canal ni está
pineado responde exit 5 "No such video"; volver a pinear uno pineado es un
no-op. `unpin` lo quita de `pins` (exit 5 "That video is not pinned" si no
estaba). Ambos imprimen `{"pinned": [...]}` con la lista resultante.

`prefs get` y `prefs set <key> <value>`
Claves: `width` (int, 300..4000), `height` (int, 220..4000), `pinned`
(`true`/`false`). Imprime el objeto prefs completo:
`{"width": 420, "height": 520, "pinned": false}`.

### Feed (`feed.py`)

URL: `https://www.youtube.com/feeds/videos.xml?channel_id=<id>`. Atom con
namespaces `yt` (`http://www.youtube.com/xml/schemas/2015`) y `media`
(`http://search.yahoo.com/mrss/`). De cada `entry` se leen `yt:videoId`,
`title`, `published` y `media:group/media:thumbnail@url`. El "último" es el
de mayor `published`, no el primero del documento. Se guardan también los ids
de todas las entradas (`recent`) para la poda de `seen`. Los Shorts no se
filtran: el RSS no los distingue.

### Almacenamiento (`store.py`)

- `$XDG_CONFIG_HOME/fresh-tube/channels.json` (default `~/.config/fresh-tube/`)
  ```json
  {"version": 1, "channels": [{"id": "UC…", "name": "…", "url": "…", "addedAt": "…"}]}
  ```
- `$XDG_STATE_HOME/fresh-tube/state.json` (default `~/.local/state/fresh-tube/`)
  ```json
  {"version": 1,
   "seen": ["videoId", "…"],
   "feeds": {"UC…": {"fetchedAt": "…", "lastError": "",
                     "latest": {"videoId": "…", "title": "…", "published": "…", "thumbnail": "…"},
                     "recent": ["id1", "id2", "…"]}},
   "fetchedAt": "…",
   "prefs": {"width": 420, "height": 520, "pinned": false},
   "pins": [{"videoId": "…", "title": "…", "channelId": "UC…", "channel": "…",
             "published": "…", "thumbnail": "…", "url": "…"}]}
  ```

Escritura atómica: archivo temporal en el mismo directorio + `os.replace`.
Un archivo ausente equivale a vacío; un archivo corrupto se reporta con exit 1
y no se sobreescribe. Poda de `seen`: se conservan solo los ids que aparecen
en la unión de todos los `recent` o en `pins`. `pins` guarda como máximo 3
registros completos; al cargar se descartan entradas sin `videoId`. Fechas siempre en UTC con
`datetime.now(timezone.utc)`, nunca `utcnow()`.

## Widget de barra (`BarWidget.qml`)

- Glifo Nerd Font `󰗃` (nf-md-youtube). Con `count > 0` el icono usa
  `bar.foreground` y a su derecha se muestra el número; con `count == 0` el
  icono va atenuado (`Qt.darker(foreground, 1.55)`) y sin número.
- Tooltip: "3 new videos" / "Nothing new".
- Click izquierdo: `togglePanel()`. Click medio: `refresh()` sin abrir.
- Carga `Panel.qml` con `Loader { active: true }` e inyecta `bar`, `settings`,
  `anchorItem` (el botón) y `hostWidget` (el widget), como readily.
- Expone `opened`, `open()`, `close()`, `closeForPopoutSwitch()` y
  `popoutSwitchClosing` para el coordinador de popouts del bar.
  `closeForPopoutSwitch()` no hace nada si el panel está pinneado.
- Timer de refresco: `interval = max(1, refreshMinutes) * 60 * 1000`. Solo la
  primera instancia del widget (`bar.moduleWidgets(moduleName)[0] === root`)
  hace polling; al terminar llama `broadcast("reloadCached")` para que las
  instancias de otros monitores relean la caché. Al arrancar: `refresh
  --cached` inmediato para el contador, y un refresco de red a los 5 s.

## Panel (`Panel.qml`)

Hereda de `qs.Ui.Panel` con `manageIpc: false` y un `IpcHandler` propio:
`open`, `close`, `toggle`, `refresh`, `togglePin`. Así una keybinding puede
hacer `omarchy-shell io.github.ferc10110.fresh-tube toggle`.

Estado:

| Propiedad | Tipo | Notas |
|---|---|---|
| `view` | `"videos"` \| `"channels"` | vista actual |
| `videos` | array | salida de `refresh` |
| `channels` | array | salida de `channels` |
| `fetchedAt`, `offline`, `errors` | | de `refresh` |
| `notice`, `noticeIsError` | string, bool | línea de aviso bajo la cabecera |
| `pinned`, `popupWidth`, `popupHeight` | | de `prefs get`, persistidos con `prefs set` |
| `refreshing`, `adding` | bool | runners en curso |
| `playerFound` | bool | resultado de `command -v <primer token de playerCommand>` al cargar |
| `selected` | int | fila seleccionada con teclado |

Runners (`FreshTubeCommand`, uno por comando: `refreshCmd`, `cachedCmd`,
`channelsCmd`, `addCmd`, `removeCmd`, `seenCmd`, `prefsCmd`, `playerCheckCmd`).
Timeout por defecto 30 s; `addCmd` y `refreshCmd` usan 60 s porque encadenan
varias descargas (página 20 s + fallback yt-dlp 20 s + feed 10 s, o N canales
de a 6 con 10 s cada uno). Un `start` mientras el runner está ocupado se ignora.

Flujos:

- `onOpenedChanged` a abierto: `view = "videos"`, `notice = ""`, corre
  `refresh --cached` y luego `refresh` real. Si `refresh` real llega con
  `offline: true`, se muestra la lista cacheada y el aviso
  "Offline, showing videos from hh:mm".
- `play(video)`: si `!playerFound`, aviso "mpv not found" y no hace nada más.
  Si no: `seen <id>`; al confirmar, `Quickshell.execDetached(playerCommand.split(/\s+/).concat([video.url]))`,
  quita la fila del array local, y cierra el panel si no está pinneado.
- `dismiss(video)`: `seen <id>` y quita la fila. No cierra.
- `addChannel(text)`: `add <text>`; mientras corre el campo queda deshabilitado
  con placeholder "Looking up channel…"; al terminar recarga `channels` y
  `refresh --cached`; el error inline sale de la última línea de stderr.
- `removeChannel(id)`: `remove <id>`, recarga `channels` y `refresh --cached`.
- `setPinned(v)`: cambia `pinned` y persiste con `prefs set pinned`.
- `resized(w, h)` desde el popup: persiste `prefs set width` y `height`.
- `reloadCached()`: `refresh --cached`. Lo llama el broadcast del widget.

Teclado (via `focusTarget` del popup): `Esc` cierra en videos, vuelve a videos
en canales; `↑`/`↓` mueven `selected`; `Enter` reproduce el seleccionado;
`Delete` lo descarta.

## Vistas

### `VideosView.qml`

- Cabecera: título "Fresh Tube" a la izquierda; a la derecha tres botones de
  icono: refresh `󰑐` (gira mientras `refreshing`), pin `󰐃` (resaltado si
  `pinned`), channels `󰕲`.
- Línea de aviso (`notice`) debajo de la cabecera cuando no está vacía; en
  color `urgent` si `noticeIsError`.
- Lista (`ListView` con `clip: true` y scroll) de filas:
  - thumbnail `Image` 96×54 con `fillMode: PreserveAspectCrop`, radio pequeño,
    `asynchronous: true`, fondo atenuado mientras carga;
  - título en hasta 2 líneas con `elide: ElideRight`;
  - debajo, "Channel · 3 h ago" en `caption` atenuado;
  - a la derecha, un `✕` visible solo con hover sobre la fila o cuando la fila
    está seleccionada; su click llama `dismiss`.
  - click en la fila llama `play`. Fila seleccionada o con hover: fondo sutil.
- Vacío con canales: "Nothing new" centrado y "updated hh:mm" en caption.
- Vacío sin canales: "Paste a channel URL to start" y un botón "Add channel"
  que cambia a la vista de canales.

### `ChannelsView.qml`

- Cabecera: botón `←` "Back" y título "Channels".
- `TextField` con placeholder "Paste a channel URL or @handle" y botón "Add";
  `Enter` también agrega. Mensaje de error inline debajo en `urgent`.
- Lista de canales: nombre; si `lastError` no está vacío, el mensaje en caption
  atenuado; a la derecha un `✕` para quitar. Sin confirmación: volver a agregar
  es un paste.
- Al entrar a la vista, el foco va al campo.

## Videos pineados

Para dejar fijo un video que se ve varias veces (música) o a lo largo de
varios días (uno largo), sin que desaparezca al reproducirlo.

- Cada fila tiene un botón de pin (`󰐃`, marcado cuando está pineado) al lado
  del `✕`; aparece al pasar el mouse y queda siempre visible en las filas
  pineadas. `P` con el panel abierto pinea o despinea la fila resaltada.
- Las filas pineadas van primero, en el orden en que se pinearon, y después
  los videos nuevos. Reproducir un video pineado lo marca visto igual que
  siempre, pero la fila no desaparece mientras esté pineado. En las filas
  pineadas no se muestra el `✕`: se sacan despineando.
- Despinear aplica la regla normal: si ya se reprodujo, desaparece; si no,
  vuelve a la lista de nuevos (siempre que siga siendo el último de su canal).
- Con 3 pineados, el botón de pin de las demás filas queda deshabilitado y al
  pasar el mouse dice "Pin limit reached (3)".
- El contador del icono cuenta solo `videos` (los nuevos), no los pineados.
  El icono queda atenuado si no hay nuevos, aunque haya pineados.
- Los pineados se muestran también con `--cached` y sin red, porque viven en
  `state.json`. Quitar un canal no los borra.
- El panel guarda `pinnedVideos` aparte de `videos`; `pin`/`unpin` se lanzan
  por un runner propio (`pinCmd`, 30 s) y al terminar se aplica la lista
  `pinned` que devuelve el CLI. Un error del CLI se muestra como aviso y la
  lista no cambia.

## Popup (`FeedPopup.qml`)

`PanelWindow` layer-shell a pantalla completa con la tarjeta adentro, como
`KeyboardPanel`. Diferencias:

- **Alineación**: el borde izquierdo de la tarjeta se alinea con el borde
  izquierdo del icono (`anchorScreenPos.x`), no centrado, y se clampa a la
  pantalla. Con barra abajo lo mismo en x; con barra a los lados, el borde
  superior se alinea al del icono. Así, al agrandar desde la esquina inferior
  derecha la tarjeta crece hacia la derecha y abajo sin moverse.
- **Pin** (`property bool pinned`): tomado de `CameraPopup`:
  - `dismissArea.enabled: open && !pinned`; los gemelos de otros monitores solo
    existen si `!pinned`.
  - `mask` cubre toda la pantalla si no está pinneado, y solo la tarjeta si lo
    está, así los clicks fuera llegan a las ventanas de abajo.
  - Al pinnear con el popup abierto se llama `bar.releasePopout(coordinatorKey)`;
    al despinnear, `bar.requestPopout(coordinatorKey)`.
  - `WlrLayershell.keyboardFocus`: `OnDemand` cuando está pinneado, si no el
    prime `Exclusive` breve y luego `OnDemand`, igual que `KeyboardPanel`.
  - En `onOpenChanged` la coordinación de popout se salta cuando está pinneado.
- **Resize** (`property bool resizable: true`, `signal resized(int w, int h)`):
  - `MouseArea` de 18×18 en la esquina inferior derecha de la tarjeta, con
    `cursorShape: Qt.SizeFDiagCursor`, `preventStealing: true`, y un glifo
    `◢` atenuado (más visible con hover).
  - `onPressed` guarda el punto en coordenadas de pantalla y el tamaño actual;
    `onPositionChanged` asigna `contentWidth = clamp(startW + dx, 300, availableCardWidth)`
    y `contentHeight = clamp(startH + dy, 220, availableCardHeight)`;
    `onReleased` emite `resized(contentWidth, contentHeight)`.
  - La tarjeta es un `Item` dentro de una ventana a pantalla completa, así que
    cambiar su tamaño no requiere re-anclar nada.
- `contentWidth`/`contentHeight` vienen del panel (`prefs`), pasados por
  `fittedContentWidth`/`cappedContentHeight` para que nunca excedan la pantalla.

## Estilo

Colores y fuente desde la barra: `bar.foreground`, `bar.urgent`,
`bar.fontFamily`; atenuado = `Qt.darker(foreground, 1.55)`. Fondo y borde de
la tarjeta desde `Color.popups.*` y `Border.surfaceSpec`. Tamaños con
`Style.space()` y `Style.font.*`. Componentes de `qs.Ui`: `Button`,
`TextField`, `BorderSurface`, `WidgetButton`. Nada hardcodeado en píxeles fuera
de mínimos de tarjeta y el thumbnail.

## Errores y casos borde

| Situación | Comportamiento |
|---|---|
| Sin red al refrescar | Lista cacheada intacta, aviso "Offline, showing videos from hh:mm". |
| Un canal falla | Los demás se actualizan; el canal conserva su caché; el error se ve en la vista de canales. |
| URL que no es de YouTube | exit 2, "That doesn't look like a YouTube channel". |
| Canal inexistente o página sin id | exit 3, "Couldn't find that channel". |
| Canal duplicado | exit 4, "Already added". |
| Cuarto pin | exit 6, "Pin limit reached (3)"; el botón de pin ya estaba deshabilitado en la UI. |
| `pin` de un video que ya no es el último de su canal y no está pineado | exit 5, "No such video". |
| Canal quitado con videos pineados | Los pineados siguen en la lista hasta que se despinean. |
| `mpv` ausente | `playerFound = false`; al hacer click, aviso "mpv not found (playerCommand)"; no se marca visto. |
| Comando colgado | El runner lo mata a los 30 s y muestra "fresh-tube took too long". |
| `state.json` corrupto | exit 1 con mensaje; el archivo no se toca. Se puede borrar a mano. |
| Panel pinneado y otro panel de la barra se abre | Fresh Tube sigue abierto; el otro panel se abre encima según orden de capas. |
| Pantalla más chica que el tamaño guardado | `fittedContentWidth`/`cappedContentHeight` recortan; el valor guardado no cambia. |
| Dos monitores | Un widget por barra; solo el primero hace polling; los demás releen caché por broadcast. |

## Pruebas

Python (`unittest`, no hay pytest en la máquina; sin red: `urlopen`, `fetch_url`, `fetch_feed` y `subprocess.run` mockeados):

- `test_feed.py`: parseo del fixture `feed.xml` (nombre, último por fecha
  aunque no sea el primero, thumbnail, `recent`), feed vacío, XML inválido.
- `test_resolve.py`: id directo, `/channel/UC…`, canonical en `channel_page.html`,
  `itemprop` en `watch_page.html`, `@handle` a secas, fallback a yt-dlp cuando
  el HTML no tiene id, entrada que no es de YouTube.
- `test_store.py`: add, duplicado, remove, remove desconocido, seen idempotente,
  poda de seen, prefs válidas e inválidas, escritura atómica, corrupto; pins:
  límite de 3, re-pin no-op, unpin, entradas inválidas descartadas al cargar,
  pineados fuera de `unseen_videos` y a salvo de la poda.
- `test_cli.py`: cada comando vía `main()` con `capsys`: forma del JSON,
  exit codes, `refresh --cached` sin red, ordering de `videos`, `offline`;
  `pin`/`unpin`: `pinned` en el payload, visto pero pineado sigue, sobrevive a
  que el canal publique otro, despinear aplica la regla normal, límite (exit 6),
  id desconocido (exit 5), `remove` conserva pins.

Node (`node --test tests/model.test.js`):

- `relativeTime`: "just now", "5 min ago", "3 h ago", "yesterday", "4 d ago",
  fecha corta pasados 7 días; entrada inválida devuelve "".
- `looksLikeChannelInput`: acepta URLs de YouTube, `@handle`, `UC…`; rechaza
  vacío y texto con espacios.

QML, checklist manual sobre la barra real (hot-reload al guardar):

1. El icono aparece a la izquierda tras `omarchy plugin enable`.
2. Sin canales: el panel invita a agregar; pegar un `@handle` agrega el canal y
   vuelve a la lista con su último video.
3. Click en un video abre mpv, la fila desaparece, el panel se cierra.
4. `✕` descarta sin abrir mpv.
5. Pin: click afuera no cierra; abrir el panel de audio no lo cierra; `Esc` sí.
   Reabrir el shell lo trae pinneado.
6. Resize desde la esquina: crece a la derecha y abajo; cerrar y abrir
   conserva el tamaño; `omarchy restart shell` también.
7. Sin red (`nmcli networking off`): aviso offline y lista intacta.
8. Teclado: `↑`/`↓`/`Enter`/`Delete`/`Esc`.
9. Contador en la barra baja al descartar y sube tras `omarchy-shell io.github.ferc10110.fresh-tube refresh`.
10. Pin: `󰐃` en una fila la manda arriba; reproducirla no la saca; el contador
    no la cuenta; `omarchy restart shell` la trae pineada; despinear tras verla
    la hace desaparecer. Con 3 pineados, el pin de las otras filas está
    deshabilitado con "Pin limit reached (3)". `P` pinea la fila resaltada.

## Instalación y desarrollo

```sh
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.ferc10110.fresh-tube
```

Guardar cualquier archivo del plugin recarga el código. Los tests Python corren
con `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` desde
la carpeta del plugin; los de Node con `node --test tests/model.test.js`.

## Fuera de alcance de esta versión

- Filtrar Shorts (el RSS no los marca).
- Mover el panel pinneado arrastrándolo.
- Notificaciones de escritorio cuando aparece un video.
- Modo "todos los no vistos por canal".
- Sincronizar vistos con la cuenta de YouTube, o reproducir en el navegador.
- Página de consentimiento de YouTube (UE): si la página del canal redirige a
  `consent.youtube.com`, el fallback a `yt-dlp` cubre el caso.
