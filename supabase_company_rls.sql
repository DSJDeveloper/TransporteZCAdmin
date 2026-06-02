-- ============================================================
-- POLÍTICAS RLS PARA LA TABLA `company`
-- Solo admins pueden INSERT / UPDATE / DELETE
-- Todos los autenticados pueden SELECT (lectura)
-- ============================================================

-- 1. Asegurar RLS activo
ALTER TABLE public.company ENABLE ROW LEVEL SECURITY;

-- 2. Política SELECT: todos los autenticados pueden leer
DROP POLICY IF EXISTS "company_select_all" ON public.company;
CREATE POLICY "company_select_all" ON public.company
  FOR SELECT
  TO authenticated
  USING (true);

-- 3. Política INSERT: solo admins
DROP POLICY IF EXISTS "company_insert_admin" ON public.company;
CREATE POLICY "company_insert_admin" ON public.company
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

-- 4. Política UPDATE: solo admins
DROP POLICY IF EXISTS "company_update_admin" ON public.company;
CREATE POLICY "company_update_admin" ON public.company
  FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5. Política DELETE: solo admins
DROP POLICY IF EXISTS "company_delete_admin" ON public.company;
CREATE POLICY "company_delete_admin" ON public.company
  FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- Limpiar políticas viejas que eran inseguras
DROP POLICY IF EXISTS "Permitir actualización de company" ON public.company;
DROP POLICY IF EXISTS "Permitir lectura de company" ON public.company;

NOTIFY pgrst, 'reload schema';
