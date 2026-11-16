# GPS Grupo (prototipo)

Mapa libre (OpenStreetMap) + ubicación en tiempo real de todos los teléfonos de un grupo.

## Opción A: compilar con GitHub (sin instalar nada en la PC)
1. Crea un proyecto gratis en supabase.com y ejecuta `supabase_setup.sql` en el SQL Editor.
2. Pon tu URL y anon key de Supabase al inicio de `lib/main.dart`.
3. Crea un repositorio en github.com y sube TODO el contenido de esta carpeta
   (incluida la carpeta oculta `.github`). Se puede arrastrar los archivos en
   "Add file > Upload files".
4. Ve a la pestaña Actions > "Compilar APK". Se ejecuta solo al subir; tarda unos 5-8 min.
5. Entra a la ejecución terminada, baja a "Artifacts" y descarga `gps-grupo-apk`.
6. Descomprime e instala `app-release.apk` en los teléfonos (permitir "orígenes desconocidos").

## Opción B: compilar en tu PC
1. `flutter create gps_grupo`, copia `pubspec.yaml` y `lib/main.dart`.
2. Agrega los permisos de `android_extra/AndroidManifest_permisos.txt`.
3. `flutter run`.

## Uso
Un teléfono pulsa "Crear grupo nuevo" y comparte el código; los demás "Unirme al grupo".

## Notas
- Para producción: añadir login y reglas de seguridad por usuario (RLS).
- Los tiles de tile.openstreetmap.org son para uso ligero.
