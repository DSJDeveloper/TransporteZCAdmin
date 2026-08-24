-- ============================================================
-- MIGRACION: Fix inventario client_stop_tickets - route_stops.price
-- Fecha: 2026-08-23
--
-- Auditoria: Ambos RPCs usaban company.ticket global para
-- convertir USD <-> tickets, ignorando route_stops.price como
-- fuente de verdad de tarifa por parada.
--
-- Bugs corregidos:
--   process_recharge_status:
--     - v_tickets_to_add calculaba TRUNC(amount / company.ticket)
--     - Ahora: TRUNC(amount / route_stops.price) cuando hay parada
--     - Fallback a company.ticket cuando NO hay parada (legacy)
--
--   charge_tickets_bulk:
--     - v_tickets_debit = ROUND(amount_usd / company.ticket)
--     - Ahora: v_ticket_count directamente (unidades reales cobradas)
--     - v_amount_usd = price_context * v_ticket_count (correcto)
--     - transactions.ticket = unidades reales (no USD-equivalentes)
--     - clients.tickets descuenta unidades reales
--
-- Restricciones:
--   - Mantiene firmas, parametros y formato de respuesta JSON
--   - RAISE 1:1 con placeholders (42601 safe)
--   - DROP FUNCTION IF EXISTS para prevenir PGRST203
--   - Transaccional: BEGIN/COMMIT
--
-- Ejecutar en SQL Editor de Supabase.
-- ============================================================

BEGIN;

-- ============================================================
-- A: process_recharge_status - Fix divisor de tickets
-- ============================================================
DROP FUNCTION IF EXISTS public.process_recharge_status(bigint, character varying, character varying);

CREATE OR REPLACE FUNCTION public.process_recharge_status(
    p_recharge_id  bigint,
    p_action       character varying,
    p_approved_by  character varying DEFAULT NULL
)
RETURNS json
    LANGUAGE plpgsql
    SECURITY DEFINER
AS $function$
DECLARE
    v_idclient       INTEGER;
    v_status         INTEGER;
    v_amount         NUMERIC(10,2);
    v_tasa           NUMERIC(10,2);
    v_method         VARCHAR(255);
    v_idroute        BIGINT;
    v_idstop         BIGINT;
    v_tickets_to_add NUMERIC(10,2) := 0.00;
    v_new_balance    NUMERIC(10,2);
    v_new_tickets    NUMERIC(10,2);
    v_final_status   INTEGER;
    v_log_message    VARCHAR(255);
    v_ticket_price   NUMERIC(10,2);
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

    IF LOWER(p_action) = 'approve' THEN
        v_final_status  := 1;
        v_log_message   := 'Recarga verificada y saldo acreditado con exito.';

        -- FIX: Usar route_stops.price como divisor cuando hay parada
        IF v_idstop IS NOT NULL THEN
            SELECT rs.price INTO v_ticket_price
            FROM public.route_stops rs
            WHERE rs.id = v_idstop;

            IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
                RETURN json_build_object('success', false, 'message',
                    'La parada de la recarga no tiene precio valido en route_stops.');
            END IF;
        ELSE
            -- Fallback global para recargas legacy sin parada
            SELECT ticket INTO v_ticket_price
            FROM public.company LIMIT 1;

            IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
                RETURN json_build_object('success', false, 'message',
                    'Error de configuracion: company.ticket no valido.');
            END IF;
        END IF;

        -- Calculo correcto: monto / precio_parada (o precio_global)
        v_tickets_to_add := TRUNC(v_amount / v_ticket_price, 2);

        -- Acumular saldo global (USD + unidades de tickets)
        UPDATE public.clients
        SET balance = balance + v_amount,
            tickets = tickets + v_tickets_to_add
        WHERE id = v_idclient
        RETURNING balance, tickets INTO v_new_balance, v_new_tickets;

        -- UPSERT en client_stop_tickets (inventario por parada)
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
        SELECT balance, tickets INTO v_new_balance, v_new_tickets
        FROM public.clients WHERE id = v_idclient;
    END IF;

    UPDATE public.recharge
    SET status = v_final_status,
        "updateAprobate" = NOW(),
        "createBy" = COALESCE(p_approved_by, "createBy")
    WHERE id = p_recharge_id;

    RETURN json_build_object(
        'success',                true,
        'message',                v_log_message,
        'recharge_id',            p_recharge_id,
        'action_executed',        p_action,
        'amount_credited',        v_amount,
        'tickets_credited',       v_tickets_to_add,
        'current_client_balance', v_new_balance,
        'current_client_tickets', v_new_tickets
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al procesar: ' || SQLERRM);
END;
$function$
;

-- ============================================================
-- B: charge_tickets_bulk - Unidades reales de tickets
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

    -- Tarifa global de la empresa (para validacion de credito y fallback)
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

        -- 4. Monto USD = precio_unitario x cantidad de tickets
        v_amount_usd := ROUND(v_price_context * v_ticket_count, 2);

        -- 5. Nuevo saldo monetario y de tickets (unidades reales)
        v_new_balance  := v_current_balance - v_amount_usd;
        v_new_tickets  := v_current_tickets - v_ticket_count;
        v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        -- Validacion de credito (en base monetaria)
        IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Transaccion rechazada. El cliente % tiene saldo insuficiente (Saldo: $%, Debito: $%, Limite Credito: $%).',
                v_client_name, v_current_balance, v_amount_usd, v_credit_limit;
        END IF;

        -- 6. Bookings del dia
        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id
          AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        -- 7. Actualizar ledger global (clients.balance USD + clients.tickets unidades)
        UPDATE public.clients
        SET balance = v_new_balance,
            tickets = v_new_tickets
        WHERE id = v_client_id;

        -- 8. Debitar directamente de client_stop_tickets (aislamiento estricto por parada)
        -- Regla: nunca transferir de otras paradas. Saldo negativo permitido.
        IF v_idstop IS NOT NULL THEN
            INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
            VALUES (v_client_id, v_idroute, v_idstop, -v_ticket_count, NOW())
            ON CONFLICT ("idclient", "idstop")
            DO UPDATE SET
                "tickets"   = public.client_stop_tickets."tickets" - v_ticket_count,
                "updated_at" = NOW();
        END IF;

        -- 9. UID de transaccion
        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS')
                    || FLOOR(RANDOM() * 100)::TEXT
                    || v_processed_count::TEXT;

        -- 10. Insertar transaccion con esquema dual completo
        --     ticket = unidades reales cobradas
        --     newTicketsClient = saldo global en unidades
        INSERT INTO public.transactions (
            uid, idclient, "createBy",
            amount, ticket,
            status, shedule,
            "newBalanceClient", "newTicketsClient",
            idunit, idroute, idstop, created_at
        )
        VALUES (
            v_tx_uid, v_client_id, p_create_by,
            v_amount_usd, v_ticket_count,
            0, v_shedule,
            v_new_balance, v_new_tickets,
            v_idunit, v_idroute, v_idstop, NOW()
        );

        -- 11. Acumular respuesta
        v_response_data := v_response_data || jsonb_build_object(
            'client_uid',      v_client_uid,
            'amount_debited',  v_amount_usd,
            'tickets_debited', v_ticket_count,
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
