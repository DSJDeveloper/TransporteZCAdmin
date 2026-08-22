-- ============================================================
-- MIGRACION: Dual Fields en transactions
-- Fecha: 2026-08-21
-- Descripcion:
--   A) Agrega columnas ticket (units) y "newTicketsClient" (units)
--   B) Migracion historica: backup + conversion USD
--   C) Reescritura de RPCs de cobro (INSERT con 4 campos)
--   D) Reescritura de RPCs de lectura (SELECT con 4 campos)
--   E) Funciones resumen (SUM, paginadas, export)
-- ============================================================

BEGIN;

-- ============================================================
-- A: Schema — nuevas columnas en transactions
-- ============================================================
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ticket NUMERIC(10,2) NOT NULL DEFAULT 0.00;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS "newTicketsClient" NUMERIC(10,2) NOT NULL DEFAULT 0.00;

-- ============================================================
-- B: Migracion historica de datos
-- ============================================================
-- B1: Copiar valores actuales (ya en USD) como backup de unidades
UPDATE public.transactions SET ticket = amount, "newTicketsClient" = "newBalanceClient";

-- B2: Re-multiplicar amount y newBalanceClient por company.ticket
UPDATE public.transactions
SET amount = amount * COALESCE((SELECT ticket FROM public.company LIMIT 1), 0),
    "newBalanceClient" = "newBalanceClient" * COALESCE((SELECT ticket FROM public.company LIMIT 1), 0);

-- ============================================================
-- C: Reescritura de RPCs de cobro (INSERT con 4 campos)
-- ============================================================

-- C1. charge_tickets_bulk (refactored — p_idstop + dual fields)
DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer);
CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(
    p_transactions jsonb,
    p_create_by    integer,
    p_idunit       integer DEFAULT NULL::integer,
    p_idstop       bigint  DEFAULT NULL::bigint
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_item            JSONB;
    v_client_uid      VARCHAR(255);
    v_ticket_count    INTEGER;
    v_shedule         VARCHAR(255);
    v_client_id       BIGINT;
    v_client_name     VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_current_tickets NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit    NUMERIC(10,2);
    v_new_balance     NUMERIC(10,2);
    v_new_tickets     NUMERIC(10,2);
    v_charge_usd      NUMERIC(10,2);
    v_tickets_to_deduct NUMERIC(10,2);
    v_count_booking   INTEGER;
    v_tx_uid          VARCHAR(255);
    v_is_admin        BOOLEAN;
    v_idunit          INTEGER;
    v_idroute         BIGINT;
    v_company_ticket  NUMERIC(10,2);
    v_unit_fare       NUMERIC(10,2);
    v_processed_count INTEGER := 0;
    v_response_data   JSONB := '[]'::jsonb;
BEGIN
    v_is_admin := public.is_admin();
    v_idunit   := COALESCE(p_idunit, p_create_by);

    SELECT idroute INTO v_idroute
    FROM public.units
    WHERE id = v_idunit;

    -- Company base ticket price (fallback)
    SELECT ticket INTO v_company_ticket
    FROM public.company
    LIMIT 1;

    IF v_company_ticket IS NULL OR v_company_ticket <= 0 THEN
        RAISE EXCEPTION 'Error de configuracion: company.ticket no valido (%).', v_company_ticket;
    END IF;

    -- Resolve unit fare: stop price or company base
    IF p_idstop IS NOT NULL THEN
        SELECT rs.price INTO v_unit_fare
        FROM public.route_stops rs
        WHERE rs.id = p_idstop;

        IF v_unit_fare IS NULL THEN
            RAISE EXCEPTION 'La parada con id % no existe en route_stops.', p_idstop;
        END IF;

        IF v_unit_fare <= 0 THEN
            RAISE EXCEPTION 'El precio de la parada % es invalido (%).', p_idstop, v_unit_fare;
        END IF;
    ELSE
        v_unit_fare := v_company_ticket;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        v_client_uid   := v_item->>'client_uid';
        v_ticket_count := (v_item->>'ticket_count')::INTEGER;
        v_shedule      := v_item->>'shedule';

        IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
            RAISE EXCEPTION 'Registro invalido. Verifique UIDs y cantidades.';
        END IF;

        SELECT id, balance, tickets, "creditLimit", name
        INTO v_client_id, v_current_balance, v_current_tickets,
             v_credit_limit_raw, v_client_name
        FROM public.clients
        WHERE uid = v_client_uid
        FOR UPDATE;

        IF v_client_id IS NULL THEN
            RAISE EXCEPTION 'El cliente con UID % no existe.', v_client_uid;
        END IF;

        -- Monetary charge: unit_fare x quantity
        v_charge_usd        := v_unit_fare * v_ticket_count;
        -- Ticket equivalent: monetary / company.base
        v_tickets_to_deduct := TRUNC(v_charge_usd / v_company_ticket, 2);
        v_new_balance       := v_current_balance - v_charge_usd;
        v_new_tickets       := v_current_tickets - v_tickets_to_deduct;
        v_credit_limit      := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Saldo insuficiente. Cliente: %, Saldo: $% (% tickets), Cargo: $% (% tickets eq.), Limite: $%.',
                v_client_name, v_current_balance, v_current_tickets,
                v_charge_usd, v_tickets_to_deduct, v_credit_limit;
        END IF;

        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id
          AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        UPDATE public.clients
        SET balance = v_new_balance,
            tickets = v_new_tickets
        WHERE id = v_client_id;

        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS')
                    || FLOOR(RANDOM() * 100)::TEXT
                    || v_processed_count::TEXT;

        INSERT INTO public.transactions (
            uid, idclient, "createBy",
            amount, ticket,
            status, shedule,
            "newBalanceClient", "newTicketsClient",
            idunit, idroute, created_at
        )
        VALUES (
            v_tx_uid, v_client_id, p_create_by,
            v_charge_usd, v_tickets_to_deduct,
            0, v_shedule,
            v_new_balance, v_new_tickets,
            v_idunit, v_idroute, NOW()
        );

        v_response_data := v_response_data || jsonb_build_object(
            'client_uid',      v_client_uid,
            'amount_debited',  v_charge_usd,
            'tickets_debited', v_tickets_to_deduct,
            'new_balance',     v_new_balance,
            'new_tickets',     v_new_tickets,
            'booking_count',   v_count_booking
        );

        v_processed_count := v_processed_count + 1;
    END LOOP;

    RETURN json_build_object(
        'success',           true,
        'message',           'Lote de transacciones procesado con exito.',
        'processed_records', v_processed_count,
        'unit_fare',         v_unit_fare,
        'details',           v_response_data
    );

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success',           false,
        'message',           'Rollback: ' || SQLERRM,
        'processed_records', 0,
        'details',           '[]'::json
    );
END;
$function$
;

-- C2. charge_ticket (DEPRECATED)
DROP FUNCTION IF EXISTS public.charge_ticket(character varying, integer, character varying, integer);
CREATE OR REPLACE FUNCTION public.charge_ticket(
    p_client_uid character varying,
    p_ticket_count integer,
    p_shedule character varying,
    p_create_by integer
)
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
    v_charge_usd NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_new_tickets NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
BEGIN
    SELECT id, balance, tickets, "creditLimit"
    INTO v_client_id, v_current_balance, v_current_tickets, v_credit_limit_raw
    FROM public.clients WHERE uid = p_client_uid FOR UPDATE;

    IF v_client_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'No existe el cliente');
    END IF;

    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'Error de configuracion: precio de ticket no valido.');
    END IF;

    v_charge_usd := p_ticket_count * v_ticket_price;
    v_new_balance := v_current_balance - v_charge_usd;
    v_new_tickets := v_current_tickets - p_ticket_count;
    v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

    IF v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Saldo insuficiente. Balance: $' || v_current_balance || ', Cargo: $' || v_charge_usd
        );
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_count_booking
    FROM public.solicitude
    WHERE idclient = v_client_id AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

    UPDATE public.clients SET balance = v_new_balance, tickets = v_new_tickets WHERE id = v_client_id;

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || '0';

    INSERT INTO public.transactions (
        uid, idclient, "createBy", amount, ticket, status, shedule,
        "newBalanceClient", "newTicketsClient", idunit, created_at
    )
    VALUES (
        v_tx_uid, v_client_id, p_create_by,
        v_charge_usd, p_ticket_count,
        0, p_shedule,
        v_new_balance, v_new_tickets,
        0, NOW()
    );

    RETURN json_build_object(
        'booking', v_count_booking,
        'success', true,
        'data', json_build_object(
            'id', v_client_id, 'balance', v_new_balance,
            'tickets', v_new_tickets, 'uid', p_client_uid
        ),
        'message', 'success'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'booking', 0,
        'success', false,
        'data', NULL,
        'message', 'Error en transaccion: ' || SQLERRM
    );
END;
$function$
;

-- C3. add_tickets_to_client
DROP FUNCTION IF EXISTS public.add_tickets_to_client(integer, integer, integer);
CREATE OR REPLACE FUNCTION public.add_tickets_to_client(
    p_idclient integer,
    p_ticket_count integer,
    p_create_by integer
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
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
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta operacion.');
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

    INSERT INTO public.transactions (
        uid, idclient, "createBy", amount, ticket, status, shedule,
        "newBalanceClient", "newTicketsClient", created_at, idunit
    )
    VALUES (
        v_tx_uid, p_idclient, p_create_by,
        v_add_usd, p_ticket_count,
        0, 'Asignacion',
        v_new_balance, v_new_tickets,
        NOW(), 0
    );

    RETURN json_build_object(
        'success', true,
        'message', 'Tickets agregados correctamente.',
        'new_balance', v_new_balance,
        'new_tickets', v_new_tickets
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al agregar tickets: ' || SQLERRM);
END;
$function$
;

-- ============================================================
-- D: Reescritura de RPCs de lectura (SELECT con 4 campos)
-- ============================================================

-- D1. get_client_history (usa SELECT t.*, no necesita cambios)
-- Se mantiene — t.* ya incluye las nuevas columnas.

-- D2. get_clients_transactions
DROP FUNCTION IF EXISTS public.get_clients_transactions(integer, text, text, integer, integer);

CREATE OR REPLACE FUNCTION public.get_clients_transactions(
    p_client_id integer,
    p_from text DEFAULT NULL,
    p_to text DEFAULT NULL,
    p_status integer DEFAULT NULL,
    p_create_by integer DEFAULT NULL
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_from_ts timestamptz := p_from::timestamptz;
    v_to_ts timestamptz := p_to::timestamptz;
    v_result json;
BEGIN
    WITH filtered_tx AS (
        SELECT 
            t.*, 
            c.name AS client_name
        FROM public.transactions t
        LEFT JOIN public.clients c ON t.idclient = c.id
        WHERE (v_from_ts IS NULL OR t.created_at >= v_from_ts)
          AND (v_to_ts IS NULL OR t.created_at <= v_to_ts)
          AND (p_client_id IS NULL OR t.idclient = p_client_id)
          AND (p_status IS NULL OR t.status = p_status)
          AND (p_create_by IS NULL OR t."createBy" = p_create_by)
        ORDER BY t.id DESC
    )
    SELECT json_build_object(
        'transactions', COALESCE(json_agg(f), '[]'::json),
        'total_transactions_amount', COALESCE(SUM(f.amount), 0.00),
        'total_transactions_tickets', COALESCE(SUM(f.ticket), 0.00)
    )
    INTO v_result
    FROM filtered_tx f;

    RETURN v_result;
END;
$function$;

-- D3. get_transactions_paginated (con 4 campos + sort whitelist)
DROP FUNCTION IF EXISTS public.get_transactions_paginated(integer, integer, date, date, integer, integer, text, text, text, bigint, text);
CREATE OR REPLACE FUNCTION public.get_transactions_paginated(
    p_page integer DEFAULT 1,
    p_per_page integer DEFAULT 10,
    p_date_from date DEFAULT NULL,
    p_date_to date DEFAULT NULL,
    p_idunit integer DEFAULT NULL,
    p_status integer DEFAULT NULL,
    p_sort_field text DEFAULT 'created_at',
    p_sort_order text DEFAULT 'DESC',
    p_shedule text DEFAULT NULL,
    p_idroute bigint DEFAULT NULL,
    p_search text DEFAULT NULL
)
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

    SELECT COUNT(*) INTO v_total FROM public.transactions t
    LEFT JOIN public.clients c ON c.id = t.idclient
    WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
      AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
      AND (p_idunit IS NULL OR t.idunit = p_idunit)
      AND (p_status IS NULL OR t.status = p_status)
      AND (p_shedule IS NULL OR t.shedule = p_shedule)
      AND (p_idroute IS NULL OR t.idroute = p_idroute)
      AND (v_search IS NULL OR c.name ILIKE v_search OR c."documentID" ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search)
      AND (public.is_admin() OR t.idroute = ANY(v_route_ids));

    SELECT json_agg(sub) INTO v_data FROM (
        SELECT
            t.id, t.uid, t.idclient, t."createBy", t.amount, t.ticket,
            t.status, t.created_at, t.idunit, t.shedule,
            t."newBalanceClient", t."newTicketsClient",
            json_build_object('name', c.name) AS clients,
            json_build_object('name', u.name) AS units,
            COALESCE(r.code || ' - ' || r.description, 'Sin ruta') AS route_name
        FROM public.transactions t
        LEFT JOIN public.clients c ON c.id = t.idclient
        LEFT JOIN public.units u ON u.id = t.idunit
        LEFT JOIN public.routes r ON r.id = t.idroute
        WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
          AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
          AND (p_idunit IS NULL OR t.idunit = p_idunit)
          AND (p_status IS NULL OR t.status = p_status)
          AND (p_shedule IS NULL OR t.shedule = p_shedule)
          AND (p_idroute IS NULL OR t.idroute = p_idroute)
          AND (v_search IS NULL OR c.name ILIKE v_search OR c."documentID" ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search)
          AND (public.is_admin() OR t.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'newBalanceClient' AND p_sort_order = 'ASC'  THEN t."newBalanceClient" END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'newBalanceClient' AND p_sort_order = 'DESC' THEN t."newBalanceClient" END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'ASC'  THEN t.created_at END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'DESC' THEN t.created_at END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'ASC'  THEN t.amount     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'DESC' THEN t.amount     END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status'     AND p_sort_order = 'ASC'  THEN t.status     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'status'     AND p_sort_order = 'DESC' THEN t.status     END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'ASC'  THEN t.id         END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'id'         AND p_sort_order = 'DESC' THEN t.id         END DESC NULLS LAST,
            t.id DESC
        LIMIT p_per_page
        OFFSET v_offset
    ) sub;

    RETURN json_build_object('data', COALESCE(v_data, '[]'::json), 'total', v_total);
END;
$function$
;

-- D4. get_transactions_export (8-param overload)
DROP FUNCTION IF EXISTS public.get_transactions_export(date, date, integer, integer, text, text, text, bigint);
CREATE OR REPLACE FUNCTION public.get_transactions_export(
    p_date_from date DEFAULT NULL,
    p_date_to date DEFAULT NULL,
    p_idunit integer DEFAULT NULL,
    p_status integer DEFAULT NULL,
    p_sort_field text DEFAULT 'created_at',
    p_sort_order text DEFAULT 'DESC',
    p_shedule text DEFAULT NULL,
    p_idroute bigint DEFAULT NULL
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
    v_route_ids BIGINT[];
BEGIN
    v_route_ids := public.get_current_user_route_ids();
    IF array_length(v_route_ids, 1) IS NULL THEN
        SELECT ARRAY_AGG(u.idroute) INTO v_route_ids FROM public.units u WHERE u.email = auth.jwt()->>'email';
    END IF;

    SELECT json_agg(sub) INTO v_data FROM (
        SELECT
            t.id, t.uid, t.idclient, t."createBy", t.amount, t.ticket,
            t.status, t.created_at, t.idunit, t.shedule,
            t."newBalanceClient", t."newTicketsClient",
            c.name AS client_name,
            c."documentID" AS client_document,
            u.name AS unit_name,
            COALESCE(r.code || ' - ' || r.description, 'Sin ruta') AS route_name
        FROM public.transactions t
        LEFT JOIN public.clients c ON c.id = t.idclient
        LEFT JOIN public.units u ON u.id = t.idunit
        LEFT JOIN public.routes r ON r.id = t.idroute
        WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
          AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
          AND (p_idunit IS NULL OR t.idunit = p_idunit)
          AND (p_status IS NULL OR t.status = p_status)
          AND (p_shedule IS NULL OR t.shedule = p_shedule)
          AND (p_idroute IS NULL OR t.idroute = p_idroute)
          AND (public.is_admin() OR t.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'ASC'  THEN t.created_at END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'DESC' THEN t.created_at END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'ASC'  THEN t.amount     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'DESC' THEN t.amount     END DESC NULLS LAST,
            t.id DESC
    ) sub;

    RETURN json_build_object('data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- D5. get_transactions_export (9-param overload with search)
DROP FUNCTION IF EXISTS public.get_transactions_export(date, date, integer, integer, text, text, text, bigint, text);
CREATE OR REPLACE FUNCTION public.get_transactions_export(
    p_date_from date DEFAULT NULL,
    p_date_to date DEFAULT NULL,
    p_idunit integer DEFAULT NULL,
    p_status integer DEFAULT NULL,
    p_sort_field text DEFAULT 'created_at',
    p_sort_order text DEFAULT 'DESC',
    p_shedule text DEFAULT NULL,
    p_idroute bigint DEFAULT NULL,
    p_search text DEFAULT NULL
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
    v_route_ids BIGINT[];
    v_search TEXT;
BEGIN
    v_route_ids := public.get_current_user_route_ids();
    v_search := CASE WHEN p_search IS NOT NULL AND p_search <> '' THEN '%' || p_search || '%' ELSE NULL END;

    IF array_length(v_route_ids, 1) IS NULL THEN
        SELECT ARRAY_AGG(u.idroute) INTO v_route_ids FROM public.units u WHERE u.email = auth.jwt()->>'email';
    END IF;

    SELECT json_agg(sub) INTO v_data FROM (
        SELECT
            t.id, t.uid, t.idclient, t."createBy", t.amount, t.ticket,
            t.status, t.created_at, t.idunit, t.shedule,
            t."newBalanceClient", t."newTicketsClient",
            c.name AS client_name,
            c."documentID" AS client_document,
            u.name AS unit_name,
            COALESCE(r.code || ' - ' || r.description, 'Sin ruta') AS route_name
        FROM public.transactions t
        LEFT JOIN public.clients c ON c.id = t.idclient
        LEFT JOIN public.units u ON u.id = t.idunit
        LEFT JOIN public.routes r ON r.id = t.idroute
        WHERE (p_date_from IS NULL OR t.created_at >= p_date_from)
          AND (p_date_to IS NULL OR t.created_at <= (p_date_to || 'T23:59:59')::TIMESTAMP)
          AND (p_idunit IS NULL OR t.idunit = p_idunit)
          AND (p_status IS NULL OR t.status = p_status)
          AND (p_shedule IS NULL OR t.shedule = p_shedule)
          AND (p_idroute IS NULL OR t.idroute = p_idroute)
          AND (v_search IS NULL OR c.name ILIKE v_search OR c."documentID" ILIKE v_search OR c.phone ILIKE v_search OR c.email ILIKE v_search)
          AND (public.is_admin() OR t.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'ASC'  THEN t.created_at END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'created_at' AND p_sort_order = 'DESC' THEN t.created_at END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'ASC'  THEN t.amount     END ASC NULLS LAST,
            CASE WHEN p_sort_field = 'amount'     AND p_sort_order = 'DESC' THEN t.amount     END DESC NULLS LAST,
            t.id DESC
    ) sub;

    RETURN json_build_object('data', COALESCE(v_data, '[]'::json));
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

-- ============================================================
-- E: Funciones resumen (ya usan t.* o SUM(amount), sin cambios)
-- ============================================================
-- get_monthly_summary: usa SUM(amount) — ya es USD, correcto.
-- get_weekly_flow: usa SUM(t.amount) — ya es USD, correcto.
-- get_recent_movements: usa t.amount — ya es USD, correcto.
-- get_reservas_detail: usa t.amount — ya es USD, correcto.
-- get_dashboard_kpis: COUNT(*) — sin cambios.

-- ============================================================
-- F: Verificacion post-migracion
-- ============================================================
DO $$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_total_rows INTEGER;
    v_sum_amount NUMERIC(12,2);
    v_sum_ticket NUMERIC(12,2);
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    SELECT COUNT(*), COALESCE(SUM(amount), 0), COALESCE(SUM(ticket), 0)
    INTO v_total_rows, v_sum_amount, v_sum_ticket
    FROM public.transactions;

    RAISE NOTICE '=== POST-MIGRATION VERIFICATION (transactions) ===';
    RAISE NOTICE 'company.ticket: %', v_ticket_price;
    RAISE NOTICE 'Total rows: %', v_total_rows;
    RAISE NOTICE 'SUM(amount) [USD]: %', v_sum_amount;
    RAISE NOTICE 'SUM(ticket) [units]: %', v_sum_ticket;
    RAISE NOTICE 'Expected: SUM(ticket) * company.ticket = %', v_sum_ticket * v_ticket_price;
    RAISE NOTICE '===============================================';
END $$;

COMMIT;
