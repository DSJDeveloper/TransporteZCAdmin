-- ==============================================================
-- Migración: Validación + Propagación de Email
-- Fecha: 2026-06-22
-- Descripción:
--   manage_client: Al actualizar un cliente:
--     1. Valida que el nuevo email no exista en clients, auth.users
--        ni profiles.
--     2. Si el cliente tiene uid (auth.user asociado), propaga el
--        cambio a profiles, auth.users.email,
--        auth.users.raw_user_meta_data y auth.users.raw_user_meta_data.
--
--   manage_unit  : Al actualizar una unidad:
--     1. Valida que el nuevo email no exista en units, auth.users
--        ni profiles.
--     2. Propaga el cambio a auth.users.raw_user_meta_data con el
--        nuevo email (profiles, auth.users.email y raw_user_meta_data
--        ya se sincronizan vía manage_profile).
-- ==============================================================

CREATE OR REPLACE FUNCTION public.manage_client(
    p_action character varying,
    p_id bigint DEFAULT NULL::bigint,
    p_name character varying DEFAULT NULL::character varying,
    p_document_id character varying DEFAULT NULL::character varying,
    p_email character varying DEFAULT NULL::character varying,
    p_phone character varying DEFAULT NULL::character varying,
    p_carrer character varying DEFAULT NULL::character varying,
    p_credit_limit character varying DEFAULT NULL::character varying,
    p_status character varying DEFAULT NULL::character varying,
    p_idroute bigint DEFAULT NULL::bigint,
    p_photo_url character varying DEFAULT NULL::character varying
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client JSON;
    v_current_email TEXT;
    v_uid TEXT;
    v_new_email TEXT;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.clients (name, "documentID", email, phone, carrer, "creditLimit", status, uid, idroute, photo_url)
            VALUES (p_name, p_document_id, p_email, p_phone, p_carrer, p_credit_limit, COALESCE(p_status, 'Activo'), gen_random_uuid()::text, p_idroute, NULLIF(p_photo_url, ''))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_client FROM inserted;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        SELECT email, uid INTO v_current_email, v_uid FROM public.clients WHERE id = p_id;
        v_new_email := COALESCE(p_email, v_current_email);

        IF v_new_email IS DISTINCT FROM v_current_email THEN
            IF EXISTS (SELECT 1 FROM public.clients WHERE LOWER(email) = LOWER(v_new_email) AND id != p_id) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en otro cliente.');
            END IF;
            IF EXISTS (SELECT 1 FROM auth.users WHERE LOWER(email) = LOWER(v_new_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
            IF EXISTS (SELECT 1 FROM public.profiles WHERE LOWER(email) = LOWER(v_new_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
        END IF;

        WITH updated AS (
            UPDATE public.clients SET
                name         = COALESCE(p_name, name),
                "documentID" = COALESCE(p_document_id, "documentID"),
                email        = v_new_email,
                phone        = COALESCE(p_phone, phone),
                carrer       = COALESCE(p_carrer, carrer),
                "creditLimit" = COALESCE(p_credit_limit, "creditLimit"),
                status       = COALESCE(p_status, status),
                idroute      = COALESCE(p_idroute, idroute),
                photo_url    = COALESCE(NULLIF(p_photo_url, ''), photo_url)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_client FROM updated;

        IF v_uid IS NOT NULL AND v_new_email IS DISTINCT FROM v_current_email THEN
            UPDATE public.profiles SET email = v_new_email WHERE id = v_uid::uuid;
            UPDATE auth.users SET
                email = v_new_email,
                raw_user_meta_data = raw_user_meta_data || jsonb_build_object('email', v_new_email)
            WHERE id = v_uid::uuid;
        END IF;

        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        IF EXISTS (SELECT 1 FROM public.recharge WHERE idclient = p_id LIMIT 1)
           OR EXISTS (SELECT 1 FROM public.transactions WHERE idclient = p_id LIMIT 1)
        THEN
            WITH deactivated AS (
                UPDATE public.clients SET status = '1' WHERE id = p_id RETURNING *
            )
            SELECT row_to_json(deactivated.*) INTO v_client FROM deactivated;
            RETURN json_build_object(
                'success', true,
                'data', v_client,
                'message', 'El cliente no puede ser eliminado porque tiene recargas o movimientos asociados. Se ha desactivado en su lugar.',
                'deactivated', true
            );
        ELSE
            DELETE FROM public.clients WHERE id = p_id;
            RETURN json_build_object('success', true, 'message', 'Cliente eliminado del sistema.');
        END IF;

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- ==============================================================
-- manage_unit — Validación + Propagación de Email
-- ==============================================================

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
    -- 1. Control de acceso
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    -- Preparamos el nombre de usuario limpio: todo a minúsculas, quitando espacios y caracteres especiales
    v_clean_username := LOWER(REGEXP_REPLACE(COALESCE(p_driver, p_name, ''), '[^a-zA-Z0-9]', '', 'g'));

    -- ==========================================
    -- ACCION: CREATE
    -- ==========================================
    IF LOWER(p_action) = 'create' THEN
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
        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

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

        v_auth_id := NULL;
        IF p_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(p_email);
        ELSIF v_old_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(v_old_email);
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
                --UPDATE auth.users SET
                --    raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('email', p_email)
                --WHERE id = v_auth_id;
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
$function$
;
