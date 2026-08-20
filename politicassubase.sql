-- =========================================================================
-- 1. CONFIGURACIÓN DE SEGURIDAD PARA LA TABLA: clients
-- =========================================================================

-- Aseguramos que el RLS esté activo en la tabla de clientes
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;

-- Borramos la política por si ya existía para evitar errores de duplicado
DROP POLICY IF EXISTS "Permitir lectura por email" ON public.clients;

-- Creamos la política para que cada usuario autenticado pueda leer su propio perfil
CREATE POLICY "Permitir lectura por email" 
ON public.clients 
FOR SELECT 
TO authenticated 
USING (email = auth.jwt()->>'email');


-- =========================================================================
-- 2. CONFIGURACIÓN DE SEGURIDAD PARA LA TABLA: transactions
-- =========================================================================

-- Aseguramos que el RLS esté activo en la tabla de transacciones
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

-- Borramos políticas anteriores (tanto la restrictiva vieja como la nueva por si acaso)
DROP POLICY IF EXISTS "Usuarios pueden ver sus propias transacciones" ON public.transactions;
DROP POLICY IF EXISTS "Usuarios ven lo suyo o Admins ven todo" ON public.transactions;

-- 3. Creamos la política corregida usando un puente hacia public.clients
CREATE POLICY "Usuarios ven lo suyo o Admins ven todo" 
ON public.transactions 
FOR SELECT 
TO authenticated 
USING (
    -- CONDICIÓN 1: El usuario logueado es el dueño de este idclient
    EXISTS (
        SELECT 1 FROM public.clients 
        WHERE public.clients.id = public.transactions.idclient 
          
    )
    OR 
    -- CONDICIÓN 2: El usuario es Súper Administrador
    COALESCE((auth.jwt()->>'is_super_admin')::boolean, false) = true
);




-- 1. Creamos un tipo de dato ENUM con los 3 roles en inglés
CREATE TYPE user_role AS ENUM ('admin', 'student', 'driver');

-- 2. Creamos la tabla pública de perfiles vinculada a auth.users
CREATE TABLE public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    email TEXT NOT NULL,
    role user_role NOT NULL DEFAULT 'student', -- 'student' como rol por defecto
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Habilitamos RLS para proteger la tabla
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
-- =========================================================================
-- 3. REFRESCAR EL ESQUEMA DE LA API
-- =========================================================================
NOTIFY pgrst, 'reload schema';



-- 1. LIMPIEZA PREVENTIVA
DROP POLICY IF EXISTS "Permitir lectura de company" ON public.company;
DROP POLICY IF EXISTS "Permitir actualización de company" ON public.company;

-- 2. POLÍTICA PARA SELECT (Lectura)
-- Todos los usuarios autenticados pueden ver la tasa y configuración de la empresa
CREATE POLICY "Permitir lectura de company" 
ON public.company
FOR SELECT 
TO authenticated 
USING (true);

-- 3. POLÍTICA PARA UPDATE (Actualización por ID)
-- Solo el usuario cuyo UUID coincida con el dueño del registro puede modificar los datos
CREATE POLICY "Permitir actualización de company" 
ON public.company
FOR UPDATE 
TO authenticated 
USING (true);
