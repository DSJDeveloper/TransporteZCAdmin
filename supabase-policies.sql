-- ============================================================
-- POLÍTICAS RLS PARA LA TABLA `solicitude`
-- ============================================================
-- La tabla `clients` tiene:
--   id  (BIGINT PK) → FK desde solicitude.idclient
--   uid (VARCHAR)   → auth.uid() guardado como string
-- La tabla `profiles` tiene:
--   id   (UUID PK, REFERENCES auth.users)
--   role (ENUM: 'admin' | 'student' | 'driver')
-- ============================================================

-- 1. Función auxiliar: obtiene el clients.id del usuario logueado
CREATE OR REPLACE FUNCTION public.get_my_client_id()
RETURNS INTEGER
LANGUAGE SQL STABLE
AS $$
  SELECT id FROM clients WHERE uid = auth.uid()::text LIMIT 1;
$$;

-- 2. Función auxiliar: verifica si el usuario logueado es admin
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE SQL STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- ============================================================
-- POLÍTICAS: usuarios regulares (student / driver)
-- Solo sobre sus propios registros
-- ============================================================

DROP POLICY IF EXISTS "users_select_own" ON solicitude;
CREATE POLICY "users_select_own" ON solicitude
  FOR SELECT
  USING (idclient = public.get_my_client_id());

DROP POLICY IF EXISTS "users_insert_own" ON solicitude;
CREATE POLICY "users_insert_own" ON solicitude
  FOR INSERT
  WITH CHECK (idclient = public.get_my_client_id());

DROP POLICY IF EXISTS "users_update_own" ON solicitude;
CREATE POLICY "users_update_own" ON solicitude
  FOR UPDATE
  USING (idclient = public.get_my_client_id())
  WITH CHECK (idclient = public.get_my_client_id());

-- DELETE no se permite para usuarios regulares (solo admin)

-- ============================================================
-- POLÍTICAS: admin → CRUD completo sobre todos los registros
-- ============================================================

DROP POLICY IF EXISTS "admin_select_all" ON solicitude;
CREATE POLICY "admin_select_all" ON solicitude
  FOR SELECT
  USING (public.is_admin());

DROP POLICY IF EXISTS "admin_insert_all" ON solicitude;
CREATE POLICY "admin_insert_all" ON solicitude
  FOR INSERT
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "admin_update_all" ON solicitude;
CREATE POLICY "admin_update_all" ON solicitude
  FOR UPDATE
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "admin_delete_all" ON solicitude;
CREATE POLICY "admin_delete_all" ON solicitude
  FOR DELETE
  USING (public.is_admin());
