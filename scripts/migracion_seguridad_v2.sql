-- =============================================================
-- MIGRACIÓN SEGURIDAD V2
-- 1. Limpieza de RPCs duplicados
-- 2. Agregar is_admin() a manage_unit, manage_client, update_user_role
-- 3. Nuevos RPCs de solo lectura para eliminar accesos directos a tablas
-- =============================================================

BEGIN;

-- =============================================================
-- PARTE 1: LIMPIEZA DE DUPLICADOS
-- =============================================================

-- manage_unit: dropear TODAS las sobrecargas y recrear la versión completa
DROP FUNCTION IF EXISTS public.manage_unit(VARCHAR, INTEGER, VARCHAR);
DROP FUNCTION IF EXISTS public.manage_unit(VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR);

CREATE OR REPLACE FUNCTION public.manage_unit(
    p_action VARCHAR,
    p_unit_id INTEGER DEFAULT NULL,
    p_name VARCHAR DEFAULT NULL,
    p_number VARCHAR DEFAULT NULL,
    p_plate VARCHAR DEFAULT NULL,
    p_status INTEGER DEFAULT NULL,
    p_driver VARCHAR DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_unit JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.units (name, number, plate, status, driver)
            VALUES (p_name, p_number, p_plate, COALESCE(p_status, 1), p_driver)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_unit FROM inserted;
        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.units SET
                name   = COALESCE(p_name, name),
                number = COALESCE(p_number, number),
                plate  = COALESCE(p_plate, plate),
                status = COALESCE(p_status, status),
                driver = COALESCE(p_driver, driver)
            WHERE id = p_unit_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_unit FROM updated;
        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.units WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$;

-- manage_client: recrear con guardia is_admin()
DROP FUNCTION IF EXISTS public.manage_client(VARCHAR, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);

CREATE OR REPLACE FUNCTION public.manage_client(
    p_action VARCHAR,
    p_id BIGINT DEFAULT NULL,
    p_name VARCHAR DEFAULT NULL,
    p_document_id VARCHAR DEFAULT NULL,
    p_email VARCHAR DEFAULT NULL,
    p_phone VARCHAR DEFAULT NULL,
    p_carrer VARCHAR DEFAULT NULL,
    p_credit_limit VARCHAR DEFAULT NULL,
    p_status VARCHAR DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_client JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.clients (name, "documentID", email, phone, carrer, "creditLimit", status, uid)
            VALUES (p_name, p_document_id, p_email, p_phone, p_carrer, p_credit_limit, COALESCE(p_status, 'Activo'), gen_random_uuid()::text)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_client FROM inserted;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.clients SET
                name         = COALESCE(p_name, name),
                "documentID" = COALESCE(p_document_id, "documentID"),
                email        = COALESCE(p_email, email),
                phone        = COALESCE(p_phone, phone),
                carrer       = COALESCE(p_carrer, carrer),
                "creditLimit" = COALESCE(p_credit_limit, "creditLimit"),
                status       = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_client FROM updated;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.clients WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Cliente eliminado del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$;

-- update_user_role: agregar guardia is_admin()
DROP FUNCTION IF EXISTS public.update_user_role(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.update_user_role(user_email TEXT, new_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Solo administradores pueden cambiar roles.';
    END IF;

    IF LOWER(new_role) NOT IN ('student', 'driver', 'admin') THEN
        RAISE EXCEPTION 'Rol no permitido. Los roles validos son: student, driver, admin.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE email = user_email) THEN
        RETURN 'ERROR: No se encontro ningun perfil asociado a ese correo electronico.';
    END IF;

    UPDATE public.profiles
    SET role = LOWER(new_role)::user_role
    WHERE email = user_email;

    UPDATE auth.users
    SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('role', LOWER(new_role))
    WHERE email = user_email;

    RETURN 'SUCCESS: El rol del usuario ha sido actualizado a ' || LOWER(new_role);
END;
$function$;

-- manage_profile: dropear sobrecargas y mantener solo la version completa con name
DROP FUNCTION IF EXISTS public.manage_profile(VARCHAR, UUID, VARCHAR, VARCHAR, user_role);
DROP FUNCTION IF EXISTS public.manage_profile(VARCHAR, UUID, VARCHAR, VARCHAR, user_role, VARCHAR);

-- =============================================================
-- PARTE 2: NUEVOS RPCs DE SOLO LECTURA
-- =============================================================

-- get_clients: listar todos los clientes (solo admin)
CREATE OR REPLACE FUNCTION public.get_clients()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden listar clientes.');
    END IF;

    SELECT json_agg(row_to_json(c.*)) INTO v_data FROM (
        SELECT * FROM public.clients ORDER BY id
    ) c;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$;

-- get_units: listar todas las unidades (solo admin)
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
        SELECT * FROM public.units ORDER BY id
    ) u;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$;

-- get_client_names: pares {id, name} para cache del frontend (sin guardia, solo nombres)
CREATE OR REPLACE FUNCTION public.get_client_names()
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
    FROM public.clients;
$function$;

-- get_unit_names: pares {id, name} para cache del frontend (sin guardia, solo nombres)
CREATE OR REPLACE FUNCTION public.get_unit_names()
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
    FROM public.units;
$function$;

-- get_client_balance: obtener saldo de un cliente
CREATE OR REPLACE FUNCTION public.get_client_balance(p_client_id INTEGER)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_balance NUMERIC;
BEGIN
    SELECT balance INTO v_balance FROM public.clients WHERE id = p_client_id;

    IF v_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado.');
    END IF;

    RETURN json_build_object('success', true, 'balance', v_balance);
END;
$function$;

-- get_transactions_paginated: listado paginado de transacciones con filtros
CREATE OR REPLACE FUNCTION public.get_transactions_paginated(
    p_page INTEGER DEFAULT 1,
    p_per_page INTEGER DEFAULT 10,
    p_date_from DATE DEFAULT NULL,
    p_date_to DATE DEFAULT NULL,
    p_idunit INTEGER DEFAULT NULL,
    p_status INTEGER DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'created_at',
    p_sort_order TEXT DEFAULT 'DESC'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.transactions t
    WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
      AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
      AND (p_idunit IS NULL OR t.idunit = p_idunit)
      AND (p_status IS NULL OR t.status = p_status);

    SELECT json_agg(sub) INTO v_data FROM (
        SELECT
            t.id, t.uid, t.idclient, t."createBy", t.amount,
            t.status, t.created_at, t.idunit, t.shedule, t."newBalanceClient",
            json_build_object('name', c.name) AS clients,
            json_build_object('name', u.name) AS units
        FROM public.transactions t
        LEFT JOIN public.clients c ON c.id = t.idclient
        LEFT JOIN public.units u ON u.id = t.idunit
        WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
          AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
          AND (p_idunit IS NULL OR t.idunit = p_idunit)
          AND (p_status IS NULL OR t.status = p_status)
        ORDER BY
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'ASC'  THEN t.created_at END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'DESC' THEN t.created_at END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'ASC'  THEN t.amount     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'DESC' THEN t.amount     END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status'     AND p_sort_order = 'ASC'  THEN t.status     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'status'     AND p_sort_order = 'DESC' THEN t.status     END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'ASC'  THEN t.id         END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'DESC' THEN t.id         END DESC NULLS LAST,
            t.id DESC
        LIMIT p_per_page
        OFFSET v_offset
    ) sub;

    RETURN json_build_object('data', COALESCE(v_data, '[]'::json), 'total', v_total);
END;
$function$;

-- get_transactions_export: exportar transacciones sin paginacion (mismos filtros)
CREATE OR REPLACE FUNCTION public.get_transactions_export(
    p_date_from DATE DEFAULT NULL,
    p_date_to DATE DEFAULT NULL,
    p_idunit INTEGER DEFAULT NULL,
    p_status INTEGER DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'created_at',
    p_sort_order TEXT DEFAULT 'DESC'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    SELECT json_agg(sub) INTO v_data FROM (
        SELECT
            t.id, t.uid, t.idclient, t."createBy", t.amount,
            t.status, t.created_at, t.idunit, t.shedule, t."newBalanceClient",
            c.name AS client_name,
            u.name AS unit_name
        FROM public.transactions t
        LEFT JOIN public.clients c ON c.id = t.idclient
        LEFT JOIN public.units u ON u.id = t.idunit
        WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
          AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
          AND (p_idunit IS NULL OR t.idunit = p_idunit)
          AND (p_status IS NULL OR t.status = p_status)
        ORDER BY
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'ASC'  THEN t.created_at END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'DESC' THEN t.created_at END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'ASC'  THEN t.amount     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'DESC' THEN t.amount     END DESC NULLS LAST,
            t.id DESC
    ) sub;

    RETURN json_build_object('data', COALESCE(v_data, '[]'::json));
END;
$function$;

-- manage_solicitude: CRUD completo via RPC
CREATE OR REPLACE FUNCTION public.manage_solicitude(
    p_action VARCHAR,
    p_id INTEGER DEFAULT NULL,
    p_date VARCHAR DEFAULT NULL,
    p_idclient INTEGER DEFAULT NULL,
    p_shedule VARCHAR DEFAULT NULL,
    p_route VARCHAR DEFAULT NULL,
    p_status INTEGER DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_solicitude JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'list_by_client' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude WHERE idclient = p_idclient ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'get_by_id' THEN
        SELECT row_to_json(s.*) INTO v_solicitude FROM public.solicitude s WHERE id = p_id;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude);

    ELSIF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.solicitude (date, idclient, shedule, route, status)
            VALUES (p_date, p_idclient, p_shedule, p_route, COALESCE(p_status, 0))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_solicitude FROM inserted;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.solicitude SET
                date     = COALESCE(p_date, date),
                idclient = COALESCE(p_idclient, idclient),
                shedule  = COALESCE(p_shedule, shedule),
                route    = COALESCE(p_route, route),
                status   = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_solicitude FROM updated;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.solicitude WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Solicitud eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$;

-- Agregar action 'list' a manage_horario
DROP FUNCTION IF EXISTS public.manage_horario(VARCHAR, BIGINT, VARCHAR, VARCHAR, INTEGER);

CREATE OR REPLACE FUNCTION public.manage_horario(
    p_action VARCHAR,
    p_id BIGINT DEFAULT NULL,
    p_code VARCHAR DEFAULT NULL,
    p_shudle VARCHAR DEFAULT NULL,
    p_status INTEGER DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_horario JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(h.*)) INTO v_horario FROM (
            SELECT * FROM public.horario ORDER BY id
        ) h;
        RETURN json_build_object('success', true, 'data', COALESCE(v_horario, '[]'::json));
    END IF;

    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.horario (code, shudle, status)
            VALUES (p_code, p_shudle, COALESCE(p_status, 0))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_horario FROM inserted;
        RETURN json_build_object('success', true, 'data', v_horario, 'message', 'Horario creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.horario SET
                code   = COALESCE(p_code, code),
                shudle = COALESCE(p_shudle, shudle),
                status = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_horario FROM updated;
        RETURN json_build_object('success', true, 'data', v_horario, 'message', 'Horario actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.horario WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Horario eliminado del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$;

-- manage_profile: version completa con name, SIN duplicados
DROP FUNCTION IF EXISTS public.manage_profile(VARCHAR, UUID, VARCHAR, VARCHAR, user_role);
DROP FUNCTION IF EXISTS public.manage_profile(VARCHAR, UUID, VARCHAR, VARCHAR, user_role, VARCHAR);

CREATE OR REPLACE FUNCTION public.manage_profile(
    p_action VARCHAR,
    p_user_id UUID DEFAULT NULL,
    p_email VARCHAR DEFAULT NULL,
    p_password VARCHAR DEFAULT NULL,
    p_role user_role DEFAULT NULL,
    p_name VARCHAR DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_profile JSON;
    v_auth_id UUID;
    v_old_email VARCHAR;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(json_build_object(
            'id', p.id,
            'email', p.email,
            'role', p.role,
            'updated_at', p.updated_at,
            'name', p.name
        ) ORDER BY p.email) INTO v_profile
        FROM public.profiles p;
        RETURN json_build_object('success', true, 'data', COALESCE(v_profile, '[]'::json));

    ELSIF LOWER(p_action) = 'create' THEN
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
            json_build_object('sub', v_auth_id, 'user_name', p_name, 'role', p_role, 'email', p_email),
            NOW(), NOW(), NOW(),
            'authenticated', 'authenticated', false
        );

        INSERT INTO auth.identities (
            id, user_id, provider, provider_id, identity_data,
            created_at, updated_at, last_sign_in_at
        ) VALUES (
            v_auth_id, v_auth_id, 'email', p_email,
            json_build_object('sub', v_auth_id, 'email', p_email, 'user_name', p_name),
            NOW(), NOW(), NOW()
        );

        UPDATE public.profiles SET name = p_name WHERE id = v_auth_id;

        SELECT row_to_json(pp.*) INTO v_profile
        FROM public.profiles pp WHERE pp.id = v_auth_id;

        RETURN json_build_object('success', true, 'data', v_profile, 'message', 'Usuario creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        SELECT email INTO v_old_email FROM public.profiles WHERE id = p_user_id;

        UPDATE public.profiles
        SET
            name = COALESCE(p_name, name),
            email = COALESCE(p_email, email),
            role = COALESCE(p_role, role),
            updated_at = NOW()
        WHERE id = p_user_id
        RETURNING row_to_json(profiles.*) INTO v_profile;

        IF v_profile IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Usuario no encontrado.');
        END IF;

        UPDATE auth.users
        SET
            raw_user_meta_data = raw_user_meta_data || json_build_object(
                'user_name', COALESCE(p_name, raw_user_meta_data->>'user_name'),
                'role', COALESCE(p_role::text, raw_user_meta_data->>'role'),
                'email', COALESCE(p_email, raw_user_meta_data->>'email')
            )::jsonb,
            email = COALESCE(p_email, email)
        WHERE id = p_user_id;

        IF p_email IS NOT NULL AND p_email != v_old_email THEN
            UPDATE public.clients SET email = p_email WHERE email = v_old_email;
        END IF;

        RETURN json_build_object('success', true, 'data', v_profile, 'message', 'Perfil actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM auth.users WHERE id = p_user_id;
        RETURN json_build_object('success', true, 'message', 'Usuario eliminado con exito.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$;

-- Refrescar schema de PostgREST
NOTIFY pgrst, 'reload schema';

COMMIT;
