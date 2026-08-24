-- ============================================================
-- MIGRACIÓN: client_stop_tickets — Desglose de tickets por parada
-- Fecha: 2026-08-21
-- Propósito: Tabla complementaria que acumula tickets por parada
--            por cliente. Se actualiza automáticamente al aprobar
--            recargas (UPSERT) y al procesar cobros (DECREMENT).
-- ============================================================

BEGIN;

-- ============================================================
-- A: Tabla client_stop_tickets
-- ============================================================
DROP TABLE IF EXISTS public.client_stop_tickets;
CREATE TABLE public.client_stop_tickets (
    "idclient"  integer     NOT NULL,
    "idroute"   bigint      NOT NULL,
    "idstop"    bigint      NOT NULL,
    "tickets"   numeric(10,2) NOT NULL DEFAULT 0.00,
    "updated_at" timestamp with time zone DEFAULT now(),
    CONSTRAINT client_stop_tickets_pkey PRIMARY KEY ("idclient", "idstop")
);

CREATE INDEX idx_cst_idclient ON public.client_stop_tickets ("idclient");
CREATE INDEX idx_cst_idroute  ON public.client_stop_tickets ("idroute");
CREATE INDEX idx_cst_idstop   ON public.client_stop_tickets ("idstop");

ALTER TABLE public.client_stop_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cst_select_authenticated" ON public.client_stop_tickets;
CREATE POLICY "cst_select_authenticated"
    ON public.client_stop_tickets
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "cst_admin_all" ON public.client_stop_tickets;
CREATE POLICY "cst_admin_all"
    ON public.client_stop_tickets
    FOR ALL
    TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- ============================================================
-- B: process_recharge_status — UPSERT en client_stop_tickets
--    al aprobar recarga con idstop + idroute
-- ============================================================
DROP FUNCTION IF EXISTS public.process_recharge_status(bigint, character varying, character varying);
CREATE OR REPLACE FUNCTION public.process_recharge_status(
    p_recharge_id bigint,
    p_action      character varying,
    p_approved_by character varying DEFAULT NULL::character varying
)
RETURNS json
    LANGUAGE plpgsql
    SECURITY DEFINER
AS $function$
DECLARE
    v_idclient      INTEGER;
    v_status        INTEGER;
    v_amount        NUMERIC(10,2);
    v_tasa          NUMERIC(10,2);
    v_method        VARCHAR(255);
    v_idroute       BIGINT;
    v_idstop        BIGINT;
    v_tickets_to_add NUMERIC(10,2) := 0.00;
    v_new_balance   NUMERIC(10,2);
    v_new_tickets   NUMERIC(10,2);
    v_final_status  INTEGER;
    v_log_message   VARCHAR(255);
    v_ticket_price  NUMERIC(10,2);
BEGIN
    IF LOWER(p_action) NOT IN ('approve', 'reject') THEN
        RETURN json_build_object('success', false, 'message', 'Accion invalida. Use approve o reject.');
    END IF;

    SELECT idclient, status, amount, tasa, method, idroute, idstop
    INTO v_idclient, v_status, v_amount, v_tasa, v_method, v_idroute, v_idstop
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
        v_final_status  := 1;
        v_log_message   := 'Recarga verificada y saldo acreditado con exito.';
        v_tickets_to_add := public.calculate_tickets_from_amount(v_amount);

        UPDATE public.clients
        SET balance = balance + v_amount,
            tickets = tickets + v_tickets_to_add
        WHERE id = v_idclient
        RETURNING balance, tickets INTO v_new_balance, v_new_tickets;

        -- Acumular tickets por parada si la recarga tiene idstop + idroute
        IF v_idstop IS NOT NULL AND v_idroute IS NOT NULL THEN
            INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
            VALUES (v_idclient, v_idroute, v_idstop, v_tickets_to_add, now())
            ON CONFLICT ("idclient", "idstop")
            DO UPDATE SET
                "tickets"   = public.client_stop_tickets."tickets" + v_tickets_to_add,
                "updated_at" = now();
        END IF;

    ELSIF LOWER(p_action) = 'reject' THEN
        v_final_status := 2;
        v_log_message  := 'Recarga rechazada. No se altero el saldo.';
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

-- ============================================================
-- C: charge_tickets_bulk — Aislamiento estricto por parada
--    p_idstop = route_stops.id; idroute se deriva de route_stops
--    Saldo negativo por parada permitido. Sin transferir de otras.
-- ============================================================

DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer);
DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer, bigint);
DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer, bigint, numeric);

CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(
    p_transactions JSONB,
    p_create_by    INTEGER,
    p_idunit       INTEGER       DEFAULT NULL,
    p_idstop       BIGINT        DEFAULT NULL,
    p_unit_price   NUMERIC(10,2) DEFAULT NULL
)
RETURNS json
    LANGUAGE plpgsql
    SECURITY DEFINER
AS $function$
DECLARE
    v_item              JSONB;
    v_client_uid        VARCHAR(255);
    v_ticket_count      INTEGER;
    v_shedule           VARCHAR(255);
    v_item_price        NUMERIC(10,2);

    v_client_id         BIGINT;
    v_client_name       VARCHAR(255);
    v_current_balance   NUMERIC(10,2);
    v_current_tickets   NUMERIC(10,2);
    v_credit_limit_raw  VARCHAR(255);
    v_credit_limit      NUMERIC(10,2);
    v_new_balance       NUMERIC(10,2);
    v_new_tickets       NUMERIC(10,2);
    v_count_booking     INTEGER;
    v_tx_uid            VARCHAR(255);
    v_is_admin          BOOLEAN;

    v_idunit            INTEGER;
    v_idroute           BIGINT;
    v_idstop            BIGINT;

    v_price_context     NUMERIC(10,2);
    v_amount_usd        NUMERIC(10,2);
    v_tickets_debit     NUMERIC(10,2);
    v_global_ticket     NUMERIC(10,2);
    v_stop_price        NUMERIC(10,2);

    v_processed_count   INTEGER := 0;
    v_response_data     JSONB := '[]'::jsonb;
BEGIN
    v_is_admin := public.is_admin();
    v_idunit   := COALESCE(p_idunit, p_create_by);

    -- Resolver ruta desde unidad
    SELECT idroute INTO v_idroute
    FROM public.units
    WHERE id = v_idunit;

    -- Tarifa global de la empresa (para conversión USD ↔ tickets)
    SELECT ticket INTO v_global_ticket
    FROM public.company
    LIMIT 1;

    IF v_global_ticket IS NULL OR v_global_ticket <= 0 THEN
        RAISE EXCEPTION 'Tarifa global de ticket no configurada o invalida (company.ticket: %).', v_global_ticket;
    END IF;

    -- Si viene p_idstop: resolver precio + ruta desde route_stops
    -- p_idstop = route_stops.id (la ruta de la parada es fuente de verdad)
    IF p_idstop IS NOT NULL THEN
        SELECT rs.price, rs.route_id INTO v_stop_price, v_idroute
        FROM public.route_stops rs
        WHERE rs.id = p_idstop;

        IF v_stop_price IS NULL THEN
            RAISE EXCEPTION 'La parada con id % no existe en route_stops.', p_idstop;
        END IF;

        v_idstop := p_idstop;
    ELSE
        v_idstop := NULL;
    END IF;

    -- 1. Iterar lote
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        v_client_uid   := v_item->>'client_uid';
        v_ticket_count := (v_item->>'ticket_count')::INTEGER;
        v_shedule      := v_item->>'shedule';
        v_item_price   := NULLIF(v_item->>'price', '')::NUMERIC(10,2);

        IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
            RAISE EXCEPTION 'Registro invalido en el lote. Verifique UIDs y cantidades de tickets.';
        END IF;

        -- 2. Buscar y bloquear cliente
        SELECT id, balance, tickets, "creditLimit", name
        INTO v_client_id, v_current_balance, v_current_tickets,
             v_credit_limit_raw, v_client_name
        FROM public.clients
        WHERE uid = v_client_uid
        FOR UPDATE;

        IF v_client_id IS NULL THEN
            RAISE EXCEPTION 'El cliente con UID % no existe en el sistema.', v_client_uid;
        END IF;

        -- 3. Resolver precio aplicable: item > param > parada > global
        v_price_context := COALESCE(v_item_price, p_unit_price, v_stop_price, v_global_ticket);

        IF v_price_context <= 0 THEN
            RAISE EXCEPTION 'Precio de parada/pasaje invalido (%).', v_price_context;
        END IF;

        -- 4. Cálculo dual: monto USD y tickets equivalentes
        v_amount_usd    := ROUND(v_price_context * v_ticket_count, 2);
        v_tickets_debit := ROUND(v_amount_usd / v_global_ticket, 2);

        v_new_balance   := v_current_balance - v_amount_usd;
        v_new_tickets   := v_current_tickets - v_tickets_debit;
        v_credit_limit  := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        -- Validación de crédito (en base monetaria)
        IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Transaccion rechazada. El cliente % tiene saldo insuficiente (Saldo: $%, Debito: $%, Limite Credito: $%).',
                v_client_name, v_current_balance, v_amount_usd, v_credit_limit;
        END IF;

        -- 5. Bookings del día
        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id
          AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        -- 6. Actualizar ledger global (clients.balance + clients.tickets)
        UPDATE public.clients
        SET balance = v_new_balance,
            tickets = v_new_tickets
        WHERE id = v_client_id;

        -- 7. Debitar directamente de client_stop_tickets (aislamiento estricto por parada)
        -- Regla: nunca transferir de otras paradas. Saldo negativo permitido.
        IF v_idstop IS NOT NULL THEN
            INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
            VALUES (v_client_id, v_idroute, v_idstop, -v_tickets_debit, NOW())
            ON CONFLICT ("idclient", "idstop")
            DO UPDATE SET
                "tickets"   = public.client_stop_tickets."tickets" - v_tickets_debit,
                "updated_at" = NOW();
        END IF;

        -- 8. UID de transacción
        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS')
                    || FLOOR(RANDOM() * 100)::TEXT
                    || v_processed_count::TEXT;

        -- 9. Insertar transacción con esquema dual completo
        INSERT INTO public.transactions (
            uid, idclient, "createBy",
            amount, ticket,
            status, shedule,
            "newBalanceClient", "newTicketsClient",
            idunit, idroute, idstop, created_at
        )
        VALUES (
            v_tx_uid, v_client_id, p_create_by,
            v_amount_usd, v_tickets_debit,
            0, v_shedule,
            v_new_balance, v_new_tickets,
            v_idunit, v_idroute, v_idstop, NOW()
        );

        -- 10. Acumular respuesta
        v_response_data := v_response_data || jsonb_build_object(
            'client_uid',      v_client_uid,
            'amount_debited',  v_amount_usd,
            'tickets_debited', v_tickets_debit,
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
        'unit_fare',         COALESCE(v_stop_price, p_unit_price, v_global_ticket),
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

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- D: get_client_stop_tickets — lectura de tickets por parada
-- ============================================================
DROP FUNCTION IF EXISTS public.get_client_stop_tickets(integer);
CREATE OR REPLACE FUNCTION public.get_client_stop_tickets(p_client_id integer)
RETURNS json
    LANGUAGE plpgsql
    SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    SELECT json_agg(row_to_json(t.*)) INTO v_data
    FROM (
        SELECT
            cst."idclient",
            cst."idroute",
            r.description AS route_name,
            s.name  AS stop_name,
            rst.price AS stop_price,
            cst."idstop",
            cst."tickets",
            cst."updated_at"
        FROM public.client_stop_tickets cst
        LEFT JOIN public.route_stops rst ON rst.id = cst."idstop"
        LEFT JOIN public.stops s ON s.id = rst.stop_id
        LEFT JOIN public.routes r ON r.id = cst."idroute"
        WHERE cst."idclient" = p_client_id
          AND cst."tickets" > 0
        ORDER BY r.description, s.name
    ) t;

    RETURN json_build_object(
        'success', true,
        'data', COALESCE(v_data, '[]'::json)
    );
END;
$function$
;

COMMIT;
