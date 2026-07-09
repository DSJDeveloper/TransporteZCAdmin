-- ==============================================================
-- Migración: add_tickets_to_client — Sumar tickets (Admin only)
-- Fecha: 2026-06-24
-- Descripción:
--   Nuevo RPC para que administradores agreguen tickets al
--   saldo de un cliente. Incrementa clients.balance y registra
--   la operación en transactions.
--   createBy e idunit se pasan como parámetros.
-- ==============================================================

CREATE OR REPLACE FUNCTION public.add_tickets_to_client(p_idclient integer, p_ticket_count integer, p_create_by integer, p_idunit integer)
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
        RETURN json_build_object('success', false, 'message', 'La cantidad de tickets debe ser mayor a cero.');
    END IF;

    -- Validación para la restricción NOT NULL de la tabla transactions
    IF p_idunit IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El ID de la unidad es obligatorio.');
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

    -- Se incluye idunit tanto en la declaración de columnas como en los VALUES
    INSERT INTO public.transactions (uid, idclient, "createBy", amount, status, shedule, "newBalanceClient", created_at, idunit)
    VALUES (v_tx_uid, p_idclient, p_create_by, p_ticket_count::NUMERIC(10,2), 0, 'Manual', v_new_balance, NOW(), p_idunit);

    RETURN json_build_object('success', true, 'message', 'Tickets agregados correctamente.', 'new_balance', v_new_balance);

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error al agregar tickets: ' || SQLERRM);
END;
$function$
;

NOTIFY pgrst, 'reload schema';