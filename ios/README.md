# Orchard para iPhone

Port de Orchard Mobile a iOS. Usa el mismo motor que escritorio y Android:
el proveedor de YouTube en JavaScript (QuickJS + `core/native/provider_host`)
y el extractor del player en Rust (`crates/orchard-youtube-extractor`).
La interfaz está en SwiftUI.

## Qué hace esta primera versión

- Iniciar sesión en YouTube Music (necesario para reproducir; buscar funciona sin cuenta).
- Inicio con tus recomendaciones, búsqueda, tus playlists y álbumes.
- Reproducción en segundo plano, controles en la pantalla de bloqueo y en los audífonos.
- Cola: reproducir a continuación, agregar, reordenar, quitar, vaciar.
- Autoplay opcional: al terminar la cola sigue con canciones parecidas.

## Compilar

No hace falta un Mac propio: el workflow `.github/workflows/ios.yml` compila en un
Mac de GitHub y deja `Orchard.ipa` en la pestaña **Actions** del repositorio
(artefacto *Orchard-iPhone*).

En un Mac, a mano:

```sh
git submodule update --init third_party/quickjs
bash ios/scripts/build-engine.sh
cd ios && xcodegen generate && open Orchard.xcodeproj
```

## Instalar en el iPhone (gratis)

1. Descarga el artefacto *Orchard-iPhone* desde Actions y descomprímelo: queda `Orchard.ipa`.
2. En el PC instala **Sideloadly** (sideloadly.io), e **iTunes** e **iCloud** desde la web de Apple
   (no las versiones de la Microsoft Store).
3. Conecta el iPhone por cable, arrastra `Orchard.ipa` a Sideloadly, escribe tu Apple ID y presiona *Start*.
4. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos** → confía en tu Apple ID.
   En iOS 16 o superior también hay que activar **Ajustes → Privacidad y seguridad → Modo de desarrollador**.

Con un Apple ID gratis la app dura 7 días; después se vuelve a instalar igual y no se pierde la sesión.
