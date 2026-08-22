-- ============================================================
-- Migracion: Modelo Contable - Tickets -> Saldo Monetario (USD)
-- Fecha: 2026-08-21
-- Descripcion:
--   A) Conversion de saldos existentes (balance * company.ticket)
--   B) Reescritura de RPCs de cobro y recarga
--   C) Reescritura de funciones de consulta de saldo
--   D) get_client_by_uid: elimina dependencia de company.ticket
-- ============================================================

-- ============================================================
-- PARTE A: Migracion de datos existentes
-- ============================================================

-- A1. Multiplicar balances actuales por company.ticket para convertir tickets -> USD
UPDATE public.clients
SET balance = balance * COALESCE((SELECT ticket FROM public.company LIMIT 1), 0)
WHERE balance != 0;

-- ============================================================
-- PARTE B: Reescritura de RPCs de cobro y recarga
-- ============================================================

-- B1. process_recharge_status: sumar monto USD directamente (sin conversion)
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
    v_ticket_price NUMERIC(10,2);
BEGIN
    IF LOWER(p_action) NOT IN ('approve', 'reject') THEN
        RETURN json_build_object('success', false, 'message', 'Accion invalida. Use approve o reject.');
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

    -- Resolver precio de parada para referencia informativa en recharge.tickets
    SELECT rs.price INTO v_ticket_price
    FROM public.route_stops rs
    WHERE rs.route_id = v_idroute
    ORDER BY rs.stop_order
    LIMIT 1;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    END IF;

    IF LOWER(p_action) = 'approve' THEN
        v_final_status := 1;
        v_log_message := 'Recarga verificada y saldo acreditado con exito.';

        -- Sumar monto USD directamente al saldo (sin conversion)
        UPDATE public.clients
        SET balance = balance + v_amount
        WHERE id = v_idclient
        RETURNING balance INTO v_new_balance;

        -- Guardar referencia informativa de tickets estimados
        UPDATE public.recharge
        SET tickets = CASE WHEN v_ticket_price > 0 THEN TRUNC(v_amount / v_ticket_price, 2) ELSE 0 END
        WHERE id = p_recharge_id;

    ELSIF LOWER(p_action) = 'reject' THEN
        v_final_status := 2;
        v_log_message := 'Recarga rechazada por el administrador. No se altero el saldo del cliente.';
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
        'current_client_balance', v_new_balance
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al procesar la operacion: ' || SQLERRM);
END;
$function$
;

-- B2. charge_tickets_bulk: descontar precio de parada de la ruta del cliente
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
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
    v_is_admin BOOLEAN;
    v_idunit INTEGER;
    v_idroute BIGINT;
    v_stop_price NUMERIC(10,2);
    v_charge_amount NUMERIC(10,2);
    v_processed_count INTEGER := 0;
    v_response_data JSONB := '[]'::jsonb;
BEGIN
    v_is_admin := public.is_admin();
    v_idunit := COALESCE(p_idunit, p_create_by);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        v_client_uid := v_item->>'client_uid';
        v_ticket_count := (v_item->>'ticket_count')::INTEGER;
        v_shedule := v_item->>'shedule';

        IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
            RAISE EXCEPTION 'Registro invalido en el lote. Verifique UIDs y cantidades.';
        END IF;

        -- Buscar cliente con su ruta
        SELECT id, balance, "creditLimit", name, idroute
        INTO v_client_id, v_current_balance, v_credit_limit_raw, v_client_name, v_idroute
        FROM public.clients
        WHERE uid = v_client_uid
        FOR UPDATE;

        IF v_client_id IS NULL THEN
            RAISE EXCEPTION 'El cliente con UID % no existe en el sistema.', v_client_uid;
        END IF;

        -- Resolver precio de parada de la ruta del cliente
        SELECT rs.price INTO v_stop_price
        FROM public.route_stops rs
        WHERE rs.route_id = v_idroute
        ORDER BY rs.stop_order
        LIMIT 1;

        -- Fallback a company.ticket
        IF v_stop_price IS NULL OR v_stop_price <= 0 THEN
            SELECT ticket INTO v_stop_price FROM public.company LIMIT 1;
        END IF;

        IF v_stop_price IS NULL OR v_stop_price <= 0 THEN
            RAISE EXCEPTION 'Error de configuracion: No se encontro precio de parada para la ruta del cliente.';
        END IF;

        -- Calcular monto a descontar: cantidad x precio de parada
        v_charge_amount := v_ticket_count * v_stop_price;
        v_new_balance := v_current_balance - v_charge_amount;
        v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Transaccion rechazada. El cliente % tiene saldo insuficiente (Saldo: $%, Cargo: $%, Limite: $%).',
                v_client_name, v_current_balance, v_charge_amount, v_credit_limit;
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
            v_charge_amount,
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
        'message', 'Lote de transacciones procesado con exito.',
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

-- B3. add_tickets_to_client: sumar monto USD directamente al saldo
DROP FUNCTION IF EXISTS public.add_tickets_to_client(integer, integer, integer);
CREATE OR REPLACE FUNCTION public.add_tickets_to_client(p_idclient integer, p_ticket_count integer, p_create_by integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_name VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_tx_uid VARCHAR(255);
    v_amount_usd NUMERIC(10,2);
    v_idroute BIGINT;
    v_stop_price NUMERIC(10,2);
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta operacion.');
    END IF;

    IF p_ticket_count IS NULL OR p_ticket_count <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'La cantidad debe ser mayor a cero.');
    END IF;

    SELECT name, balance, idroute INTO v_client_name, v_current_balance, v_idroute
    FROM public.clients WHERE id = p_idclient
    FOR UPDATE;

    IF v_client_name IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    -- Resolver precio de parada para convertir cantidad a USD
    SELECT rs.price INTO v_stop_price
    FROM public.route_stops rs
    WHERE rs.route_id = v_idroute
    ORDER BY rs.stop_order
    LIMIT 1;

    IF v_stop_price IS NULL OR v_stop_price <= 0 THEN
        SELECT ticket INTO v_stop_price FROM public.company LIMIT 1;
    END IF;

    IF v_stop_price IS NULL OR v_stop_price <= 0 THEN
        RAISE EXCEPTION 'Error de configuracion: No se encontro precio de parada.';
    END IF;

    -- Calcular monto USD: cantidad x precio de parada
    v_amount_usd := p_ticket_count * v_stop_price;
    v_new_balance := v_current_balance + v_amount_usd;

    UPDATE public.clients SET balance = v_new_balance WHERE id = p_idclient;

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || '0';

    INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", created_at, idunit)
    VALUES (v_tx_uid, p_idclient, p_create_by, v_amount_usd, 0, 'Asignacion', v_new_balance, NOW(), 0);

    RETURN json_build_object('success', true, 'message', 'Saldo agregado correctamente.', 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al agregar saldo: ' || SQLERRM);
END;
$function$
;

-- B4. charge_ticket: DEPRECATED — mantener por compatibilidad
DROP FUNCTION IF EXISTS public.charge_ticket(character varying, integer, character varying, integer);
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
    v_ticket_price NUMERIC(10,2);
    v_total_amount_usd NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
BEGIN
    SELECT id, balance, "creditLimit"
    INTO v_client_id, v_current_balance, v_credit_limit_raw
    FROM public.clients WHERE uid = p_client_uid FOR UPDATE;

    IF v_client_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'No existe el cliente');
    END IF;

    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'Error de configuracion: precio de ticket no valido.');
    END IF;

    v_total_amount_usd := p_ticket_count * v_ticket_price;
    v_new_balance := v_current_balance - v_total_amount_usd;
    v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

    IF v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
        RETURN json_build_object('success', false, 'message',
            'Saldo insuficiente. Balance: $' || v_current_balance || ', Cargo: $' || v_total_amount_usd);
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_count_booking
    FROM public.solicitude
    WHERE idclient = v_client_id AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

    UPDATE public.clients SET balance = v_new_balance WHERE id = v_client_id;

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || '0';

    INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", idunit, created_at)
    VALUES (v_tx_uid, v_client_id, p_create_by, v_total_amount_usd, 0, p_shedule, v_new_balance, 0, NOW());

    RETURN json_build_object(
        'success', true, 'message', 'Cobro registrado.',
        'new_balance', v_new_balance, 'booking_count', v_count_booking
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- ============================================================
-- PARTE C: Funciones de consulta de saldo
-- ============================================================

-- C1. get_client_balance: balance ya esta en USD, sin cambios necesarios
-- Se mantiene identico — solo lee y retorna el valor.

-- C2. get_client_by_uid: balance ya esta en USD
DROP FUNCTION IF EXISTS public.get_client_by_uid(character varying);
CREATE OR REPLACE FUNCTION public.get_client_by_uid(p_uid character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_id BIGINT;
    v_name VARCHAR(255);
    v_balance NUMERIC(10,2);
    v_document_id VARCHAR(255);
    v_photo_url VARCHAR(1000);
BEGIN
    SELECT id, name, balance, "documentID", photo_url
    INTO v_client_id, v_name, v_balance, v_document_id, v_photo_url
    FROM public.clients
    WHERE uid = p_uid
    LIMIT 1;

    IF v_client_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado');
    END IF;

    RETURN json_build_object(
        'success', true,
        'data', json_build_object(
            'id', v_client_id,
            'name', v_name,
            'documentID', v_document_id,
            'photo_url', v_photo_url,
            'balance', v_balance
        )
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al consultar el cliente: ' || SQLERRM);
END;
$function$
;
