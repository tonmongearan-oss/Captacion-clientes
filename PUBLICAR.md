# Publicar la app en internet (Render)

Con esta guía tendrás la app en una dirección como `https://captacion-clientes-xxxx.onrender.com`, accesible desde cualquier ordenador o móvil y **protegida con usuario y contraseña**.

> **Por qué Render y no Netlify:** Netlify solo aloja webs estáticas. Esta app necesita un servidor encendido (busca empresas, visita webs, guarda datos), y Render sí lo ofrece.

**Coste aproximado:** plan *Starter* (unos 7 $/mes) + disco de 1 GB (unos céntimos al mes). Consulta los precios actuales en https://render.com/pricing.
No uses el plan gratuito: no admite disco, así que **se borrarían todos tus leads** cada vez que el servidor se reinicie.

Necesitas una cuenta de **GitHub** (gratis) y tu cuenta de **Render** (ya la tienes: equipo «WEB Making»).

---

## Paso 1 — Subir el código a GitHub (sin instalar nada)

1. Entra en **https://github.com/new**.
2. Nombre del repositorio: `captacion-clientes`. Marca **Private** (privado). Pulsa **Create repository**.
3. En la página siguiente, pulsa el enlace **«uploading an existing file»**.
4. Descomprime **`captacion-clientes-render.zip`** (en tu Escritorio). Abre la carpeta y **arrastra todo su contenido** a la página de GitHub: `Dockerfile`, `Gemfile`, `render.yaml`, `server.rb`, `README.md`, `PUBLICAR.md` y las carpetas `lib` y `public`.
5. Abajo, pulsa **Commit changes**.

⚠️ **Nunca subas el archivo `.env`** ni la carpeta `data/`: contienen tus claves y tus leads. El zip preparado ya no los incluye.

## Paso 2 — Crear el servicio en Render

1. Entra en **https://dashboard.render.com** → **New +** → **Blueprint**.
2. Conecta tu cuenta de GitHub si te lo pide, y elige el repositorio `captacion-clientes`.
3. Render leerá el archivo `render.yaml` y te mostrará lo que va a crear: un servicio web en **Frankfurt (UE)** con un disco de 1 GB.
4. Te pedirá los valores de `ANTHROPIC_API_KEY` y `GOOGLE_PLACES_API_KEY`. Son **opcionales**: puedes dejarlos vacíos y añadirlos después.
5. Pulsa **Apply** y espera a que termine (unos 3-5 minutos). El estado debe acabar en **Live**.

Si la construcción falla, copia el mensaje de error de la pestaña **Logs** y pídeme ayuda.

## Paso 3 — Crear tu cuenta (solo la primera vez)

1. En Render, abre el servicio **captacion-clientes** → **Environment**. Busca `SETUP_CODE` y pulsa el ojo para verlo. Cópialo.
2. Abre la dirección del servicio (arriba, termina en `.onrender.com`).
3. Pega el **código de instalación**, elige usuario y una contraseña de **al menos 12 caracteres**.

Solo se puede crear **una cuenta**, y solo con ese código. Nadie más puede registrarse.

## Paso 4 — Añadir las claves (opcional)

En Render → servicio → **Environment** → **Edit**:
- `ANTHROPIC_API_KEY` = tu clave de Claude (asistente de IA)
- `GOOGLE_PLACES_API_KEY` = tu clave de Google Places

Pulsa **Save, rebuild, and deploy**. Cómo conseguir cada clave: ver `README.md`, apartado 3.

---

## Seguridad en internet

Al publicarla, la app activa automáticamente el **modo público**:
- Alta de cuenta solo con `SETUP_CODE` y contraseña de 12 caracteres o más.
- Bloqueo tras 8 intentos fallidos de inicio de sesión en 5 minutos (por IP) y 60 por hora en total.
- Cookie de sesión segura (solo HTTPS), cabeceras de seguridad (CSP, anti-iframe, HSTS).
- La app no visita direcciones de red internas aunque una web enlace a ellas.
- Límites de búsquedas y de usos de IA por hora (en Ajustes).

## Privacidad (RGPD)

- Los datos se guardan en el disco del servidor de Render en **Frankfurt (UE)**. Render actúa como **encargado del tratamiento**: acepta su acuerdo de tratamiento de datos (DPA) desde su web y menciónalo en tu registro de actividades.
- Las copias de seguridad del disco las hace Render a diario. Puedes descargar tus datos cuando quieras con **Exportar Excel**.

## Mantenimiento

- **Actualizar la app:** sube los archivos nuevos al mismo repositorio de GitHub (igual que en el Paso 1). Render la vuelve a publicar solo, y tus datos se conservan en el disco.
- **Olvidaste la contraseña:** en Render → **Shell**, ejecuta `rm /var/data/captacion.db` (⚠️ borra todos los datos) y crea la cuenta de nuevo con `SETUP_CODE`.
- **Pausar el coste:** en Render → servicio → **Settings** → **Suspend**. Para borrarlo del todo, **Delete Service** (se pierde el disco).
- La app en tu Mac (`Iniciar Captacion.command`) sigue funcionando por separado, con sus propios datos.
