-- =====================================================
-- MIGRACIÓN CENTRALIZADA: Integridad del saldo de tickets
-- Fecha: 2026-09-03
-- Propósito: Unificar toda la corrección de la disparidad
--            clients.tickets vs SUM(client_stop_tickets.tickets).
--
-- FASE A — Fuente única de tickets (código):
--   1. resolve_stop_for_tickets()        -> parada destino
--   2. sync_clients_tickets_from_stops() + trigger AFTER I/U/D
--   3. process_recharge_status (aprobar) -> inventario por parada
--   4. charge_tickets_bulk               -> inventario por parada
--   5. add_tickets_to_client             -> inventario por parada
--   6. charge_ticket (deprecada)         -> inventario por parada
--   Regla: los RPCs NUNCA escriben clients.tickets; el trigger
--   mantiene clients.tickets = SUM(client_stop_tickets) atómicamente.
--
-- FASE B — Reconciliación one-shot (nivelación histórica):
--   * Materializa excedentes en la parada más barata de la ruta.
--   * Canonicaliza clients.tickets = SUM(inventario).
--   * Lista excepciones (clientes sin paradas) sin tocar balance.
--
-- Ejecutar UNA sola vez en el SQL Editor de Supabase.
-- Para AUDITAR sin persistir: cambiar el COMMIT final por ROLLBACK
-- (la FASE B muestra auditorías antes de escribir).
-- =====================================================

BEGIN;

-- ─────────────────────────────────────────────────────
-- FASE A: Fuente única de tickets en client_stop_tickets
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_stop_for_tickets(p_client_id bigint DEFAULT NULL::bigint, p_route_id bigint DEFAULT NULL::bigint, p_idstop bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(
        (SELECT rs.id FROM public.route_stops rs WHERE rs.id = p_idstop),
        (SELECT rs.id FROM public.route_stops rs
          WHERE rs.route_id = COALESCE(p_route_id, (SELECT c.idroute FROM public.clients c WHERE c.id = p_client_id))
          ORDER BY rs.price ASC, rs.id ASC
          LIMIT 1)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.sync_clients_tickets_from_stops()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_id BIGINT;
BEGIN
    v_client_id := COALESCE(NEW."idclient", OLD."idclient");
    IF v_client_id IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE public.clients
    SET tickets = COALESCE(
        (SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = v_client_id),
        0
    )
    WHERE id = v_client_id;

    RETURN COALESCE(NEW, OLD);
END;
$function$
;

DROP TRIGGER IF EXISTS trg_sync_clients_tickets_from_stops ON public.client_stop_tickets;
CREATE TRIGGER trg_sync_clients_tickets_from_stops
AFTER INSERT OR UPDATE OR DELETE ON public.client_stop_tickets
FOR EACH ROW EXECUTE FUNCTION public.sync_clients_tickets_from_stops();

-- ─────────────────────────────────────────────────────
-- process_recharge_status
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.process_recharge_status(p_recharge_id bigint, p_action character varying, p_approved_by character varying DEFAULT NULL::character varying)
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

        -- Parada destino: la de la recarga o la mas barata de la ruta del cliente
        v_idstop := public.resolve_stop_for_tickets(v_idclient, v_idroute, v_idstop);

        IF v_idstop IS NULL THEN
            RETURN json_build_object('success', false, 'message',
                'La recarga no tiene parada asignada y el cliente no tiene ruta/paradas configuradas. Asigne una ruta con paradas antes de aprobar.');
        END IF;

        -- Precio y ruta reales de la parada destino
        SELECT rs.price, rs.route_id INTO v_ticket_price, v_idroute
        FROM public.route_stops rs
        WHERE rs.id = v_idstop;

        IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
            RETURN json_build_object('success', false, 'message',
                'La parada de la recarga no tiene precio valido en route_stops.');
        END IF;

        -- Tickets a acreditar = monto / precio de la parada
        v_tickets_to_add := TRUNC(v_amount / v_ticket_price, 2);

        -- Saldo monetario en cabecera; los tickets derivan del inventario por parada
        UPDATE public.clients
        SET balance = balance + v_amount
        WHERE id = v_idclient
        RETURNING balance INTO v_new_balance;

        -- Inventario por parada (fuente unica); trigger recalcula clients.tickets
        INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
        VALUES (v_idclient, v_idroute, v_idstop, v_tickets_to_add, now())
        ON CONFLICT ("idclient", "idstop")
        DO UPDATE SET
            "tickets"   = public.client_stop_tickets."tickets" + v_tickets_to_add,
            "updated_at" = now();

        SELECT tickets INTO v_new_tickets FROM public.clients WHERE id = v_idclient;

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

-- ─────────────────────────────────────────────────────
-- charge_tickets_bulk
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(p_transactions jsonb, p_create_by integer, p_idunit integer DEFAULT NULL::integer, p_idstop bigint DEFAULT NULL::bigint, p_unit_price numeric DEFAULT NULL::numeric)
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
        -- Sin parada explicita: usar la mas barata de la ruta de la unidad
        v_idstop := public.resolve_stop_for_tickets(NULL, v_idroute, NULL);
        IF v_idstop IS NOT NULL THEN
            SELECT rs.price, rs.route_id INTO v_stop_price, v_idroute
            FROM public.route_stops rs
            WHERE rs.id = v_idstop;
        ELSE
            RAISE EXCEPTION 'Cobro sin parada imposible: la unidad % no tiene ruta con paradas configuradas.', COALESCE(p_idunit, p_create_by);
        END IF;
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
        SELECT id, balance, "creditLimit", name
        INTO v_client_id, v_current_balance,
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

        -- 5. Nuevo saldo monetario (los tickets derivan del inventario por parada)
        v_new_balance  := v_current_balance - v_amount_usd;
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

        -- 7. Actualizar ledger monetario (los tickets derivan del inventario por parada)
        UPDATE public.clients
        SET balance = v_new_balance
        WHERE id = v_client_id;

        -- 8. Debitar inventario de la parada (fuente unica; aislamiento estricto por parada)
        -- Regla: nunca transferir de otras paradas. Saldo negativo permitido.
        -- El trigger recalcula clients.tickets = SUM(client_stop_tickets).
        INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
        VALUES (v_client_id, v_idroute, v_idstop, -v_ticket_count, NOW())
        ON CONFLICT ("idclient", "idstop")
        DO UPDATE SET
            "tickets"   = public.client_stop_tickets."tickets" - v_ticket_count,
            "updated_at" = NOW();

        -- 9. Tickets derivados tras el trigger (para transaccion y respuesta)
        SELECT tickets INTO v_new_tickets FROM public.clients WHERE id = v_client_id;

        -- 10. UID de transaccion
        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS')
                    || FLOOR(RANDOM() * 100)::TEXT
                    || v_processed_count::TEXT;

        -- 11. Insertar transaccion con esquema dual completo
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

        -- 12. Acumular respuesta
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

-- ─────────────────────────────────────────────────────
-- add_tickets_to_client
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.add_tickets_to_client(p_idclient integer, p_ticket_count integer, p_create_by integer, p_idroute bigint DEFAULT NULL::bigint, p_idstop bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_name    VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_new_balance    NUMERIC(10,2);
    v_new_tickets    NUMERIC(10,2);
    v_add_usd        NUMERIC(10,2);
    v_ticket_price   NUMERIC(10,2);
    v_idroute        BIGINT;
    v_idstop         BIGINT;
    v_tx_uid         VARCHAR(255);
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta operacion.');
    END IF;

    IF p_ticket_count IS NULL OR p_ticket_count <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'La cantidad debe ser mayor a cero.');
    END IF;

    -- Parada destino: la indicada o la mas barata de la ruta (parametro o del cliente)
    v_idstop := public.resolve_stop_for_tickets(p_idclient, p_idroute, p_idstop);

    IF v_idstop IS NULL THEN
        RETURN json_build_object('success', false, 'message',
            'El cliente no tiene ruta/paradas configuradas para asignar tickets. Asigne una ruta con paradas.');
    END IF;

    -- Precio y ruta reales de la parada destino (fuente unica de tarifa)
    SELECT rs.price, rs.route_id INTO v_ticket_price, v_idroute
    FROM public.route_stops rs
    WHERE rs.id = v_idstop;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'La parada destino no tiene precio valido en route_stops.');
    END IF;

    SELECT name, balance
    INTO v_client_name, v_current_balance
    FROM public.clients WHERE id = p_idclient FOR UPDATE;

    IF v_client_name IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    v_add_usd     := p_ticket_count * v_ticket_price;
    v_new_balance := v_current_balance + v_add_usd;

    -- Saldo monetario en cabecera; los tickets derivan del inventario por parada
    UPDATE public.clients
    SET balance = v_new_balance
    WHERE id = p_idclient;

    -- Inventario por parada (fuente unica); trigger recalcula clients.tickets
    INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
    VALUES (p_idclient, v_idroute, v_idstop, p_ticket_count, NOW())
    ON CONFLICT ("idclient", "idstop")
    DO UPDATE SET
        "tickets"   = public.client_stop_tickets."tickets" + p_ticket_count,
        "updated_at" = NOW();

    -- Tickets derivados tras el trigger (para transaccion y respuesta)
    SELECT tickets INTO v_new_tickets FROM public.clients WHERE id = p_idclient;

    v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || '0';

    INSERT INTO public.transactions (
        uid, idclient, "createBy", amount, ticket, status, shedule,
        "newBalanceClient", "newTicketsClient", created_at, idunit,
        idroute, idstop
    )
    VALUES (
        v_tx_uid, p_idclient, p_create_by,
        v_add_usd, p_ticket_count,
        0, 'Asignacion',
        v_new_balance, v_new_tickets,
        NOW(), 0,
        v_idroute, v_idstop
    );

    RETURN json_build_object(
        'success', true,
        'message', 'Tickets agregados correctamente.',
        'new_balance', v_new_balance,
        'new_tickets', v_new_tickets
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success', false,
        'message', 'Error al procesar la transaccion: ' || SQLERRM
    );
END;
$function$
;

-- ─────────────────────────────────────────────────────
-- charge_ticket
-- ─────────────────────────────────────────────────────
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
    v_charge_usd NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_new_tickets NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
    v_idroute      BIGINT;
    v_idstop       BIGINT;
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

    -- Parada destino: la mas barata de la ruta del cliente (funcion deprecada sin parada explicita)
    v_idstop := public.resolve_stop_for_tickets(v_client_id, NULL, NULL);
    IF v_idstop IS NULL THEN
        RETURN json_build_object('success', false,
            'message', 'El cliente no tiene ruta/paradas configuradas. No se puede descontar el ticket.');
    END IF;

    SELECT rs.route_id INTO v_idroute FROM public.route_stops rs WHERE rs.id = v_idstop;

    -- Saldo monetario en cabecera; los tickets derivan del inventario por parada
    UPDATE public.clients SET balance = v_new_balance WHERE id = v_client_id;

    -- Inventario por parada (fuente unica); trigger recalcula clients.tickets
    INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
    VALUES (v_client_id, v_idroute, v_idstop, -p_ticket_count, NOW())
    ON CONFLICT ("idclient", "idstop")
    DO UPDATE SET
        "tickets"   = public.client_stop_tickets."tickets" - p_ticket_count,
        "updated_at" = NOW();

    SELECT tickets INTO v_new_tickets FROM public.clients WHERE id = v_client_id;

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

-- ─────────────────────────────────────────────────────
-- FASE B: Reconciliación one-shot
-- ─────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────
-- 1) AUDITORÍA PREVIA
-- ─────────────────────────────────────────────────────
SELECT
    (SELECT COUNT(*) FROM public.clients)                                            AS total_clientes,
    (SELECT COALESCE(SUM(tickets),0) FROM public.clients)                            AS tickets_global_clients,
    (SELECT COALESCE(SUM(tickets),0) FROM public.client_stop_tickets)                AS tickets_global_inventario,
    (SELECT COUNT(*) FROM (
        SELECT c.id
        FROM public.clients c
        WHERE COALESCE(c.tickets,0) <> COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0)
    ) x)                                                                             AS clientes_discrepantes;

-- Clientes con excedente materializable (tienen ruta con paradas)
SELECT c.id, c.name, c.idroute,
       COALESCE(c.tickets,0) AS header,
       COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0) AS inventario,
       COALESCE(c.tickets,0) - COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0) AS delta
FROM public.clients c
WHERE COALESCE(c.tickets,0) - COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0) <> 0
  AND EXISTS (SELECT 1 FROM public.route_stops rs WHERE rs.route_id = c.idroute)
ORDER BY c.id;

-- EXCEPCIONES: discrepantes sin ruta/paradas donde materializar (no se tocan)
SELECT c.id, c.name, c.idroute,
       COALESCE(c.tickets,0) AS header,
       COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0) AS inventario
FROM public.clients c
WHERE COALESCE(c.tickets,0) <> COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0)
  AND NOT EXISTS (SELECT 1 FROM public.route_stops rs WHERE rs.route_id = c.idroute)
ORDER BY c.id;

-- ─────────────────────────────────────────────────────
-- 2) MATERIALIZAR EXCEDENTE en la parada más barata de la ruta
--    (solo deltas positivos y clientes con paradas disponibles)
-- ─────────────────────────────────────────────────────
INSERT INTO public.client_stop_tickets ("idclient","idroute","idstop","tickets","updated_at")
SELECT d.id, c.idroute, t.idstop, d.delta, NOW()
FROM (
    SELECT cc.id,
           COALESCE(cc.tickets,0)
             - COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = cc.id),0) AS delta
    FROM public.clients cc
) d
JOIN public.clients c ON c.id = d.id
JOIN LATERAL (
    SELECT rs.id AS idstop
    FROM public.route_stops rs
    WHERE rs.route_id = c.idroute
    ORDER BY rs.price ASC, rs.id ASC
    LIMIT 1
) t ON TRUE
WHERE d.delta > 0
ON CONFLICT ("idclient","idstop")
DO UPDATE SET
    "tickets"   = public.client_stop_tickets."tickets" + EXCLUDED."tickets",
    "updated_at" = NOW();

-- ─────────────────────────────────────────────────────
-- 3) CANONICALIZAR header := SUM(inventario) para clientes CON inventario
-- ─────────────────────────────────────────────────────
UPDATE public.clients c
SET tickets = COALESCE(
    (SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),
    0
)
WHERE EXISTS (SELECT 1 FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id);

-- ─────────────────────────────────────────────────────
-- 4) VERIFICACIÓN FINAL
-- ─────────────────────────────────────────────────────
SELECT
    (SELECT COUNT(*) FROM (
        SELECT c.id
        FROM public.clients c
        WHERE COALESCE(c.tickets,0) <> COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0)
    ) x)                                                                             AS clientes_aun_discrepantes,
    (SELECT COALESCE(SUM(tickets),0) FROM public.clients)                            AS tickets_global_clients,
    (SELECT COALESCE(SUM(tickets),0) FROM public.client_stop_tickets)                AS tickets_global_inventario;

-- Excepciones residuales (clientes con header <> 0 pero SIN paradas donde materializar)
SELECT c.id, c.name, c.idroute, COALESCE(c.tickets,0) AS header
FROM public.clients c
WHERE COALESCE(c.tickets,0) <> COALESCE((SELECT SUM(cst."tickets") FROM public.client_stop_tickets cst WHERE cst."idclient" = c.id),0)
ORDER BY c.id;

-- ROLLBACK;  -- descomentar para auditar sin persistir

COMMIT;
