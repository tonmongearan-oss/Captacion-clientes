# Captación de Clientes

Aplicación local para encontrar **empresas reales** que pueden ser clientes tuyos (B2B), analizar su presencia digital, puntuarlas, hacer el seguimiento comercial y exportarlas a Excel.

- Solo usa **fuentes públicas reales** (OpenStreetMap y, si la activas, Google Places) y la **web del propio negocio**.
- **Nunca inventa datos.** Si un dato no aparece en ninguna fuente, se muestra «No encontrado».
- Cada dato indica **de dónde sale** y **cuándo se comprobó**.
- Funciona en tu Mac, sin instalar nada: usa el Ruby y el SQLite que ya trae macOS.

---

## 1. Cómo arrancarla

1. Abre la carpeta `captacion-clientes` (en el Escritorio).
2. Haz **doble clic en `Iniciar Captacion.command`**.
   - La primera vez, macOS puede decir que «no se puede abrir porque es de un desarrollador no identificado». En ese caso: **clic derecho → Abrir → Abrir**. Solo hay que hacerlo una vez.
3. Se abre una ventana de Terminal (déjala abierta mientras uses la app) y el navegador en **http://localhost:4567**.
4. La primera vez, crea tu **usuario y contraseña** (se guardan cifrados solo en tu ordenador).

Para **cerrar** la aplicación: cierra la ventana de Terminal o pulsa `Ctrl + C` en ella.

> Alternativa desde Terminal: `cd ~/Desktop/captacion-clientes && ruby server.rb`

**No necesitas instalar nada** (ni Node.js, ni Homebrew, ni Python). Todo funciona con lo que trae macOS.

**¿Quieres usarla desde internet?** Sigue la guía **[PUBLICAR.md](PUBLICAR.md)** (Render, con acceso protegido).

---

## 2. Cómo usarla

1. **Panel** → escribe lo que buscas, por ejemplo `clínicas dentales en Barcelona`, y pulsa **Buscar**.
   Para afinar más usa **Nueva búsqueda**: qué vendes, tipo de cliente, rasgos del cliente ideal, sector, zona, código postal, cuántas empresas y filtros (con/sin web, con/sin Instagram, con email, puntuación mínima, excluir las que ya tienes guardadas).
2. La búsqueda tarda normalmente **entre 30 segundos y 3 minutos**: la app consulta las fuentes y **visita la web de cada negocio** para buscar evidencias (HTTPS, adaptación a móvil, año del copyright, redes enlazadas, email publicado, reservas online, formulario de contacto…).
3. En **resultados** puedes filtrar (país, comunidad, provincia, ciudad, código postal, sector, empleados, web, Instagram, email, puntuación, estado), ordenar haciendo clic en cada columna, guardar empresas con ⭐ y **exportar a Excel (.xlsx) o CSV**.
4. En la **ficha de cada empresa** verás:
   - Todos los datos con su fuente (enlace a OpenStreetMap / Google / su web).
   - **Oportunidades detectadas** con la evidencia concreta.
   - **Puntuación 0-100** desglosada y explicada.
   - **Seguimiento comercial (mini CRM)**: estado, próxima acción y fecha, último contacto, notas, comentarios e historial.
   - **Asistente IA**: borradores de DM de Instagram, email, WhatsApp (solo si el negocio publica ese canal), propuesta inicial, argumentario y por qué podría necesitarte.
   - **Privacidad**: base jurídica, origen de los datos y botón de **solicitud de supresión**.
5. **Mis leads** es tu base de datos de empresas guardadas. **Historial** guarda todas las búsquedas (puedes repetirlas). **Estadísticas** muestra el embudo comercial.

### Puntuación (0-100)

| Bloque | Máx. | Qué mide |
|---|---|---|
| Encaje con cliente ideal | 30 | Sector buscado + palabras clave de tu cliente ideal en su ficha o web |
| Necesidad aparente | 30 | Carencias visibles relacionadas con **lo que vendes** (p. ej., sin web si vendes webs; sin Instagram si vendes redes) |
| Margen de mejora | 15 | Número total de carencias detectadas |
| Datos de contacto | 15 | Teléfono, email y web/Instagram públicos |
| Señales de actividad | 10 | Negocio activo, horario publicado, web actualizada recientemente, reseñas |

**80-100 Prioritario · 60-79 Interesante · 40-59 Secundario · 0-39 Baja prioridad.**

La **confianza** (alta/media/baja) indica lo fiables que son los datos: alta si se confirma en varias fuentes o en la web del propio negocio.

**Lo que la app NO hace (a propósito):** no inventa contactos, no adivina nombres de personas (el decisor solo se añade a mano y con su fuente pública), no puede comprobar si un Instagram está «abandonado» (Meta no lo permite sin su API oficial) y **no envía nada automáticamente**.

---

## 3. Fuentes de datos y claves API

### OpenStreetMap (gratis, ya funciona)
Se usa **Nominatim** (rápido) y **Overpass** (más completo). No necesitan clave. Respetamos sus normas de uso (máx. 1 petición/segundo a Nominatim, una consulta Overpass a la vez, identificación de la app).
Overpass a veces va lento o está saturado: si tarda más de ~2 minutos, la app sigue con los resultados de Nominatim y te lo avisa.
La cobertura depende de lo que la comunidad haya mapeado: en ciudades grandes suele ser buena, en pueblos menor, y muchos negocios no tienen teléfono o web en OSM (por eso se visita su web para completar).

### Google Places API (opcional, más resultados y teléfonos)
Es de **pago por uso** (Google da un crédito mensual gratuito; consulta los precios actuales en la web de Google Maps Platform antes de activarla).

1. Entra en **https://console.cloud.google.com/** con tu cuenta de Google y crea un proyecto.
2. Activa la facturación (te pedirá una tarjeta).
3. Ve a **APIs y servicios → Biblioteca**, busca **«Places API (New)»** y pulsa **Habilitar**.
4. Ve a **APIs y servicios → Credenciales → Crear credenciales → Clave de API**. Copia la clave.
5. Recomendado: en la clave, pulsa **Restringir clave** → limita a «Places API (New)».
6. Abre el archivo **`.env`** de la carpeta de la app con TextEdit y pégala así:
   `GOOGLE_PLACES_API_KEY=tu_clave_aquí`
7. Cierra la ventana de Terminal y vuelve a abrir `Iniciar Captacion.command`.

Nota: las condiciones de Google limitan cuánto tiempo se pueden guardar ciertos datos de Places. Si lo usas de forma intensiva, revisa sus términos de servicio.

> El archivo `.env` está oculto en Finder: pulsa `Cmd + Mayús + .` dentro de la carpeta para ver los archivos ocultos.

### Asistente IA — Claude (opcional)
1. Crea una cuenta en **https://console.anthropic.com/** y añade saldo en *Billing*.
2. Ve a **Settings → API Keys → Create Key** y copia la clave (empieza por `sk-ant-`).
3. En el archivo `.env` pega: `ANTHROPIC_API_KEY=sk-ant-...`
4. Por defecto se usa el modelo `claude-opus-5-5` (máxima calidad). Si prefieres que sea más barato, cambia `ANTHROPIC_MODEL=claude-sonnet-5-5`.
5. Reinicia la app.

Los borradores se generan **solo con los datos reales de la ficha** y quedan como **borradores** que tú revisas, editas y apruebas. La app nunca envía mensajes ni hace envíos masivos.

**Las claves solo se guardan en `.env`, en tu ordenador** (el navegador nunca las ve).

---

## 4. Privacidad (RGPD y LOPDGDD) — léelo

- Cada lead guarda su **origen** y su **base jurídica** (por defecto: interés legítimo, art. 6.1.f RGPD, para prospección B2B con datos de contacto profesionales publicados por la propia empresa). Puedes cambiarla por lead o en Ajustes.
- **Conservación**: en Ajustes eliges cuántos días se guardan los resultados no guardados (30 por defecto) y los leads sin actividad (730 por defecto). La limpieza es automática cada hora.
- **Supresión**: desde la ficha, «Solicitud de supresión» borra todos sus datos y lo añade a una **lista de exclusión** para que no vuelva a aparecer en búsquedas.
- **Registro de actividad**: exportaciones, supresiones y cambios de ajustes quedan registrados (Ajustes → Registro).
- **Ojo con el email comercial**: en España la **LSSI (art. 21)** prohíbe enviar comunicaciones comerciales por email sin consentimiento previo, también a empresas en la práctica de la AEPD. Antes de enviar emails en frío, valora usar otros canales (teléfono público, visita, formulario de contacto de su web) o asesórate. Incluye siempre una forma fácil de darse de baja.
- El nombre de un **decisor** es un dato personal: añádelo solo si es público (p. ej., en la web de la empresa) y anota la fuente.
- Esta app es una herramienta; **la responsabilidad del tratamiento es tuya**. Si vas a hacer prospección a gran escala, consulta con un profesional de protección de datos.

---

## 5. Problemas frecuentes

| Problema | Solución |
|---|---|
| «Ninguna fuente respondió» | Los servidores públicos de OpenStreetMap están saturados. Espera unos minutos y repite la búsqueda (Historial → Repetir). |
| Pocos resultados | Prueba con un sector más general («clínica» en vez de «clínica de implantes»), una zona más grande, o activa Google Places. |
| Muchos «No encontrado» | Es normal: solo mostramos lo que está publicado. Pulsa «Volver a comprobar» en la ficha para revisar la web otra vez. |
| La página no carga | Comprueba que la ventana de Terminal sigue abierta. Si el puerto 4567 está ocupado, cambia `PORT=` en `.env`. |
| Olvidé la contraseña | Cierra la app y borra la carpeta `data/` (se borran también todos los datos) o pide ayuda técnica. |

---

## 6. Detalles técnicos (decisiones)

- **Ruby 2.6 + WEBrick + SQLite** (incluidos en macOS): cero instalación, ideal para una app local de un solo usuario. Node.js no está instalado en este Mac, así que se evitó depender de él.
- **Base de datos**: `data/captacion.db` (SQLite). Haz copia de esa carpeta para tener copia de seguridad.
- **Seguridad**: el servidor solo escucha en `127.0.0.1` (no accesible desde otros equipos), contraseñas con PBKDF2-SHA256, sesiones con cookie HttpOnly/SameSite, protección CSRF básica, claves solo en el servidor.
- **Límites de uso**: búsquedas e IA por hora (configurables), intentos de inicio de sesión, una búsqueda a la vez; Nominatim a 1 petición/segundo; análisis de webs con 8 conexiones en paralelo, respetando `robots.txt` y sin acceder a direcciones de red privadas.
- **Deduplicación**: por nombre normalizado + código postal/ciudad, y fusión entre fuentes por nombre + cercanía o mismo teléfono.
- **IA**: API de Anthropic por HTTP (el SDK oficial de Ruby requiere una versión de Ruby más reciente que la de macOS), con salida JSON estructurada y modelo de respaldo automático si la petición se rechaza.
- **Exportación**: CSV con `;` y BOM (se abre bien en Excel en español) y XLSX generado sin dependencias.

Estructura:

```
Iniciar Captacion.command   ← doble clic para arrancar
server.rb                   ← servidor y API
lib/                        ← búsqueda, fuentes, análisis web, puntuación, CRM, IA, exportación
public/                     ← interfaz (HTML, CSS, JS)
data/                       ← base de datos (se crea sola)
.env                        ← tus claves y ajustes
```
