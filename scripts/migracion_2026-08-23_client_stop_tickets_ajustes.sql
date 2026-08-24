-- ============================================================
-- Migración: 2026-08-23
-- Nombre: add_tickets_to_client — extiende con parámetros de ruta/parada
-- Propósito: Permitir al admin asociar manuales de saldo a una ruta+parada
--           específica, escribiendo en client_stop_tickets vía UPSERT.
--           Sin p_idstop se comporta como antes (company.ticket global).
-- ============================================================

BEGIN;

-- Drop de las firmas conocidas para idempotencia
DROP FUNCTION IF EXISTS public.add_tickets_to_client(integer, integer, integer);
DROP FUNCTION IF EXISTS public.add_tickets_to_client(integer, numeric, integer);

CREATE OR REPLACE FUNCTION public.add_tickets_to_client(
    p_idclient integer,
    p_ticket_count integer,
    p_create_by integer,
    p_idroute bigint DEFAULT NULL,
    p_idstop bigint DEFAULT NULL
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_name    VARCHAR(255);
    v_current_balance NUMERIC(10,2);
    v_current_tickets NUMERIC(10,2);
    v_new_balance    NUMERIC(10,2);
    v_new_tickets    NUMERIC(10,2);
    v_add_usd        NUMERIC(10,2);
    v_ticket_price   NUMERIC(10,2);
    v_stop_price     NUMERIC(10,2);
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

    -- Resolver precio: si se pasa p_idstop → route_stops.price; sino → company.ticket
    IF p_idstop IS NOT NULL THEN
        SELECT rs.price, rs.route_id INTO v_stop_price, v_idroute
        FROM public.route_stops rs
        WHERE rs.id = p_idstop;

        IF v_stop_price IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'La parada seleccionada no existe en route_stops.');
        END IF;

        IF v_stop_price <= 0 THEN
            RETURN json_build_object('success', false, 'message', 'La parada seleccionada tiene precio inválido.');
        END IF;

        v_idstop  := p_idstop;
        v_ticket_price := v_stop_price;
    ELSE
        SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
        v_idroute := p_idroute;
    END IF;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object('success', false, 'message', 'Error de configuracion: precio de ticket no válido.');
    END IF;

    SELECT name, balance, tickets
    INTO v_client_name, v_current_balance, v_current_tickets
    FROM public.clients WHERE id = p_idclient FOR UPDATE;

    IF v_client_name IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente no existe.');
    END IF;

    v_add_usd     := p_ticket_count * v_ticket_price;
    v_new_balance := v_current_balance + v_add_usd;
    v_new_tickets := v_current_tickets + p_ticket_count;

    UPDATE public.clients
    SET balance = v_new_balance, tickets = v_new_tickets
    WHERE id = p_idclient;

    -- UPSERT inventario por parada (solo cuando se indica parada)
    IF v_idstop IS NOT NULL THEN
        INSERT INTO public.client_stop_tickets ("idclient", "idroute", "idstop", "tickets", "updated_at")
        VALUES (p_idclient, v_idroute, v_idstop, p_ticket_count, NOW())
        ON CONFLICT ("idclient", "idstop")
        DO UPDATE SET
            "tickets"   = public.client_stop_tickets."tickets" + p_ticket_count,
            "updated_at" = NOW();
    END IF;

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

-- Notificar a PostgREST para invalidar el caché
NOTIFY pgrst, 'reload schema';

COMMIT;
