-- Función que copia el nuevo usuario a la tabla pública
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, role)
  VALUES (
    NEW.id, 
    NEW.email, 
    -- Por defecto será 'student', a menos que en los metadatos indiques otra cosa al registrarlo
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'student')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger que se ejecuta inmediatamente después de un INSERT en auth.users
CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

  -- =========================================================================
-- 2. MIGRACIÓN INICIAL: PASAR USUARIOS EXISTENTES A 'student'
-- =========================================================================

-- Insertamos todos los usuarios que están en auth.users hacia public.profiles.
-- Si el perfil ya existe, lo ignora (ON CONFLICT DO NOTHING) para no sobreescribir.
INSERT INTO public.profiles (id, email, role)
SELECT id, email, 'student'::user_role
FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- =========================================================================
-- 3. ASIGNACIÓN DE ROLES ESPECÍFICOS POR EMAIL
-- =========================================================================

-- 🛠️ ASIGNAR ADMINISTRADORES:
-- Cambia los correos de ejemplo por los correos reales de tus administradores
UPDATE public.profiles
SET role = 'admin'::user_role
WHERE email IN (
    'tu_correo_admin@dominio.com',
    'otro_admin@dominio.com'
);

-- 🛠️ ASIGNAR CHOFERES (DRIVERS):
-- Cambia los correos de ejemplo por los correos reales de tus choferes
UPDATE public.profiles
SET role = 'driver'::user_role
WHERE email IN (
    'chofer1@dominio.com',
    'chofer2@dominio.com',
    'carlos.driver@dominio.com'
);


-- =========================================================================
-- 4. POLÍTICA RLS PARA LA NUEVA TABLA PROFILES
-- =========================================================================
DROP POLICY IF EXISTS "Usuarios leen su propio perfil" ON public.profiles;

CREATE POLICY "Usuarios leen su propio perfil"
ON public.profiles
FOR SELECT
TO authenticated
USING (id = auth.uid());


-- =========================================================================
-- 5. REFRESCAR ESQUEMA DE LA API
-- =========================================================================
NOTIFY pgrst, 'reload schema';