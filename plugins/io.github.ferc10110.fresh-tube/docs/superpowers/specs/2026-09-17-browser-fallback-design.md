# Fresh Tube 1.3: navegador de respaldo cuando mpv no puede abrir el video

Fecha: 2026-09-17. Extiende las especificaciones de 2026-09-16 y 2026-09-17 (`watch-later`);
lo que no se menciona acá no cambia.

## Problema

YouTube bloquea por momentos a yt-dlp ("Sign in to confirm you're not a bot"). mpv abre YouTube
a través de yt-dlp, así que muestra la ventana negra (`--force-window=immediate`), no consigue el
stream y sale. Un navegador con la sesión del usuario no sufre el bloqueo.

## Objetivo

1. mpv sigue siendo el reproductor. Si mpv no logra abrir el video, se abre el navegador de
   respaldo (Chromium por defecto) con el mismo video, en modo app: sin barra de direcciones ni
   pestañas, solo el reproductor de YouTube, sin nada para hacer scroll.
2. El navegador usa un perfil propio del plugin. El usuario inicia sesión ahí una vez
   (`fresh-tube login`); los videos con restricción de edad o de miembros funcionan como en el
   navegador.
3. La ventana del navegador aparece donde aparece la de mpv (debajo de la barra, a la izquierda),
   flotante, y recuerda su propio tamaño.

## Configuración

`shell.json` gana `fallbackCommand` (cadena, por defecto `"chromium"`, etiqueta
"Fallback player when mpv fails"). Vacía, desactiva el respaldo. Se pasa igual que
`playerCommand`: el panel lee `setting("fallbackCommand", "chromium")`.

## `fresh-tube play [--player CMD] [--fallback CMD] <videoId>`

- `--fallback` es opcional. Sin él, `play` se comporta como en 1.2.
- Con `--fallback` y reproductor mpv, mpv recibe además
  `--script-opt=fresh_tube-fallback=<CMD>`. El script de mpv (abajo) lanza
  `<bin> play --player "<CMD>" -- <videoId>` cuando mpv no pudo abrir el video. Esa segunda
  llamada no lleva `--fallback`, así que no hay cadena.
- Con `--fallback` y un reproductor que no es mpv, `--fallback` se ignora (sin detección de fallo).

### Reproductor "navegador"

`play` reconoce como navegador un comando cuyo primer token tiene nombre base `chromium`,
`chromium-browser`, `google-chrome`, `google-chrome-stable`, `brave`, `brave-browser`,
`vivaldi`, `vivaldi-stable`, `microsoft-edge`, `microsoft-edge-stable`, `helium` u `opera`.
Para esos, el argv es:

    <tokens del comando>
    --user-data-dir=$XDG_STATE_HOME/fresh-tube/browser
    --no-first-run --no-default-browser-check
    --autoplay-policy=no-user-gesture-required
    --window-size=<W>,<H>
    --app=http://127.0.0.1:<puerto>/

El reproductor embebido de YouTube exige una cabecera `Referer` (sin ella muestra el error 153),
así que `play` no abre el embed directamente: abre un socket en `127.0.0.1` con un puerto libre,
lanza el navegador con `--app=http://127.0.0.1:<puerto>/` y le pasa el socket al helper
(`place-window <pid> … --serve <fd> --video <videoId>`), que sirve una página mínima (fondo negro,
un `<iframe>` a pantalla completa con `https://www.youtube.com/embed/<videoId>?autoplay=1`) desde
un hilo mientras vigila la ventana; al cerrarse la ventana termina el helper y con él el servidor.
Si no se consigue puerto, el navegador recibe el embed directo (degradado: error 153).

`W`/`H` son las preferencias `browserWidth`/`browserHeight` (enteros 200–8000, en píxeles
lógicos porque Chromium mide `--window-size` así); si no existen, `W` = `width / scale` del
monitor enfocado / 4 redondeado y `H` = `W` × 9 / 16; sin `hyprctl`, 860×484.
El perfil propio hace que sea un proceso aparte (no se entrega la URL a un Chromium ya abierto),
por eso la ubicación por `pid` funciona igual que con mpv. Las banderas de
`~/.config/chromium-flags.conf` de Omarchy se aplican solas porque es el mismo binario.

Cualquier otro reproductor que no sea mpv ni navegador recibe solo la URL, como hoy.

### Ubicación y tamaño de la ventana del navegador

Hyprland 0.56 (el de Omarchy) toma `hyprctl dispatch` como Lua: los dispatchers clásicos
(`setfloating`, `movewindowpixel`, `resizewindowpixel`) ya no existen y `place-window` usa
`hl.dsp.window.float({ window = 'address:<addr>', action = 'on' })` (idempotente; sin `action`
es un toggle), `hl.dsp.window.resize({ window = …, exact = true, x = W, y = H })` y
`hl.dsp.window.move({ window = …, exact = true, x = X, y = Y })`, en ese orden, porque
`resize` conserva el centro de la ventana. La dirección se valida como hexadecimal antes de
interpolarla en el Lua.

Chromium reutiliza una instancia abierta del perfil (la ventana de `login` u otro video): el pid
lanzado termina enseguida y la ventana pertenece a la instancia vieja. Por eso la página servida
lleva el título `Fresh Tube <videoId> :<puerto>`, único por ventana, y `place-window` busca la
ventana por pid o por ese título (`find_window(pid, title)`), y la vigila por el pid de la ventana
que encontró, no por el lanzado.

`place-window <pid> [--resize WxH] [--watch]`:

- `--resize WxH`: después de flotar, `hl.dsp.window.resize({ window = 'address:<addr>', exact = true, x = W, y = H })` y recién entonces `move` (ver arriba).
  (una ventana recién flotada no conserva el `--window-size`).
- `--watch`: después de ubicar, consulta `hyprctl clients -j` cada segundo hasta que la ventana
  desaparece o el proceso muere; guarda el último `size` no nulo como `browserWidth`/`browserHeight`
  (a través de la transacción del estado). Sin ventana encontrada, sale sin guardar.

`play` lanza el ayudante con `--resize` y `--watch` solo para navegadores. Para mpv, el tamaño lo
sigue recordando el script de mpv.

## Script de mpv

- Marca `loaded = true` en el evento `file-loaded`.
- `end-file` con `reason == "error"` y `loaded == false` (mpv no pudo abrir el video): si tiene
  `fresh_tube-fallback`, corre `<bin> play --player <fallback> -- <id>` desatachado, una sola vez.
  Un error después de cargar (corte de red a mitad del video) no dispara el respaldo.
- El tamaño (`osd-dimensions`) se registra solo con `loaded == true`: la ventana negra de un
  video que no cargó no debe quedar como tamaño recordado.
- Lo demás (`done` en `eof`/`eof-reached`, `prefs set` en `shutdown`) no cambia.

## `fresh-tube login`

Abre el navegador de respaldo (`fallbackCommand`, o `chromium` sin argumento; `--player CMD`
para elegir otro) con el perfil del plugin en una ventana normal (sin `--app`) en
`https://www.youtube.com/`: ahí el usuario inicia sesión y, si quiere, instala un bloqueador de
anuncios (uBlock Origin Lite) para ese perfil. Sale al lanzar; imprime `{"login": "<comando>"}`.
Si el comando no es un navegador conocido: `fresh-tube: <nombre> is not a browser I know how to
open`, exit 2. Si no se puede lanzar: `Could not start <nombre>: <motivo>`, exit 1.

## Panel

- `play` pasa `--fallback <fallbackCommand>` cuando la preferencia no está vacía.
- Nada más cambia en la interfaz. El README explica `login`, el respaldo y sus límites.

## Errores

| Situación | Comportamiento |
|---|---|
| mpv no abre el video (bloqueo de yt-dlp, red, video privado) | Ventana negra unos segundos, luego el navegador con el video. |
| Navegador de respaldo ausente | El script lanza `play`, que falla en silencio (stderr a /dev/null); el video queda visto. El README dice cómo probar con `fresh-tube play --player chromium <id>`. |
| El canal deshabilitó el embed | El reproductor de YouTube muestra "Watch on YouTube"; el enlace abre la página completa en la misma ventana. |
| Error de mpv a mitad del video | Sin respaldo (ya había cargado). |
| `fallbackCommand` vacío | Como 1.2: la ventana negra se cierra y no pasa nada más. |
| Ventana del navegador cerrada antes de ubicarse | El ayudante sale sin guardar tamaño. |

## Límites (aceptados)

- Con el navegador no hay detección de fin: el video no sale solo de "Watch later" (✕ o `Delete`).
- El embed arranca desde el principio; no retoma donde quedó.
- Publicidad salvo que el usuario instale un bloqueador en el perfil.

## Pruebas

Python (`unittest`, sin red, sin mpv, sin navegador ni hyprctl reales):

- `test_play.py`: `is_browser` para cada nombre de la lista y para `mpv`/`vlc`; argv del
  navegador completo (perfil bajo `$XDG_STATE_HOME`, `--window-size`, `--app` con el embed);
  `--fallback` agrega `--script-opt=fresh_tube-fallback=<CMD>` solo con mpv; tamaño del
  navegador desde `browserWidth/Height`, desde el monitor (con `scale`) y 860×484;
  `place-window --resize` despacha `hl.dsp.window.resize` antes de `move`; `--watch` guarda el último tamaño
  cuando la ventana desaparece y no guarda si nunca apareció; `cmd_play` con navegador lanza el
  ayudante con `--resize` y `--watch`; `login` argv y errores.
- `test_store.py`: límites de `browserWidth`/`browserHeight`.

Lua: sin prueba automática. QML: sin cambios visuales.

Checklist manual (con el bloqueo activo o simulando con `--player 'mpv --ytdl=no'`):

1. Reproducir desde cualquier pestaña: ventana negra breve, luego el navegador con el video
   reproduciéndose, debajo de la barra, a la izquierda, un cuarto del ancho.
2. Cambiar el tamaño de la ventana del navegador, cerrarla, reproducir otro: abre con ese tamaño.
3. `fresh-tube login`: ventana normal de Chromium con el perfil del plugin; iniciar sesión;
   un video con restricción de edad reproduce en el embed.
4. `fallbackCommand` vacío en `shell.json`: la ventana negra se cierra y no se abre nada.
5. Cuando el bloqueo se levanta, mpv reproduce normalmente y el navegador no aparece.

## Fuera de alcance

- Detección de fin y retomar posición con el navegador.
- Instalar el bloqueador de anuncios automáticamente.
- Elegir el navegador según `xdg-settings` (se configura a mano en `fallbackCommand`).
