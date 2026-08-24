-- ============================================================
-- MIGRACIÓN: charge_tickets_bulk — Aislamiento estricto por parada
-- Fecha: 2026-08-23
-- Propósito: Refactorizar charge_tickets_bulk para:
--   1. Derivar idroute desde route_stops cuando p_idstop viene dado
--   2. Aislamiento estricto por parada en client_stop_tickets
--   3. Permitir saldo negativo por parada (sin transferir de otras)
--   4. DROP FUNCTION IF EXISTS de todas las firmas anteriores
--   5. RAISE 1:1 con placeholders
--
-- Firma final: (jsonb, integer, integer, bigint, numeric)
-- p_idstop = route_stops.id (confirmado por usuario)
--
-- Modelo: Dual-field (clients.balance USD + clients.tickets units)
--         (transactions.amount USD + transactions.ticket units)
--
-- Entregable: Script transaccional listo para ejecutar en SQL Editor
-- ============================================================

BEGIN;

-- Dropear TODAS las firmas anteriores para evitar PGRST203
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

COMMIT;
