-- =====================================================================
-- MIGRACION: Visibilidad y CRUD de Unidades para rol Supervisor
-- Fecha: 2026-08-28
-- Proposito:
--   1. get_units()          -> permite a supervisores listar SOLO unidades de sus rutas asignadas.
--   2. manage_unit()        -> permite a supervisores CRUD restringido a sus rutas asignadas.
--   3. get_unit_names()     -> filtra por ruta asignada para supervisores.
--   4. get_routes()         -> filtra por ruta asignada para supervisores.
--   5. get_route_names()    -> filtra por ruta asignada para supervisores.
--
-- Patron de visibilidad: admin ve todo (is_admin() primero); el supervisor
-- ve lo que devuelva get_current_user_route_ids() (bigint[]).
-- =====================================================================

BEGIN;

-- =====================================================================
-- 1. get_units() — listado de unidades con visibilidad por rol
-- =====================================================================
DROP FUNCTION IF EXISTS public.get_units();

CREATE OR REPLACE FUNCTION public.get_units()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF NOT public.is_admin_or_supervisor() THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
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
        WHERE public.is_admin() OR u.idroute = ANY(public.get_current_user_route_ids())
        ORDER BY u.id
    ) u;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$;

-- =====================================================================
-- 2. manage_unit() — CRUD restringido por ruta para supervisores
-- =====================================================================
DROP FUNCTION IF EXISTS public.manage_unit(character varying, integer, character varying, character varying, character varying, integer, character varying, bigint, character varying, character varying, character varying);

CREATE OR REPLACE FUNCTION public.manage_unit(p_action character varying, p_unit_id integer DEFAULT NULL::integer, p_name character varying DEFAULT NULL::character varying, p_number character varying DEFAULT NULL::character varying, p_plate character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_driver character varying DEFAULT NULL::character varying, p_idroute bigint DEFAULT NULL::bigint, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_photo_url character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_unit JSON;
    v_old_email VARCHAR;
    v_profile_res JSON;
    v_auth_id UUID;
    v_clean_username VARCHAR;
BEGIN
    -- 1. Control de acceso (admin o supervisor)
    IF NOT public.is_admin_or_supervisor() THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;

    -- Preparamos el nombre de usuario limpio: todo a minúsculas, quitando espacios y caracteres especiales
    v_clean_username := LOWER(REGEXP_REPLACE(COALESCE(p_driver, p_name, ''), '[^a-zA-Z0-9]', '', 'g'));

    -- ==========================================
    -- ACCION: CREATE
    -- ==========================================
    IF LOWER(p_action) = 'create' THEN
        -- Supervisor: debe elegir una ruta asignada
        IF NOT public.is_admin() THEN
            IF p_idroute IS NULL OR NOT (p_idroute = ANY(public.get_current_user_route_ids())) THEN
                RETURN json_build_object('success', false, 'message', 'Debe seleccionar una ruta asignada a su perfil.');
            END IF;
        END IF;

        IF p_email IS NOT NULL AND p_password IS NOT NULL THEN
            SELECT public.manage_profile(
                'create'::character varying,
                NULL::uuid,
                p_email,
                p_password,
                'driver'::public.user_role,
                v_clean_username
            ) INTO v_profile_res;

            IF NOT (v_profile_res->>'success')::BOOLEAN THEN
                RETURN json_build_object('success', false, 'message', 'Error al crear credenciales del chofer: ' || (v_profile_res->>'message'));
            END IF;
        END IF;

        WITH inserted AS (
            INSERT INTO public.units (name, number, plate, status, driver, idroute, email, photo_url)
            VALUES (p_name, p_number, p_plate, COALESCE(p_status, 1), p_driver, p_idroute, p_email, p_photo_url)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_unit FROM inserted;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad creada con exito.');

    -- ==========================================
    -- ACCION: UPDATE
    -- ==========================================
    ELSIF LOWER(p_action) = 'update' THEN
        -- Supervisor: solo unidades de sus rutas, y nueva ruta asignada
        IF NOT public.is_admin() THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.units
                WHERE id = p_unit_id AND idroute = ANY(public.get_current_user_route_ids())
            ) THEN
                RETURN json_build_object('success', false, 'message', 'No tiene permisos sobre esta unidad.');
            END IF;
            IF p_idroute IS NOT NULL AND NOT (p_idroute = ANY(public.get_current_user_route_ids())) THEN
                RETURN json_build_object('success', false, 'message', 'La ruta seleccionada no está asignada a su perfil.');
            END IF;
        END IF;

        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

        -- Buscar si el email viejo ya cuenta con un perfil de autenticación ANTES de cambiarlo en public.units
        v_auth_id := NULL;
        IF v_old_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(v_old_email);
        END IF;

        -- Validar unicidad del email si cambió
        IF p_email IS NOT NULL AND LOWER(p_email) != LOWER(COALESCE(v_old_email, '')) THEN
            IF EXISTS (SELECT 1 FROM public.units WHERE LOWER(email) = LOWER(p_email) AND id != p_unit_id) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en otra unidad.');
            END IF;
            IF EXISTS (SELECT 1 FROM auth.users WHERE LOWER(email) = LOWER(p_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
            IF EXISTS (SELECT 1 FROM public.profiles WHERE LOWER(email) = LOWER(p_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
        END IF;

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

        -- Si no se encontró por email viejo y pasaron un email nuevo, intentamos buscar por el nuevo por si acaso
        IF v_auth_id IS NULL AND p_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(p_email);
        END IF;

        v_clean_username := LOWER(REGEXP_REPLACE(COALESCE(p_driver, p_name, (v_unit->>'driver'), ''), '[^a-zA-Z0-9]', '', 'g'));

        IF v_auth_id IS NOT NULL THEN
            SELECT public.manage_profile(
                'update'::character varying,
                v_auth_id,
                COALESCE(p_email, v_old_email),
                p_password,
                'driver'::public.user_role,
                v_clean_username
            ) INTO v_profile_res;

            -- Actualizar raw_user_meta_data con el nuevo email
            IF p_email IS NOT NULL AND LOWER(p_email) != LOWER(COALESCE(v_old_email, '')) THEN
                UPDATE public.profiles SET email = p_email WHERE id = v_auth_id::uuid;
                UPDATE auth.users SET
                    email = p_email,
                    raw_user_meta_data = raw_user_meta_data || jsonb_build_object('email', p_email)
                WHERE id = v_auth_id::uuid;
            END IF;

        ELSIF v_auth_id IS NULL AND p_password IS NOT NULL AND COALESCE(p_email, v_old_email) IS NOT NULL THEN
            SELECT public.manage_profile(
                'create'::character varying,
                NULL::uuid,
                COALESCE(p_email, v_old_email),
                p_password,
                'driver'::public.user_role,
                v_clean_username
            ) INTO v_profile_res;

            IF NOT (v_profile_res->>'success')::BOOLEAN THEN
                RETURN json_build_object('success', false, 'message', 'Error al registrar credenciales nuevas al chofer: ' || (v_profile_res->>'message'));
            END IF;
        END IF;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad actualizada y credenciales sincronizadas.');

    -- ==========================================
    -- ACCION: DELETE
    -- ==========================================
    ELSIF LOWER(p_action) = 'delete' THEN
        -- Supervisor: solo unidades de sus rutas
        IF NOT public.is_admin() THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.units
                WHERE id = p_unit_id AND idroute = ANY(public.get_current_user_route_ids())
            ) THEN
                RETURN json_build_object('success', false, 'message', 'No tiene permisos sobre esta unidad.');
            END IF;
        END IF;

        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

        DELETE FROM public.units WHERE id = p_unit_id;

        IF v_old_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(v_old_email);

            IF v_auth_id IS NOT NULL THEN
                PERFORM public.manage_profile(
                    'delete'::character varying,
                    v_auth_id,
                    NULL::character varying,
                    NULL::character varying,
                    'driver'::public.user_role,
                    NULL::character varying
                );
            END IF;
        END IF;

        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en manage_unit: ' || SQLERRM);
END;
$function$;

-- =====================================================================
-- 3. get_unit_names() — nombres de unidades con visibilidad por rol
-- =====================================================================
DROP FUNCTION IF EXISTS public.get_unit_names();

CREATE OR REPLACE FUNCTION public.get_unit_names()
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
    FROM public.units
    WHERE public.is_admin() OR idroute = ANY(public.get_current_user_route_ids());
$function$;

-- =====================================================================
-- 4. get_routes() — rutas con visibilidad por rol
-- =====================================================================
DROP FUNCTION IF EXISTS public.get_routes();

CREATE OR REPLACE FUNCTION public.get_routes()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(r.*)) INTO v_data FROM (
        SELECT
            r.*,
            COALESCE(b.bank_name, 'Sin banco') AS bank_info_name
        FROM public.routes r
        LEFT JOIN public.bank_info b ON b.id = r.idbank_info
        WHERE public.is_admin() OR r.id = ANY(public.get_current_user_route_ids())
        ORDER BY r.id
    ) r;
    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$;

-- =====================================================================
-- 5. get_route_names() — rutas (names) con visibilidad por rol
-- =====================================================================
DROP FUNCTION IF EXISTS public.get_route_names();

CREATE OR REPLACE FUNCTION public.get_route_names()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'data', '[]'::json);
    END IF;
    SELECT COALESCE(json_agg(json_build_object('id', id, 'code', code, 'description', description, 'idbank_info', idbank_info)), '[]'::json)
    INTO v_data
    FROM public.routes
    WHERE status = 0
      AND (public.is_admin() OR id = ANY(public.get_current_user_route_ids()));
    RETURN json_build_object('success', true, 'data', v_data);
END;
$function$;

COMMIT;
