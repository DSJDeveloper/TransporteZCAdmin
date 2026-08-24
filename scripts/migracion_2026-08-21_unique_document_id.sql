-- ============================================================
-- Migración: Unique documentID en clients
-- Fecha: 2026-08-21
-- Descripción: Índice único normalizado sobre documentID para
--              impedir cédulas duplicadas (con/sin formato).
--              Actualiza manage_client con validación server-side.
-- ============================================================

-- 1. Función helper: normaliza cédula (elimina puntos, comas, guiones, espacios)
DROP FUNCTION IF EXISTS public.normalize_document_id(character varying);
CREATE OR REPLACE FUNCTION public.normalize_document_id(p_value character varying)
RETURNS text
    LANGUAGE sql
    IMMUTABLE
    SECURITY DEFINER
AS $function$
    SELECT UPPER(REGEXP_REPLACE(COALESCE(p_value, ''), '[.\-\,\s]', '', 'g'));
$function$
;
-- 1.1 sanitize_document_id(text): cédula robusta [^a-zA-Z0-9] (registro público)
DROP FUNCTION IF EXISTS public.sanitize_document_id(character varying);
CREATE OR REPLACE FUNCTION public.sanitize_document_id(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 PARALLEL SAFE
AS $function$
    SELECT UPPER(REGEXP_REPLACE(COALESCE(p_value, ''), '[^a-zA-Z0-9]', '', 'g'))
$function$
;



-- 2. Índice único normalizado sobre documentID
--    Previene duplicados aunque los valores tengan formato distinto
--    (ej. "V-12.345.678" = "V12345678" = "12345678")
DROP INDEX IF EXISTS "idx_clients_document_id_unique";
CREATE UNIQUE INDEX "idx_clients_document_id_unique"
    ON public."clients"
    (public.normalize_document_id("documentID"));

-- 3. Actualizar manage_client: validación de documentID duplicado
DROP FUNCTION IF EXISTS public.manage_client(character varying, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, bigint, character varying);
CREATE OR REPLACE FUNCTION public.manage_client(
    p_action        character varying,
    p_id            bigint DEFAULT NULL,
    p_name          character varying DEFAULT NULL,
    p_document_id   character varying DEFAULT NULL,
    p_email         character varying DEFAULT NULL,
    p_phone         character varying DEFAULT NULL,
    p_carrer        character varying DEFAULT NULL,
    p_credit_limit  character varying DEFAULT NULL,
    p_status        character varying DEFAULT NULL,
    p_idroute       bigint DEFAULT NULL,
    p_photo_url     character varying DEFAULT NULL
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client        JSON;
    v_current_email TEXT;
    v_uid           TEXT;
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
            INSERT INTO public.clients (name, "documentID", email, phone, carrer, "creditLimit", status, uid, idroute, photo_url)
            VALUES (p_name, v_new_doc, p_email, p_phone, p_carrer, p_credit_limit, COALESCE(p_status, 'Activo'), gen_random_uuid()::text, p_idroute, NULLIF(p_photo_url, ''))
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
