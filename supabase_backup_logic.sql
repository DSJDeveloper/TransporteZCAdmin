-- =====================================================
-- BACKUP: LÓGICA DE SERVIDOR (RPC, RLS, TRIGGERS)
-- Fecha: 2026-06-02T12:06:07.127Z
-- =====================================================

-- >>> FUNCIONES / RPC <<<

-- Función: rls_auto_enable
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

-- Función: get_email_by_username
CREATE OR REPLACE FUNCTION public.get_email_by_username(username_input text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN (
    SELECT email 
    FROM auth.users 
    WHERE LOWER(raw_user_meta_data->>'user_name') = LOWER(username_input)
    LIMIT 1
  );
END;
$function$
;

-- Función: get_complete_user_profile
CREATE OR REPLACE FUNCTION public.get_complete_user_profile(p_uuid text, p_email text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
BEGIN
    SELECT row_to_json(profile_row)
    INTO v_result
    FROM (
        SELECT 
            c.id AS idclient,         -- Mapeamos 'id' a 'idclient' para tu frontend
            p.id AS uuid,             -- El UUID de auth.users
            c.name,
            c.email,
            c.phone,
            c."documentID",          -- Entre comillas dobles porque respeta mayúsculas
            c."creditLimit",
            c.status,
            c.carrer,
            c.balance,               -- Tu columna real de saldo
            c."createAt",            -- Tu columna real de fecha
            p.role                   -- El rol ('admin', 'student', 'driver') de tu tabla profiles
        FROM public.clients c
        INNER JOIN public.profiles p ON p.id = c.uid::uuid -- Cruce directo y seguro por UUID
        WHERE p.id = p_uuid::uuid AND c.email = p_email
        LIMIT 1
    ) profile_row;

    RETURN COALESCE(v_result, '{}'::json);
END;
$function$
;

-- Función: get_my_client_id
CREATE OR REPLACE FUNCTION public.get_my_client_id()
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  SELECT id FROM clients WHERE uid = auth.uid()::text LIMIT 1;
$function$
;

-- Función: is_admin
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$SELECT EXISTS (
  SELECT 1 FROM public.profiles
  WHERE email = auth.jwt()->>'email' -- 👈 Extrae el email del usuario logueado en la sesión actual
    AND role = 'admin'::user_role    -- 👈 Casteo al ENUM para evitar conflictos de tipo
);$function$
;

-- Función: get_pending_solicitude
CREATE OR REPLACE FUNCTION public.get_pending_solicitude(p_idclient integer)
 RETURNS SETOF solicitude
 LANGUAGE sql
 STABLE
AS $function$SELECT *
  FROM solicitude
  WHERE idclient = p_idclient
  AND COALESCE(status, 0) = 0
  ORDER BY id DESC
  LIMIT 1;$function$
;

-- Función: cancel_solicitude
CREATE OR REPLACE FUNCTION public.cancel_solicitude(p_id integer, p_idclient integer)
 RETURNS solicitude
 LANGUAGE sql
AS $function$
  UPDATE solicitude
  SET status = 2
  WHERE id = p_id
    AND idclient = p_idclient
    AND COALESCE(status, 0) = 0
  RETURNING *;
$function$
;

-- Función: get_client_history
CREATE OR REPLACE FUNCTION public.get_client_history(p_client_id integer, p_from timestamp without time zone, p_to timestamp without time zone, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_recharges json;
  v_transactions json;
  v_total_transactions numeric(10,2); 
begin

  -- 1. CONSULTA DE RECARGAS (Optimizada y Blindada)
  select json_agg(t) into v_recharges 
  from (
    select 
      id, 
      idclient, 
      method, 
      ref, 
      picture, 
      amount, 
      tasa, 
      date, 
      status, 
      "createBy", 
      "createAt" AS created_at_formatted -- Le damos un alias plano sin comillas para el frontend
    from public.recharge 
    where idclient = p_client_id 
      -- Forzamos a Postgres a comparar como Timestamps puros sin importar zonas horarias
      and "createAt"::timestamp >= p_from::timestamp 
      and "createAt"::timestamp <= p_to::timestamp 
      and (p_status is null or status = p_status) -- Cambiado <= por = para ser exactos con el entero
    order by id desc
  ) t;
  
  -- 2. CONSULTA DE TRANSACCIONES
  select json_agg(t) into v_transactions 
  from (
    SELECT 
      t.*,
      c.name AS client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON t.idclient = c.id 
    WHERE t.idclient = p_client_id 
      AND t.created_at::timestamp >= p_from::timestamp 
      AND t.created_at::timestamp <= p_to::timestamp
      AND (p_status IS NULL OR t.status = p_status) -- Descomentado y adaptado con el alias 't.'
    ORDER BY t.id DESC
    -- select * from public.transactions 
    -- where idclient = p_client_id 
    --   and created_at::timestamp >= p_from::timestamp 
    --   and created_at::timestamp <= p_to::timestamp 
    -- order by id desc
  ) t;

  -- 3. SUMATORIA
  select coalesce(sum(amount), 0.00) into v_total_transactions
  from public.transactions
  where idclient = p_client_id 
    and created_at::timestamp >= p_from::timestamp 
    and created_at::timestamp <= p_to::timestamp;
  
  return json_build_object(
    'recharges', coalesce(v_recharges, '[]'::json), 
    'transactions', coalesce(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions
  );
end;
$function$
;

-- Función: get_clients_transactions
CREATE OR REPLACE FUNCTION public.get_clients_transactions(p_from timestamp without time zone, p_to timestamp without time zone, p_client_id integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_create_by integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_transactions JSON;
  v_total_transactions NUMERIC(10,2); 
BEGIN

  -- 1. CONSULTA DE TRANSACCIONES CON FILTROS DINÁMICOS
  SELECT json_agg(t) INTO v_transactions 
  FROM (
    SELECT 
      t.*,
      c.name AS client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON t.idclient = c.id 
    WHERE t.created_at::timestamp >= p_from::timestamp 
      AND t.created_at::timestamp <= p_to::timestamp
      -- 🎯 Filtros Dinámicos (Si el parámetro es NULL, se ignora el filtro):
      AND (p_client_id IS NULL OR t.idclient = p_client_id)
      AND (p_status IS NULL OR t.status = p_status)
      AND (p_create_by IS NULL OR t."createBy" = p_create_by)
    ORDER BY t.id DESC
  ) t;

  -- 2. SUMATORIA ATÓMICA CON LOS MISMOS FILTROS DINÁMICOS
  SELECT COALESCE(SUM(amount), 0.00) INTO v_total_transactions
  FROM public.transactions
  WHERE created_at::timestamp >= p_from::timestamp 
    AND created_at::timestamp <= p_to::timestamp
    AND (p_client_id IS NULL OR idclient = p_client_id)
    AND (p_status IS NULL OR status = p_status)
    AND (p_create_by IS NULL OR "createBy" = p_create_by);
  
  -- 3. RETORNO EN FORMATO JSON
  RETURN json_build_object(
    'transactions', COALESCE(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions
  );
END;
$function$
;

-- Función: charge_ticket
CREATE OR REPLACE FUNCTION public.charge_ticket(p_client_uid character varying, p_ticket_count integer, p_shedule character varying, p_create_by integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_id BIGINT;
    v_current_balance NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_ticket_price NUMERIC(10,2);   -- 👈 Variable para el costo del ticket de la empresa
    v_total_amount_usd NUMERIC(10,2);-- 👈 Variable para el monto final en dólares a descontar
    v_new_balance NUMERIC(10,2);
    v_count_booking INTEGER;
    v_status INTEGER := 0; 
    v_tx_uid VARCHAR(255);
BEGIN
    -- 1. Buscar al cliente por su UID de texto y bloquear la fila para evitar condiciones de carrera
    SELECT id, balance, "creditLimit"
    INTO v_client_id, v_current_balance, v_credit_limit_raw
    FROM public.clients
    WHERE uid = p_client_uid
    FOR UPDATE;

    -- Validar si el cliente existe
    IF v_client_id IS NULL THEN
        RETURN json_build_object(
            'success', false,
            'data', NULL,
            'message', 'No existe el cliente'
        );
    END IF;

    -- 2. 🏢 OBTENER EL PRECIO ACTUAL DEL TICKET DESDE LA TABLA COMPANY
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    -- Validar que la tabla company tenga un precio configurado válido
    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object(
            'success', false,
            'data', NULL,
            'message', 'Error de configuración: El costo del ticket en la tabla company no es válido.'
        );
    END IF;

    -- 3. 🧮 Calcular el cobro real en dólares (Cantidad de tickets * Precio unitario)
    v_total_amount_usd := p_ticket_count * v_ticket_price;

    -- 4. Contar solicitudes del día actual del cliente
    SELECT COUNT(*)::INTEGER INTO v_count_booking
    FROM public.solicitude
    WHERE idclient = v_client_id
      AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

    -- 5. Calcular el nuevo balance restando el monto total en USD
    v_new_balance := v_current_balance - v_total_amount_usd;
    v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

    -- 6. Revisar reglas de crédito / saldo insuficiente
    IF v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
        RETURN json_build_object(
            'booking', v_count_booking,
            'success', false,
            'data', json_build_object('id', v_client_id, 'balance', v_current_balance),
            'message', 'Saldo insuficiente'
        );
    END IF;

    -- 7. Generar un UID único para la transacción
    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT;

    -- 8. Actualizar balance del cliente
    UPDATE public.clients
    SET balance = v_new_balance
    WHERE id = v_client_id;

    -- 9. Registrar la transacción en el historial con el dinero real cobrado
    INSERT INTO public.transactions (
        uid,
        idclient,
        "createBy",
        amount, -- 👈 Guarda los dólares totales descontados (ej: 4.00 si usó 2 tickets de $2)
        status,
        shedule,
        "newBalanceClient",
        idunit, 
        created_at
    )
    VALUES (
        v_tx_uid,
        v_client_id,
        p_create_by,
        v_total_amount_usd, 
        v_status,
        p_shedule,
        v_new_balance,
        1, 
        NOW()
    );

    -- 10. Retorno exitoso
    RETURN json_build_object(
        'booking', v_count_booking,
        'success', true,
        'data', json_build_object('id', v_client_id, 'balance', v_new_balance, 'uid', p_client_uid),
        'message', 'success'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'booking', 0,
        'success', false,
        'data', NULL,
        'message', 'Error en transacción: ' || SQLERRM
    );
END;
$function$
;

-- Función: get_client_by_uid
CREATE OR REPLACE FUNCTION public.get_client_by_uid(p_uid character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_client_id BIGINT;
    v_name VARCHAR(255);
    v_balance NUMERIC(10,2);
BEGIN
    -- 1. 🏢 Obtener el precio actual del ticket desde la empresa
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    -- Validar que exista la configuración de la empresa
    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Error de configuración: El costo del ticket en la tabla company no es válido.'
        );
    END IF;

    -- 2. 🔍 Buscar los datos base del cliente por su UID
    SELECT id, name, balance
    INTO v_client_id, v_name, v_balance
    FROM public.clients
    WHERE uid = p_uid
    LIMIT 1;

    -- Si no se encuentra el cliente, retornar fallo controlado
    IF v_client_id IS NULL THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Cliente no encontrado'
        );
    END IF;

    -- 3. 🎯 Retornar la data del cliente incluyendo el saldo equivalente en tickets
    RETURN json_build_object(
        'success', true,
        'data', json_build_object(
            'id', v_client_id,
            'name', v_name,
            'balance', v_balance, -- Saldo en dinero (Ej: 10.00)
            'tickets_balance', TRUNC(v_balance / v_ticket_price, 2) -- 👈 Saldo convertido a tickets (Ej: 5.00 si el ticket vale 2)
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success', false,
        'message', 'Error al consultar el cliente: ' || SQLERRM
    );
END;
$function$
;

-- Función: handle_new_user
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_name TEXT;
  v_phone TEXT;
  v_document_id TEXT;
  v_carrer TEXT;
  v_role TEXT;
BEGIN
  
  -- 1. Forzamos a que el rol sea un texto limpio en minúsculas ('student', 'driver', 'admin')
  v_role := LOWER(COALESCE(NEW.raw_user_meta_data->>'role', 'student'));

  -- 2. Intento de inserción en la tabla de perfiles
  BEGIN
    -- ⚠️ NOTA CRUCIAL: Si tu tabla se llama 'profiles', cambia 'users_profiles' por 'profiles' abajo
    INSERT INTO public.users_profiles (uid, email, role)
    VALUES (
      NEW.id,
      NEW.email,
      v_role -- Lo insertamos como texto limpio para evitar errores de ENUM/casteo
    );
  EXCEPTION WHEN OTHERS THEN
    -- Si vuelve a fallar aquí, este Warning dejará el error exacto en los logs de Supabase
    RAISE WARNING 'Fallo específico en perfiles: %', SQLERRM;
  END;

  -- 3. Crear el registro en la tabla de clientes (Si viene el nombre)
  v_name := NEW.raw_user_meta_data->>'name';

  IF v_name IS NOT NULL AND v_name <> '' THEN
    v_phone       := COALESCE(NEW.raw_user_meta_data->>'phone', '');
    v_document_id := COALESCE(NEW.raw_user_meta_data->>'document_id', '');
    v_carrer      := NEW.raw_user_meta_data->>'carrer';

    BEGIN
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
        0,         
        '1',       
        v_name,    
        v_carrer,
        0,         
        NEW.id     
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Fallo específico en clientes: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$
;

-- Función: calculate_tickets
CREATE OR REPLACE FUNCTION public.calculate_tickets(p_amount numeric, p_method character varying, p_tasa numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_amount_in_usd NUMERIC(10,2);
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RAISE EXCEPTION 'Error de configuración: El precio del ticket en la tabla company no es válido o está en cero.';
    END IF;

    IF LOWER(p_method) = 'efectivo' THEN
        v_amount_in_usd := p_amount;
    ELSE
        IF p_tasa IS NULL OR p_tasa <= 0 THEN
            RAISE EXCEPTION 'Conversión fallida: Se requiere una tasa válida mayor a cero para pagos en Bs.';
        END IF;
        v_amount_in_usd := p_amount / p_tasa;
    END IF;

    RETURN TRUNC(v_amount_in_usd / v_ticket_price, 2);
END;
$function$
;

-- Función: get_current_ticket_price
CREATE OR REPLACE FUNCTION public.get_current_ticket_price()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Error: El costo del ticket no está configurado en la tabla company.'
        );
    END IF;

    RETURN json_build_object(
        'success', true,
        'ticket_price', v_ticket_price
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success', false,
        'message', 'Error al obtener el precio: ' || SQLERRM
    );
END;
$function$
;

-- Función: process_payment
CREATE OR REPLACE FUNCTION public.process_payment(p_idclient integer, p_amount numeric, p_method character varying, p_ref character varying DEFAULT NULL::character varying, p_tasa numeric DEFAULT NULL::numeric, p_date date DEFAULT CURRENT_DATE, p_picture character varying DEFAULT NULL::character varying, p_create_by character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_current_balance NUMERIC(10,2);
    v_recharge_id BIGINT;
    v_estimated_tickets NUMERIC(10,2); 
BEGIN
    -- 🛡️ Validaciones preliminares
    IF p_amount <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'El monto de la recarga debe ser mayor a cero.');
    END IF;

    SELECT balance INTO v_current_balance FROM public.clients WHERE id = p_idclient;
    IF v_current_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente especificado no existe.');
    END IF;

    -- 🚀 Invocación limpia al helper (El precio ya no se pasa desde aquí)
    v_estimated_tickets := public.calculate_tickets(p_amount, p_method, p_tasa);

    -- 📝 Insertar el registro histórico (Status 0 = Pendiente)
    INSERT INTO public.recharge (
        idclient, method, ref, picture, amount, tasa, date, status, "createBy", "createAt"
    )
    VALUES (
        p_idclient, p_method, NULLIF(p_ref, ''), NULLIF(p_picture, ''), p_amount, p_tasa, p_date, 0, p_create_by, NOW()
    )
    RETURNING id INTO v_recharge_id;

    RETURN json_build_object(
        'success', true,
        'message', 'Pago registrado exitosamente. En espera por verificación administrativa.',
        'recharge_id', v_recharge_id,
        'estimated_tickets', v_estimated_tickets,
        'current_balance', v_current_balance
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en transacción: ' || SQLERRM);
END;
$function$
;

-- Función: charge_tickets_bulk
CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(p_transactions jsonb, p_create_by integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_item JSONB;               -- Variable temporal para iterar el array
    
    -- Variables internas para el mapeo de cada registro
    v_client_uid VARCHAR(255);
    v_ticket_count INTEGER;
    v_shedule VARCHAR(255);
    
    -- Variables de procesamiento de negocio
    v_client_id BIGINT;
    v_current_balance NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
    
    -- Contadores y control de respuesta
    v_processed_count INTEGER := 0;
    v_response_data JSONB := '[]'::jsonb; 
BEGIN

    -- 🏢 SE REMOVIÓ LA CONSULTA A LA TABLA COMPANY 
    -- Ya no hace falta el precio del ticket porque el cobro se descuenta directamente sobre el balance indexado en tickets.

    -- 1. 🔄 ITERAR EL ARRAY DE TRANSACCIONES ENVIADO DESDE VUE
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        
        -- Extraer y castear los campos del objeto JSON actual
        v_client_uid := v_item->>'client_uid';
        v_ticket_count := (v_item->>'ticket_count')::INTEGER;
        v_shedule := v_item->>'shedule';

        -- Validar que la data del item no venga corrupta o vacía
        IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
            RAISE EXCEPTION 'Registro inválido en el lote. Verifique UIDs y cantidades de tickets.';
        END IF;

        -- 2. 🔍 BUSCAR Y BLOQUEAR AL CLIENTE (FOR UPDATE evita colisiones si se procesa el mismo cliente en el lote)
        SELECT id, balance, "creditLimit"
        INTO v_client_id, v_current_balance, v_credit_limit_raw
        FROM public.clients
        WHERE uid = v_client_uid
        FOR UPDATE;

        IF v_client_id IS NULL THEN
            RAISE EXCEPTION 'El cliente con UID % no existe en el sistema.', v_client_uid;
        END IF;

        -- 3. 🧮 CALCULAR EL NUEVO BALANCE DIRECTAMENTE EN TICKETS
        -- 👈 CORREGIDO: Restamos directamente v_ticket_count en vez de un monto en USD
        v_new_balance := v_current_balance - v_ticket_count; 
        v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        -- Verificar saldo insuficiente contra límite de crédito (evaluado en la misma unidad del balance)
        IF v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Transacción rechazada. El cliente con UID % tiene saldo insuficiente (Balance actual: % tickets, Intenta cobrar: % tickets, Límite Crédito: % tickets).', 
                v_client_uid, v_current_balance, v_ticket_count, v_credit_limit;
        END IF;

        -- 4. 📊 CONTAR BOOKINGS DEL DÍA
        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id
          AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        -- 5. 📝 ACTUALIZAR BALANCE DEL CLIENTE
        UPDATE public.clients
        SET balance = v_new_balance
        WHERE id = v_client_id;

        -- 6. 🆔 GENERAR UID DE TRANSACCIÓN ÚNICA
        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || v_processed_count::TEXT;

        -- 7. 📥 REGISTRAR EN LA TABLA TRANSACTIONS
        INSERT INTO public.transactions (
            uid,
            idclient,
            "createBy",
            amount,
            status,
            shedule,
            "newBalanceClient",
            idunit, 
            created_at
        )
        VALUES (
            v_tx_uid,
            v_client_id,
            p_create_by,
            v_ticket_count::NUMERIC(10,2), -- Se guarda la cantidad neta consumida
            0, -- Status: 0 = Exitoso
            v_shedule,
            v_new_balance,
            1, -- Unidad por defecto
            NOW()
        );

        -- 8. 📌 Acumular información de éxito para el retorno de este cliente específico
        v_response_data := v_response_data || jsonb_build_object(
            'client_uid', v_client_uid,
            'new_balance', v_new_balance,
            'booking_count', v_count_booking
        );

        v_processed_count := v_processed_count + 1;

    END LOOP;

    -- 9. 🎯 RETORNO EXITOSO DE TODO EL LOTE
    RETURN json_build_object(
        'success', true,
        'message', 'Lote de transacciones procesado con éxito.',
        'processed_records', v_processed_count,
        'details', v_response_data
    );

EXCEPTION WHEN OTHERS THEN
    -- 🔥 Ocurrió un error (Saldo insuficiente, exception manual, etc.)
    -- Postgres hace ROLLBACK de todo el bucle automáticamente aquí.
    RETURN json_build_object(
        'success', false,
        'message', 'Lote cancelado (Rollback ejecutado): ' || SQLERRM,
        'processed_records', 0,
        'details', '[]'::json
    );
END;
$function$
;

-- Función: get_current_app_name
CREATE OR REPLACE FUNCTION public.get_current_app_name()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_agent TEXT;
BEGIN
    v_agent := current_setting('request.headers', true)::json->>'user-agent';
    
    IF v_agent LIKE '%admin-app-agent%' THEN
        RETURN 'admin-app';
    ELSIF v_agent LIKE '%client-app-agent%' THEN
        RETURN 'client-app';
    ELSE
        RETURN NULL;
    END IF;
END;
$function$
;

-- Función: manage_unit
CREATE OR REPLACE FUNCTION public.manage_unit(p_action character varying, p_unit_id integer DEFAULT NULL::integer, p_name character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_user_role VARCHAR(50);
    v_app_source TEXT;
BEGIN


    -- 2. 🔄 PROCESAMIENTO DE ACCIONES
    IF LOWER(p_action) = 'create' THEN
        IF p_name IS NULL OR TRIM(p_name) = '' THEN
            RETURN json_build_object('success', false, 'message', 'El nombre de la unidad es requerido.');
        END IF;
        
        INSERT INTO public.units (name, created_at) VALUES (p_name, NOW());
        RETURN json_build_object('success', true, 'message', 'Unidad creada con éxito.');

    ELSIF LOWER(p_action) = 'update' THEN
        IF p_unit_id IS NULL OR p_name IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Parámetros insuficientes para actualizar.');
        END IF;

        UPDATE public.units SET name = p_name WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad actualizada con éxito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        IF p_unit_id IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'ID de unidad requerido.');
        END IF;

        -- Aquí podrías validar si la unidad está en uso por algún bus/ticket antes de borrar
        DELETE FROM public.units WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');
    
    ELSE
        RETURN json_build_object('success', false, 'message', 'Acción no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- Función: manage_unit
CREATE OR REPLACE FUNCTION public.manage_unit(p_action character varying, p_unit_id integer DEFAULT NULL::integer, p_name character varying DEFAULT NULL::character varying, p_number character varying DEFAULT NULL::character varying, p_plate character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_driver character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_unit JSON;
BEGIN
    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.units (name, number, plate, status, driver)
            VALUES (p_name, p_number, p_plate, COALESCE(p_status, 1), p_driver)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_unit FROM inserted;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad creada con éxito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.units
            SET
                name = COALESCE(p_name, name),
                number = COALESCE(p_number, number),
                plate = COALESCE(p_plate, plate),
                status = COALESCE(p_status, status),
                driver = COALESCE(p_driver, driver)
            WHERE id = p_unit_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_unit FROM updated;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad actualizada con éxito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.units WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Acción no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- Función: manage_unit
CREATE OR REPLACE FUNCTION public.manage_unit(p_action character varying, p_unit_id integer DEFAULT NULL::integer, p_name character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_user_role VARCHAR(50);
    v_app_source TEXT;
BEGIN


    -- 2. 🔄 PROCESAMIENTO DE ACCIONES
    IF LOWER(p_action) = 'create' THEN
        IF p_name IS NULL OR TRIM(p_name) = '' THEN
            RETURN json_build_object('success', false, 'message', 'El nombre de la unidad es requerido.');
        END IF;
        
        INSERT INTO public.units (name, created_at) VALUES (p_name, NOW());
        RETURN json_build_object('success', true, 'message', 'Unidad creada con éxito.');

    ELSIF LOWER(p_action) = 'update' THEN
        IF p_unit_id IS NULL OR p_name IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Parámetros insuficientes para actualizar.');
        END IF;

        UPDATE public.units SET name = p_name WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad actualizada con éxito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        IF p_unit_id IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'ID de unidad requerido.');
        END IF;

        -- Aquí podrías validar si la unidad está en uso por algún bus/ticket antes de borrar
        DELETE FROM public.units WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');
    
    ELSE
        RETURN json_build_object('success', false, 'message', 'Acción no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- Función: manage_unit
CREATE OR REPLACE FUNCTION public.manage_unit(p_action character varying, p_unit_id integer DEFAULT NULL::integer, p_name character varying DEFAULT NULL::character varying, p_number character varying DEFAULT NULL::character varying, p_plate character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_driver character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_unit JSON;
BEGIN
    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.units (name, number, plate, status, driver)
            VALUES (p_name, p_number, p_plate, COALESCE(p_status, 1), p_driver)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_unit FROM inserted;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad creada con éxito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.units
            SET
                name = COALESCE(p_name, name),
                number = COALESCE(p_number, number),
                plate = COALESCE(p_plate, plate),
                status = COALESCE(p_status, status),
                driver = COALESCE(p_driver, driver)
            WHERE id = p_unit_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_unit FROM updated;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad actualizada con éxito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.units WHERE id = p_unit_id;
        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Acción no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- Función: manage_client
CREATE OR REPLACE FUNCTION public.manage_client(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_name character varying DEFAULT NULL::character varying, p_document_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_carrer character varying DEFAULT NULL::character varying, p_credit_limit character varying DEFAULT NULL::character varying, p_status character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client JSON;
BEGIN
    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.clients (name, "documentID", email, phone, carrer, "creditLimit", status, uid)
            VALUES (p_name, p_document_id, p_email, p_phone, p_carrer, p_credit_limit, COALESCE(p_status, 'Activo'), gen_random_uuid()::text)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_client FROM inserted;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente creado con éxito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.clients
            SET
                name = COALESCE(p_name, name),
                "documentID" = COALESCE(p_document_id, "documentID"),
                email = COALESCE(p_email, email),
                phone = COALESCE(p_phone, phone),
                carrer = COALESCE(p_carrer, carrer),
                "creditLimit" = COALESCE(p_credit_limit, "creditLimit"),
                status = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_client FROM updated;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente actualizado con éxito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.clients WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Cliente eliminado del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Acción no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- Función: get_recharge_stats
CREATE OR REPLACE FUNCTION public.get_recharge_stats()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_pending BIGINT;
  v_rejected BIGINT;
  v_approved BIGINT;
  v_total_amount NUMERIC(10,2);
BEGIN
  SELECT COUNT(*) FILTER (WHERE status = 0),
         COUNT(*) FILTER (WHERE status = 2),
         COUNT(*) FILTER (WHERE status = 1)
  INTO v_pending, v_rejected, v_approved
  FROM public.recharge;

  SELECT COALESCE(SUM(amount), 0)
  INTO v_total_amount
  FROM public.recharge
  WHERE status = 1;

  RETURN json_build_object(
    'pending', v_pending,
    'rejected', v_rejected,
    'approved', v_approved,
    'total_amount', v_total_amount
  );
END;
$function$
;

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge
    WHERE (p_status IS NULL OR status = p_status);

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
        ORDER BY r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
        ORDER BY r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            r.id DESC
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

-- Función: process_recharge_status
CREATE OR REPLACE FUNCTION public.process_recharge_status(p_recharge_id bigint, p_action character varying, p_approved_by character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_idclient INTEGER;
    v_status INTEGER;
    v_amount NUMERIC(10,2);
    v_tasa NUMERIC(10,2);
    v_method VARCHAR(255);
    v_tickets_to_add NUMERIC(10,2) := 0.00;
    v_new_balance NUMERIC(10,2);
    v_final_status INTEGER;
    v_log_message VARCHAR(255);
BEGIN
    IF LOWER(p_action) NOT IN ('approve', 'reject') THEN
        RETURN json_build_object('success', false, 'message', 'Acción inválida. Use ''approve'' o ''reject''.');
    END IF;

    SELECT idclient, status, amount, tasa, method
    INTO v_idclient, v_status, v_amount, v_tasa, v_method
    FROM public.recharge
    WHERE id = p_recharge_id
    FOR UPDATE;

    IF v_idclient IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'La recarga especificada no existe.');
    END IF;

    IF v_status != 0 THEN
        RETURN json_build_object('success', false, 'message', 'Esta recarga ya fue procesada previamente.');
    END IF;

    IF LOWER(p_action) = 'approve' THEN
        v_final_status := 1;
        v_log_message := 'Recarga verificada y tickets acreditados con éxito.';

        v_tickets_to_add := public.calculate_tickets(v_amount, v_method, v_tasa);

        UPDATE public.clients
        SET balance = balance + v_tickets_to_add
        WHERE id = v_idclient
        RETURNING balance INTO v_new_balance;

    ELSIF LOWER(p_action) = 'reject' THEN
        v_final_status := 2;
        v_log_message := 'Recarga rechazada por el administrador. No se alteró el saldo del cliente.';

        SELECT balance INTO v_new_balance FROM public.clients WHERE id = v_idclient;
    END IF;

    UPDATE public.recharge
    SET status = v_final_status,
        "updateAprobate" = NOW(),
        "createBy" = COALESCE(p_approved_by, "createBy")
    WHERE id = p_recharge_id;

    RETURN json_build_object(
        'success', true,
        'message', v_log_message,
        'recharge_id', p_recharge_id,
        'action_executed', p_action,
        'tickets_credited', v_tickets_to_add,
        'current_client_balance', v_new_balance
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al procesar la operación: ' || SQLERRM);
END;
$function$
;

-- Función: get_reservas_detail
CREATE OR REPLACE FUNCTION public.get_reservas_detail(p_date date, p_shedule character varying)
 RETURNS TABLE(id integer, client_name text, amount numeric, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT t.id, c.name::TEXT, t.amount, t.created_at::TIMESTAMPTZ
  FROM public.transactions t
  LEFT JOIN public.clients c ON c.id = t.idclient
  WHERE t.created_at::date = p_date AND t.shedule = p_shedule
  ORDER BY t.created_at;
END;
$function$
;

-- Función: get_monthly_summary
CREATE OR REPLACE FUNCTION public.get_monthly_summary(p_year integer, p_month integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'total_transactions',   COALESCE((SELECT COUNT(*)  FROM public.transactions  WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'total_recharges',      COALESCE((SELECT COUNT(*)  FROM public.recharge       WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month), 0),
    'transactions_amount',  COALESCE((SELECT SUM(amount) FROM public.transactions WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'recharges_amount',     COALESCE((SELECT SUM(amount) FROM public.recharge    WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month), 0),
    'active_clients',       COALESCE((SELECT COUNT(DISTINCT idclient) FROM public.transactions WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'daily_data',           COALESCE((
      SELECT json_agg(json_build_object(
        'day', COALESCE(t.day, r.day),
        'transactions', COALESCE(t.count, 0),
        'transactions_amount', COALESCE(t.amount, 0),
        'recharges', COALESCE(r.count, 0),
        'recharges_amount', COALESCE(r.amount, 0)
      ) ORDER BY COALESCE(t.day, r.day))
      FROM (
        SELECT DATE(created_at) as day, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as amount
        FROM public.transactions
        WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month
        GROUP BY DATE(created_at)
      ) t
      FULL OUTER JOIN (
        SELECT date as day, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as amount
        FROM public.recharge
        WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month
        GROUP BY date
      ) r ON t.day = r.day
    ), '[]'::JSON),
    'top_clients', COALESCE((
      SELECT json_agg(json_build_object(
        'name', c.name,
        'count', t.count,
        'total', t.total
      ) ORDER BY t.total DESC)
      FROM (
        SELECT idclient, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as total
        FROM public.transactions
        WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month
        GROUP BY idclient
        ORDER BY total DESC
        LIMIT 10
      ) t
      JOIN public.clients c ON c.id = t.idclient
    ), '[]'::JSON)
  ) INTO result;
  RETURN result;
END;
$function$
;

-- Función: check_admin_profile_on_login
CREATE OR REPLACE FUNCTION public.check_admin_profile_on_login()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_is_admin BOOLEAN := false;
    v_app_name TEXT;
    v_jwt_claims JSONB;
BEGIN
    -- 🛡️ 1. DETECCIÓN RADICAL DE REGISTRO (SIGNUP)
    -- Extraemos los claims del JWT actual de la sesión de red.
    -- Si no hay JWT o si el rol del token es 'anon' (público sin loguear),
    -- significa que es un registro nuevo o una confirmación de correo. ¡Dejar pasar libre!
    BEGIN
        v_jwt_claims := auth.jwt();
    EXCEPTION WHEN OTHERS THEN
        v_jwt_claims := NULL;
    END;

    IF v_jwt_claims IS NULL OR (v_jwt_claims->>'role') = 'anon' THEN
        RETURN NEW;
    END IF;

    -- 🚀 2. PROCESAMIENTO EXCLUSIVO PARA LOGINS REALES
    -- Extraer el identificador app_source enviado desde las opciones del frontend
    v_app_name := NEW.raw_user_meta_data->>'app_source';

    -- Limpiar registros anteriores de bloqueo
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) - 'login_blocked' - 'block_reason';

    -- Si no se envía app_source en un intento de login con sesión iniciada
    IF v_app_name IS NULL OR NULLIF(TRIM(v_app_name), '') IS NULL THEN
        NEW.raw_app_meta_data := NEW.raw_app_meta_data || jsonb_build_object(
            'login_blocked', true,
            'block_reason', 'Firma de aplicacion requerida en las opciones de inicio de sesion.'
        );
        RETURN NEW;
    END IF;

    -- 🔄 3. EVALUACIÓN DE ROLES SEGÚN LA APLICACIÓN
    IF v_app_name = 'admin-app' THEN
        
        SELECT EXISTS (
            SELECT 1 
            FROM public.users_profiles  
            WHERE uid::text = NEW.id::text 
              AND role = 'admin'        
        ) INTO v_is_admin;

        IF NOT v_is_admin THEN
            NEW.raw_app_meta_data := NEW.raw_app_meta_data || jsonb_build_object(
                'login_blocked', true,
                'block_reason', 'Esta aplicacion esta reservada exclusivamente para administradores.'
            );
        END IF;

    ELSIF v_app_name = 'client-app' THEN
        RETURN NEW; -- Pasa directo
    ELSE
        NEW.raw_app_meta_data := NEW.raw_app_meta_data || jsonb_build_object(
            'login_blocked', true,
            'block_reason', 'Origen de aplicacion no autorizado.'
        );
    END IF;

    RETURN NEW;
END;
$function$
;

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge
    WHERE (p_status IS NULL OR status = p_status);

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
        ORDER BY r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
        ORDER BY r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge
    WHERE (p_status IS NULL OR status = p_status);

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
        ORDER BY r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
        ORDER BY r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
BEGIN
    v_offset := (p_page - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            json_build_object('name', c.name) AS clients
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            r.id DESC
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

-- Función: update_user_role
CREATE OR REPLACE FUNCTION public.update_user_role(user_email text, new_role text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    -- 1. Validar que el rol enviado sea uno de los permitidos
    IF LOWER(new_role) NOT IN ('student', 'driver', 'admin') THEN
        RAISE EXCEPTION 'Rol no permitido. Los roles válidos son: student, driver, admin.';
    END IF;

    -- 2. Verificar si el usuario existe en la tabla profiles
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE email = user_email) THEN
        RETURN 'ERROR: No se encontró ningún perfil asociado a ese correo electrónico.';
    END IF;

    -- 3. Actualizar el rol en la tabla pública de perfiles (casteándolo al ENUM)
    UPDATE public.profiles
    SET role = LOWER(new_role)::user_role
    WHERE email = user_email;

    -- 4. Opcional pero recomendado: Sincronizar el rol también en auth.users (raw_app_meta_data)
    -- Esto asegura que si usas RLS basados en JWT, el token del usuario se actualice en su próximo login
    UPDATE auth.users
    SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('role', LOWER(new_role))
    WHERE email = user_email;

    RETURN 'SUCCESS: El rol del usuario ha sido actualizado a ' || LOWER(new_role);
END;
$function$
;

-- Función: manage_horario
CREATE OR REPLACE FUNCTION public.manage_horario(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_shudle character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_horario JSON;
BEGIN
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
$function$
;

-- Función: manage_profile
CREATE OR REPLACE FUNCTION public.manage_profile(p_action character varying, p_user_id uuid DEFAULT NULL::uuid, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_role user_role DEFAULT NULL::user_role)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_profile JSON;
  v_auth_id UUID;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'list' THEN
    SELECT json_agg(row_to_json(p.*)) INTO v_profile FROM (
      SELECT id, email, role, updated_at
      FROM public.profiles
      ORDER BY email
    ) p;
    RETURN json_build_object('success', true, 'data', COALESCE(v_profile, '[]'::json));

  ELSIF LOWER(p_action) = 'create' THEN
    v_auth_id := gen_random_uuid();

    INSERT INTO auth.users (
      id, instance_id, email, encrypted_password,
      email_confirmed_at, raw_user_meta_data,
      created_at, updated_at, confirmation_sent_at,
      aud, role
    ) VALUES (
      v_auth_id,
      '00000000-0000-0000-0000-000000000000',
      p_email,
      crypt(p_password, gen_salt('bf')),
      NOW(),
      json_build_object('role', p_role),
      NOW(), NOW(), NOW(),
      'authenticated', 'authenticated'
    );

    INSERT INTO auth.identities (
      id, user_id, provider, identity_data,
      created_at, updated_at, last_sign_in_at
    ) VALUES (
      v_auth_id, v_auth_id, 'email',
      json_build_object('sub', v_auth_id, 'email', p_email),
      NOW(), NOW(), NOW()
    );

    SELECT row_to_json(pp.*) INTO v_profile
    FROM public.profiles pp WHERE pp.id = v_auth_id;

    RETURN json_build_object('success', true, 'data', v_profile, 'message', 'Usuario creado con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    UPDATE public.profiles
    SET role = p_role, updated_at = NOW()
    WHERE id = p_user_id
    RETURNING row_to_json(profiles.*) INTO v_profile;

    IF v_profile IS NULL THEN
      RETURN json_build_object('success', false, 'message', 'Usuario no encontrado.');
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

-- Función: manage_profile
CREATE OR REPLACE FUNCTION public.manage_profile(p_action character varying, p_user_id uuid DEFAULT NULL::uuid, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_role user_role DEFAULT NULL::user_role, p_name character varying DEFAULT NULL::character varying)
 RETURNS json
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
      aud, role
    ) VALUES (
      v_auth_id,
      '00000000-0000-0000-0000-000000000000',
      p_email,
      crypt(p_password, gen_salt('bf')),
      NOW(),
      json_build_object('sub', v_auth_id, 'user_name', p_name, 'role', p_role, 'email', p_email),
      NOW(), NOW(), NOW(),
      'authenticated', 'authenticated'
    );

    INSERT INTO auth.identities (
      id, user_id, provider, identity_data,
      created_at, updated_at, last_sign_in_at
    ) VALUES (
      v_auth_id, v_auth_id, 'email',
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
$function$
;

-- Función: manage_profile
CREATE OR REPLACE FUNCTION public.manage_profile(p_action character varying, p_user_id uuid DEFAULT NULL::uuid, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_role user_role DEFAULT NULL::user_role)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_profile JSON;
  v_auth_id UUID;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'list' THEN
    SELECT json_agg(row_to_json(p.*)) INTO v_profile FROM (
      SELECT id, email, role, updated_at
      FROM public.profiles
      ORDER BY email
    ) p;
    RETURN json_build_object('success', true, 'data', COALESCE(v_profile, '[]'::json));

  ELSIF LOWER(p_action) = 'create' THEN
    v_auth_id := gen_random_uuid();

    INSERT INTO auth.users (
      id, instance_id, email, encrypted_password,
      email_confirmed_at, raw_user_meta_data,
      created_at, updated_at, confirmation_sent_at,
      aud, role
    ) VALUES (
      v_auth_id,
      '00000000-0000-0000-0000-000000000000',
      p_email,
      crypt(p_password, gen_salt('bf')),
      NOW(),
      json_build_object('role', p_role),
      NOW(), NOW(), NOW(),
      'authenticated', 'authenticated'
    );

    INSERT INTO auth.identities (
      id, user_id, provider, identity_data,
      created_at, updated_at, last_sign_in_at
    ) VALUES (
      v_auth_id, v_auth_id, 'email',
      json_build_object('sub', v_auth_id, 'email', p_email),
      NOW(), NOW(), NOW()
    );

    SELECT row_to_json(pp.*) INTO v_profile
    FROM public.profiles pp WHERE pp.id = v_auth_id;

    RETURN json_build_object('success', true, 'data', v_profile, 'message', 'Usuario creado con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    UPDATE public.profiles
    SET role = p_role, updated_at = NOW()
    WHERE id = p_user_id
    RETURNING row_to_json(profiles.*) INTO v_profile;

    IF v_profile IS NULL THEN
      RETURN json_build_object('success', false, 'message', 'Usuario no encontrado.');
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

-- Función: manage_profile
CREATE OR REPLACE FUNCTION public.manage_profile(p_action character varying, p_user_id uuid DEFAULT NULL::uuid, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_role user_role DEFAULT NULL::user_role, p_name character varying DEFAULT NULL::character varying)
 RETURNS json
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
      aud, role
    ) VALUES (
      v_auth_id,
      '00000000-0000-0000-0000-000000000000',
      p_email,
      crypt(p_password, gen_salt('bf')),
      NOW(),
      json_build_object('sub', v_auth_id, 'user_name', p_name, 'role', p_role, 'email', p_email),
      NOW(), NOW(), NOW(),
      'authenticated', 'authenticated'
    );

    INSERT INTO auth.identities (
      id, user_id, provider, identity_data,
      created_at, updated_at, last_sign_in_at
    ) VALUES (
      v_auth_id, v_auth_id, 'email',
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
$function$
;

-- Función: get_dashboard_kpis
CREATE OR REPLACE FUNCTION public.get_dashboard_kpis()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'debtors_total',    COALESCE((SELECT SUM(balance) FROM public.clients WHERE balance < 0), 0),
    'debtors_count',    COALESCE((SELECT COUNT(*)  FROM public.clients WHERE balance < 0), 0),
    'active_clients',   COALESCE((SELECT COUNT(*)  FROM public.clients WHERE status = '0'), 0),
    'total_clients',    COALESCE((SELECT COUNT(*)  FROM public.clients), 0),
    'recharges_today',  COALESCE((SELECT COUNT(*)  FROM public.recharge  WHERE date = CURRENT_DATE), 0),
    'recharges_amount_today', COALESCE((SELECT SUM(amount) FROM public.recharge WHERE date = CURRENT_DATE), 0),
    'transactions_today', COALESCE((SELECT COUNT(*) FROM public.transactions WHERE created_at::date = CURRENT_DATE), 0)
  ) INTO result;
  RETURN result;
END;
$function$
;

-- Función: get_daily_reservas
CREATE OR REPLACE FUNCTION public.get_daily_reservas(p_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(shedule character varying, count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT t.shedule, COUNT(*)::BIGINT
  FROM public.transactions t
  WHERE t.created_at::date = p_date
  GROUP BY t.shedule
  ORDER BY t.shedule;
END;
$function$
;

-- Función: get_weekly_flow
CREATE OR REPLACE FUNCTION public.get_weekly_flow()
 RETURNS TABLE(day date, count bigint, total_amount numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT DATE(t.created_at) as day, COUNT(*)::BIGINT, COALESCE(SUM(t.amount), 0) as total_amount
  FROM public.transactions t
  WHERE t.created_at >= NOW() - INTERVAL '7 days'
  GROUP BY DATE(t.created_at)
  ORDER BY day;
END;
$function$
;

-- Función: get_recent_movements
CREATE OR REPLACE FUNCTION public.get_recent_movements(p_limit integer DEFAULT 5)
 RETURNS TABLE(id bigint, type text, description text, amount numeric, created_at timestamp with time zone, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT sub.id, sub.type, sub.description, sub.amount, sub.created_at, sub.client_name
  FROM (
    SELECT t.id, 'transaction'::TEXT as type,
           COALESCE(t.shedule, 'Sin horario')::TEXT as description,
           t.amount, t.created_at::TIMESTAMPTZ, c.name::TEXT as client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON c.id = t.idclient
    UNION ALL
    SELECT r.id, 'recharge'::TEXT as type,
           ('Recarga #' || r.id)::TEXT as description,
           r.amount, r."createAt"::TIMESTAMPTZ, c.name::TEXT as client_name
    FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
  ) sub
  ORDER BY sub.created_at DESC
  LIMIT p_limit;
END;
$function$
;

-- >>> POLÍTICAS DE SEGURIDAD (RLS) <<<

-- Política para: clients
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Permitir lectura general de clientes" ON public.clients;
CREATE POLICY "Permitir lectura general de clientes" ON public.clients FOR SELECT TO authenticated USING (true);

-- Política para: clients
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Permitir lectura por email" ON public.clients;
CREATE POLICY "Permitir lectura por email" ON public.clients FOR SELECT TO authenticated USING (((email)::text = (auth.jwt() ->> 'email'::text)));

-- Política para: units
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Permitir lectura general de unidades" ON public.units;
CREATE POLICY "Permitir lectura general de unidades" ON public.units FOR SELECT TO authenticated USING (true);

-- Política para: company
ALTER TABLE public.company ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "company_delete_admin" ON public.company;
CREATE POLICY "company_delete_admin" ON public.company FOR DELETE TO authenticated USING (is_admin());

-- Política para: company
ALTER TABLE public.company ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "company_insert_admin" ON public.company;
CREATE POLICY "company_insert_admin" ON public.company FOR INSERT TO authenticated USING (null) WITH CHECK (is_admin());

-- Política para: company
ALTER TABLE public.company ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "company_select_all" ON public.company;
CREATE POLICY "company_select_all" ON public.company FOR SELECT TO authenticated USING (true);

-- Política para: company
ALTER TABLE public.company ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "company_update_admin" ON public.company;
CREATE POLICY "company_update_admin" ON public.company FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política para: profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Usuarios leen su propio perfil" ON public.profiles;
CREATE POLICY "Usuarios leen su propio perfil" ON public.profiles FOR SELECT TO authenticated USING ((id = auth.uid()));

-- Política para: transactions
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Usuarios ven lo suyo o Admins ven todo" ON public.transactions;
CREATE POLICY "Usuarios ven lo suyo o Admins ven todo" ON public.transactions FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM clients
  WHERE (clients.id = transactions.idclient))) OR (COALESCE(((auth.jwt() ->> 'is_super_admin'::text))::boolean, false) = true)));

-- Política para: horario
ALTER TABLE public.horario ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "horario_delete_admin" ON public.horario;
CREATE POLICY "horario_delete_admin" ON public.horario FOR DELETE TO authenticated USING (is_admin());

-- Política para: horario
ALTER TABLE public.horario ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "horario_insert_admin" ON public.horario;
CREATE POLICY "horario_insert_admin" ON public.horario FOR INSERT TO authenticated USING (null) WITH CHECK (is_admin());

-- Política para: horario
ALTER TABLE public.horario ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "horario_select_all" ON public.horario;
CREATE POLICY "horario_select_all" ON public.horario FOR SELECT TO authenticated USING (true);

-- Política para: horario
ALTER TABLE public.horario ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "horario_update_admin" ON public.horario;
CREATE POLICY "horario_update_admin" ON public.horario FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_delete_all" ON public.solicitude;
CREATE POLICY "admin_delete_all" ON public.solicitude FOR DELETE TO public USING (is_admin());

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_insert_all" ON public.solicitude;
CREATE POLICY "admin_insert_all" ON public.solicitude FOR INSERT TO public USING (null) WITH CHECK (is_admin());

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_select_all" ON public.solicitude;
CREATE POLICY "admin_select_all" ON public.solicitude FOR SELECT TO public USING (is_admin());

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_update_all" ON public.solicitude;
CREATE POLICY "admin_update_all" ON public.solicitude FOR UPDATE TO public USING (is_admin()) WITH CHECK (is_admin());

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "users_insert_own" ON public.solicitude;
CREATE POLICY "users_insert_own" ON public.solicitude FOR INSERT TO public USING (null) WITH CHECK ((idclient = get_my_client_id()));

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "users_select_own" ON public.solicitude;
CREATE POLICY "users_select_own" ON public.solicitude FOR SELECT TO public USING ((idclient = get_my_client_id()));

-- Política para: solicitude
ALTER TABLE public.solicitude ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "users_update_own" ON public.solicitude;
CREATE POLICY "users_update_own" ON public.solicitude FOR UPDATE TO public USING ((idclient = get_my_client_id())) WITH CHECK ((idclient = get_my_client_id()));

-- >>> TRIGGERS <<<

-- Trigger: on_auth_user_created sobre users
DROP TRIGGER IF EXISTS on_auth_user_created ON users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION handle_new_user();

