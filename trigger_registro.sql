-- ============================================================
-- MIGRACIÓN: Actualizar trigger handle_new_user para crear
-- también el registro en clients al registrarse desde el frontend
-- ============================================================
-- El frontend debe enviar los datos en options.data al llamar
-- supabase.auth.signUp():
--
-- supabase.auth.signUp({
--   email,
--   password,
--   options: {
--     data: {
--       name: 'Juan Pérez',
--       phone: '+58 412 000 0000',
--       document_id: 'V-00.000.000',
--       carrer: 'logistica',
--       role: 'student',
--     },
--   },
-- })
--
-- El trigger se encarga de crear el profile y el cliente automáticamente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_name TEXT;
  v_phone TEXT;
  v_document_id TEXT;
  v_carrer TEXT;
BEGIN
  -- 1. Crear el perfil en public.profiles (comportamiento original)
  INSERT INTO public.profiles (id, email, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'student')
  );

  -- 2. Si los metadatos incluyen 'name', crear también el registro en clients
  v_name := NEW.raw_user_meta_data->>'name';

  IF v_name IS NOT NULL AND v_name <> '' THEN
    v_phone    := COALESCE(NEW.raw_user_meta_data->>'phone', '');
    v_document_id := COALESCE(NEW.raw_user_meta_data->>'document_id', '');
    v_carrer   := NEW.raw_user_meta_data->>'carrer';

    INSERT INTO public.clients (
      name,
      phone,
      "documentID",
      email,
      "creditLimit",
      status,
      "createBy",
      carrer,
      balance,
      uid
    ) VALUES (
      v_name,
      v_phone,
      v_document_id,
      NEW.email,
      '0',       -- creditLimit por defecto
      '1',       -- status activo
      v_name,    -- createBy es el nombre del usuario
      v_carrer,
      0,         -- balance inicial
      NEW.id     -- uid = auth.users.id
    );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Refrescar esquema de la API
NOTIFY pgrst, 'reload schema';
