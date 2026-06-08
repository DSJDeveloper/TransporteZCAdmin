-- ============================================================
-- MIGRATION: Add name column to profiles
-- ============================================================
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS name TEXT;

-- Backfill name from auth.users.raw_user_meta_data
UPDATE public.profiles p
SET name = u.raw_user_meta_data->>'user_name'
FROM auth.users u
WHERE u.id = p.id AND p.name IS NULL;

-- Nullify duplicate names so the unique index can be created
UPDATE public.profiles
SET name = NULL
WHERE name IN (
  SELECT name FROM public.profiles
  WHERE name IS NOT NULL AND name != ''
  GROUP BY name
  HAVING COUNT(*) > 1
);

-- Partial unique index: name must be unique when present
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_name_unique
ON public.profiles (name) WHERE name IS NOT NULL AND name != '';

-- ============================================================
-- RPC: manage_profile
-- CRUD de usuarios (profiles) con guardia de admin
-- ============================================================
CREATE OR REPLACE FUNCTION public.manage_profile(
  p_action    VARCHAR,
  p_user_id   UUID DEFAULT NULL,
  p_email     VARCHAR DEFAULT NULL,
  p_password  VARCHAR DEFAULT NULL,
  p_role      user_role DEFAULT NULL,
  p_name      VARCHAR DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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

    -- Sync name & email to auth.users.raw_user_meta_data
    UPDATE auth.users
    SET
      raw_user_meta_data = raw_user_meta_data || json_build_object(
        'user_name', COALESCE(p_name, raw_user_meta_data->>'user_name'),
        'role', COALESCE(p_role::text, raw_user_meta_data->>'role'),
        'email', COALESCE(p_email, raw_user_meta_data->>'email')
      )::jsonb,
      email = COALESCE(p_email, email)
    WHERE id = p_user_id;

    -- Sync email to clients if changed
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
$$;

NOTIFY pgrst, 'reload schema';
