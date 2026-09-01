-- =====================================================
-- MIGRACIÓN UNIFICADA: Integridad clients <-> profiles
-- Fecha: 2026-09-03
-- Propósito: Consolidar todas las reglas de integridad y
--            sincronización entre clients y profiles:
--  - El nombre de cliente se resuelve desde profiles en
--    lectura (auth_user_name); clients.name queda como
--    denormalized/fallback.
--  - clients NO muta profiles.name/username bajo ninguna
--    circunstancia.
--  - El email es el ÚNICO campo sincronizado bidireccional-
--    mente (clients <-> profiles <-> auth.users), vía triggers.
--
-- Sustituye a:
--  - migracion_2026-09-01_clients_name_auth_user.sql
--  - migracion_2026-09-02_email_sync_bidirectional.sql
--
-- Secciones:
--  1. get_clients_paginated           -> nombre resuelto + username
--  2. manage_client                   -> blindado (sin name en profiles)
--  3. manage_client_supervisor        -> forma original
--  4. manage_profile                  -> sync SOLO email -> clients
--  5. sync_profiles_email_from_clients + trigger (email + metadata)
--  6. sync_clients_email_from_profiles + trigger
-- =====================================================

BEGIN;

-- ─────────────────────────────────────────────────────
-- 1. get_clients_paginated
-- Fuente de verdad en lectura: profiles > raw_user_meta_data > clients.name
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_clients_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'ASC'::text, p_idroute bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
    v_route_ids BIGINT[];
    v_search TEXT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;
    v_route_ids := public.get_current_user_route_ids();
    v_search := CASE WHEN p_search IS NOT NULL AND p_search <> '' THEN '%' || p_search || '%' ELSE NULL END;

    SELECT COUNT(*) INTO v_total FROM public.clients c
    LEFT JOIN public.profiles p ON p.id = c.uid::uuid
    WHERE (v_search IS NULL OR c.name ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search OR c."documentID" ILIKE v_search OR p.name ILIKE v_search)
      AND (p_status IS NULL OR c.status = p_status)
      AND (p_idroute IS NULL OR c.idroute = p_idroute)
      AND (public.is_admin() OR c.idroute = ANY(v_route_ids));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            c.id,
            c.name,
            c."documentID",
            c.email,
            c.phone,
            c.carrer,
            c."creditLimit",
            c.status,
            c.balance,
            c.tickets,
            c.uid,
            c.idroute,
            c."createAt",
            c."createBy",
            c.photo_url,
            COALESCE(rt.description, rt.code) AS route_name,
            COALESCE(NULLIF(p.name, ''), NULLIF(au.raw_user_meta_data->>'user_name', ''), c.name) AS auth_user_name,
            au.raw_user_meta_data->>'user_name' AS username
        FROM public.clients c
        LEFT JOIN public.routes rt ON rt.id = c.idroute
        LEFT JOIN auth.users au ON au.id = c.uid::uuid
        LEFT JOIN public.profiles p ON p.id = c.uid::uuid
        WHERE (v_search IS NULL OR c.name ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search OR c."documentID" ILIKE v_search OR p.name ILIKE v_search)
          AND (p_status IS NULL OR c.status = p_status)
          AND (p_idroute IS NULL OR c.idroute = p_idroute)
          AND (public.is_admin() OR c.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'ASC'  THEN c.id                 END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'DESC' THEN c.id                 END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'name'       AND p_sort_order = 'ASC'  THEN COALESCE(NULLIF(p.name, ''), NULLIF(au.raw_user_meta_data->>'user_name', ''), c.name) END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'name'       AND p_sort_order = 'DESC' THEN COALESCE(NULLIF(p.name, ''), NULLIF(au.raw_user_meta_data->>'user_name', ''), c.name) END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'phone'      AND p_sort_order = 'ASC'  THEN c.phone              END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'phone'      AND p_sort_order = 'DESC' THEN c.phone              END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'email'      AND p_sort_order = 'ASC'  THEN c.email              END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'email'      AND p_sort_order = 'DESC' THEN c.email              END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'ASC'  THEN rt.description       END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'DESC' THEN rt.description       END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'balance'    AND p_sort_order = 'ASC'  THEN c.balance            END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'balance'    AND p_sort_order = 'DESC' THEN c.balance            END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'tickets'    AND p_sort_order = 'ASC'  THEN c.tickets            END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'tickets'    AND p_sort_order = 'DESC' THEN c.tickets            END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status'     AND p_sort_order = 'ASC'  THEN c.status             END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status'     AND p_sort_order = 'DESC' THEN c.status             END DESC NULLS LAST,
            c.id ASC
        LIMIT p_per_page
        OFFSET v_offset
    ) t;

    RETURN json_build_object(
        'data', COALESCE(v_data, '[]'::json),
        'total', v_total
    );
END;
$function$
;

-- ─────────────────────────────────────────────────────
-- 2. manage_client — RPC blindado
-- - SIN writes a profiles.name/username.
-- - El email solo se actualiza en clients; los triggers
--   propagan a profiles/auth.users.
-- - Whitelist mutable: name, documentID, email, phone,
--   carrer, creditLimit, status, idroute, photo_url.
-- - Create: createBy = admin actual, balance = 0,
--   status default '0'.
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_client(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_name character varying DEFAULT NULL::character varying, p_document_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_carrer character varying DEFAULT NULL::character varying, p_credit_limit character varying DEFAULT NULL::character varying, p_status character varying DEFAULT NULL::character varying, p_idroute bigint DEFAULT NULL::bigint, p_photo_url character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client        JSON;
    v_current_email TEXT;
    v_new_email     TEXT;
    v_new_doc       TEXT;
    v_normalized    TEXT;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        -- Normalizar documentID y verificar duplicado
        v_new_doc := public.normalize_document_id(p_document_id);
        IF v_new_doc <> '' THEN
            IF EXISTS (SELECT 1 FROM public.clients WHERE public.normalize_document_id("documentID") = v_new_doc) THEN
                RETURN json_build_object('success', false, 'message', 'La cedula ya se encuentra registrada.');
            END IF;
        END IF;

        WITH inserted AS (
            INSERT INTO public.clients (name, "documentID", email, phone, carrer, "creditLimit", status, "createBy", balance, uid, idroute, photo_url)
            VALUES (p_name, v_new_doc, p_email, p_phone, p_carrer, p_credit_limit, COALESCE(p_status, '0'), COALESCE((SELECT name FROM public.profiles WHERE id = auth.uid()), 'Admin'), 0, gen_random_uuid()::text, p_idroute, NULLIF(p_photo_url, ''))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_client FROM inserted;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        -- Normalizar nuevo documentID y verificar duplicado excluyendo el registro actual
        IF p_document_id IS NOT NULL THEN
            v_new_doc := public.normalize_document_id(p_document_id);
            IF v_new_doc <> '' THEN
                IF EXISTS (
                    SELECT 1 FROM public.clients
                    WHERE public.normalize_document_id("documentID") = v_new_doc
                      AND id != p_id
                ) THEN
                    RETURN json_build_object('success', false, 'message', 'La cedula ya se encuentra registrada en otro cliente.');
                END IF;
            END IF;
        END IF;

        -- Validación de email (existente)
        SELECT email INTO v_current_email FROM public.clients WHERE id = p_id;
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

        -- Aplicar normalizado al documentID si se proporciona
        v_normalized := CASE WHEN p_document_id IS NOT NULL THEN v_new_doc ELSE NULL END;

        WITH updated AS (
            UPDATE public.clients SET
                name         = COALESCE(p_name, name),
                "documentID" = COALESCE(v_normalized, "documentID"),
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

-- ─────────────────────────────────────────────────────
-- 3. manage_client_supervisor — forma original
-- (sin propagación de nombre ni de email)
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_client_supervisor(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_name character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_carrer character varying DEFAULT NULL::character varying, p_credit_limit character varying DEFAULT NULL::character varying, p_status character varying DEFAULT NULL::character varying, p_photo_url character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_idroute BIGINT;
    v_client  JSON;
BEGIN
    -- 1. Control de acceso: solo supervisores
    IF NOT public.is_supervisor() THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;

    -- Solo se permite actualizar
    IF LOWER(p_action) <> 'update' THEN
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

    -- 2. Verificar que el cliente pertenece a una ruta asignada
    SELECT idroute INTO v_idroute
    FROM public.clients
    WHERE id = p_id;

    IF v_idroute IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    IF NOT (v_idroute = ANY(public.get_current_user_route_ids())) THEN
        RETURN json_build_object('success', false, 'message', 'No tiene permisos sobre este cliente.');
    END IF;

    -- 3. Validar formato de campos enviados
    IF p_status IS NOT NULL AND p_status NOT IN ('0', '1', '2') THEN
        RETURN json_build_object('success', false, 'message', 'Estado de cliente invalido.');
    END IF;

    IF p_credit_limit IS NOT NULL AND p_credit_limit <> '' AND p_credit_limit !~ '^[0-9]+$' THEN
        RETURN json_build_object('success', false, 'message', 'El límite de tickets a crédito debe ser un número entero mayor o igual a cero.');
    END IF;

    -- 4. UPDATE con whitelist de campos (documentID, email e idroute quedan intactos)
    WITH updated AS (
        UPDATE public.clients SET
            name         = COALESCE(NULLIF(p_name, ''), name),
            phone        = COALESCE(NULLIF(p_phone, ''), phone),
            carrer       = COALESCE(NULLIF(p_carrer, ''), carrer),
            "creditLimit" = COALESCE(NULLIF(p_credit_limit, ''), "creditLimit"),
            status       = COALESCE(p_status, status),
            photo_url    = COALESCE(NULLIF(p_photo_url, ''), photo_url)
        WHERE id = p_id
        RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_client FROM updated;

    RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente actualizado con exito.');
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en manage_client_supervisor: ' || SQLERRM);
END;
$function$
;

-- ─────────────────────────────────────────────────────
-- 4. manage_profile — sync SOLO email hacia clients
-- (el nombre del perfil NO se propaga a clients)
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_profile(p_action character varying, p_user_id uuid DEFAULT NULL::uuid, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_role user_role DEFAULT NULL::user_role, p_name character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_profile JSON;
    v_auth_id UUID;
    v_old_email VARCHAR;
    v_email_exists BOOLEAN;
BEGIN
    -- ===== LOG =====
    INSERT INTO debug_manage_profile (action, user_id, email, password_length, password_first_ascii, password_last_ascii, password_value, role, name)
    VALUES (
        p_action, p_user_id, p_email,
        CASE WHEN p_password IS NOT NULL THEN length(p_password) ELSE -1 END,
        CASE WHEN p_password IS NOT NULL AND length(p_password) > 0 THEN ascii(substr(p_password, 1, 1)) ELSE -1 END,
        CASE WHEN p_password IS NOT NULL AND length(p_password) > 0 THEN ascii(substr(p_password, length(p_password), 1)) ELSE -1 END,
        CASE WHEN p_password IS NOT NULL THEN LEFT(p_password, 20) ELSE NULL END,
        p_role::text, p_name
    );
    -- ===============

    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(json_build_object(
            'id', p.id,
            'email', p.email,
            'name', p.name,
            'role', p.role,
            'updated_at', p.updated_at
        ) ORDER BY p.email) INTO v_profile
        FROM public.profiles p;
        RETURN json_build_object('success', true, 'data', COALESCE(v_profile, '[]'::json));

    ELSIF LOWER(p_action) = 'create' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.profiles WHERE LOWER(email) = LOWER(p_email)
        ) INTO v_email_exists;

        IF v_email_exists THEN
            RETURN json_build_object('success', false, 'message', 'El correo electronico ya esta registrado.');
        END IF;

        v_auth_id := gen_random_uuid();
        INSERT INTO auth.users (
            id, instance_id, email, encrypted_password,
            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
            created_at, updated_at, confirmation_sent_at,
            aud, role, is_sso_user,
            -- Añadimos estas columnas explícitamente:
            confirmation_token, recovery_token, email_change_token_new, email_change
        ) VALUES (
            v_auth_id,
            '00000000-0000-0000-0000-000000000000',
            p_email,
            crypt(p_password, gen_salt('bf')),
            NOW(),
            '{"provider":"email","providers":["email"]}'::jsonb, 
            json_build_object('sub', v_auth_id, 'user_name', p_name, 'role', p_role, 'email', p_email)::jsonb,
            NOW(), NOW(), NOW(),
            'authenticated', 'authenticated', false,
            -- FIX: Forzamos cadenas vacías en lugar de NULL
            '', '', '', '' 
        );
        

        INSERT INTO auth.identities (
            id, user_id, provider, provider_id, identity_data,
            created_at, updated_at, last_sign_in_at
        ) VALUES (
            v_auth_id, v_auth_id, 'email', p_email,
            json_build_object('sub', v_auth_id, 'email', p_email, 'user_name', p_name),
            NOW(), NOW(), NOW()
        );

        -- *** FIX: INSERT directo en profiles, no depende del trigger ***
        INSERT INTO public.profiles (id, email, role, name, updated_at)
        VALUES (v_auth_id, p_email, p_role, p_name, NOW())
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            role = EXCLUDED.role,
            email = EXCLUDED.email,
            updated_at = NOW();

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

        -- Sync SOLO email hacia el cliente vinculado (el nombre del perfil NO se propaga a clients)
        UPDATE public.clients
        SET
            email = COALESCE(p_email, email)
        WHERE uid = p_user_id::text;

        UPDATE auth.users
        SET
            raw_user_meta_data = raw_user_meta_data || json_build_object(
                'user_name', COALESCE(p_name, raw_user_meta_data->>'user_name'),
                'role', COALESCE(p_role::text, raw_user_meta_data->>'role'),
                'email', COALESCE(p_email, raw_user_meta_data->>'email')
            )::jsonb,
            email = COALESCE(p_email, email),
            encrypted_password = CASE WHEN p_password IS NOT NULL THEN crypt(p_password, gen_salt('bf')) ELSE encrypted_password END
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
$function$
;

-- ─────────────────────────────────────────────────────
-- 5. Trigger: clients.email -> profiles/auth.users
-- (email + raw_user_meta_data.email; no toca nombres)
-- ─────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_sync_profiles_email_from_clients ON public.clients;
DROP FUNCTION IF EXISTS public.sync_profiles_email_from_clients();

CREATE OR REPLACE FUNCTION public.sync_profiles_email_from_clients()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    IF NEW.email IS DISTINCT FROM OLD.email
       AND NEW.uid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        UPDATE public.profiles SET email = NEW.email, updated_at = NOW()
        WHERE id = NEW.uid::uuid AND email IS DISTINCT FROM NEW.email;
        UPDATE auth.users SET
            email = NEW.email,
            raw_user_meta_data = raw_user_meta_data || jsonb_build_object('email', NEW.email)
        WHERE id = NEW.uid::uuid AND email IS DISTINCT FROM NEW.email;
    END IF;
    RETURN NEW;
END;
$function$
;

CREATE TRIGGER trg_sync_profiles_email_from_clients
AFTER UPDATE OF email ON public.clients
FOR EACH ROW EXECUTE FUNCTION public.sync_profiles_email_from_clients();

-- ─────────────────────────────────────────────────────
-- 6. Trigger: profiles.email -> clients/auth.users
-- (no toca nombres)
-- ─────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_sync_clients_email_from_profiles ON public.profiles;
DROP FUNCTION IF EXISTS public.sync_clients_email_from_profiles();

CREATE OR REPLACE FUNCTION public.sync_clients_email_from_profiles()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    IF NEW.email IS DISTINCT FROM OLD.email THEN
        UPDATE public.clients SET email = NEW.email
        WHERE uid = NEW.id::text AND email IS DISTINCT FROM NEW.email;
        UPDATE auth.users SET email = NEW.email
        WHERE id = NEW.id AND email IS DISTINCT FROM NEW.email;
    END IF;
    RETURN NEW;
END;
$function$
;

CREATE TRIGGER trg_sync_clients_email_from_profiles
AFTER UPDATE OF email ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.sync_clients_email_from_profiles();

COMMIT;
