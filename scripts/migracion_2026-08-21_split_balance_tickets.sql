-- =====================================================
-- MIGRACION: Dual Field -- balance (USD) + tickets (units)
-- Fecha: 2026-08-21
-- Proposito: Separar clients.balance (USD money) de
--            clients.tickets (ticket units). Ambos
--            campos se mantienen sincronizados en RPCs.
-- =====================================================

BEGIN;

-- -------------------------------------------------------
-- A: Schema -- nueva columna tickets
-- -------------------------------------------------------
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS tickets NUMERIC(10,2) NOT NULL DEFAULT 0.00;

-- -------------------------------------------------------
-- B: Migracion de datos
-- -------------------------------------------------------
-- B1: Copiar balance actual (tickets) -> tickets
UPDATE public.clients SET tickets = balance;

-- B2: Convertir balance a USD (balance * company.ticket)
UPDATE public.clients
SET balance = balance * (SELECT ticket FROM public.company LIMIT 1);

-- -------------------------------------------------------
-- C: Helper function
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.calculate_tickets_from_amount(numeric);
CREATE OR REPLACE FUNCTION public.calculate_tickets_from_amount(p_amount_usd numeric)
 RETURNS numeric(10,2)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RAISE EXCEPTION 'Precio de ticket no configurado en company.ticket';
    END IF;
    RETURN TRUNC(p_amount_usd / v_ticket_price, 2);
END;
$function$
;

-- -------------------------------------------------------
-- D: process_recharge_status
-- Aprobar: balance += amount (USD), tickets += calculated
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.process_recharge_status(bigint, character varying, character varying);
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
    v_new_tickets NUMERIC(10,2);
    v_final_status INTEGER;
    v_log_message VARCHAR(255);
    v_ticket_price NUMERIC(10,2);
BEGIN
    IF LOWER(p_action) NOT IN ('approve', 'reject') THEN
        RETURN json_build_object('success', false, 'message', 'Accion invalida. Use approve o reject.');
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

    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    IF LOWER(p_action) = 'approve' THEN
        v_final_status := 1;
        v_log_message := 'Recarga verificada y saldo acreditado con exito.';
        v_tickets_to_add := public.calculate_tickets_from_amount(v_amount);

        UPDATE public.clients
        SET balance = balance + v_amount,
            tickets = tickets + v_tickets_to_add
        WHERE id = v_idclient
        RETURNING balance, tickets INTO v_new_balance, v_new_tickets;

    ELSIF LOWER(p_action) = 'reject' THEN
        v_final_status := 2;
        v_log_message := 'Recarga rechazada. No se altero el saldo.';
        SELECT balance, tickets INTO v_new_balance, v_new_tickets FROM public.clients WHERE id = v_idclient;
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
        'amount_credited', v_amount,
        'tickets_credited', v_tickets_to_add,
        'current_client_balance', v_new_balance,
        'current_client_tickets', v_new_tickets
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al procesar: ' || SQLERRM);
END;
$function$
;

-- -------------------------------------------------------
-- E: charge_tickets_bulk
-- Cobro: balance -= (qty * company.ticket), tickets -= qty
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer);
CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(p_transactions jsonb, p_create_by integer, p_idunit integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_item JSONB;
    v_client_uid VARCHAR(255);
    v_ticket_count INTEGER;
    v_shedule VARCHAR(255);
    v_client_id BIGINT;
    v_client_name VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_current_tickets NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_new_tickets NUMERIC(10,2);
    v_charge_usd NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
    v_is_admin BOOLEAN;
    v_idunit INTEGER;
    v_idroute BIGINT;
    v_ticket_price NUMERIC(10,2);
    v_processed_count INTEGER := 0;
    v_response_data JSONB := '[]'::jsonb;
BEGIN
    v_is_admin := public.is_admin();
    v_idunit := COALESCE(p_idunit, p_create_by);
    SELECT idroute INTO v_idroute FROM public.units WHERE id = v_idunit;
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        v_client_uid := v_item->>'client_uid';
        v_ticket_count := (v_item->>'ticket_count')::INTEGER;
        v_shedule := v_item->>'shedule';

        IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
            RAISE EXCEPTION 'Registro invalido. Verifique UIDs y cantidades.';
        END IF;

        SELECT id, balance, tickets, "creditLimit", name
        INTO v_client_id, v_current_balance, v_current_tickets, v_credit_limit_raw, v_client_name
        FROM public.clients WHERE uid = v_client_uid FOR UPDATE;

        IF v_client_id IS NULL THEN
            RAISE EXCEPTION 'El cliente con UID % no existe.', v_client_uid;
        END IF;

        v_charge_usd := v_ticket_count * v_ticket_price;
        v_new_balance := v_current_balance - v_charge_usd;
        v_new_tickets := v_current_tickets - v_ticket_count;
        v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Saldo insuficiente. $% Saldo: $% (% tickets), Cargo: $% (% tickets).',
                v_client_name, v_current_balance, v_current_tickets, v_charge_usd, v_ticket_count;
        END IF;

        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        UPDATE public.clients SET balance = v_new_balance, tickets = v_new_tickets WHERE id = v_client_id;

        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || v_processed_count::TEXT;

        INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", idunit, idroute, created_at)
        VALUES (v_tx_uid, v_client_id, p_create_by, v_charge_usd, 0, v_shedule, v_new_balance, v_idunit, v_idroute, NOW());

        v_response_data := v_response_data || jsonb_build_object(
            'client_uid', v_client_uid, 'new_balance', v_new_balance, 'new_tickets', v_new_tickets, 'booking_count', v_count_booking
        );
        v_processed_count := v_processed_count + 1;
    END LOOP;

    RETURN json_build_object('success', true, 'message', 'Lote procesado.', 'processed_records', v_processed_count, 'details', v_response_data);
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Rollback: ' || SQLERRM, 'processed_records', 0, 'details', '[]'::json);
END;
$function$
;

-- -------------------------------------------------------
-- F: add_tickets_to_client
-- Suma tickets + calcula y suma USD a balance
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.add_tickets_to_client(integer, integer, integer);
CREATE OR REPLACE FUNCTION public.add_tickets_to_client(p_idclient integer, p_ticket_count integer, p_create_by integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
    v_client_name VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_current_tickets NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_new_tickets NUMERIC(10,2);
    v_add_usd NUMERIC(10,2);
    v_ticket_price NUMERIC(10,2);
    v_tx_uid VARCHAR(255);
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores.');
    END IF;
    IF p_ticket_count IS NULL OR p_ticket_count <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'La cantidad debe ser mayor a cero.');
    END IF;

    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    SELECT name, balance, tickets INTO v_client_name, v_current_balance, v_current_tickets
    FROM public.clients WHERE id = p_idclient FOR UPDATE;

    IF v_client_name IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    v_add_usd := p_ticket_count * v_ticket_price;
    v_new_balance := v_current_balance + v_add_usd;
    v_new_tickets := v_current_tickets + p_ticket_count;

    UPDATE public.clients SET balance = v_new_balance, tickets = v_new_tickets WHERE id = p_idclient;

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || '0';
    INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", created_at, idunit)
    VALUES (v_tx_uid, p_idclient, p_create_by, v_add_usd, 0, 'Asignacion', v_new_balance, NOW(), 0);

    RETURN json_build_object('success', true, 'message', 'Tickets agregados.', 'new_balance', v_new_balance, 'new_tickets', v_new_tickets);
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;$function$
;

-- -------------------------------------------------------
-- G: charge_ticket (DEPRECATED)
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.charge_ticket(varchar, integer, varchar, integer);
CREATE OR REPLACE FUNCTION public.charge_ticket(p_client_uid character varying, p_ticket_count integer, p_shedule character varying, p_create_by integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_id BIGINT;
    v_current_balance NUMERIC(10,2);
    v_current_tickets NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_ticket_price NUMERIC(10,2);
    v_total_amount_usd NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_new_tickets NUMERIC(10,2);
    v_count_booking INTEGER;
    v_status INTEGER := 0;
    v_tx_uid VARCHAR(255);
BEGIN
    SELECT id, balance, tickets, "creditLimit"
    INTO v_client_id, v_current_balance, v_current_tickets, v_credit_limit_raw
    FROM public.clients WHERE uid = p_client_uid FOR UPDATE;

    IF v_client_id IS NULL THEN
        RETURN json_build_object('success', false, 'data', NULL, 'message', 'No existe el cliente');
    END IF;

    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object('success', false, 'data', NULL, 'message', 'Configuracion de ticket invalida.');
    END IF;

    v_total_amount_usd := p_ticket_count * v_ticket_price;
    v_new_balance := v_current_balance - v_total_amount_usd;
    v_new_tickets := v_current_tickets - p_ticket_count;
    v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

    IF v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
        RETURN json_build_object('booking', 0, 'success', false,
            'data', json_build_object('id', v_client_id, 'balance', v_current_balance, 'tickets', v_current_tickets),
            'message', 'Saldo insuficiente');
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_count_booking
    FROM public.solicitude WHERE idclient = v_client_id AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT;

    UPDATE public.clients SET balance = v_new_balance, tickets = v_new_tickets WHERE id = v_client_id;

    INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", idunit, created_at)
    VALUES (v_tx_uid, v_client_id, p_create_by, v_total_amount_usd, v_status, p_shedule, v_new_balance, 1, NOW());

    RETURN json_build_object('booking', v_count_booking, 'success', true,
        'data', json_build_object('id', v_client_id, 'balance', v_new_balance, 'tickets', v_new_tickets, 'uid', p_client_uid),
        'message', 'success');
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('booking', 0, 'success', false, 'data', NULL, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- -------------------------------------------------------
-- H: handle_new_user trigger -- INSERT with tickets
-- -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_raw_name TEXT;
  v_raw_full_name text;
  v_name TEXT;
  v_phone TEXT;
  v_photo_url text;
  v_document_id TEXT;
  v_carrer TEXT;
  v_role TEXT;
  v_role_enum public.user_role;
BEGIN
  v_role := LOWER(COALESCE(NEW.raw_user_meta_data->>'role', 'student'));
  v_role_enum := CASE v_role
    WHEN 'admin' THEN 'admin'::public.user_role
    WHEN 'student' THEN 'student'::public.user_role
    WHEN 'driver' THEN 'driver'::public.user_role
    WHEN 'supervisor' THEN 'supervisor'::public.user_role
    ELSE 'student'::public.user_role
  END;
  v_raw_name := COALESCE(NEW.raw_user_meta_data->>'user_name', 'usuario');
  v_raw_full_name := COALESCE(NEW.raw_user_meta_data->>'name', v_raw_name);
  v_photo_url := NULLIF(NEW.raw_user_meta_data->>'photo_url', '');
  v_name := LOWER(regexp_replace(v_raw_name, '[^a-zA-Z0-9]', '', 'g'));
  IF v_name = '' OR v_name IS NULL THEN
    v_name := LOWER(regexp_replace(split_part(NEW.email, '@', 1), '[^a-zA-Z0-9]', '', 'g'));
  END IF;

  INSERT INTO public.profiles (id, email, role, name, updated_at)
  VALUES (NEW.id, NEW.email, v_role_enum, v_name, NOW());

  IF v_role = 'student' THEN
    v_phone := COALESCE(NEW.raw_user_meta_data->>'phone', '');
    v_document_id := COALESCE(NEW.raw_user_meta_data->>'document_id', '');
    v_carrer := NEW.raw_user_meta_data->>'carrer';

    INSERT INTO public.clients (
      name, phone, "documentID", email, "creditLimit", status, "createBy",
      carrer, photo_url, balance, tickets, uid, idroute
    ) VALUES (
      v_raw_full_name, v_phone, v_document_id, NEW.email, 0, '2', 'App',
      v_carrer, v_photo_url, 0, 0, NEW.id,
      NULLIF(NEW.raw_user_meta_data->>'idroute', '')::bigint
    );
  END IF;

  RETURN NEW;
END;
$function$
;

-- -------------------------------------------------------
-- I: get_client_balance
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_balance(integer);
CREATE OR REPLACE FUNCTION public.get_client_balance(p_client_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_balance NUMERIC;
    v_tickets NUMERIC;
BEGIN
    SELECT balance, tickets INTO v_balance, v_tickets FROM public.clients WHERE id = p_client_id;
    IF v_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado.');
    END IF;
    RETURN json_build_object('success', true, 'balance', v_balance, 'tickets', v_tickets);
END;
$function$
;

-- -------------------------------------------------------
-- J: get_client_by_uid
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_by_uid(varchar);
CREATE OR REPLACE FUNCTION public.get_client_by_uid(p_uid character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_id BIGINT;
    v_name VARCHAR(255);
    v_balance NUMERIC(10,2);
    v_tickets NUMERIC(10,2);
    v_document_id VARCHAR(255);
    v_photo_url VARCHAR(1000);
BEGIN
    SELECT id, name, balance, tickets, "documentID", photo_url
    INTO v_client_id, v_name, v_balance, v_tickets, v_document_id, v_photo_url
    FROM public.clients WHERE uid = p_uid LIMIT 1;

    IF v_client_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado');
    END IF;

    RETURN json_build_object('success', true, 'data', json_build_object(
        'id', v_client_id, 'name', v_name, 'documentID', v_document_id,
        'photo_url', v_photo_url, 'balance', v_balance, 'tickets', v_tickets
    ));
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- -------------------------------------------------------
-- K: get_debtors_list
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_debtors_list();
CREATE OR REPLACE FUNCTION public.get_debtors_list()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores.');
    END IF;

    SELECT json_agg(row_to_json(d.*)) INTO v_data FROM (
        SELECT id, name, "documentID", balance, tickets
        FROM public.clients WHERE balance < 0 ORDER BY balance ASC
    ) d;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- -------------------------------------------------------
-- L: get_client_history
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_history(integer, text, text);
CREATE OR REPLACE FUNCTION public.get_client_history(p_client_id integer, p_from text DEFAULT NULL, p_to text DEFAULT NULL)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_recharges json;
  v_transactions json;
  v_total_transactions numeric;
  v_from timestamp;
  v_to timestamp;
begin
  v_from := COALESCE(p_from::timestamp, (date_trunc('month', CURRENT_DATE))::timestamp);
  v_to := COALESCE(p_to::timestamp, NOW()::timestamp);

  select coalesce(json_agg(r.*), '[]'::json) into v_recharges
  from (
    select r.id, r.amount, r.tasa, r.method, r.date, r.status, r.tickets, r."createBy", r."createAt", r.ref
    from public.recharge r
    where r.idclient = p_client_id
      and r.created_at::timestamp >= v_from
      and r.created_at::timestamp <= v_to
    order by r.id desc
  ) r;

  select coalesce(json_agg(t.*), '[]'::json) into v_transactions
  from (
    select t.uid, t.amount, t.status, t.shedule, t."newBalanceClient", t."createBy", t.created_at, t.idroute, t.idunit
    from public.transactions t
    where t.idclient = p_client_id
      and t.created_at::timestamp >= v_from
      and t.created_at::timestamp <= v_to
    order by t.id desc
  ) t;

  select coalesce(sum(amount), 0.00) into v_total_transactions
  from public.transactions
  where idclient = p_client_id
    and created_at::timestamp >= v_from
    and created_at::timestamp <= v_to;

  return json_build_object(
    'recharges', coalesce(v_recharges, '[]'::json),
    'transactions', coalesce(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions,
    'current_balance', (SELECT balance FROM public.clients WHERE id = p_client_id),
    'current_tickets', (SELECT tickets FROM public.clients WHERE id = p_client_id)
  );
end;
$function$
;

-- -------------------------------------------------------
-- M: process_payment
-- -------------------------------------------------------
DROP FUNCTION IF EXISTS public.process_payment(integer, numeric, character varying, numeric, text, text, text);
CREATE OR REPLACE FUNCTION public.process_payment(p_idclient integer, p_amount numeric, p_method character varying, p_tasa numeric, p_date text, p_ref text DEFAULT NULL::text, p_picture text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_current_balance NUMERIC(10,2);
    v_current_tickets NUMERIC(10,2);
    v_recharge_id BIGINT;
    v_amount_in_usd NUMERIC(10,2);
    v_estimated_tickets NUMERIC(10,2);
    v_calc JSON;
    v_idroute BIGINT;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    IF p_amount <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'El monto debe ser mayor a cero.');
    END IF;

    SELECT balance, tickets, idroute INTO v_current_balance, v_current_tickets, v_idroute FROM public.clients WHERE id = p_idclient;
    IF v_current_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    IF p_idroute IS NOT NULL THEN
        v_idroute := p_idroute;
    END IF;

    v_calc := public.calculate_tickets(p_amount, v_idroute);
    IF (v_calc->>'success')::boolean = false THEN
        RETURN json_build_object('success', false, 'message', v_calc->>'message');
    END IF;

    v_amount_in_usd := (v_calc->>'usd_amount')::NUMERIC;
    v_estimated_tickets := (v_calc->>'estimated_tickets')::NUMERIC;

    INSERT INTO public.recharge (idclient, method, ref, picture, amount, tasa, date, status, "createBy", "createAt", codigo_banco, idroute, tickets, idshedule)
    VALUES (p_idclient, p_method, NULLIF(p_ref, ''), NULLIF(p_picture, ''), v_amount_in_usd, p_tasa, p_date, 0, p_idclient, NOW(), NULL, v_idroute, v_estimated_tickets, NULL)
    RETURNING id INTO v_recharge_id;

    RETURN json_build_object(
        'success', true,
        'message', 'Pago registrado. En espera de verificacion.',
        'recharge_id', v_recharge_id,
        'estimated_tickets', v_estimated_tickets,
        'current_balance', v_current_balance,
        'current_tickets', v_current_tickets
    );
EXCEPTION
    WHEN SQLSTATE '23505' THEN
        RETURN json_build_object('success', false, 'message', 'Referencia duplicada.');
    WHEN OTHERS THEN
        RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;



-- Función: get_clients_paginated
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
    WHERE (v_search IS NULL OR c.name ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search OR c."documentID" ILIKE v_search)
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
            au.raw_user_meta_data->>'user_name' AS auth_user_name
        FROM public.clients c
        LEFT JOIN public.routes rt ON rt.id = c.idroute
        LEFT JOIN auth.users au ON au.id = c.uid::uuid
        WHERE (v_search IS NULL OR c.name ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search OR c."documentID" ILIKE v_search)
          AND (p_status IS NULL OR c.status = p_status)
          AND (p_idroute IS NULL OR c.idroute = p_idroute)
          AND (public.is_admin() OR c.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'ASC'  THEN c.id                 END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'DESC' THEN c.id                 END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'name'       AND p_sort_order = 'ASC'  THEN c.name               END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'name'       AND p_sort_order = 'DESC' THEN c.name               END DESC NULLS LAST,
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

-- Función: get_complete_user_profile
CREATE OR REPLACE FUNCTION public.get_complete_user_profile(p_uuid text, p_email text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_role TEXT;
BEGIN
    SELECT role::text INTO v_role FROM public.profiles WHERE id = p_uuid::uuid;

    IF v_role = 'driver' THEN
        SELECT row_to_json(driver_row) INTO v_result
        FROM (
            SELECT
                u.id AS idclient,
                p.id AS uuid,
                COALESCE(u.driver, u.name) AS name,
                p.email,
                ''::character varying AS phone,
                0 AS saldo,
                NOW()::timestamp without time zone AS created_at,
                p.role,
                u.photo_url,
                u.id AS unit_id,
                u.name AS unit_name,
                u.number AS unit_number,
                u.plate AS unit_plate,
                u.status AS unit_status,
                r.id AS route_id,
                r.code AS route_code,
                r.description AS route_description
            FROM public.units u
            INNER JOIN public.profiles p ON LOWER(p.email) = LOWER(u.email)
            LEFT JOIN public.routes r ON r.id = u.idroute
            WHERE p.id = p_uuid::uuid AND LOWER(u.email) = LOWER(p_email)
            LIMIT 1
        ) driver_row;
    ELSE
        SELECT row_to_json(profile_row) INTO v_result
        FROM (
            SELECT
                COALESCE(c.id, 0) AS idclient,
                p.id AS uuid,
                COALESCE(c.name, SPLIT_PART(p.email, '@', 1)) AS name,
                COALESCE(c.email, p.email) AS email,
                c.phone,
                c."documentID",
                c."creditLimit",
                c.status,
                c.carrer,
                c.balance AS saldo,
                c.tickets AS tickets,
                COALESCE(c."createAt", NOW()) AS created_at,
                p.role,
                c.photo_url
            FROM public.profiles p
            LEFT JOIN public.clients c ON p.id = c.uid::uuid AND c.email = p_email
            WHERE p.id = p_uuid::uuid
            LIMIT 1
        ) profile_row;
    END IF;

    RETURN COALESCE(v_result, '{}'::json);
END;
$function$
;

-- -------------------------------------------------------
-- N: Verificacion post-migracion
-- -------------------------------------------------------
DO $$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_total_balance NUMERIC(12,2);
    v_total_tickets NUMERIC(12,2);
    v_total_clients INTEGER;
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    SELECT COUNT(*), COALESCE(SUM(balance), 0), COALESCE(SUM(tickets), 0)
    INTO v_total_clients, v_total_balance, v_total_tickets
    FROM public.clients;

    RAISE NOTICE '=== POST-MIGRATION VERIFICATION ===';
    RAISE NOTICE 'company.ticket: %', v_ticket_price;
    RAISE NOTICE 'Total clients: %', v_total_clients;
    RAISE NOTICE 'Total balance (USD): %', v_total_balance;
    RAISE NOTICE 'Total tickets: %', v_total_tickets;
    RAISE NOTICE '====================================';
END $$;

COMMIT;
