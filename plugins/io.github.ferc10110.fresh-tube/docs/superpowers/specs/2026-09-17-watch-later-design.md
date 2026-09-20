# Fresh Tube 1.2: ventana del reproductor y lista "Watch later"

Fecha: 2026-09-17. Extiende la especificación de 2026-09-16 (`2026-09-16-fresh-tube-design.md`);
lo que no se menciona acá no cambia.

## Objetivo

1. La ventana de mpv aparece flotante en la esquina superior izquierda de la pantalla, justo
   debajo de la barra, chica por defecto (un cuarto del ancho del monitor, 16:9), y recuerda
   el tamaño con el que la cerraste. Se mueve y redimensiona como cualquier ventana flotante.
2. Una lista propia de videos para ver ("Watch later"), en otra pestaña del panel, separada de
   los videos nuevos de los canales. Se agregan pegando la URL del video, se ordenan
   arrastrando con el mouse, y salen de la lista cuando el video llega al final o cuando se
   marcan vistos con `✕`. Si cerrás el reproductor antes del final, el video queda y la próxima
   vez sigue desde donde lo dejaste.

## Reproducir: `fresh-tube play`

El panel deja de lanzar el reproductor directo. Toda reproducción, desde cualquier pestaña,
pasa por un comando nuevo:

    fresh-tube play [--player "<comando>"] <videoId>

- Lanza `<comando>` (por defecto `mpv`; el panel pasa la preferencia `playerCommand`) con la
  URL `https://www.youtube.com/watch?v=<videoId>`, desatachado (sesión propia, sin heredar
  stdout/stderr).
- Si el reproductor es mpv (el nombre base del primer token es `mpv`), agrega:
  - `--save-position-on-quit`: mpv guarda la posición si cerrás antes del final y retoma sola
    la próxima vez; al llegar al final, mpv borra esa marca.
  - `--force-window=immediate`: la ventana aparece antes de que cargue el stream.
  - `--geometry=<W>x<H>`: tamaño inicial. `W`/`H` son las preferencias `playerWidth` y
    `playerHeight`; si no existen, `W` = ancho físico del monitor enfocado (`width` de
    `hyprctl monitors -j`) / 4 (redondeado) y `H` = `W` × 9 / 16, porque mpv 0.41 mide
    `--geometry` en píxeles físicos (`hidpi-window-scale=no` por defecto). Sin
    `hyprctl`, el default es 860×484.
  - `--script=<plugin>/mpv/fresh-tube.lua` y
    `--script-opt=fresh_tube-id=<videoId>` `--script-opt=fresh_tube-bin=<ruta absoluta de bin/fresh-tube>`
    (dos flags: `--script-opts` pisaría la lista del usuario).
- Con otro reproductor solo se agrega la URL: no hay detección de fin ni tamaño recordado.
- Si el lanzamiento falla (`FileNotFoundError`, `OSError`), imprime
  `fresh-tube: Could not start <nombre>: <motivo>` y sale con 1; nada se marca visto.
- Si el lanzamiento anda, marca el video como visto (igual que hoy `seen`) y, si está en la
  lista, lo deja ahí. Imprime `{"played": "<videoId>"}` y sale con 0.

### Ubicación de la ventana

Solo bajo Hyprland (si `hyprctl` no está en `PATH` o falla, se omite en silencio):

1. Hasta 10 s después del lanzamiento, cada 100 ms, `hyprctl clients -j` hasta encontrar la
   ventana cuyo `pid` es el del proceso lanzado.
2. Con `hyprctl monitors -j`, el monitor de esa ventana (`monitor` → `id`): destino
   `x = monitor.x + reserved[0]`, `y = monitor.y + reserved[1]`. `reserved` es
   `[izquierda, arriba, derecha, abajo]` y es lo que la barra le pide a Hyprland, así que la
   ventana queda debajo de una barra arriba, o a la derecha de una barra a la izquierda.
3. Si la ventana no es flotante: `hyprctl dispatch setfloating address:<address>`.
   (Omarchy ya flota a `mpv` por regla; esto cubre a quien la haya quitado.)
4. `hyprctl dispatch movewindowpixel exact <x> <y>,address:<address>`.

No se agrega ninguna regla a `~/.config/hypr/`. La ventana no queda anclada: se mueve y
redimensiona a mano; solo la posición inicial es fija y solo el tamaño se recuerda.

### Script de mpv: `mpv/fresh-tube.lua`

- Lee `fresh_tube-id` y `fresh_tube-bin` con `mp.get_opt`. Sin alguno de los dos, no hace nada.
- Fin del video: en `end-file` con `reason == "eof"`, o cuando la propiedad `eof-reached`
  pasa a `true` (cubre `keep-open=yes` en la configuración del usuario), corre
  `<bin> done <id>` como subproceso desatachado (`detach = true`, `playback_only = false`),
  una sola vez por ejecución.
- Tamaño: observa `osd-dimensions`; guarda el último `w`×`h` distinto de cero. En `shutdown`,
  si tiene un tamaño, corre `<bin> prefs set playerWidth <w> playerHeight <h>` desatachado.
- Nunca bloquea a mpv: todo subproceso es asíncrono.

## Lista "Watch later"

### Datos

`state.json` gana `queue`: una lista ordenada (el orden es el del usuario) de
`{"videoId", "title", "channel", "thumbnail", "url", "addedAt"}`. Al cargar, se descartan
las entradas que no sean objetos con `videoId` de texto no vacío, y los duplicados por id
(queda el primero). La lista no interviene en `unseen_videos`, en los pines ni en la poda
de `seen`.

Preferencias nuevas: `playerWidth` y `playerHeight`, enteros entre 200 y 8000 (fuera de
rango o tipo: se ignoran al cargar y `prefs set` responde exit 2).

### Comandos

    fresh-tube queue add <url o id>
    fresh-tube queue move <videoId> <posición>
    fresh-tube queue --json
    fresh-tube done <videoId>
    fresh-tube prefs set <clave> <valor> [<clave> <valor> ...]

- `queue add`: acepta `watch?v=ID`, `youtu.be/ID`, `shorts/ID`, `embed/ID`, `live/ID`
  (con o sin `https://`, `www.`, `m.`, parámetros extra) y el id pelado (11 caracteres
  `[A-Za-z0-9_-]`). Cualquier otra cosa: `That doesn't look like a YouTube video`, exit 2.
  Ya en la lista: `Already in the list`, exit 4. Título, canal y miniatura salen del oEmbed de
  YouTube (`https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=<id>&format=json`:
  `title`, `author_name`, `thumbnail_url`, timeout 10 s); si falla, yt-dlp
  (`yt-dlp --no-download --print "%(title)s\t%(channel)s" <url>`, miniatura
  `https://i.ytimg.com/vi/<id>/hqdefault.jpg`, timeout 40 s); si los dos fallan,
  `oembed: …; yt-dlp: …` (mismo formato que los canales), exit 3, y no se agrega. El video
  entra al final de la lista. Imprime la entrada agregada.
- `queue move <videoId> <posición>`: `posición` es el índice destino desde 0; se recorta al
  rango válido. Id ausente: `Not in the list`, exit 5. Imprime `{"queue": [...]}`.
- `queue --json`: `{"queue": [...]}`. Sin `--json`, una línea por video: `<canal>: <título>  <url>`.
- `done <videoId>`: lo saca de la lista si está y lo marca visto; siempre exit 0, imprime
  `{"done": "<videoId>", "removed": true|false}`. Lo usan el script de mpv, el `✕` y `Delete`.
- `refresh --json` (con y sin `--cached`) agrega `"queue": [...]` a su salida, así el panel
  recarga todo con una llamada.
- `prefs set` acepta uno o más pares; valida todos antes de guardar; cualquier par inválido
  responde exit 2 sin guardar nada.

Un video puede estar a la vez en "nuevos" y en la lista. Reproducirlo lo saca de "nuevos"
(visto) y lo deja en la lista; `done` lo saca de los dos.

### Panel

- Encabezado con dos pestañas a la izquierda: `New (n)` y `Watch later (m)`, `n` = videos
  nuevos (sin contar pineados), `m` = largo de la lista. Los botones de canales y de pin del
  panel siguen a la derecha. `Ctrl+Tab` alterna pestañas. La pestaña activa se conserva
  mientras el shell vive; al iniciar es `New`.
- Pestaña "Watch later": campo `Paste a video link` con botón `Add` arriba (mismo patrón que
  la vista de canales: `Enter` agrega, error en rojo debajo del campo, el campo se limpia y
  conserva el foco al agregar). Debajo, la lista con las mismas filas que "nuevos"
  (miniatura, título, canal, fecha de agregado en relativo) sin botón de pin.
  Estado vacío: `Nothing saved yet. Paste a video link above.`
- Ordenar: arrastrar una fila con el mouse (presionar y mover verticalmente) la reubica; al
  soltar, `queue move`. `Ctrl+↑` / `Ctrl+↓` mueven la fila resaltada un lugar. Mientras el
  `queue move` corre, la lista muestra ya el orden nuevo; si el comando falla, vuelve al
  orden guardado y muestra el error.
- Click o `Enter` reproduce (`play`). `✕` o `Delete` marca visto (`done`). Tras cualquiera,
  el panel recarga con `refresh --cached`. Al reproducir, el panel se cierra como hoy.
- El contador del icono de la barra no cambia: solo videos nuevos.
- La vista de canales no cambia.
- `play` reemplaza a `execDetached` + `seen` en `Panel.qml`: el comando corre por
  `FreshTubeCommand`; exit 0 → recarga en caché y cierra el panel; exit ≠ 0 → aviso de error
  con la última línea de stderr, nada se marca. El chequeo previo de `playerCommand` en `PATH`
  se mantiene.

### Errores

| Situación | Comportamiento |
|---|---|
| Reproductor ausente o falla al lanzar | Aviso de error en el panel; el video sigue en su lista. |
| `hyprctl` ausente, ventana que no aparece en 10 s, o error de `hyprctl` | Se reproduce igual; sin ubicar. |
| Reproductor distinto de mpv | Se lanza con la URL; sin fin detectado ni tamaño recordado; el README lo dice. |
| oEmbed caído | yt-dlp; si también falla, exit 3 y no se agrega. |
| URL de canal o texto cualquiera en "Watch later" | `That doesn't look like a YouTube video`, exit 2. |
| `queue` corrupto en `state.json` | Entradas inválidas descartadas al cargar. |
| Fin de video con `keep-open=yes` | `eof-reached` dispara `done`. |
| mpv se cierra antes de guardar (kill -9, apagado) | mpv no guarda posición ni tamaño; sin daño. |

## Pruebas

Python (`unittest`, sin red, sin mpv ni hyprctl reales):

- `test_videos.py` (nuevo módulo `videos.py`): id desde cada forma de URL, id pelado,
  rechazo de canales y texto; oEmbed parseado desde JSON; fallback a yt-dlp con
  `subprocess.run` mockeado; los dos fallan.
- `test_store.py`: `queue`: agregar, duplicado, mover con recorte a los bordes, mover id
  ausente, quitar; validación al cargar (no lista, entradas sin id, duplicados);
  `playerWidth`/`playerHeight` límites; `set_pref` de a pares con validación atómica.
- `test_cli.py`: `queue add` (oEmbed mock, fallback, ambos fallan, entrada inválida,
  duplicado), `queue move`, `queue --json`, `done` (en lista, fuera de lista, dos veces),
  `refresh --json --cached` incluye `queue`, `prefs set` de a pares y con un par inválido.
- `test_play.py` (nuevo módulo `play.py`, con `subprocess.Popen` y el corredor de `hyprctl`
  mockeados): argv de mpv completo (flags, script, script-opts, geometry desde prefs y
  default desde `monitors -j`); reproductor no-mpv sin flags; `Popen` que falla → exit 1 y
  nada visto; éxito → visto; ubicación: `clients -j` con el pid → `movewindowpixel exact` con
  los offsets de `reserved`, `setfloating` solo si no flota; ventana que nunca aparece →
  exit 0 sin `dispatch`; `hyprctl` ausente → exit 0.

Lua: sin prueba automática (necesita mpv); cubierto por el checklist manual.

QML, checklist manual sobre la barra real:

1. Reproducir un video: la ventana de mpv aparece debajo de la barra, pegada a la izquierda,
   de un cuarto del ancho de pantalla; se mueve y redimensiona a mano.
2. Cerrar mpv con otro tamaño y reproducir de nuevo: aparece con ese tamaño, otra vez en la
   esquina.
3. Pestañas `New` / `Watch later` con contadores; `Ctrl+Tab` alterna.
4. Pegar una URL de video en "Watch later": aparece al final con título, canal y miniatura;
   pegar una URL de canal muestra `That doesn't look like a YouTube video`.
5. Arrastrar una fila a otra posición: queda ahí; `omarchy restart shell` conserva el orden.
   `Ctrl+↑`/`Ctrl+↓` también mueven.
6. Un video corto de la lista reproducido hasta el final desaparece solo de la lista.
7. Cerrar mpv a la mitad: el video sigue en la lista; reproducirlo de nuevo retoma donde iba.
8. `✕` y `Delete` sacan el video de la lista; si también estaba en "nuevos", de ahí también.
9. Un video que está en las dos pestañas: reproducirlo lo saca de `New` y lo deja en
   `Watch later`.
10. El contador del icono no cuenta la lista.

## Fuera de alcance

- Agregar a la lista desde una fila de "nuevos" (el usuario eligió solo pegar URLs).
- Recordar la posición de la ventana (solo el tamaño).
- Detección de fin con reproductores distintos de mpv.
- Listas de reproducción o videos que no sean de YouTube.
