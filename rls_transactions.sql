-- ============================================================================
-- RLS Policies for transactions (read-only admin view)
-- Execute in Supabase SQL Editor.
-- ============================================================================

-- 1. Ensure RLS is enabled (idempotent)
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

-- 2. Drop any existing policy to avoid duplicates
DROP POLICY IF EXISTS "Usuarios ven lo suyo o Admins ven todo" ON public.transactions;
DROP POLICY IF EXISTS "Admin read all transactions" ON public.transactions;

-- 3. Create the SELECT policy for the admin panel
--    Admins (is_super_admin = true in JWT) can read ALL transactions.
--    Regular authenticated users only see transactions whose idclient exists
--    in the clients table.
CREATE POLICY "Admin read all transactions"
ON public.transactions
FOR SELECT
TO authenticated
USING (
  COALESCE((auth.jwt() ->> 'is_super_admin')::boolean, false) = true
  OR
  EXISTS (
    SELECT 1 FROM public.clients
    WHERE clients.id = transactions.idclient
      AND clients.email = auth.jwt() ->> 'email'
  )
);

-- 4. ⚠️ IMPORTANT: The clients table also has RLS
--    The default policy only returns the row where email matches the JWT.
--    For the admin to see client names via JOIN, you need an admin bypass:
DROP POLICY IF EXISTS "Permitir lectura por email" ON public.clients;

CREATE POLICY "Admins leen todos los clientes, usuarios solo el suyo"
ON public.clients
FOR SELECT
TO authenticated
USING (
  COALESCE((auth.jwt() ->> 'is_super_admin')::boolean, false) = true
  OR email = auth.jwt() ->> 'email'
);

-- 5. Units already allow all authenticated reads, no changes needed.
--    Verify with: SELECT * FROM pg_policies WHERE tablename = 'units';

-- 6. Notify Supabase to reload schema
NOTIFY pgrst, 'reload schema';
