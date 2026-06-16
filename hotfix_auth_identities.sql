-- ============================================================
-- HOTFIX: Agregar provider_id a auth.identities en manage_profile
-- y is_sso_user a auth.users (requerido por Supabase más reciente)
-- ============================================================

BEGIN;

DO $$
DECLARE
    f text;
BEGIN
    FOR f IN SELECT p.oid::regprocedure::text
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'manage_profile'
    LOOP
        EXECUTE 'DROP FUNCTION ' || f || ' CASCADE';
    END LOOP;
END $$;

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
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
