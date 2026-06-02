CREATE OR REPLACE FUNCTION public.get_client_history(
  p_client_id integer, 
  p_from timestamp, 
  p_to timestamp,
  p_status integer default null 
) 
returns json as $$
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
$$ 
language plpgsql
SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
-- Índice para transacciones
create index idx_transactions_client_date on transactions (idclient, created_at);

-- Índice para recargas (atención a la columna entre comillas)
create index idx_recharge_client_date on recharge (idclient, "createAt");
-- 1. LIMPIEZA DE FIRMAS ANTERIORES (Obligatorio porque cambiamos la cantidad de parámetros)
DROP FUNCTION IF EXISTS public.get_clients_transactions(INT, TIMESTAMP, TIMESTAMP, INT);
DROP FUNCTION IF EXISTS public.get_clients_transactions(INT, TIMESTAMP, TIMESTAMP, INT, VARCHAR);

-- 2. CREACIÓN DE LA FUNCIÓN CON PARÁMETROS OPCIONALES
CREATE OR REPLACE FUNCTION public.get_clients_transactions(
  p_from TIMESTAMP, 
  p_to TIMESTAMP,
  p_client_id INTEGER DEFAULT NULL,    -- 👈 Ahora es opcional y se puede omitir
  p_status INTEGER DEFAULT NULL,       -- 👈 Ya era opcional
  p_create_by INTEGER DEFAULT NULL    -- 👈 Nuevo parámetro opcional
) 
RETURNS JSON AS $$
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
$$ 
LANGUAGE plpgsql
SECURITY DEFINER;

-- Sincronizar API de Supabase
NOTIFY pgrst, 'reload schema';
--Funcion para obtener el perfil del usuario con role y todo
-- 2. Creación de la función adaptada a tu estructura real
CREATE OR REPLACE FUNCTION public.get_complete_user_profile(
    p_uuid TEXT, 
    p_email TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER 
AS $$
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
$$;




CREATE OR REPLACE FUNCTION public.process_payment(
    p_idclient INTEGER,
    p_amount NUMERIC,
    p_method VARCHAR,
    p_ref VARCHAR DEFAULT NULL,
    p_tasa NUMERIC DEFAULT NULL,
    p_date DATE DEFAULT CURRENT_DATE,
    p_picture VARCHAR DEFAULT NULL,
    p_create_by VARCHAR DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER 
AS $$
DECLARE
    v_current_balance NUMERIC(10,2);-- 👈 Para obtener el saldo actual sin alterarlo
    v_recharge_id BIGINT;
    v_amount_to_add NUMERIC(10,2); -- Monto convertido temporal (tickets estimados)
    v_price_ticket NUMERIC(10,2);  
BEGIN
    -- 🛡️ Validaciones de negocio preliminares
    IF p_amount <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'El monto de la recarga debe ser mayor a cero.');
    END IF;

    -- 🔍 Buscar el cliente y almacenar su saldo actual
    SELECT balance INTO v_current_balance FROM public.clients WHERE id = p_idclient;

    IF v_current_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente especificado no existe.');
    END IF;

    -- 🏢 1. Obtener el precio del ticket desde la tabla 'company'
    SELECT ticket INTO v_price_ticket FROM public.company LIMIT 1;

    -- Validar que exista la empresa y que el precio del ticket sea válido
    IF v_price_ticket IS NULL OR v_price_ticket <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'Error de configuración: El precio del ticket en la empresa no es válido o está en cero.');
    END IF;

    -- 🧮 2. Determinar el monto base según el método de pago (Efectivo o Bs)
    IF LOWER(p_method) = 'efectivo' THEN
        v_amount_to_add := p_amount;
    ELSE
        -- Validación para pagos en Bs
        IF p_tasa IS NULL OR p_tasa <= 0 THEN
            RETURN json_build_object('success', false, 'message', 'Para pagos en Bs se requiere una tasa válida mayor a cero.');
        END IF;
        
        v_amount_to_add := p_amount / p_tasa;
    END IF;

    -- 🎫 3. Ajustar el monto neto final dividiéndolo entre el precio del ticket (Cálculo de tickets estimados)
    v_amount_to_add := v_amount_to_add / v_price_ticket;

    -- 📝 4. Insertar el registro histórico en tu tabla 'recharge' (Con status 0 = Pendiente)
    INSERT INTO public.recharge (
        idclient, 
        method, 
        ref, 
        picture, 
        amount, -- Guarda el monto original enviado desde Vue
        tasa, 
        date, 
        status, -- 👈 Permanece en 0 (Pendiente de verificación)
        "createBy",
        "createAt"
    )
    VALUES (
        p_idclient, 
        p_method, 
        NULLIF(p_ref, ''), 
        NULLIF(p_picture, ''), 
        p_amount, 
        p_tasa, 
        p_date, 
        0, 
        p_create_by,
        NOW()
    )
    RETURNING id INTO v_recharge_id;

    -- 💰 5. SE REMOVIÓ EL UPDATE DE CLIENTS
    -- El saldo permanece intacto hasta la aprobación manual del administrador.

    -- 🎯 6. Responder con éxito de registro y los cálculos estimados en el JSON
    RETURN json_build_object(
        'success', true,
        'message', 'Pago registrado exitosamente. En espera por verificación administrativa.', -- 👈 Mensaje coherente
        'recharge_id', v_recharge_id,
        'estimated_tickets', ROUND(v_amount_to_add, 2),  -- Cantidad de tickets que se le sumarán al verificar
        'current_balance', v_current_balance -- 👈 Se devuelve su saldo real actual intacto
    );

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en transacción: ' || SQLERRM);
END;
$$;

-- 3. Sincronizar API de Supabase
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- RPC: get_recharge_stats
-- Retorna conteos agrupados por status + monto total aprobado
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_recharge_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
$$;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- RPC: get_recharges_paginated
-- Retorna recargas paginadas con nombre del cliente (JOIN)
-- Sort whitelist: id, date, amount, method, status, client_name
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(
    p_page INTEGER DEFAULT 1,
    p_per_page INTEGER DEFAULT 10,
    p_status INTEGER DEFAULT NULL,
    p_date_from DATE DEFAULT NULL,
    p_date_to DATE DEFAULT NULL,
    p_method VARCHAR DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'id',
    p_sort_order TEXT DEFAULT 'DESC'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
$$;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- Función helper: calculate_tickets
-- Convierte monto + método + tasa a tickets según precio actual
-- ============================================================
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
$function$;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- RPC: process_recharge_status
-- Aprueba o rechaza una recarga, acredita tickets al cliente
-- ============================================================
CREATE OR REPLACE FUNCTION public.process_recharge_status(
    p_recharge_id bigint,
    p_action character varying,
    p_approved_by character varying DEFAULT NULL::character varying
)
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
$function$;

NOTIFY pgrst, 'reload schema';