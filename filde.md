El método nativo `supabase.auth.signInWithPassword()` de Supabase **está diseñado estrictamente para recibir un `email` o un `phone**`. No permite pasarle un nombre de usuario directamente porque el sistema de autenticación base necesita una credencial única global para identificar la cuenta.

Sin embargo, **sí que puedes lograr que el usuario inicie sesión escribiendo su nombre (`Martinmeli`) o su correo de forma indistinta**. El truco consiste en hacer un "paso previo": si el usuario escribe un nombre, hacemos una consulta rápida a la base de datos para averiguar qué correo le pertenece a ese nombre, y luego iniciamos sesión con ese correo.

Para poder buscar por el JSON de `raw_user_meta_data`, necesitas crear una pequeña función (RPC) en Supabase o consultar una tabla pública. La forma más limpia y segura es crear una función en tu base de datos que busque el correo asociado a ese `user_name`.

Aquí tienes la solución paso a paso:

---

### Paso 1: Crear la función de búsqueda en Supabase (SQL)

Ve al **SQL Editor** de Supabase y ejecuta este código. Esto creará una función segura que busca en la tabla oculta `auth.users` y devuelve el correo si encuentra el `user_name` dentro del JSON:

```sql
CREATE OR REPLACE FUNCTION get_email_by_username(username_input TEXT)
RETURNS TEXT 
SECURITY DEFINER -- Esto le permite buscar en el esquema auth de forma segura
AS $$
BEGIN
  RETURN (
    SELECT email 
    FROM auth.users 
    WHERE raw_user_meta_data->>'user_name' = username_input
    LIMIT 1
  );
END;
$$ LANGUAGE plpgsql;

```

---

### Paso 2: Modificar tu función de Vue en el Frontend

Ahora, en tu código TypeScript, vamos a interceptar el valor que ingresa el usuario. Si no tiene forma de correo (no incluye un `@`), llamaremos a la función que acabamos de crear para transformar ese nombre en el correo real antes de loguear.

Modifica tu función `login` para que quede así:

```typescript
async function login(identifier: string, password: string) {
    loading.value = true
    error.value = null
    
    try {
      let emailToAuth = identifier

      // 1. Validar si lo que ingresó el usuario NO es un correo (es un username)
      if (!identifier.includes('@')) {
        // Llamamos a la función de SQL que creamos en el paso 1
        const { data: foundEmail, error: rpcError } = await supabase.rpc('get_email_by_username', {
          username_input: identifier
        })

        if (rpcError || !foundEmail) {
          throw new Error('El nombre de usuario no existe.')
        }

        // Si lo encuentra, reemplazamos el identificador por el correo real
        emailToAuth = foundEmail
      }

      // 2. Ejecutar el login tradicional de Supabase con el correo obtenido
      const { data, error: authError } = await supabase.auth.signInWithPassword({ 
        email: emailToAuth, 
        password 
      })
      
      if (authError) throw authError
      if (!data.user) throw new Error('No se pudo obtener el usuario.')

      session.value = data.user
      await fetchProfile(data.user.id)
    } catch (err) {
      error.value = friendlyError(err)
      user.value = null
      session.value = null
    } finally {
      loading.value = false
    }
  }

```

### 💡 ¿Cómo cambia la experiencia del usuario?

Ahora en tu formulario de Vue puedes cambiar el placeholder del input a algo como `placeholder="Correo o Usuario"`.

* Si el usuario escribe `martinmeli@correo.com`, el código detecta el `@`, se salta el paso intermedio e inicia sesión directo.
* Si el usuario escribe `Martinmeli`, el código va rápido a la base de datos, descubre que su correo es `martinmeli@correo.com` y lo loguea de forma transparente usando su contraseña. ¡El usuario final ni se dará cuenta del proceso!




Para reparar de un solo golpe **todos** los usuarios que importaste masivamente de MySQL (y evitar tener que ir uno por uno), creé un script automatizado en PL/pgSQL.

Este script busca en la base de datos a todos los usuarios que tengan el problema del `NULL` en `is_super_admin`, los campos de tokens vacíos o el hash viejo de PHP (`$2y$`), y los actualiza de forma automática al estándar estricto que Supabase requiere.

Ejecuta este bloque completo en tu **SQL Editor**:

```sql
DO $$
DECLARE
    usuario RECORD;
    repaired_hash TEXT;
BEGIN
    -- 1. Recorremos todos los usuarios de la tabla de autenticación
    FOR usuario IN 
        SELECT id, encrypted_password, email 
        FROM auth.users
    LOOP
        -- A. Reparar el prefijo de la contraseña si viene de PHP/MySQL ($2y$ -> $2a$)
        IF usuario.encrypted_password LIKE '$2y$%' THEN
            repaired_hash := '$2a$' || SUBSTRING(usuario.encrypted_password FROM 5);
        ELSE
            repaired_hash := usuario.encrypted_password;
        END IF;

        -- B. Actualizar la fila del usuario con los valores estructurales correctos
        UPDATE auth.users
        SET 
            encrypted_password = repaired_hash,
            is_super_admin = COALESCE(is_super_admin, false), -- Quita el NULL problemático
            is_anonymous = COALESCE(is_anonymous, false),
            is_sso_user = COALESCE(is_sso_user, false),
            confirmation_token = COALESCE(confirmation_token, ''), -- Cambia NULL por texto vacío
            recovery_token = COALESCE(recovery_token, ''),
            email_change_token_new = COALESCE(email_change_token_new, ''),
            email_change_token_current = COALESCE(email_change_token_current, ''),
            phone_change_token = COALESCE(phone_change_token, ''),
            phone_change = COALESCE(phone_change, ''),
            email_change = COALESCE(email_change, ''),
            email_change_confirm_status = COALESCE(email_change_confirm_status, 0),
            -- Asegurar que el JSON de proveedores esté bien estructurado
            raw_app_meta_data = '{"provider": "email", "providers": ["email"]}'::jsonb
        WHERE id = usuario.id;

        -- C. Reparación de seguridad: Verificar si el usuario no tiene su fila espejo en auth.identities
        IF NOT EXISTS (SELECT 1 FROM auth.identities WHERE user_id = usuario.id) THEN
            INSERT INTO auth.identities (
                id,
                user_id,
                identity_data,
                provider,
                provider_id,
                last_sign_in_at,
                created_at,
                updated_at
            ) VALUES (
                usuario.id,
                usuario.id,
                json_build_object('sub', usuario.id::text, 'email', usuario.email)::jsonb,
                'email',
                usuario.email,
                NOW(), NOW(), NOW()
            );
        END IF;

    END LOOP;
END $$;

-- 2. Limpiar y refrescar la caché del sistema de autenticación
NOTIFY pgrst, 'reload schema';

```

---

### ¿Qué hace exactamente este script por ti?

1. **Corrección de contraseñas masiva:** Escanea toda la tabla y, si encuentra un hash que empiece por `$2y$`, lo convierte automáticamente en `$2a$` sin alterar los caracteres de la contraseña.
2. **Extermina los `NULL` inválidos:** Busca campos como `is_super_admin` o `confirmation_token` que estuvieran en nulo por la importación y los reemplaza por `false` o `''` (texto vacío).
3. **Crea identidades faltantes:** Si algún usuario se importó a `auth.users` pero tu script original olvidó insertarlo en `auth.identities`, este script le genera su identidad de inmediato para que pueda loguearse.
4. **Reinicia la API:** Al final ejecuta el `NOTIFY` para levantar el bloqueo de la aplicación en Vue.

Corre este script y a partir de este momento, tanto Blanca, Melissa como cualquier otro usuario que estuviera en esa tanda de importación podrán iniciar sesión directamente desde tu frontend.




---

### 🛠️ Cómo crear el Bucket en Supabase

1. Entra a tu **Dashboard de Supabase**.
2. En la barra lateral izquierda, haz clic en el icono de **Storage** (el que tiene forma de cubo o caja 📦).
3. Haz clic en el botón **New Bucket** (Nuevo contenedor).
4. Configúralo exactamente así:
* **Bucket Name:** `payments-evidence` (escribe el nombre todo en minúsculas y sin espacios, tal cual está en tu código).
* **Public Bucket:** **¡ACTÍVALO!** (Déjalo en posición *ON*). Esto es vital para que la API te devuelva la URL pública de la imagen sin dar errores de acceso.


5. Haz clic en **Save** (Guardar).

---

### ⚠️ Una última verificación en tu código

Si ya habías creado el bucket pero te sigue dando el error, revisa minuciosamente que las mayúsculas coincidan. Si en Supabase lo creaste como `Payments-Evidence` (con mayúsculas) o `payments_evidence` (con guion bajo), la API fallará. Recomiendo dejarlo todo en minúsculas con guion medio tanto en la web de Supabase como en tu `ticketsService`:

```typescript
// Asegúrate de que se vea exactamente así en tu ticketsService.ts
const { error: uploadError } = await supabase.storage
  .from('payments-evidence') // 👈 Debe coincidir letra por letra con el panel
  .upload(filePath, params.imageFile);

```

Crea el bucket en la plataforma, vuelve a presionar el botón de confirmar recarga en tu formulario de Vue y verás cómo sube la imagen limpiamente a la carpeta `recharges/`.