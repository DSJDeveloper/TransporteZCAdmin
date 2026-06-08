-- =============================================================
-- MIGRACIÓN: Unidades — foto, email y credenciales de conductor
-- Agrega columnas a units, actualiza RPCs, crea auth + perfil
-- para conductores, y modifica get_complete_user_profile
-- =============================================================

BEGIN;

-- =============================================================
-- 1. Agregar columnas a units
-- =============================================================
ALTER TABLE public.units ADD COLUMN IF NOT EXISTS email VARCHAR(255);
ALTER TABLE public.units ADD COLUMN IF NOT EXISTS photo_url VARCHAR(1000);

-- Índice único para búsqueda por email
CREATE UNIQUE INDEX IF NOT EXISTS idx_units_email ON public.units (email) WHERE email IS NOT NULL;

-- =============================================================
-- 2. Recrear manage_unit con p_email, p_password, p_photo_url
-- =============================================================
DO $$
DECLARE
    f text;
BEGIN
    FOR f IN SELECT p.oid::regprocedure::text
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'manage_unit'
    LOOP
        EXECUTE 'DROP FUNCTION ' || f || ' CASCADE';
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.manage_unit(
    p_action    VARCHAR,
    p_unit_id   INTEGER DEFAULT NULL,
    p_name      VARCHAR DEFAULT NULL,
    p_number    VARCHAR DEFAULT NULL,
    p_plate     VARCHAR DEFAULT NULL,
    p_status    INTEGER DEFAULT NULL,
    p_driver    VARCHAR DEFAULT NULL,
    p_idroute   BIGINT DEFAULT NULL,
    p_email     VARCHAR DEFAULT NULL,
    p_password  VARCHAR DEFAULT NULL,
    p_photo_url VARCHAR DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_unit JSON;
    v_auth_id UUID;
    v_old_email VARCHAR;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.units (name, number, plate, status, driver, idroute, email, photo_url)
            VALUES (p_name, p_number, p_plate, COALESCE(p_status, 1), p_driver, p_idroute, p_email, p_photo_url)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_unit FROM inserted;

        -- Si se proporcionó email + password, crear auth user + profile
        IF p_email IS NOT NULL AND p_password IS NOT NULL THEN
            v_auth_id := gen_random_uuid();

            INSERT INTO auth.users (
                id, instance_id, email, encrypted_password,
                email_confirmed_at, raw_user_meta_data,
                created_at, updated_at, confirmation_sent_at,
                aud, role, is_sso_user
            ) VALUES (
                v_auth_id,
                '00000000-0000-0000-0000-000000000000',
                p_email,
                crypt(p_password, gen_salt('bf')),
                NOW(),
                json_build_object('sub', v_auth_id, 'user_name', LOWER(REGEXP_REPLACE(p_name, '[^a-zA-Z0-9]', '', 'g')), 'role', 'driver', 'email', p_email),
                NOW(), NOW(), NOW(),
                'authenticated', 'authenticated', false
            );

            INSERT INTO auth.identities (
                id, user_id, provider, provider_id, identity_data,
                created_at, updated_at, last_sign_in_at
            ) VALUES (
                v_auth_id, v_auth_id, 'email', p_email,
                json_build_object('sub', v_auth_id, 'email', p_email, 'user_name', LOWER(REGEXP_REPLACE(p_name, '[^a-zA-Z0-9]', '', 'g'))),
                NOW(), NOW(), NOW()
            );

            INSERT INTO public.profiles (id, email, role, name, updated_at)
            VALUES (v_auth_id, p_email, 'driver', p_driver, NOW())
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                role = 'driver',
                email = EXCLUDED.email,
                updated_at = NOW();
        END IF;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        -- Obtener email actual antes de actualizar
        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

        WITH updated AS (
            UPDATE public.units SET
                name      = COALESCE(p_name, name),
                number    = COALESCE(p_number, number),
                plate     = COALESCE(p_plate, plate),
                status    = COALESCE(p_status, status),
                driver    = COALESCE(p_driver, driver),
                idroute   = COALESCE(p_idroute, idroute),
                email     = COALESCE(p_email, email),
                photo_url = COALESCE(p_photo_url, photo_url)
            WHERE id = p_unit_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_unit FROM updated;

        -- Si hay email, sincronizar auth + profiles
        IF p_email IS NOT NULL THEN
            -- Buscar si ya existe un auth user con este email (de otro email)
            SELECT id INTO v_auth_id FROM public.profiles WHERE email = v_old_email;

            IF v_auth_id IS NOT NULL THEN
                -- Actualizar auth user existente
                UPDATE auth.users SET
                    email = p_email,
                    raw_user_meta_data = raw_user_meta_data || json_build_object(
                        'email', p_email,
                        'user_name', CASE WHEN p_name IS NOT NULL THEN LOWER(REGEXP_REPLACE(p_name, '[^a-zA-Z0-9]', '', 'g')) ELSE raw_user_meta_data->>'user_name' END,
                        'role', 'driver'
                    )::jsonb
                WHERE id = v_auth_id;

                UPDATE public.profiles SET
                    email = p_email,
                    name = COALESCE(p_driver, name),
                    role = 'driver',
                    updated_at = NOW()
                WHERE id = v_auth_id;
            ELSIF p_password IS NOT NULL THEN
                -- No existe perfil previo, crear uno nuevo
                v_auth_id := gen_random_uuid();

                INSERT INTO auth.users (
                    id, instance_id, email, encrypted_password,
                    email_confirmed_at, raw_user_meta_data,
                    created_at, updated_at, confirmation_sent_at,
                    aud, role, is_sso_user
                ) VALUES (
                    v_auth_id,
                    '00000000-0000-0000-0000-000000000000',
                    p_email,
                    crypt(p_password, gen_salt('bf')),
                    NOW(),
                    json_build_object('sub', v_auth_id, 'user_name', LOWER(REGEXP_REPLACE(COALESCE(p_name, ''), '[^a-zA-Z0-9]', '', 'g')), 'role', 'driver', 'email', p_email),
                    NOW(), NOW(), NOW(),
                    'authenticated', 'authenticated', false
                );

                INSERT INTO auth.identities (
                    id, user_id, provider, provider_id, identity_data,
                    created_at, updated_at, last_sign_in_at
                ) VALUES (
                    v_auth_id, v_auth_id, 'email', p_email,
                    json_build_object('sub', v_auth_id, 'email', p_email, 'user_name', LOWER(REGEXP_REPLACE(COALESCE(p_name, ''), '[^a-zA-Z0-9]', '', 'g'))),
                    NOW(), NOW(), NOW()
                );

                INSERT INTO public.profiles (id, email, role, name, updated_at)
                VALUES (v_auth_id, p_email, 'driver', COALESCE(p_driver, ''), NOW())
                ON CONFLICT (id) DO UPDATE SET
                    name = EXCLUDED.name,
                    role = 'driver',
                    email = EXCLUDED.email,
                    updated_at = NOW();
            END IF;
        END IF;

        -- Si solo se proporcionó password (sin cambio de email), actualizar contraseña
        IF p_password IS NOT NULL AND p_email IS NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE email = v_old_email;
            IF v_auth_id IS NOT NULL THEN
                UPDATE auth.users SET
                    encrypted_password = crypt(p_password, gen_salt('bf'))
                WHERE id = v_auth_id;
            END IF;
        END IF;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        -- Obtener email antes de eliminar para limpiar auth user
        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

        DELETE FROM public.units WHERE id = p_unit_id;

        -- Limpiar auth relacionado
        IF v_old_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE email = v_old_email AND role = 'driver';
            IF v_auth_id IS NOT NULL THEN
                DELETE FROM auth.users WHERE id = v_auth_id;
            END IF;
        END IF;

        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$;

-- =============================================================
-- 3. Recrear get_units con email, photo_url
-- =============================================================
DO $$
DECLARE
    f text;
BEGIN
    FOR f IN SELECT p.oid::regprocedure::text
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'get_units'
    LOOP
        EXECUTE 'DROP FUNCTION ' || f || ' CASCADE';
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.get_units()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden listar unidades.');
    END IF;

    SELECT json_agg(row_to_json(u.*)) INTO v_data FROM (
        SELECT
            u.id,
            u.name,
            u.number,
            u.plate,
            u.status,
            u.driver,
            u.idroute,
            u.email,
            u.photo_url,
            COALESCE(r.code || ' - ' || r.description, 'Sin ruta') AS route_name
        FROM public.units u
        LEFT JOIN public.routes r ON r.id = u.idroute
        ORDER BY u.id
    ) u;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$;

-- =============================================================
-- 4. Recrear get_complete_user_profile con soporte para drivers
-- =============================================================
DO $$
DECLARE
    f text;
BEGIN
    FOR f IN SELECT p.oid::regprocedure::text
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'get_complete_user_profile'
    LOOP
        EXECUTE 'DROP FUNCTION ' || f || ' CASCADE';
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.get_complete_user_profile(
    p_uuid TEXT,
    p_email TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result JSON;
    v_role TEXT;
BEGIN
    -- Primero determinar el rol
    SELECT role::text INTO v_role FROM public.profiles WHERE id = p_uuid::uuid;

    IF v_role = 'driver' THEN
        -- Perfil de conductor: buscar en units
        SELECT row_to_json(driver_row) INTO v_result
        FROM (
            SELECT
                u.id AS unit_id,
                p.id AS uuid,
                u.driver AS name,
                u.email,
                u.photo_url,
                u.name AS unit_name,
                u.number AS unit_number,
                u.plate AS unit_plate,
                u.status AS unit_status,
                p.role
            FROM public.units u
            INNER JOIN public.profiles p ON LOWER(p.email) = LOWER(u.email)
            WHERE p.id = p_uuid::uuid AND LOWER(u.email) = LOWER(p_email)
            LIMIT 1
        ) driver_row;
    ELSE
        -- Perfil normal (admin/student): buscar en clients
        SELECT row_to_json(profile_row) INTO v_result
        FROM (
            SELECT
                c.id AS idclient,
                p.id AS uuid,
                c.name,
                c.email,
                c.phone,
                c."documentID",
                c."creditLimit",
                c.status,
                c.carrer,
                c.balance AS saldo,
                c."createAt" AS created_at,
                p.role
            FROM public.clients c
            INNER JOIN public.profiles p ON p.id = c.uid::uuid
            WHERE p.id = p_uuid::uuid AND c.email = p_email
            LIMIT 1
        ) profile_row;
    END IF;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;

-- =============================================================
-- 5. Política de almacenamiento para fotos de unidades
-- =============================================================
-- Permitir a usuarios autenticados subir fotos de unidades
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'objects'
        AND policyname = 'Give authenticated users access to folder units_1'
    ) THEN
        CREATE POLICY "Give authenticated users access to folder units_1"
        ON storage.objects
        FOR INSERT
        TO authenticated
        WITH CHECK (
            bucket_id = 'payments-evidence'
            AND (storage.foldername(name))[1] = 'units'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'objects'
        AND policyname = 'Give authenticated users UPDATE access to folder units_2'
    ) THEN
        CREATE POLICY "Give authenticated users UPDATE access to folder units_2"
        ON storage.objects
        FOR UPDATE
        TO authenticated
        USING (
            bucket_id = 'payments-evidence'
            AND (storage.foldername(name))[1] = 'units'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'objects'
        AND policyname = 'Give authenticated users DELETE access to folder units_3'
    ) THEN
        CREATE POLICY "Give authenticated users DELETE access to folder units_3"
        ON storage.objects
        FOR DELETE
        TO authenticated
        USING (
            bucket_id = 'payments-evidence'
            AND (storage.foldername(name))[1] = 'units'
        );
    END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
