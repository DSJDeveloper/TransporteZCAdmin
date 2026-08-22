-- =====================================================
-- MIGRACIÓN: Centralizar cálculos de tickets en RPCs
-- Fecha: 2026-08-21
-- Propósito: Revertir modelo USD → tickets, centralizar
--            fórmulas en funciones PostgreSQL usando
--            company.ticket como referencia base.
-- Balance = cantidad de tickets (numeric 10,2)
-- =====================================================

BEGIN;

-- ─────────────────────────────────────────────────────
-- SECCIÓN A: Conversión de datos existentes
-- Los saldos en USD se convierten a tickets dividiendo
-- por company.ticket (referencia base)
-- ─────────────────────────────────────────────────────
UPDATE public.clients
SET balance = public.calculate_tickets_from_amount(balance)
WHERE balance != 0;

-- ─────────────────────────────────────────────────────
-- SECCIÓN B: Función helper — calculate_tickets_from_amount
-- Fórmula única: tickets = amount_usd / company.ticket
-- ─────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────
-- SECCIÓN C: Refactor process_recharge_status
-- Aprobar recarga: balance += calculate_tickets_from_amount(monto)
-- ─────────────────────────────────────────────────────
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
    v_idroute BIGINT;
    v_new_balance NUMERIC(10,2);
    v_final_status INTEGER;
    v_log_message VARCHAR(255);
    v_tickets_to_add NUMERIC(10,2);
BEGIN
    IF LOWER(p_action) NOT IN ('approve', 'reject') THEN
        RETURN json_build_object('success', false, 'message', 'Acción inválida. Use ''approve'' o ''reject''.');
    END IF;

    SELECT idclient, status, amount, tasa, method, idroute
    INTO v_idclient, v_status, v_amount, v_tasa, v_method, v_idroute
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
        v_log_message := 'Recarga verificada y saldo acreditado con éxito.';

        v_tickets_to_add := public.calculate_tickets_from_amount(v_amount);

        UPDATE public.clients
        SET balance = balance + v_tickets_to_add
        WHERE id = v_idclient
        RETURNING balance INTO v_new_balance;

        UPDATE public.recharge
        SET tickets = v_tickets_to_add
        WHERE id = p_recharge_id;

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
        'amount_credited', v_amount,
        'tickets_credited', v_tickets_to_add,
        'current_client_balance', v_new_balance
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al procesar la operación: ' || SQLERRM);
END;
$function$
;

-- ─────────────────────────────────────────────────────
-- SECCIÓN D: Refactor charge_tickets_bulk
-- Cobro: tickets = calculate_tickets_from_amount(monto_usd)
-- El frontend envía monto USD en ticket_count; la RPC
-- convierte internamente usando company.ticket.
-- ─────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer);
CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(p_transactions jsonb, p_create_by integer, p_idunit integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_item JSONB;
    v_client_uid VARCHAR(255);
    v_amount_usd NUMERIC(10,2);
    v_shedule VARCHAR(255);
    v_client_id BIGINT;
    v_client_name VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
    v_is_admin BOOLEAN;
    v_idunit INTEGER;
    v_idroute BIGINT;
    v_tickets_to_deduct NUMERIC(10,2);
    v_processed_count INTEGER := 0;
    v_response_data JSONB := '[]'::jsonb;
BEGIN
    v_is_admin := public.is_admin();
    v_idunit := COALESCE(p_idunit, p_create_by);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        v_client_uid := v_item->>'client_uid';
        v_amount_usd := (v_item->>'ticket_count')::NUMERIC;
        v_shedule := v_item->>'shedule';

        IF v_client_uid IS NULL OR v_amount_usd IS NULL OR v_amount_usd <= 0 THEN
            RAISE EXCEPTION 'Registro inválido en el lote. Verifique UIDs y montos.';
        END IF;

        SELECT id, balance, "creditLimit", name, idroute
        INTO v_client_id, v_current_balance, v_credit_limit_raw, v_client_name, v_idroute
        FROM public.clients
        WHERE uid = v_client_uid
        FOR UPDATE;

        IF v_client_id IS NULL THEN
            RAISE EXCEPTION 'El cliente con UID % no existe en el sistema.', v_client_uid;
        END IF;

        -- Centralized conversion: USD → tickets via company.ticket
        v_tickets_to_deduct := public.calculate_tickets_from_amount(v_amount_usd);

        v_new_balance := v_current_balance - v_tickets_to_deduct;
        v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Transacción rechazada. El cliente % tiene saldo insuficiente (Saldo: % tickets, Cargo: % tickets, Límite: %).',
                v_client_name, v_current_balance, v_tickets_to_deduct, v_credit_limit;
        END IF;

        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id
          AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        UPDATE public.clients
        SET balance = v_new_balance
        WHERE id = v_client_id;

        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || v_processed_count::TEXT;

        INSERT INTO public.transactions (
            uid, idclient, "createBy", amount, status, shedule,
            "newBalanceClient", idunit, idroute, created_at
        )
        VALUES (
            v_tx_uid, v_client_id, p_create_by,
            v_amount_usd,
            0, v_shedule, v_new_balance, v_idunit, v_idroute, NOW()
        );

        v_response_data := v_response_data || jsonb_build_object(
            'client_uid', v_client_uid,
            'new_balance', v_new_balance,
            'booking_count', v_count_booking
        );

        v_processed_count := v_processed_count + 1;
    END LOOP;

    RETURN json_build_object(
        'success', true,
        'message', 'Lote de transacciones procesado con éxito.',
        'processed_records', v_processed_count,
        'details', v_response_data
    );

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success', false,
        'message', 'Lote cancelado (Rollback ejecutado): ' || SQLERRM,
        'processed_records', 0,
        'details', '[]'::json
    );
END;
$function$
;

-- ─────────────────────────────────────────────────────
-- SECCIÓN E: Simplificar add_tickets_to_client
-- Suma directa de tickets (sin conversión).
-- El caller envía cantidad de tickets, la RPC suma.
-- ─────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.add_tickets_to_client(integer, integer, integer);
CREATE OR REPLACE FUNCTION public.add_tickets_to_client(p_idclient integer, p_ticket_count numeric, p_create_by integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_name VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_tx_uid VARCHAR(255);
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta operacion.');
    END IF;
    IF p_ticket_count IS NULL OR p_ticket_count <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'La cantidad debe ser mayor a cero.');
    END IF;

    SELECT name, balance INTO v_client_name, v_current_balance
    FROM public.clients WHERE id = p_idclient
    FOR UPDATE;

    IF v_client_name IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    v_new_balance := v_current_balance + p_ticket_count;

    UPDATE public.clients SET balance = v_new_balance WHERE id = p_idclient;

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || '0';

    INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", created_at, idunit)
    VALUES (v_tx_uid, p_idclient, p_create_by, p_ticket_count, 0, 'Asignacion', v_new_balance, NOW(), 0);

    RETURN json_build_object('success', true, 'message', 'Saldo agregado correctamente.', 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al agregar saldo: ' || SQLERRM);
END;
$function$
;

-- ─────────────────────────────────────────────────────
-- SECCIÓN F: Verificación post-migración
-- ─────────────────────────────────────────────────────
DO $$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_total_balance NUMERIC(12,2);
    v_total_clients INTEGER;
    v_negative_count INTEGER;
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    SELECT COUNT(*), COALESCE(SUM(balance), 0) INTO v_total_clients, v_total_balance
    FROM public.clients;
    SELECT COUNT(*) INTO v_negative_count FROM public.clients WHERE balance < 0;

    RAISE NOTICE '=== POST-MIGRATION VERIFICATION ===';
    RAISE NOTICE 'company.ticket: %', v_ticket_price;
    RAISE NOTICE 'Total clients: %', v_total_clients;
    RAISE NOTICE 'Total balance (tickets): %', v_total_balance;
    RAISE NOTICE 'Clients with negative balance: %', v_negative_count;
    RAISE NOTICE '====================================';
END $$;

COMMIT;
