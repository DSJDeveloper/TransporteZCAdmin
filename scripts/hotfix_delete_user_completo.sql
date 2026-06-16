-- ============================================================
-- HOTFIX: Eliminación completa de un usuario
-- ============================================================
-- El DELETE original de manage_profile solo hace:
--   DELETE FROM auth.users WHERE id = p_user_id;
-- 
-- Pero auth.users NO tiene CASCADE hacia las tablas públicas:
--   profiles, clients, user_routes.
-- 
-- Este script:
--   a) Limpia TODAS las tablas relacionadas
--   b) Actualiza manage_profile para que el delete sea completo
--
-- ============================================================
-- USO:
--   Opción 1 — Ejecutar TODO para parchear la función
--   Opción 2 — Solo ejecutar "CREATE OR REPLACE FUNCTION" si
--              ya corriste los DROPs antes (no hay problema
--              con el OR REPLACE)
-- ============================================================

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

        UPDATE public.clients
        SET
            name = COALESCE(p_name, name),
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
        -- Limpiar rutas asignadas (supervisor)
        DELETE FROM public.user_routes WHERE user_id = p_user_id;

        -- Limpiar perfil
        DELETE FROM public.profiles WHERE id = p_user_id;

        -- Limpiar cliente asociado (uid almacena el UUID como text)
        DELETE FROM public.clients WHERE uid = p_user_id::text;

        -- Limpiar identidades (por si no hay CASCADE)
        DELETE FROM auth.identities WHERE user_id = p_user_id;

        -- Eliminar el auth user (esto también limpia sesiones, etc.)
        DELETE FROM auth.users WHERE id = p_user_id;

        RETURN json_build_object('success', true, 'message', 'Usuario eliminado completamente.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;
