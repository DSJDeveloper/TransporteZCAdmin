-- =====================================================
-- BACKUP: LÓGICA DE SERVIDOR (VISTAS, RPC, RLS, TRIGGERS)
-- Fecha: 2026-08-24T02:05:09.941Z
-- =====================================================

-- >>> FOREIGN KEYS <<<
ALTER TABLE public."route_stops" DROP CONSTRAINT IF EXISTS "route_stops_stop_id_fkey";
ALTER TABLE public."route_stops" ADD CONSTRAINT "route_stops_stop_id_fkey" FOREIGN KEY (stop_id) REFERENCES stops(id) ON DELETE CASCADE;
ALTER TABLE public."clients" DROP CONSTRAINT IF EXISTS "clients_idroute_fkey";
ALTER TABLE public."clients" ADD CONSTRAINT "clients_idroute_fkey" FOREIGN KEY (idroute) REFERENCES routes(id);
ALTER TABLE public."units" DROP CONSTRAINT IF EXISTS "units_idroute_fkey";
ALTER TABLE public."units" ADD CONSTRAINT "units_idroute_fkey" FOREIGN KEY (idroute) REFERENCES routes(id) ON DELETE SET NULL;
ALTER TABLE public."route_horarios" DROP CONSTRAINT IF EXISTS "route_horarios_idhorario_fkey";
ALTER TABLE public."route_horarios" ADD CONSTRAINT "route_horarios_idhorario_fkey" FOREIGN KEY (idhorario) REFERENCES horario(id) ON DELETE CASCADE;
ALTER TABLE public."route_horarios" DROP CONSTRAINT IF EXISTS "route_horarios_idroute_fkey";
ALTER TABLE public."route_horarios" ADD CONSTRAINT "route_horarios_idroute_fkey" FOREIGN KEY (idroute) REFERENCES routes(id) ON DELETE CASCADE;
ALTER TABLE public."recharge" DROP CONSTRAINT IF EXISTS "recharge_idclient_fkey";
ALTER TABLE public."recharge" ADD CONSTRAINT "recharge_idclient_fkey" FOREIGN KEY (idclient) REFERENCES clients(id);
ALTER TABLE public."profiles" DROP CONSTRAINT IF EXISTS "profiles_id_fkey";
ALTER TABLE public."profiles" ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public."user_routes" DROP CONSTRAINT IF EXISTS "user_routes_idroute_fkey";
ALTER TABLE public."user_routes" ADD CONSTRAINT "user_routes_idroute_fkey" FOREIGN KEY (idroute) REFERENCES routes(id) ON DELETE CASCADE;
ALTER TABLE public."user_routes" DROP CONSTRAINT IF EXISTS "user_routes_user_id_fkey";
ALTER TABLE public."user_routes" ADD CONSTRAINT "user_routes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE public."transactions" DROP CONSTRAINT IF EXISTS "transactions_idclient_fkey";
ALTER TABLE public."transactions" ADD CONSTRAINT "transactions_idclient_fkey" FOREIGN KEY (idclient) REFERENCES clients(id);
ALTER TABLE public."routes" DROP CONSTRAINT IF EXISTS "routes_idbank_info_fkey";
ALTER TABLE public."routes" ADD CONSTRAINT "routes_idbank_info_fkey" FOREIGN KEY (idbank_info) REFERENCES bank_info(id) ON DELETE SET NULL;

-- >>> VISTAS <<<

-- >>> FUNCIONES / RPC <<<

-- Función: process_recharge_status
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

-- Función: charge_tickets_bulk
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

-- Función: manage_solicitude
CREATE OR REPLACE FUNCTION public.manage_solicitude(p_action character varying, p_id integer DEFAULT NULL::integer, p_date character varying DEFAULT NULL::character varying, p_idclient integer DEFAULT NULL::integer, p_shedule character varying DEFAULT NULL::character varying, p_route character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_idroute bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_solicitude JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'list_by_client' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude WHERE idclient = p_idclient ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'get_by_id' THEN
        SELECT row_to_json(s.*) INTO v_solicitude FROM public.solicitude s WHERE id = p_id;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude);

    ELSIF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.solicitude (date, idclient, shedule, route, status, idroute)
            VALUES (p_date, p_idclient, p_shedule, p_route, COALESCE(p_status, 0), p_idroute)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_solicitude FROM inserted;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.solicitude SET
                date     = COALESCE(p_date, date),
                idclient = COALESCE(p_idclient, idclient),
                shedule  = COALESCE(p_shedule, shedule),
                route    = COALESCE(p_route, route),
                status   = COALESCE(p_status, status),
                idroute  = COALESCE(p_idroute, idroute)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_solicitude FROM updated;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.solicitude WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Solicitud eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: manage_solicitude
CREATE OR REPLACE FUNCTION public.manage_solicitude(p_action character varying, p_id integer DEFAULT NULL::integer, p_date character varying DEFAULT NULL::character varying, p_idclient integer DEFAULT NULL::integer, p_shedule character varying DEFAULT NULL::character varying, p_route character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_idroute bigint DEFAULT NULL::bigint, p_idstop bigint DEFAULT NULL::bigint, p_amount numeric DEFAULT NULL::numeric)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_solicitude JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'list_by_client' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude WHERE idclient = p_idclient ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'get_by_id' THEN
        SELECT row_to_json(s.*) INTO v_solicitude FROM public.solicitude s WHERE id = p_id;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude);

    ELSIF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.solicitude (date, idclient, shedule, route, status, idroute, idstop, amount)
            VALUES (p_date, p_idclient, p_shedule, p_route, COALESCE(p_status, 0), p_idroute, p_idstop, p_amount)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_solicitude FROM inserted;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.solicitude SET
                date     = COALESCE(p_date, date),
                idclient = COALESCE(p_idclient, idclient),
                shedule  = COALESCE(p_shedule, shedule),
                route    = COALESCE(p_route, route),
                status   = COALESCE(p_status, status),
                idroute  = COALESCE(p_idroute, idroute),
                idstop   = COALESCE(p_idstop, idstop),
                amount   = COALESCE(p_amount, amount)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_solicitude FROM updated;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.solicitude WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Solicitud eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_solicitudes_by_date_range
CREATE OR REPLACE FUNCTION public.get_solicitudes_by_date_range(p_date_from date DEFAULT CURRENT_DATE, p_date_to date DEFAULT CURRENT_DATE, p_idroute bigint[] DEFAULT NULL::bigint[], p_idhorario bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(id integer, client_name text, client_carrer text, client_document text, client_phone text, date character varying, shedule character varying, route character varying, status smallint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_route_ids BIGINT[];
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RAISE EXCEPTION 'No autorizado.';
    END IF;

    -- Solo admin, supervisor y driver pueden ver este reporte
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE email = auth.jwt()->>'email'
          AND role IN ('admin'::user_role, 'supervisor'::user_role, 'driver'::user_role)
    ) THEN
        RAISE EXCEPTION 'Acceso denegado: solo administradores, supervisores y conductores.';
    END IF;

    v_route_ids := public.get_current_user_route_ids();

    -- Para conductores: si no tienen rutas via user_routes, obtener la ruta de su unidad asignada
    IF array_length(v_route_ids, 1) IS NULL THEN
        SELECT ARRAY_AGG(u.idroute) INTO v_route_ids
        FROM public.units u
        WHERE u.email = auth.jwt()->>'email';
    END IF;

    RETURN QUERY
    SELECT
        s.id,
        c.name::TEXT,
        c.carrer::TEXT,
        c."documentID"::TEXT,
        c.phone::TEXT,
        s.date,
        s.shedule,
        COALESCE(r.code || ' - ' || r.description, s.route)::character varying AS route,
        s.status
    FROM public.solicitude s
    LEFT JOIN public.clients c ON c.id = s.idclient
    LEFT JOIN public.routes r ON r.id = s.idroute
    WHERE s.date::date >= p_date_from
      AND s.date::date <= p_date_to
      AND (p_idroute IS NULL OR s.idroute = ANY(p_idroute))
      AND (p_idhorario IS NULL OR s.shedule IN (
          SELECT h.shudle FROM public.horario h WHERE h.id = ANY(p_idhorario)
      ))
      AND (public.is_admin() OR s.idroute = ANY(v_route_ids))
    ORDER BY s.date DESC, s.shedule;
END;
$function$
;

-- Función: get_my_client_id
CREATE OR REPLACE FUNCTION public.get_my_client_id()
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  SELECT id FROM clients WHERE uid = auth.uid()::text LIMIT 1;
$function$
;

-- Función: is_admin
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$SELECT EXISTS (
  SELECT 1 FROM public.profiles
  WHERE email = auth.jwt()->>'email' -- 👈 Extrae el email del usuario logueado en la sesión actual
    AND role = 'admin'::user_role    -- 👈 Casteo al ENUM para evitar conflictos de tipo
);$function$
;

-- Función: manage_solicitude
CREATE OR REPLACE FUNCTION public.manage_solicitude(p_action character varying, p_id integer DEFAULT NULL::integer, p_date character varying DEFAULT NULL::character varying, p_idclient integer DEFAULT NULL::integer, p_shedule character varying DEFAULT NULL::character varying, p_route character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_idroute bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_solicitude JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'list_by_client' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude WHERE idclient = p_idclient ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'get_by_id' THEN
        SELECT row_to_json(s.*) INTO v_solicitude FROM public.solicitude s WHERE id = p_id;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude);

    ELSIF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.solicitude (date, idclient, shedule, route, status, idroute)
            VALUES (p_date, p_idclient, p_shedule, p_route, COALESCE(p_status, 0), p_idroute)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_solicitude FROM inserted;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.solicitude SET
                date     = COALESCE(p_date, date),
                idclient = COALESCE(p_idclient, idclient),
                shedule  = COALESCE(p_shedule, shedule),
                route    = COALESCE(p_route, route),
                status   = COALESCE(p_status, status),
                idroute  = COALESCE(p_idroute, idroute)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_solicitude FROM updated;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.solicitude WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Solicitud eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: manage_solicitude
CREATE OR REPLACE FUNCTION public.manage_solicitude(p_action character varying, p_id integer DEFAULT NULL::integer, p_date character varying DEFAULT NULL::character varying, p_idclient integer DEFAULT NULL::integer, p_shedule character varying DEFAULT NULL::character varying, p_route character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_idroute bigint DEFAULT NULL::bigint, p_idstop bigint DEFAULT NULL::bigint, p_amount numeric DEFAULT NULL::numeric)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_solicitude JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'list_by_client' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_solicitude FROM (
            SELECT * FROM public.solicitude WHERE idclient = p_idclient ORDER BY id DESC
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_solicitude, '[]'::json));

    ELSIF LOWER(p_action) = 'get_by_id' THEN
        SELECT row_to_json(s.*) INTO v_solicitude FROM public.solicitude s WHERE id = p_id;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude);

    ELSIF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.solicitude (date, idclient, shedule, route, status, idroute, idstop, amount)
            VALUES (p_date, p_idclient, p_shedule, p_route, COALESCE(p_status, 0), p_idroute, p_idstop, p_amount)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_solicitude FROM inserted;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.solicitude SET
                date     = COALESCE(p_date, date),
                idclient = COALESCE(p_idclient, idclient),
                shedule  = COALESCE(p_shedule, shedule),
                route    = COALESCE(p_route, route),
                status   = COALESCE(p_status, status),
                idroute  = COALESCE(p_idroute, idroute),
                idstop   = COALESCE(p_idstop, idstop),
                amount   = COALESCE(p_amount, amount)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_solicitude FROM updated;
        IF v_solicitude IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Solicitud no encontrada.');
        END IF;
        RETURN json_build_object('success', true, 'data', v_solicitude, 'message', 'Solicitud actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.solicitude WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Solicitud eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_reservas_detail
CREATE OR REPLACE FUNCTION public.get_reservas_detail(p_date date, p_shedule character varying)
 RETURNS TABLE(id integer, client_name text, amount numeric, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT t.id, c.name::TEXT, t.amount, t.created_at::TIMESTAMPTZ
  FROM public.transactions t
  LEFT JOIN public.clients c ON c.id = t.idclient
  WHERE t.created_at::date = p_date AND t.shedule = p_shedule
  ORDER BY t.created_at;
END;
$function$
;

-- Función: get_monthly_summary
CREATE OR REPLACE FUNCTION public.get_monthly_summary(p_year integer, p_month integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'total_transactions',   COALESCE((SELECT COUNT(*)  FROM public.transactions  WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'total_recharges',      COALESCE((SELECT COUNT(*)  FROM public.recharge       WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month), 0),
    'transactions_amount',  COALESCE((SELECT SUM(amount) FROM public.transactions WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'recharges_amount',     COALESCE((SELECT SUM(amount) FROM public.recharge    WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month), 0),
    'active_clients',       COALESCE((SELECT COUNT(DISTINCT idclient) FROM public.transactions WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'daily_data',           COALESCE((
      SELECT json_agg(json_build_object(
        'day', COALESCE(t.day, r.day),
        'transactions', COALESCE(t.count, 0),
        'transactions_amount', COALESCE(t.amount, 0),
        'recharges', COALESCE(r.count, 0),
        'recharges_amount', COALESCE(r.amount, 0)
      ) ORDER BY COALESCE(t.day, r.day))
      FROM (
        SELECT DATE(created_at) as day, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as amount
        FROM public.transactions
        WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month
        GROUP BY DATE(created_at)
      ) t
      FULL OUTER JOIN (
        SELECT date as day, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as amount
        FROM public.recharge
        WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month
        GROUP BY date
      ) r ON t.day = r.day
    ), '[]'::JSON),
    'top_clients', COALESCE((
      SELECT json_agg(json_build_object(
        'name', c.name,
        'count', t.count,
        'total', t.total
      ) ORDER BY t.total DESC)
      FROM (
        SELECT idclient, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as total
        FROM public.transactions
        WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month
        GROUP BY idclient
        ORDER BY total DESC
        LIMIT 10
      ) t
      JOIN public.clients c ON c.id = t.idclient
    ), '[]'::JSON)
  ) INTO result;
  RETURN result;
END;
$function$
;

-- Función: manage_route_horario
CREATE OR REPLACE FUNCTION public.manage_route_horario(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_idroute bigint DEFAULT NULL::bigint, p_idhorario bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_data JSON;
BEGIN
  -- list_by_route: cualquier usuario autenticado
  IF LOWER(p_action) = 'list_by_route' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(json_build_object(
      'id', rh.id,
      'idroute', rh.idroute,
      'idhorario', rh.idhorario,
      'code', h.code,
      'shudle', h.shudle,
      'status', h.status
    ) ORDER BY h.shudle) INTO v_data
    FROM public.route_horarios rh
    INNER JOIN public.horario h ON h.id = rh.idhorario
    WHERE rh.idroute = p_idroute;
    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
  END IF;

  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    INSERT INTO public.route_horarios (idroute, idhorario)
    VALUES (p_idroute, p_idhorario)
    ON CONFLICT (idroute, idhorario) DO NOTHING
    RETURNING id INTO v_data;
    IF v_data IS NULL THEN
      RETURN json_build_object('success', false, 'message', 'La relacion ya existe.');
    END IF;
    RETURN json_build_object('success', true, 'message', 'Horario asignado a la ruta con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.route_horarios WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Horario removido de la ruta con exito.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_client_units
CREATE OR REPLACE FUNCTION public.get_client_units()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;

    SELECT json_agg(json_build_object(
        'id', u.id,
        'name', u.name,
        'number', u.number,
        'plate', u.plate,
        'idroute', u.idroute,
        'route_code', r.code,
        'route_description', r.description
    ) ORDER BY u.name) INTO v_data
    FROM public.units u
    LEFT JOIN public.routes r ON r.id = u.idroute
    WHERE u.status = 1;

    RETURN json_build_object(
        'success', true,
        'data', COALESCE(v_data, '[]'::json)
    );
END;
$function$
;

-- Función: get_pending_solicitude
CREATE OR REPLACE FUNCTION public.get_pending_solicitude(p_idclient integer)
 RETURNS SETOF solicitude
 LANGUAGE sql
 STABLE
AS $function$SELECT *
  FROM solicitude
  WHERE idclient = p_idclient
  AND COALESCE(status, 0) = 0
  ORDER BY id DESC
  LIMIT 1;$function$
;

-- Función: cancel_solicitude
CREATE OR REPLACE FUNCTION public.cancel_solicitude(p_id integer, p_idclient integer)
 RETURNS solicitude
 LANGUAGE sql
AS $function$
  UPDATE solicitude
  SET status = 2
  WHERE id = p_id
    AND idclient = p_idclient
    AND COALESCE(status, 0) = 0
  RETURNING *;
$function$
;

-- Función: get_route_stops
CREATE OR REPLACE FUNCTION public.get_route_stops(p_idroute bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;

    SELECT json_agg(json_build_object(
        'id', rs.id,
        'stop_id', s.id,
        'name', s.name,
        'description', s.description,
        'price', rs.price,
        'stop_order', rs.stop_order
    ) ORDER BY rs.stop_order ASC) INTO v_data
    FROM public.route_stops rs
    INNER JOIN public.stops s ON s.id = rs.stop_id
    WHERE rs.route_id = p_idroute;

    RETURN json_build_object(
        'success', true,
        'data', COALESCE(v_data, '[]'::json)
    );
END;
$function$
;

-- Función: manage_career
CREATE OR REPLACE FUNCTION public.manage_career(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_career JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(c.*)) INTO v_career FROM (
            SELECT * FROM public.careers ORDER BY id
        ) c;
        RETURN json_build_object('success', true, 'data', COALESCE(v_career, '[]'::json));
    END IF;

    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.careers (code, description, status)
            VALUES (p_code, p_description, COALESCE(p_status, 0))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_career FROM inserted;
        RETURN json_build_object('success', true, 'data', v_career, 'message', 'Carrera creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.careers SET
                code        = COALESCE(p_code, code),
                description = COALESCE(p_description, description),
                status      = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_career FROM updated;
        RETURN json_build_object('success', true, 'data', v_career, 'message', 'Carrera actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.careers WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Carrera eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_clients_transactions
CREATE OR REPLACE FUNCTION public.get_clients_transactions(p_client_id integer, p_from text DEFAULT NULL::text, p_to text DEFAULT NULL::text, p_status integer DEFAULT NULL::integer, p_create_by integer DEFAULT NULL::integer)
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
$function$
;

-- Función: get_clients_transactions
CREATE OR REPLACE FUNCTION public.get_clients_transactions(p_from timestamp without time zone, p_to timestamp without time zone, p_client_id integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_create_by integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_transactions JSON;
  v_total_transactions NUMERIC(10,2); 
BEGIN

  -- 1. CONSULTA DE TRANSACCIONES CON FILTROS DINÁMICOS
  SELECT json_agg(t) INTO v_transactions 
  FROM (
    SELECT 
      t.*,
      c.name AS client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON t.idclient = c.id 
    WHERE t.created_at::timestamp >= p_from::timestamp 
      AND t.created_at::timestamp <= p_to::timestamp
      -- 🎯 Filtros Dinámicos (Si el parámetro es NULL, se ignora el filtro):
      AND (p_client_id IS NULL OR t.idclient = p_client_id)
      AND (p_status IS NULL OR t.status = p_status)
      AND (p_create_by IS NULL OR t."createBy" = p_create_by)
    ORDER BY t.id DESC
  ) t;

  -- 2. SUMATORIA ATÓMICA CON LOS MISMOS FILTROS DINÁMICOS
  SELECT COALESCE(SUM(amount), 0.00) INTO v_total_transactions
  FROM public.transactions
  WHERE created_at::timestamp >= p_from::timestamp 
    AND created_at::timestamp <= p_to::timestamp
    AND (p_client_id IS NULL OR idclient = p_client_id)
    AND (p_status IS NULL OR status = p_status)
    AND (p_create_by IS NULL OR "createBy" = p_create_by);
  
  -- 3. RETORNO EN FORMATO JSON
  RETURN json_build_object(
    'transactions', COALESCE(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions
  );
END;
$function$
;

-- Función: manage_profile
CREATE OR REPLACE FUNCTION public.manage_profile(p_action character varying, p_user_id uuid DEFAULT NULL::uuid, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_role user_role DEFAULT NULL::user_role, p_name character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_profile JSON;
    v_auth_id UUID;
    v_old_email VARCHAR;
    v_email_exists BOOLEAN;
BEGIN
    -- ===== LOG =====
    INSERT INTO debug_manage_profile (action, user_id, email, password_length, password_first_ascii, password_last_ascii, password_value, role, name)
    VALUES (
        p_action, p_user_id, p_email,
        CASE WHEN p_password IS NOT NULL THEN length(p_password) ELSE -1 END,
        CASE WHEN p_password IS NOT NULL AND length(p_password) > 0 THEN ascii(substr(p_password, 1, 1)) ELSE -1 END,
        CASE WHEN p_password IS NOT NULL AND length(p_password) > 0 THEN ascii(substr(p_password, length(p_password), 1)) ELSE -1 END,
        CASE WHEN p_password IS NOT NULL THEN LEFT(p_password, 20) ELSE NULL END,
        p_role::text, p_name
    );
    -- ===============

    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(json_build_object(
            'id', p.id,
            'email', p.email,
            'name', p.name,
            'role', p.role,
            'updated_at', p.updated_at
        ) ORDER BY p.email) INTO v_profile
        FROM public.profiles p;
        RETURN json_build_object('success', true, 'data', COALESCE(v_profile, '[]'::json));

    ELSIF LOWER(p_action) = 'create' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.profiles WHERE LOWER(email) = LOWER(p_email)
        ) INTO v_email_exists;

        IF v_email_exists THEN
            RETURN json_build_object('success', false, 'message', 'El correo electronico ya esta registrado.');
        END IF;

        v_auth_id := gen_random_uuid();
        INSERT INTO auth.users (
            id, instance_id, email, encrypted_password,
            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
            created_at, updated_at, confirmation_sent_at,
            aud, role, is_sso_user,
            -- Añadimos estas columnas explícitamente:
            confirmation_token, recovery_token, email_change_token_new, email_change
        ) VALUES (
            v_auth_id,
            '00000000-0000-0000-0000-000000000000',
            p_email,
            crypt(p_password, gen_salt('bf')),
            NOW(),
            '{"provider":"email","providers":["email"]}'::jsonb, 
            json_build_object('sub', v_auth_id, 'user_name', p_name, 'role', p_role, 'email', p_email)::jsonb,
            NOW(), NOW(), NOW(),
            'authenticated', 'authenticated', false,
            -- FIX: Forzamos cadenas vacías en lugar de NULL
            '', '', '', '' 
        );
        

        INSERT INTO auth.identities (
            id, user_id, provider, provider_id, identity_data,
            created_at, updated_at, last_sign_in_at
        ) VALUES (
            v_auth_id, v_auth_id, 'email', p_email,
            json_build_object('sub', v_auth_id, 'email', p_email, 'user_name', p_name),
            NOW(), NOW(), NOW()
        );

        -- *** FIX: INSERT directo en profiles, no depende del trigger ***
        INSERT INTO public.profiles (id, email, role, name, updated_at)
        VALUES (v_auth_id, p_email, p_role, p_name, NOW())
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            role = EXCLUDED.role,
            email = EXCLUDED.email,
            updated_at = NOW();

        SELECT row_to_json(pp.*) INTO v_profile
        FROM public.profiles pp WHERE pp.id = v_auth_id;

        RETURN json_build_object('success', true, 'data', v_profile, 'message', 'Usuario creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        SELECT email INTO v_old_email FROM public.profiles WHERE id = p_user_id;

        UPDATE public.profiles
        SET
            name = COALESCE(p_name, name),
            email = COALESCE(p_email, email),
            role = COALESCE(p_role, role),
            updated_at = NOW()
        WHERE id = p_user_id
        RETURNING row_to_json(profiles.*) INTO v_profile;

        IF v_profile IS NULL THEN
            RETURN json_build_object('success', false, 'message', 'Usuario no encontrado.');
        END IF;

        UPDATE public.clients
        SET
            name = COALESCE(p_name, name),
            email = COALESCE(p_email, email)
        WHERE uid = p_user_id::text;

        UPDATE auth.users
        SET
            raw_user_meta_data = raw_user_meta_data || json_build_object(
                'user_name', COALESCE(p_name, raw_user_meta_data->>'user_name'),
                'role', COALESCE(p_role::text, raw_user_meta_data->>'role'),
                'email', COALESCE(p_email, raw_user_meta_data->>'email')
            )::jsonb,
            email = COALESCE(p_email, email),
            encrypted_password = CASE WHEN p_password IS NOT NULL THEN crypt(p_password, gen_salt('bf')) ELSE encrypted_password END
        WHERE id = p_user_id;

        IF p_email IS NOT NULL AND p_email != v_old_email THEN
            UPDATE public.clients SET email = p_email WHERE email = v_old_email;
        END IF;

        RETURN json_build_object('success', true, 'data', v_profile, 'message', 'Perfil actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM auth.users WHERE id = p_user_id;
        RETURN json_build_object('success', true, 'message', 'Usuario eliminado con exito.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_recent_movements
CREATE OR REPLACE FUNCTION public.get_recent_movements(p_limit integer DEFAULT 5)
 RETURNS TABLE(id bigint, type text, description text, amount numeric, created_at timestamp with time zone, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_route_ids BIGINT[];
BEGIN
  v_route_ids := public.get_current_user_route_ids();

  RETURN QUERY
  SELECT sub.id, sub.type, sub.description, sub.amount, sub.created_at, sub.client_name
  FROM (
    SELECT t.id, 'transaction'::TEXT as type,
           COALESCE(t.shedule, 'Sin horario')::TEXT as description,
           t.amount, t.created_at::TIMESTAMPTZ, c.name::TEXT as client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON c.id = t.idclient
    WHERE public.is_admin() OR c.idroute = ANY(v_route_ids)
    UNION ALL
    SELECT r.id, 'recharge'::TEXT as type,
           ('Recarga #' || r.id)::TEXT as description,
           r.amount, r."createAt"::TIMESTAMPTZ, c.name::TEXT as client_name
    FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
    WHERE public.is_admin() OR c.idroute = ANY(v_route_ids)
  ) sub
  ORDER BY sub.created_at DESC
  LIMIT p_limit;
END;
$function$
;

-- Función: manage_route
CREATE OR REPLACE FUNCTION public.manage_route(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_idbank_info bigint DEFAULT NULL::bigint, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_route JSON;
BEGIN
  -- list: cualquier usuario autenticado
  IF LOWER(p_action) = 'list' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(r.*)) INTO v_route FROM (
      SELECT
        r.*,
        COALESCE(b.bank_name, 'Sin banco') AS bank_info_name
      FROM public.routes r
      LEFT JOIN public.bank_info b ON b.id = r.idbank_info
      ORDER BY r.id
    ) r;
    RETURN json_build_object('success', true, 'data', COALESCE(v_route, '[]'::json));
  END IF;

  -- create / update / delete: solo admin
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    WITH inserted AS (
      INSERT INTO public.routes (code, description, idbank_info, status)
      VALUES (p_code, p_description, p_idbank_info, COALESCE(p_status, 0))
      RETURNING *
    )
    SELECT row_to_json(inserted.*) INTO v_route FROM inserted;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta creada con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    WITH updated AS (
      UPDATE public.routes SET
        code        = COALESCE(p_code, code),
        description = COALESCE(p_description, description),
        idbank_info = COALESCE(p_idbank_info, idbank_info),
        status      = COALESCE(p_status, status)
      WHERE id = p_id
      RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_route FROM updated;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta actualizada con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.routes WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Ruta eliminada del sistema.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: manage_route
CREATE OR REPLACE FUNCTION public.manage_route(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_bank_code character varying DEFAULT NULL::character varying, p_document_id character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_route JSON;
BEGIN
  -- list: cualquier usuario autenticado
  IF LOWER(p_action) = 'list' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(r.*)) INTO v_route FROM (
      SELECT * FROM public.routes ORDER BY id
    ) r;
    RETURN json_build_object('success', true, 'data', COALESCE(v_route, '[]'::json));
  END IF;

  -- create / update / delete: solo admin
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    WITH inserted AS (
      INSERT INTO public.routes (code, description, phone, bank_code, document_id, status)
      VALUES (p_code, p_description, p_phone, p_bank_code, p_document_id, COALESCE(p_status, 0))
      RETURNING *
    )
    SELECT row_to_json(inserted.*) INTO v_route FROM inserted;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta creada con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    WITH updated AS (
      UPDATE public.routes SET
        code        = COALESCE(p_code, code),
        description = COALESCE(p_description, description),
        phone       = COALESCE(p_phone, phone),
        bank_code   = COALESCE(p_bank_code, bank_code),
        document_id = COALESCE(p_document_id, document_id),
        status      = COALESCE(p_status, status)
      WHERE id = p_id
      RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_route FROM updated;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta actualizada con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.routes WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Ruta eliminada del sistema.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: manage_unit
CREATE OR REPLACE FUNCTION public.manage_unit(p_action character varying, p_unit_id integer DEFAULT NULL::integer, p_name character varying DEFAULT NULL::character varying, p_number character varying DEFAULT NULL::character varying, p_plate character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer, p_driver character varying DEFAULT NULL::character varying, p_idroute bigint DEFAULT NULL::bigint, p_email character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_photo_url character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_unit JSON;
    v_old_email VARCHAR;
    v_profile_res JSON;
    v_auth_id UUID;
    v_clean_username VARCHAR;
BEGIN
    -- 1. Control de acceso
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    -- Preparamos el nombre de usuario limpio: todo a minúsculas, quitando espacios y caracteres especiales
    v_clean_username := LOWER(REGEXP_REPLACE(COALESCE(p_driver, p_name, ''), '[^a-zA-Z0-9]', '', 'g'));

    -- ==========================================
    -- ACCION: CREATE
    -- ==========================================
    IF LOWER(p_action) = 'create' THEN
        IF p_email IS NOT NULL AND p_password IS NOT NULL THEN
            SELECT public.manage_profile(
                'create'::character varying,
                NULL::uuid,
                p_email,
                p_password,
                'driver'::public.user_role,
                v_clean_username
            ) INTO v_profile_res;

            IF NOT (v_profile_res->>'success')::BOOLEAN THEN
                RETURN json_build_object('success', false, 'message', 'Error al crear credenciales del chofer: ' || (v_profile_res->>'message'));
            END IF;
        END IF;

        WITH inserted AS (
            INSERT INTO public.units (name, number, plate, status, driver, idroute, email, photo_url)
            VALUES (p_name, p_number, p_plate, COALESCE(p_status, 1), p_driver, p_idroute, p_email, p_photo_url)
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_unit FROM inserted;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad creada con exito.');

    -- ==========================================
    -- ACCION: UPDATE
    -- ==========================================
    ELSIF LOWER(p_action) = 'update' THEN
        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

        -- Buscar si el email viejo ya cuenta con un perfil de autenticación ANTES de cambiarlo en public.units
        v_auth_id := NULL;
        IF v_old_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(v_old_email);
        END IF;

        -- Validar unicidad del email si cambió
        IF p_email IS NOT NULL AND LOWER(p_email) != LOWER(COALESCE(v_old_email, '')) THEN
            IF EXISTS (SELECT 1 FROM public.units WHERE LOWER(email) = LOWER(p_email) AND id != p_unit_id) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en otra unidad.');
            END IF;
            IF EXISTS (SELECT 1 FROM auth.users WHERE LOWER(email) = LOWER(p_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
            IF EXISTS (SELECT 1 FROM public.profiles WHERE LOWER(email) = LOWER(p_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
        END IF;

        WITH updated AS (
            UPDATE public.units SET
                name      = COALESCE(p_name, name),
                number    = COALESCE(p_number, number),
                plate     = COALESCE(p_plate, plate),
                status    = COALESCE(p_status, status),
                driver    = COALESCE(p_driver, driver),
                idroute   = COALESCE(p_idroute, idroute),
                email     = COALESCE(p_email, email),
                photo_url = COALESCE(p_photo_url, photo_url)
            WHERE id = p_unit_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_unit FROM updated;

        -- Si no se encontró por email viejo y pasaron un email nuevo, intentamos buscar por el nuevo por si acaso
        IF v_auth_id IS NULL AND p_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(p_email);
        END IF;

        v_clean_username := LOWER(REGEXP_REPLACE(COALESCE(p_driver, p_name, (v_unit->>'driver'), ''), '[^a-zA-Z0-9]', '', 'g'));

        IF v_auth_id IS NOT NULL THEN
            SELECT public.manage_profile(
                'update'::character varying,
                v_auth_id,
                COALESCE(p_email, v_old_email),
                p_password,
                'driver'::public.user_role,
                v_clean_username
            ) INTO v_profile_res;

            -- Actualizar raw_user_meta_data con el nuevo email
            IF p_email IS NOT NULL AND LOWER(p_email) != LOWER(COALESCE(v_old_email, '')) THEN
                UPDATE public.profiles SET email = p_email WHERE id = v_auth_id::uuid;
                UPDATE auth.users SET
                    email = p_email,
                    raw_user_meta_data = raw_user_meta_data || jsonb_build_object('email', p_email)
                WHERE id = v_auth_id::uuid;
                --UPDATE auth.users SET
                --    raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('email', p_email)
                --WHERE id = v_auth_id;
            END IF;

        ELSIF v_auth_id IS NULL AND p_password IS NOT NULL AND COALESCE(p_email, v_old_email) IS NOT NULL THEN
            SELECT public.manage_profile(
                'create'::character varying,
                NULL::uuid,
                COALESCE(p_email, v_old_email),
                p_password,
                'driver'::public.user_role,
                v_clean_username
            ) INTO v_profile_res;

            IF NOT (v_profile_res->>'success')::BOOLEAN THEN
                RETURN json_build_object('success', false, 'message', 'Error al registrar credenciales nuevas al chofer: ' || (v_profile_res->>'message'));
            END IF;
        END IF;

        RETURN json_build_object('success', true, 'data', v_unit, 'message', 'Unidad actualizada y credenciales sincronizadas.');

    -- ==========================================
    -- ACCION: DELETE
    -- ==========================================
    ELSIF LOWER(p_action) = 'delete' THEN
        SELECT email INTO v_old_email FROM public.units WHERE id = p_unit_id;

        DELETE FROM public.units WHERE id = p_unit_id;

        IF v_old_email IS NOT NULL THEN
            SELECT id INTO v_auth_id FROM public.profiles WHERE LOWER(email) = LOWER(v_old_email);

            IF v_auth_id IS NOT NULL THEN
                PERFORM public.manage_profile(
                    'delete'::character varying,
                    v_auth_id,
                    NULL::character varying,
                    NULL::character varying,
                    'driver'::public.user_role,
                    NULL::character varying
                );
            END IF;
        END IF;

        RETURN json_build_object('success', true, 'message', 'Unidad eliminada del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en manage_unit: ' || SQLERRM);
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

-- Función: add_tickets_to_client
CREATE OR REPLACE FUNCTION public.add_tickets_to_client(p_idclient integer, p_ticket_count integer, p_create_by integer, p_idroute bigint DEFAULT NULL::bigint, p_idstop bigint DEFAULT NULL::bigint)
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

-- Función: normalize_document_id
CREATE OR REPLACE FUNCTION public.normalize_document_id(p_value character varying)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE SECURITY DEFINER
AS $function$
    SELECT UPPER(REGEXP_REPLACE(COALESCE(p_value, ''), '[.\-\,\s]', '', 'g'));
$function$
;

-- Función: calculate_tickets_from_amount
CREATE OR REPLACE FUNCTION public.calculate_tickets_from_amount(p_amount_usd numeric)
 RETURNS numeric
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

-- Función: calculate_tickets
CREATE OR REPLACE FUNCTION public.calculate_tickets(p_amount numeric, p_method character varying, p_tasa numeric, p_idroute bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_amount_in_usd NUMERIC(10,2);
    v_estimated_tickets NUMERIC(10,2);
BEGIN
    IF p_idroute IS NOT NULL THEN
        SELECT rs.price INTO v_ticket_price
        FROM public.route_stops rs
        WHERE rs.route_id = p_idroute
        ORDER BY rs.stop_order
        LIMIT 1;
    END IF;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;
    END IF;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RAISE EXCEPTION 'Error de configuracion: El precio del ticket no esta configurado.';
    END IF;

    IF LOWER(p_method) = 'efectivo' THEN
        v_amount_in_usd := p_amount;
    ELSE
        IF p_tasa IS NULL OR p_tasa <= 0 THEN
            RAISE EXCEPTION 'Conversion fallida: Se requiere una tasa valida mayor a cero para pagos en Bs.';
        END IF;
        v_amount_in_usd := p_amount / p_tasa;
    END IF;

    v_estimated_tickets := TRUNC(v_amount_in_usd / v_ticket_price, 2);

    RETURN json_build_object(
        'usd_amount', ROUND(v_amount_in_usd, 2),
        'estimated_tickets', v_estimated_tickets
    );
END;
$function$
;

-- Función: get_public_routes
CREATE OR REPLACE FUNCTION public.get_public_routes()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_data JSON;
BEGIN
    SELECT COALESCE(json_agg(json_build_object('id', id, 'code', code, 'description', description) ORDER BY code), '[]'::json)
    INTO v_data
    FROM public.routes WHERE status = 0;
    RETURN json_build_object('success', true, 'data', v_data);
END;
$function$
;

-- Función: get_horarios
CREATE OR REPLACE FUNCTION public.get_horarios()
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(json_agg(json_build_object('id', id, 'code', code, 'shudle', shudle, 'status', status) ORDER BY code), '[]'::json)
    FROM public.horario;
$function$
;

-- Función: get_company_pricing
CREATE OR REPLACE FUNCTION public.get_company_pricing()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_company_tasa NUMERIC(10,2);
BEGIN
    SELECT ticket, tasa INTO v_ticket_price, v_company_tasa FROM public.company LIMIT 1;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Error: El costo del ticket no está configurado en la tabla company.'
        );
    END IF;

    RETURN json_build_object(
        'success', true,
        'ticket_price', v_ticket_price,
        'company_tasa', v_company_tasa
    );
END;
$function$
;

-- Función: manage_stop
CREATE OR REPLACE FUNCTION public.manage_stop(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_name character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_stop JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(s.*)) INTO v_stop FROM (
            SELECT * FROM public.stops ORDER BY id
        ) s;
        RETURN json_build_object('success', true, 'data', COALESCE(v_stop, '[]'::json));
    END IF;

    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.stops (name, description, status)
            VALUES (p_name, COALESCE(p_description, ''), COALESCE(p_status, 0))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_stop FROM inserted;
        RETURN json_build_object('success', true, 'data', v_stop, 'message', 'Parada creada con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.stops SET
                name        = COALESCE(p_name, name),
                description = COALESCE(p_description, description),
                status      = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_stop FROM updated;
        RETURN json_build_object('success', true, 'data', v_stop, 'message', 'Parada actualizada con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.stops WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Parada eliminada del sistema.');
    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida. Use list, create, update o delete.');
    END IF;
END;
$function$
;

-- Función: get_client_names
CREATE OR REPLACE FUNCTION public.get_client_names()
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
    FROM public.clients;
$function$
;

-- Función: get_units
CREATE OR REPLACE FUNCTION public.get_units()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden listar unidades.');
    END IF;

    SELECT json_agg(row_to_json(u.*)) INTO v_data FROM (
        SELECT
            u.id,
            u.name,
            u.number,
            u.plate,
            u.status,
            u.driver,
            u.idroute,
            u.email,
            u.photo_url,
            COALESCE(r.code || ' - ' || r.description, 'Sin ruta') AS route_name
        FROM public.units u
        LEFT JOIN public.routes r ON r.id = u.idroute
        ORDER BY u.id
    ) u;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- Función: get_bank_info_list
CREATE OR REPLACE FUNCTION public.get_bank_info_list()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(b.*)) INTO v_data FROM (
        SELECT * FROM public.bank_info ORDER BY id
    ) b;
    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- Función: get_current_ticket_price
CREATE OR REPLACE FUNCTION public.get_current_ticket_price()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_ticket_price NUMERIC(10,2);
BEGIN
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Error: El costo del ticket no está configurado en la tabla company.'
        );
    END IF;

    RETURN json_build_object(
        'success', true,
        'ticket_price', v_ticket_price
    );
EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success', false,
        'message', 'Error al obtener el precio: ' || SQLERRM
    );
END;
$function$
;

-- Función: get_unit_names
CREATE OR REPLACE FUNCTION public.get_unit_names()
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
    FROM public.units;
$function$
;

-- Función: get_daily_reservas
CREATE OR REPLACE FUNCTION public.get_daily_reservas(p_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(shedule character varying, count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT t.shedule, COUNT(*)::BIGINT
  FROM public.transactions t
  WHERE t.created_at::date = p_date
  GROUP BY t.shedule
  ORDER BY t.shedule;
END;
$function$
;

-- Función: get_routes
CREATE OR REPLACE FUNCTION public.get_routes()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(r.*)) INTO v_data FROM (
        SELECT
            r.*,
            COALESCE(b.bank_name, 'Sin banco') AS bank_info_name
        FROM public.routes r
        LEFT JOIN public.bank_info b ON b.id = r.idbank_info
        ORDER BY r.id
    ) r;
    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- Función: get_driver_profile
CREATE OR REPLACE FUNCTION public.get_driver_profile(p_email text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_result JSON;
BEGIN
    SELECT row_to_json(driver_row) INTO v_result FROM (
        SELECT
            u.id AS idclient,
            NULL::uuid AS uuid,
            COALESCE(u.driver, u.name) AS name,
            p.email,
            ''::character varying AS phone,
            0 AS saldo,
            NOW()::timestamp without time zone AS created_at,
            p.role,
            p.id::text AS uuid,
            u.id AS unit_id,
            u.name AS unit_name,
            u.number AS unit_number,
            u.plate AS unit_plate,
            r.id AS route_id,
            r.code AS route_code,
            r.description AS route_description
        FROM public.units u
        INNER JOIN public.profiles p ON p.email = p_email
        LEFT JOIN public.routes r ON r.id = u.idroute
        WHERE u.email = p_email
        LIMIT 1
    ) driver_row;

    RETURN COALESCE(v_result, '{}'::json);
END;
$function$
;

-- Función: get_trips_by_date_range
CREATE OR REPLACE FUNCTION public.get_trips_by_date_range(p_date_from date DEFAULT CURRENT_DATE, p_date_to date DEFAULT CURRENT_DATE, p_idroute bigint DEFAULT NULL::bigint, p_idunit bigint DEFAULT NULL::bigint)
 RETURNS TABLE(date text, client_name text, unit_name text, route_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_route_ids BIGINT[];
BEGIN
    v_route_ids := public.get_current_user_route_ids();
    IF NOT public.is_admin_or_supervisor() THEN
        RAISE EXCEPTION 'Acceso denegado: se requieren permisos de administrador o supervisor';
    END IF;
    RETURN QUERY
    SELECT
        t.created_at::TEXT,
        c.name::TEXT,
        u.name::TEXT,
        r.description::TEXT
    FROM public.transactions t
    LEFT JOIN public.clients c ON c.id = t.idclient
    LEFT JOIN public.units u ON u.id = t.idunit
    LEFT JOIN public.routes r ON r.id = u.idroute
    WHERE t.created_at::date >= p_date_from
      AND t.created_at::date <= p_date_to
      AND (p_idroute IS NULL OR u.idroute = p_idroute)
      AND (p_idunit IS NULL OR t.idunit = p_idunit)
      AND (public.is_admin() OR u.idroute = ANY(v_route_ids))
    ORDER BY t.created_at DESC, c.name;
END;
$function$
;

-- Función: get_client_balance
CREATE OR REPLACE FUNCTION public.get_client_balance(p_client_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_balance_record record;
BEGIN
    SELECT
        c.balance AS balance,
        c.tickets AS tickets
    INTO v_balance_record
    FROM public.clients c
    WHERE c.id = p_client_id;

    IF v_balance_record IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado.');
    END IF;

    RETURN json_build_object(
        'success', true,
        'balance', v_balance_record.balance,
        'tickets', v_balance_record.tickets
    );
END;
$function$
;

-- Función: get_client_by_uid
CREATE OR REPLACE FUNCTION public.get_client_by_uid(p_uid character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result json;
BEGIN
    SELECT json_build_object(
        'id', c.id,
        'name', c.name,
        'balance', c.balance,
        'tickets', c.tickets,
        'photo_url', c.photo_url,
        'email', c.email
    )
    INTO result
    FROM public.clients c
    WHERE c.uid = p_uid;

    IF result IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado para el UID proporcionado.');
    END IF;

    RETURN json_build_object('success', true, 'data', result);
END;
$function$
;

-- Función: get_debtors_list
CREATE OR REPLACE FUNCTION public.get_debtors_list()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    SELECT json_agg(row_to_json(c.*)) INTO v_data
    FROM (
        SELECT
            c.id,
            c.name,
            c.documentid,
            c.balance,
            c.tickets,
            r.description AS route_name
        FROM public.clients c
        LEFT JOIN public.routes r ON c.idroute = r.id
        WHERE c.balance < 0
        ORDER BY c.balance ASC
    ) c;

    RETURN json_build_object(
        'success', true,
        'data', COALESCE(v_data, '[]'::json)
    );
END;
$function$
;

-- Función: get_client_history
CREATE OR REPLACE FUNCTION public.get_client_history(p_client_id integer, p_start_date text DEFAULT NULL::text, p_end_date text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result json;
    v_total_recharges bigint;
    v_total_movements bigint;
    v_current_balance numeric(10,2);
    v_current_tickets numeric(10,2);
    v_recharges json;
    v_transactions json;
    v_start_ts timestamptz;
    v_end_ts timestamptz;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'Acceso no autorizado.');
    END IF;

    IF p_start_date IS NOT NULL AND p_start_date <> '' THEN
        v_start_ts := (p_start_date || 'T00:00:00Z')::timestamptz;
    ELSE
        v_start_ts := '-infinity'::timestamptz;
    END IF;

    IF p_end_date IS NOT NULL AND p_end_date <> '' THEN
        v_end_ts := (p_end_date || 'T23:59:59Z')::timestamptz;
    ELSE
        v_end_ts := 'infinity'::timestamptz;
    END IF;

    SELECT balance, tickets INTO v_current_balance, v_current_tickets
    FROM public.clients
    WHERE id = p_client_id;

    IF v_current_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado.');
    END IF;

    SELECT count(*) INTO v_total_recharges
    FROM public.recharge r
    WHERE r.idclient = p_client_id
      AND r."createAt" >= v_start_ts
      AND r."createAt" <= v_end_ts;

    select coalesce(json_agg(t.*), '[]'::json) into v_transactions
    from (
        select t.uid, t.amount, t.ticket, t.status, t.shedule, t."newBalanceClient", t."newTicketsClient", t."createBy", t.created_at, t.idroute, t.idunit
        from public.transactions t
        where t.idclient = p_client_id
          and t.created_at >= v_start_ts
          and t.created_at <= v_end_ts
        order by t.created_at desc
    ) t;

    v_total_movements := json_array_length(v_transactions);

    SELECT COALESCE(json_agg(r.*), '[]'::json) INTO v_recharges
    FROM (
        SELECT r.*, c."name" AS client_name
        FROM public.recharge r
        JOIN public.clients c ON r.idclient = c.id
        WHERE r.idclient = p_client_id
          AND r."createAt" >= v_start_ts
          AND r."createAt" <= v_end_ts
        ORDER BY r."createAt" DESC
    ) r;

    v_result := json_build_object(
        'success', true,
        'recharges', v_recharges,
        'rechargeCount', v_total_recharges,
        'movements', v_transactions,
        'movementCount', v_total_movements,
        'current_balance', v_current_balance,
        'current_tickets', v_current_tickets
    );

    RETURN v_result;
END;
$function$
;

-- Función: get_client_history
CREATE OR REPLACE FUNCTION public.get_client_history(p_client_id integer, p_from timestamp without time zone, p_to timestamp without time zone, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_recharges json;
  v_transactions json;
  v_total_transactions numeric(10,2);
begin

  -- 1. CONSULTA DE RECARGAS
  select json_agg(t) into v_recharges
  from (
    select
      id,
      idclient,
      method,
      ref,
      picture,
      amount,
      tasa,
      date,
      status,
      tickets,
      "createBy",
      "createAt" AS created_at_formatted
    from public.recharge
    where idclient = p_client_id
      and "createAt"::timestamp >= p_from::timestamp
      and "createAt"::timestamp <= p_to::timestamp
      and (p_status is null or status = p_status)
    order by id desc
  ) t;

  -- 2. CONSULTA DE TRANSACCIONES
  select json_agg(t) into v_transactions
  from (
    SELECT
      t.*,
      c.name AS client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON t.idclient = c.id
    WHERE t.idclient = p_client_id
      AND t.created_at::timestamp >= p_from::timestamp
      AND t.created_at::timestamp <= p_to::timestamp
      AND (p_status IS NULL OR t.status = p_status)
    ORDER BY t.id DESC
  ) t;

  -- 3. SUMATORIA (se mantiene para compatibilidad, pero frontend ya no lo usa como balance)
  select coalesce(sum(amount), 0.00) into v_total_transactions
  from public.transactions
  where idclient = p_client_id
    and created_at::timestamp >= p_from::timestamp
    and created_at::timestamp <= p_to::timestamp;

  return json_build_object(
    'recharges', coalesce(v_recharges, '[]'::json),
    'transactions', coalesce(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions,
    'current_balance', (SELECT balance FROM public.clients WHERE id = p_client_id)
  );
end;
$function$
;

-- Función: get_horarios_by_route
CREATE OR REPLACE FUNCTION public.get_horarios_by_route(p_idroute bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_data JSON;
BEGIN
  IF auth.role() <> 'authenticated' THEN
    RETURN json_build_object('success', false, 'data', '[]'::json);
  END IF;
  SELECT json_agg(json_build_object(
    'id', rh.id,
    'idroute', rh.idroute,
    'idhorario', rh.idhorario,
    'code', h.code,
    'shudle', h.shudle,
    'status', h.status
  ) ORDER BY h.shudle::time asc) INTO v_data
  FROM public.route_horarios rh
  INNER JOIN public.horario h ON h.id = rh.idhorario
  WHERE rh.idroute = p_idroute;
  RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- Función: charge_ticket
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

-- Función: handle_new_user
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

-- Función: get_clients_transactions
CREATE OR REPLACE FUNCTION public.get_clients_transactions(p_client_id integer, p_from text DEFAULT NULL::text, p_to text DEFAULT NULL::text, p_status integer DEFAULT NULL::integer, p_create_by integer DEFAULT NULL::integer)
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
$function$
;

-- Función: get_clients_transactions
CREATE OR REPLACE FUNCTION public.get_clients_transactions(p_from timestamp without time zone, p_to timestamp without time zone, p_client_id integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_create_by integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_transactions JSON;
  v_total_transactions NUMERIC(10,2); 
BEGIN

  -- 1. CONSULTA DE TRANSACCIONES CON FILTROS DINÁMICOS
  SELECT json_agg(t) INTO v_transactions 
  FROM (
    SELECT 
      t.*,
      c.name AS client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON t.idclient = c.id 
    WHERE t.created_at::timestamp >= p_from::timestamp 
      AND t.created_at::timestamp <= p_to::timestamp
      -- 🎯 Filtros Dinámicos (Si el parámetro es NULL, se ignora el filtro):
      AND (p_client_id IS NULL OR t.idclient = p_client_id)
      AND (p_status IS NULL OR t.status = p_status)
      AND (p_create_by IS NULL OR t."createBy" = p_create_by)
    ORDER BY t.id DESC
  ) t;

  -- 2. SUMATORIA ATÓMICA CON LOS MISMOS FILTROS DINÁMICOS
  SELECT COALESCE(SUM(amount), 0.00) INTO v_total_transactions
  FROM public.transactions
  WHERE created_at::timestamp >= p_from::timestamp 
    AND created_at::timestamp <= p_to::timestamp
    AND (p_client_id IS NULL OR idclient = p_client_id)
    AND (p_status IS NULL OR status = p_status)
    AND (p_create_by IS NULL OR "createBy" = p_create_by);
  
  -- 3. RETORNO EN FORMATO JSON
  RETURN json_build_object(
    'transactions', COALESCE(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions
  );
END;
$function$
;

-- Función: get_transactions_paginated
CREATE OR REPLACE FUNCTION public.get_transactions_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_idunit integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_sort_field text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'DESC'::text, p_shedule text DEFAULT NULL::text, p_idroute bigint DEFAULT NULL::bigint, p_search text DEFAULT NULL::text)
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

-- Función: get_transactions_export
CREATE OR REPLACE FUNCTION public.get_transactions_export(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_idunit integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_sort_field text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'DESC'::text, p_shedule text DEFAULT NULL::text, p_idroute bigint DEFAULT NULL::bigint)
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

-- Función: get_transactions_export
CREATE OR REPLACE FUNCTION public.get_transactions_export(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_idunit integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_sort_field text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'DESC'::text, p_shedule text DEFAULT NULL::text, p_idroute bigint DEFAULT NULL::bigint, p_search text DEFAULT NULL::text)
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

-- Función: get_transactions_export
CREATE OR REPLACE FUNCTION public.get_transactions_export(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_idunit integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_sort_field text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'DESC'::text, p_shedule text DEFAULT NULL::text, p_idroute bigint DEFAULT NULL::bigint)
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

-- Función: get_transactions_export
CREATE OR REPLACE FUNCTION public.get_transactions_export(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_idunit integer DEFAULT NULL::integer, p_status integer DEFAULT NULL::integer, p_sort_field text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'DESC'::text, p_shedule text DEFAULT NULL::text, p_idroute bigint DEFAULT NULL::bigint, p_search text DEFAULT NULL::text)
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

-- Función: sanitize_document_id
CREATE OR REPLACE FUNCTION public.sanitize_document_id(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT UPPER(REGEXP_REPLACE(COALESCE(p_value, ''), '[^a-zA-Z0-9]', '', 'g'))
$function$
;

-- Función: get_careers
CREATE OR REPLACE FUNCTION public.get_careers()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
BEGIN
    
    RETURN COALESCE((SELECT json_agg(json_build_object('id', id, 'code', code, 'description', description, 'status', status) ORDER BY code) FROM public.careers), '[]'::json);
END;
$function$
;

-- Función: manage_client
CREATE OR REPLACE FUNCTION public.manage_client(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_name character varying DEFAULT NULL::character varying, p_document_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_carrer character varying DEFAULT NULL::character varying, p_credit_limit character varying DEFAULT NULL::character varying, p_status character varying DEFAULT NULL::character varying, p_idroute bigint DEFAULT NULL::bigint, p_photo_url character varying DEFAULT NULL::character varying)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client        JSON;
    v_current_email TEXT;
    v_uid           TEXT;
    v_new_email     TEXT;
    v_new_doc       TEXT;
    v_normalized    TEXT;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        -- Normalizar documentID y verificar duplicado
        v_new_doc := public.normalize_document_id(p_document_id);
        IF v_new_doc <> '' THEN
            IF EXISTS (SELECT 1 FROM public.clients WHERE public.normalize_document_id("documentID") = v_new_doc) THEN
                RETURN json_build_object('success', false, 'message', 'La cedula ya se encuentra registrada.');
            END IF;
        END IF;

        WITH inserted AS (
            INSERT INTO public.clients (name, "documentID", email, phone, carrer, "creditLimit", status, uid, idroute, photo_url)
            VALUES (p_name, v_new_doc, p_email, p_phone, p_carrer, p_credit_limit, COALESCE(p_status, 'Activo'), gen_random_uuid()::text, p_idroute, NULLIF(p_photo_url, ''))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_client FROM inserted;
        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        -- Normalizar nuevo documentID y verificar duplicado excluyendo el registro actual
        IF p_document_id IS NOT NULL THEN
            v_new_doc := public.normalize_document_id(p_document_id);
            IF v_new_doc <> '' THEN
                IF EXISTS (
                    SELECT 1 FROM public.clients
                    WHERE public.normalize_document_id("documentID") = v_new_doc
                      AND id != p_id
                ) THEN
                    RETURN json_build_object('success', false, 'message', 'La cedula ya se encuentra registrada en otro cliente.');
                END IF;
            END IF;
        END IF;

        -- Validación de email (existente)
        SELECT email, uid INTO v_current_email, v_uid FROM public.clients WHERE id = p_id;
        v_new_email := COALESCE(p_email, v_current_email);

        IF v_new_email IS DISTINCT FROM v_current_email THEN
            IF EXISTS (SELECT 1 FROM public.clients WHERE LOWER(email) = LOWER(v_new_email) AND id != p_id) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en otro cliente.');
            END IF;
            IF EXISTS (SELECT 1 FROM auth.users WHERE LOWER(email) = LOWER(v_new_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
            IF EXISTS (SELECT 1 FROM public.profiles WHERE LOWER(email) = LOWER(v_new_email)) THEN
                RETURN json_build_object('success', false, 'message', 'El correo ya esta registrado en el sistema.');
            END IF;
        END IF;

        -- Aplicar normalizado al documentID si se proporciona
        v_normalized := CASE WHEN p_document_id IS NOT NULL THEN v_new_doc ELSE NULL END;

        WITH updated AS (
            UPDATE public.clients SET
                name         = COALESCE(p_name, name),
                "documentID" = COALESCE(v_normalized, "documentID"),
                email        = v_new_email,
                phone        = COALESCE(p_phone, phone),
                carrer       = COALESCE(p_carrer, carrer),
                "creditLimit" = COALESCE(p_credit_limit, "creditLimit"),
                status       = COALESCE(p_status, status),
                idroute      = COALESCE(p_idroute, idroute),
                photo_url    = COALESCE(NULLIF(p_photo_url, ''), photo_url)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_client FROM updated;

        IF v_uid IS NOT NULL AND v_new_email IS DISTINCT FROM v_current_email THEN
            UPDATE public.profiles SET email = v_new_email WHERE id = v_uid::uuid;
            UPDATE auth.users SET
                email = v_new_email,
                raw_user_meta_data = raw_user_meta_data || jsonb_build_object('email', v_new_email)
            WHERE id = v_uid::uuid;
        END IF;

        RETURN json_build_object('success', true, 'data', v_client, 'message', 'Cliente actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        IF EXISTS (SELECT 1 FROM public.recharge WHERE idclient = p_id LIMIT 1)
           OR EXISTS (SELECT 1 FROM public.transactions WHERE idclient = p_id LIMIT 1)
        THEN
            WITH deactivated AS (
                UPDATE public.clients SET status = '1' WHERE id = p_id RETURNING *
            )
            SELECT row_to_json(deactivated.*) INTO v_client FROM deactivated;
            RETURN json_build_object(
                'success', true,
                'data', v_client,
                'message', 'El cliente no puede ser eliminado porque tiene recargas o movimientos asociados. Se ha desactivado en su lugar.',
                'deactivated', true
            );
        ELSE
            DELETE FROM public.clients WHERE id = p_id;
            RETURN json_build_object('success', true, 'message', 'Cliente eliminado del sistema.');
        END IF;

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error en el servidor: ' || SQLERRM);
END;
$function$
;

-- Función: get_client_stop_tickets
CREATE OR REPLACE FUNCTION public.get_client_stop_tickets(p_client_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
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
        ORDER BY r.description, s.name
    ) t;

    RETURN json_build_object(
        'success', true,
        'data', COALESCE(v_data, '[]'::json)
    );
END;$function$
;

-- Función: check_admin_profile_on_login
CREATE OR REPLACE FUNCTION public.check_admin_profile_on_login()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_is_admin BOOLEAN := false;
    v_app_name TEXT;
    v_jwt_claims JSONB;
BEGIN
    -- 🛡️ 1. DETECCIÓN RADICAL DE REGISTRO (SIGNUP)
    -- Extraemos los claims del JWT actual de la sesión de red.
    -- Si no hay JWT o si el rol del token es 'anon' (público sin loguear),
    -- significa que es un registro nuevo o una confirmación de correo. ¡Dejar pasar libre!
    BEGIN
        v_jwt_claims := auth.jwt();
    EXCEPTION WHEN OTHERS THEN
        v_jwt_claims := NULL;
    END;

    IF v_jwt_claims IS NULL OR (v_jwt_claims->>'role') = 'anon' THEN
        RETURN NEW;
    END IF;

    -- 🚀 2. PROCESAMIENTO EXCLUSIVO PARA LOGINS REALES
    -- Extraer el identificador app_source enviado desde las opciones del frontend
    v_app_name := NEW.raw_user_meta_data->>'app_source';

    -- Limpiar registros anteriores de bloqueo
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) - 'login_blocked' - 'block_reason';

    -- Si no se envía app_source en un intento de login con sesión iniciada
    IF v_app_name IS NULL OR NULLIF(TRIM(v_app_name), '') IS NULL THEN
        NEW.raw_app_meta_data := NEW.raw_app_meta_data || jsonb_build_object(
            'login_blocked', true,
            'block_reason', 'Firma de aplicacion requerida en las opciones de inicio de sesion.'
        );
        RETURN NEW;
    END IF;

    -- 🔄 3. EVALUACIÓN DE ROLES SEGÚN LA APLICACIÓN
    IF v_app_name = 'admin-app' THEN
        
        SELECT EXISTS (
            SELECT 1 
            FROM public.users_profiles  
            WHERE uid::text = NEW.id::text 
              AND role = 'admin'        
        ) INTO v_is_admin;

        IF NOT v_is_admin THEN
            NEW.raw_app_meta_data := NEW.raw_app_meta_data || jsonb_build_object(
                'login_blocked', true,
                'block_reason', 'Esta aplicacion esta reservada exclusivamente para administradores.'
            );
        END IF;

    ELSIF v_app_name = 'client-app' THEN
        RETURN NEW; -- Pasa directo
    ELSE
        NEW.raw_app_meta_data := NEW.raw_app_meta_data || jsonb_build_object(
            'login_blocked', true,
            'block_reason', 'Origen de aplicacion no autorizado.'
        );
    END IF;

    RETURN NEW;
END;
$function$
;

-- Función: get_current_user_route_ids
CREATE OR REPLACE FUNCTION public.get_current_user_route_ids()
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(ARRAY_AGG(ur.idroute), ARRAY[]::bigint[])
  FROM public.user_routes ur
  INNER JOIN public.profiles p ON p.id = ur.user_id
  WHERE p.email = auth.jwt()->>'email'
$function$
;

-- Función: is_supervisor
CREATE OR REPLACE FUNCTION public.is_supervisor()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$SELECT EXISTS (
  SELECT 1 FROM public.profiles
  WHERE email = auth.jwt()->>'email'
    AND role = 'supervisor'::user_role
);$function$
;

-- Función: check_client_document
CREATE OR REPLACE FUNCTION public.check_client_document(p_document text, p_exclude_id bigint DEFAULT NULL::bigint, p_email text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_norm TEXT;
    v_exists BOOLEAN := false;
    v_email_norm TEXT;
    v_email_exists BOOLEAN := false;
BEGIN
    -- ── Cédula ──
    v_norm := public.sanitize_document_id(p_document);

    IF v_norm IS NOT NULL AND v_norm <> '' THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE public.sanitize_document_id(c."documentID") = v_norm
              AND (p_exclude_id IS NULL OR c.id <> p_exclude_id)
        ) INTO v_exists;
    END IF;

    -- ── Correo ──
    v_email_norm := LOWER(btrim(COALESCE(p_email, '')));

    IF v_email_norm <> '' THEN
        v_email_exists :=
            EXISTS (SELECT 1 FROM public.clients   WHERE LOWER(email) = v_email_norm
                     AND (p_exclude_id IS NULL OR id <> p_exclude_id))
         OR EXISTS (SELECT 1 FROM auth.users       WHERE LOWER(email) = v_email_norm)
         OR EXISTS (SELECT 1 FROM public.profiles  WHERE LOWER(email) = v_email_norm);
    END IF;

    RETURN json_build_object(
        'success', true,
        'exists', COALESCE(v_exists, false),
        'email_exists', COALESCE(v_email_exists, false)
    );
END;
$function$
;

-- Función: get_bank_info_names
CREATE OR REPLACE FUNCTION public.get_bank_info_names()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'data', '[]'::json);
    END IF;
    SELECT COALESCE(json_agg(json_build_object('id', id, 'bank_name', bank_name, 'bank_code', bank_code)), '[]'::json)
    INTO v_data
    FROM public.bank_info WHERE status = 0;
    RETURN json_build_object('success', true, 'data', v_data);
END;
$function$
;

-- Función: manage_user_routes
CREATE OR REPLACE FUNCTION public.manage_user_routes(p_user_id uuid, p_route_ids bigint[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'No autorizado.');
  END IF;

  DELETE FROM public.user_routes WHERE user_id = p_user_id;

  IF array_length(p_route_ids, 1) > 0 THEN
    INSERT INTO public.user_routes (user_id, idroute)
    SELECT p_user_id, unnest(p_route_ids);
  END IF;

  RETURN json_build_object('success', true, 'message', 'Rutas actualizadas con exito.');
END;
$function$
;

-- Función: rls_auto_enable
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

-- Función: get_email_by_username
CREATE OR REPLACE FUNCTION public.get_email_by_username(username_input text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN (
    SELECT email 
    FROM auth.users 
    WHERE LOWER(raw_user_meta_data->>'user_name') = LOWER(username_input)
    LIMIT 1
  );
END;
$function$
;

-- Función: is_admin_or_supervisor
CREATE OR REPLACE FUNCTION public.is_admin_or_supervisor()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$SELECT EXISTS (
  SELECT 1 FROM public.profiles
  WHERE email = auth.jwt()->>'email'
    AND (role = 'admin'::user_role OR role = 'supervisor'::user_role)
);$function$
;

-- Función: process_payment
CREATE OR REPLACE FUNCTION public.process_payment(p_idclient integer, p_amount numeric, p_method character varying, p_ref character varying DEFAULT NULL::character varying, p_tasa numeric DEFAULT NULL::numeric, p_date date DEFAULT CURRENT_DATE, p_picture character varying DEFAULT NULL::character varying, p_create_by character varying DEFAULT NULL::character varying, p_codigo_banco character varying DEFAULT NULL::character varying, p_idroute bigint DEFAULT NULL::bigint, p_idshedule bigint DEFAULT NULL::bigint, p_idstop bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_current_balance NUMERIC(10,2);
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
        RETURN json_build_object('success', false, 'message', 'El monto de la recarga debe ser mayor a cero.');
    END IF;

    SELECT balance, idroute INTO v_current_balance, v_idroute FROM public.clients WHERE id = p_idclient;
    IF v_current_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'El cliente especificado no existe.');
    END IF;

    IF p_idroute IS NOT NULL THEN
        v_idroute := p_idroute;
    END IF;

    -- Usa precio de parada de la ruta si existe, fallback a company.ticket
    v_calc := public.calculate_tickets(p_amount, p_method, p_tasa, v_idroute);
    v_amount_in_usd := (v_calc->>'usd_amount')::NUMERIC;
    v_estimated_tickets := (v_calc->>'estimated_tickets')::NUMERIC;

    INSERT INTO public.recharge (
        idclient, method, ref, picture, amount, tasa, date, status, "createBy", "createAt",
        codigo_banco, idroute, tickets, idshedule, idstop
    )
    VALUES (
        p_idclient, p_method, NULLIF(p_ref, ''), NULLIF(p_picture, ''),
        v_amount_in_usd, p_tasa, p_date, 0, p_create_by, NOW(),
        NULLIF(p_codigo_banco, ''), v_idroute, v_estimated_tickets, p_idshedule, p_idstop
    )
    RETURNING id INTO v_recharge_id;

    RETURN json_build_object(
        'success', true,
        'message', 'Pago registrado exitosamente. En espera por verificacion administrativa.',
        'recharge_id', v_recharge_id,
        'estimated_tickets', v_estimated_tickets,
        'current_balance', v_current_balance
    );
EXCEPTION
    WHEN SQLSTATE '23505' THEN
        RETURN json_build_object('success', false, 'message', 'Esta combinacion de banco y referencia ya fue procesada. Verifique los datos e intente de nuevo.');
    WHEN OTHERS THEN
        RETURN json_build_object('success', false, 'message', 'Error en transaccion: ' || SQLERRM);
END;
$function$
;

-- Función: update_user_role
CREATE OR REPLACE FUNCTION public.update_user_role(user_email text, new_role text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Solo administradores pueden cambiar roles.';
    END IF;

    IF LOWER(new_role) NOT IN ('student', 'driver', 'admin') THEN
        RAISE EXCEPTION 'Rol no permitido. Los roles validos son: student, driver, admin.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE email = user_email) THEN
        RETURN 'ERROR: No se encontro ningun perfil asociado a ese correo electronico.';
    END IF;

    UPDATE public.profiles
    SET role = LOWER(new_role)::user_role
    WHERE email = user_email;

    UPDATE auth.users
    SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('role', LOWER(new_role))
    WHERE email = user_email;

    RETURN 'SUCCESS: El rol del usuario ha sido actualizado a ' || LOWER(new_role);
END;
$function$
;

-- Función: get_client_history
CREATE OR REPLACE FUNCTION public.get_client_history(p_client_id integer, p_start_date text DEFAULT NULL::text, p_end_date text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result json;
    v_total_recharges bigint;
    v_total_movements bigint;
    v_current_balance numeric(10,2);
    v_current_tickets numeric(10,2);
    v_recharges json;
    v_transactions json;
    v_start_ts timestamptz;
    v_end_ts timestamptz;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'Acceso no autorizado.');
    END IF;

    IF p_start_date IS NOT NULL AND p_start_date <> '' THEN
        v_start_ts := (p_start_date || 'T00:00:00Z')::timestamptz;
    ELSE
        v_start_ts := '-infinity'::timestamptz;
    END IF;

    IF p_end_date IS NOT NULL AND p_end_date <> '' THEN
        v_end_ts := (p_end_date || 'T23:59:59Z')::timestamptz;
    ELSE
        v_end_ts := 'infinity'::timestamptz;
    END IF;

    SELECT balance, tickets INTO v_current_balance, v_current_tickets
    FROM public.clients
    WHERE id = p_client_id;

    IF v_current_balance IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Cliente no encontrado.');
    END IF;

    SELECT count(*) INTO v_total_recharges
    FROM public.recharge r
    WHERE r.idclient = p_client_id
      AND r."createAt" >= v_start_ts
      AND r."createAt" <= v_end_ts;

    select coalesce(json_agg(t.*), '[]'::json) into v_transactions
    from (
        select t.uid, t.amount, t.ticket, t.status, t.shedule, t."newBalanceClient", t."newTicketsClient", t."createBy", t.created_at, t.idroute, t.idunit
        from public.transactions t
        where t.idclient = p_client_id
          and t.created_at >= v_start_ts
          and t.created_at <= v_end_ts
        order by t.created_at desc
    ) t;

    v_total_movements := json_array_length(v_transactions);

    SELECT COALESCE(json_agg(r.*), '[]'::json) INTO v_recharges
    FROM (
        SELECT r.*, c."name" AS client_name
        FROM public.recharge r
        JOIN public.clients c ON r.idclient = c.id
        WHERE r.idclient = p_client_id
          AND r."createAt" >= v_start_ts
          AND r."createAt" <= v_end_ts
        ORDER BY r."createAt" DESC
    ) r;

    v_result := json_build_object(
        'success', true,
        'recharges', v_recharges,
        'rechargeCount', v_total_recharges,
        'movements', v_transactions,
        'movementCount', v_total_movements,
        'current_balance', v_current_balance,
        'current_tickets', v_current_tickets
    );

    RETURN v_result;
END;
$function$
;

-- Función: get_client_history
CREATE OR REPLACE FUNCTION public.get_client_history(p_client_id integer, p_from timestamp without time zone, p_to timestamp without time zone, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_recharges json;
  v_transactions json;
  v_total_transactions numeric(10,2);
begin

  -- 1. CONSULTA DE RECARGAS
  select json_agg(t) into v_recharges
  from (
    select
      id,
      idclient,
      method,
      ref,
      picture,
      amount,
      tasa,
      date,
      status,
      tickets,
      "createBy",
      "createAt" AS created_at_formatted
    from public.recharge
    where idclient = p_client_id
      and "createAt"::timestamp >= p_from::timestamp
      and "createAt"::timestamp <= p_to::timestamp
      and (p_status is null or status = p_status)
    order by id desc
  ) t;

  -- 2. CONSULTA DE TRANSACCIONES
  select json_agg(t) into v_transactions
  from (
    SELECT
      t.*,
      c.name AS client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON t.idclient = c.id
    WHERE t.idclient = p_client_id
      AND t.created_at::timestamp >= p_from::timestamp
      AND t.created_at::timestamp <= p_to::timestamp
      AND (p_status IS NULL OR t.status = p_status)
    ORDER BY t.id DESC
  ) t;

  -- 3. SUMATORIA (se mantiene para compatibilidad, pero frontend ya no lo usa como balance)
  select coalesce(sum(amount), 0.00) into v_total_transactions
  from public.transactions
  where idclient = p_client_id
    and created_at::timestamp >= p_from::timestamp
    and created_at::timestamp <= p_to::timestamp;

  return json_build_object(
    'recharges', coalesce(v_recharges, '[]'::json),
    'transactions', coalesce(v_transactions, '[]'::json),
    'total_transactions_amount', v_total_transactions,
    'current_balance', (SELECT balance FROM public.clients WHERE id = p_client_id)
  );
end;
$function$
;

-- Función: get_dashboard_kpis
CREATE OR REPLACE FUNCTION public.get_dashboard_kpis()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result JSON;
  v_route_ids BIGINT[];
BEGIN
  v_route_ids := public.get_current_user_route_ids();

  SELECT json_build_object(
    'debtors_total',    COALESCE((SELECT SUM(balance) FROM public.clients WHERE balance < 0 AND (public.is_admin() OR idroute = ANY(v_route_ids))), 0),
    'debtors_count',    COALESCE((SELECT COUNT(*)  FROM public.clients WHERE balance < 0 AND (public.is_admin() OR idroute = ANY(v_route_ids))), 0),
    'active_clients',   COALESCE((SELECT COUNT(*)  FROM public.clients WHERE status = '0' AND (public.is_admin() OR idroute = ANY(v_route_ids))), 0),
    'total_clients',    COALESCE((SELECT COUNT(*)  FROM public.clients WHERE public.is_admin() OR idroute = ANY(v_route_ids)), 0),
    'recharges_today',  COALESCE((SELECT COUNT(*)  FROM public.recharge r LEFT JOIN public.clients c ON c.id = r.idclient WHERE r.date = CURRENT_DATE AND (public.is_admin() OR c.idroute = ANY(v_route_ids))), 0),
    'recharges_amount_today', COALESCE((SELECT SUM(r.amount) FROM public.recharge r LEFT JOIN public.clients c ON c.id = r.idclient WHERE r.date = CURRENT_DATE AND (public.is_admin() OR c.idroute = ANY(v_route_ids))), 0),
    'transactions_today', COALESCE((SELECT COUNT(*) FROM public.transactions t LEFT JOIN public.clients c ON c.id = t.idclient WHERE t.created_at::date = CURRENT_DATE AND (public.is_admin() OR c.idroute = ANY(v_route_ids))), 0)
  ) INTO result;
  RETURN result;
END;
$function$
;

-- Función: get_weekly_flow
CREATE OR REPLACE FUNCTION public.get_weekly_flow()
 RETURNS TABLE(day date, count bigint, total_amount numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_route_ids BIGINT[];
BEGIN
  v_route_ids := public.get_current_user_route_ids();

  RETURN QUERY
  SELECT DATE(t.created_at) as day, COUNT(*)::BIGINT, COALESCE(SUM(t.amount), 0) as total_amount
  FROM public.transactions t
  LEFT JOIN public.clients c ON c.id = t.idclient
  WHERE t.created_at >= NOW() - INTERVAL '7 days'
    AND (public.is_admin() OR c.idroute = ANY(v_route_ids))
  GROUP BY DATE(t.created_at)
  ORDER BY day;
END;
$function$
;

-- Función: manage_bank_info
CREATE OR REPLACE FUNCTION public.manage_bank_info(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_bank_name character varying DEFAULT NULL::character varying, p_bank_code character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_document_id character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_record JSON;
BEGIN
  -- list: cualquier usuario autenticado
  IF LOWER(p_action) = 'list' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(b.*)) INTO v_record FROM (
      SELECT * FROM public.bank_info ORDER BY id
    ) b;
    RETURN json_build_object('success', true, 'data', COALESCE(v_record, '[]'::json));
  END IF;

  -- create / update / delete: solo admin
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    WITH inserted AS (
      INSERT INTO public.bank_info (bank_name, bank_code, phone, document_id, status)
      VALUES (p_bank_name, p_bank_code, p_phone, p_document_id, COALESCE(p_status, 0))
      RETURNING *
    )
    SELECT row_to_json(inserted.*) INTO v_record FROM inserted;
    RETURN json_build_object('success', true, 'data', v_record, 'message', 'Informacion bancaria creada con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    WITH updated AS (
      UPDATE public.bank_info SET
        bank_name   = COALESCE(p_bank_name, bank_name),
        bank_code   = COALESCE(p_bank_code, bank_code),
        phone       = COALESCE(p_phone, phone),
        document_id = COALESCE(p_document_id, document_id),
        status      = COALESCE(p_status, status)
      WHERE id = p_id
      RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_record FROM updated;
    RETURN json_build_object('success', true, 'data', v_record, 'message', 'Informacion bancaria actualizada con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.bank_info WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Informacion bancaria eliminada del sistema.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_route_names
CREATE OR REPLACE FUNCTION public.get_route_names()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'data', '[]'::json);
    END IF;
    SELECT COALESCE(json_agg(json_build_object('id', id, 'code', code, 'description', description, 'idbank_info', idbank_info)), '[]'::json)
    INTO v_data
    FROM public.routes WHERE status = 0;
    RETURN json_build_object('success', true, 'data', v_data);
END;
$function$
;

-- Función: manage_route_stop
CREATE OR REPLACE FUNCTION public.manage_route_stop(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_route_id bigint DEFAULT NULL::bigint, p_stop_id bigint DEFAULT NULL::bigint, p_price numeric DEFAULT NULL::numeric, p_stop_order integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_data JSON;
BEGIN
  IF LOWER(p_action) = 'list_by_route' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(json_build_object(
      'id', rs.id,
      'route_id', rs.route_id,
      'stop_id', rs.stop_id,
      'price', rs.price,
      'stop_order', rs.stop_order,
      'name', s.name,
      'description', s.description
    ) ORDER BY rs.stop_order) INTO v_data
    FROM public.route_stops rs
    INNER JOIN public.stops s ON s.id = rs.stop_id
    WHERE rs.route_id = p_route_id;
    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
  END IF;

  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    INSERT INTO public.route_stops (route_id, stop_id, price, stop_order)
    VALUES (p_route_id, p_stop_id, COALESCE(p_price, 0), COALESCE(p_stop_order, 0))
    ON CONFLICT (route_id, stop_id) DO NOTHING
    RETURNING id INTO v_data;
    IF v_data IS NULL THEN
      RETURN json_build_object('success', false, 'message', 'La parada ya esta asignada a esta ruta.');
    END IF;
    RETURN json_build_object('success', true, 'data', json_build_object('id', v_data), 'message', 'Parada asignada a la ruta con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    WITH updated AS (
      UPDATE public.route_stops SET
        price      = COALESCE(p_price, price),
        stop_order = COALESCE(p_stop_order, stop_order)
      WHERE id = p_id
      RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_data FROM updated;
    IF v_data IS NULL THEN
      RETURN json_build_object('success', false, 'message', 'Registro no encontrado.');
    END IF;
    RETURN json_build_object('success', true, 'data', v_data, 'message', 'Parada actualizada con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.route_stops WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Parada removida de la ruta con exito.');

  ELSIF LOWER(p_action) = 'delete_by_route' THEN
    DELETE FROM public.route_stops WHERE route_id = p_route_id;
    RETURN json_build_object('success', true, 'message', 'Todas las paradas removidas de la ruta.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_stops_by_route
CREATE OR REPLACE FUNCTION public.get_stops_by_route(p_idroute bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_data JSON;
BEGIN
  IF auth.role() <> 'authenticated' THEN
    RETURN json_build_object('success', false, 'data', '[]'::json);
  END IF;
  SELECT json_agg(json_build_object(
    'id', rs.id,
    'route_id', rs.route_id,
    'stop_id', rs.stop_id,
    'price', rs.price,
    'stop_order', rs.stop_order,
    'name', s.name,
    'description', s.description
  ) ORDER BY rs.stop_order) INTO v_data
  FROM public.route_stops rs
  INNER JOIN public.stops s ON s.id = rs.stop_id
  WHERE rs.route_id = p_idroute;
  RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- Función: get_clients
CREATE OR REPLACE FUNCTION public.get_clients()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden listar clientes.');
    END IF;

    SELECT json_agg(row_to_json(c.*)) INTO v_data FROM (
        SELECT * FROM public.clients ORDER BY id
    ) c;

    RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
END;
$function$
;

-- Función: manage_horario
CREATE OR REPLACE FUNCTION public.manage_horario(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_shudle character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_horario JSON;
BEGIN
    IF LOWER(p_action) = 'list' THEN
        SELECT json_agg(row_to_json(h.*)) INTO v_horario FROM (
            SELECT * FROM public.horario ORDER BY id
        ) h;
        RETURN json_build_object('success', true, 'data', COALESCE(v_horario, '[]'::json));
    END IF;

    IF NOT public.is_admin() THEN
        RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
    END IF;

    IF LOWER(p_action) = 'create' THEN
        WITH inserted AS (
            INSERT INTO public.horario (code, shudle, status)
            VALUES (p_code, p_shudle, COALESCE(p_status, 0))
            RETURNING *
        )
        SELECT row_to_json(inserted.*) INTO v_horario FROM inserted;
        RETURN json_build_object('success', true, 'data', v_horario, 'message', 'Horario creado con exito.');

    ELSIF LOWER(p_action) = 'update' THEN
        WITH updated AS (
            UPDATE public.horario SET
                code   = COALESCE(p_code, code),
                shudle = COALESCE(p_shudle, shudle),
                status = COALESCE(p_status, status)
            WHERE id = p_id
            RETURNING *
        )
        SELECT row_to_json(updated.*) INTO v_horario FROM updated;
        RETURN json_build_object('success', true, 'data', v_horario, 'message', 'Horario actualizado con exito.');

    ELSIF LOWER(p_action) = 'delete' THEN
        DELETE FROM public.horario WHERE id = p_id;
        RETURN json_build_object('success', true, 'message', 'Horario eliminado del sistema.');

    ELSE
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: get_route_horarios
CREATE OR REPLACE FUNCTION public.get_route_horarios(p_idroute bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSON;
BEGIN
    IF auth.role() <> 'authenticated' THEN
        RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;

    SELECT json_agg(json_build_object(
        'id', h.id,
        'code', h.code,
        'shudle', h.shudle
    ) ORDER BY h.shudle::time asc) INTO v_data
    FROM public.route_horarios rh
    INNER JOIN public.horario h ON h.id = rh.idhorario
    WHERE rh.idroute = p_idroute AND h.status = 0;

    RETURN json_build_object(
        'success', true,
        'data', COALESCE(v_data, '[]'::json)
    );
END;
$function$
;

-- Función: get_recharge_stats
CREATE OR REPLACE FUNCTION public.get_recharge_stats()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_pending BIGINT;
  v_rejected BIGINT;
  v_approved BIGINT;
  v_total_amount NUMERIC(10,2);
  v_route_ids BIGINT[];
BEGIN
  v_route_ids := public.get_current_user_route_ids();

  SELECT COUNT(*) FILTER (WHERE r.status = 0),
         COUNT(*) FILTER (WHERE r.status = 2),
         COUNT(*) FILTER (WHERE r.status = 1)
  INTO v_pending, v_rejected, v_approved
  FROM public.recharge r
  LEFT JOIN public.clients c ON c.id = r.idclient
  WHERE (public.is_admin() OR c.idroute = ANY(v_route_ids));

  SELECT COALESCE(SUM(r.amount), 0)
  INTO v_total_amount
  FROM public.recharge r
  LEFT JOIN public.clients c ON c.id = r.idclient
  WHERE r.status = 1
    AND (public.is_admin() OR c.idroute = ANY(v_route_ids));

  RETURN json_build_object(
    'pending', v_pending,
    'rejected', v_rejected,
    'approved', v_approved,
    'total_amount', v_total_amount
  );
END;
$function$
;

-- Función: manage_route
CREATE OR REPLACE FUNCTION public.manage_route(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_idbank_info bigint DEFAULT NULL::bigint, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_route JSON;
BEGIN
  -- list: cualquier usuario autenticado
  IF LOWER(p_action) = 'list' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(r.*)) INTO v_route FROM (
      SELECT
        r.*,
        COALESCE(b.bank_name, 'Sin banco') AS bank_info_name
      FROM public.routes r
      LEFT JOIN public.bank_info b ON b.id = r.idbank_info
      ORDER BY r.id
    ) r;
    RETURN json_build_object('success', true, 'data', COALESCE(v_route, '[]'::json));
  END IF;

  -- create / update / delete: solo admin
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    WITH inserted AS (
      INSERT INTO public.routes (code, description, idbank_info, status)
      VALUES (p_code, p_description, p_idbank_info, COALESCE(p_status, 0))
      RETURNING *
    )
    SELECT row_to_json(inserted.*) INTO v_route FROM inserted;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta creada con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    WITH updated AS (
      UPDATE public.routes SET
        code        = COALESCE(p_code, code),
        description = COALESCE(p_description, description),
        idbank_info = COALESCE(p_idbank_info, idbank_info),
        status      = COALESCE(p_status, status)
      WHERE id = p_id
      RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_route FROM updated;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta actualizada con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.routes WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Ruta eliminada del sistema.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: manage_route
CREATE OR REPLACE FUNCTION public.manage_route(p_action character varying, p_id bigint DEFAULT NULL::bigint, p_code character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_bank_code character varying DEFAULT NULL::character varying, p_document_id character varying DEFAULT NULL::character varying, p_status integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_route JSON;
BEGIN
  -- list: cualquier usuario autenticado
  IF LOWER(p_action) = 'list' THEN
    IF auth.role() <> 'authenticated' THEN
      RETURN json_build_object('success', false, 'message', 'No autorizado.');
    END IF;
    SELECT json_agg(row_to_json(r.*)) INTO v_route FROM (
      SELECT * FROM public.routes ORDER BY id
    ) r;
    RETURN json_build_object('success', true, 'data', COALESCE(v_route, '[]'::json));
  END IF;

  -- create / update / delete: solo admin
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'message', 'Solo administradores pueden realizar esta accion.');
  END IF;

  IF LOWER(p_action) = 'create' THEN
    WITH inserted AS (
      INSERT INTO public.routes (code, description, phone, bank_code, document_id, status)
      VALUES (p_code, p_description, p_phone, p_bank_code, p_document_id, COALESCE(p_status, 0))
      RETURNING *
    )
    SELECT row_to_json(inserted.*) INTO v_route FROM inserted;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta creada con exito.');

  ELSIF LOWER(p_action) = 'update' THEN
    WITH updated AS (
      UPDATE public.routes SET
        code        = COALESCE(p_code, code),
        description = COALESCE(p_description, description),
        phone       = COALESCE(p_phone, phone),
        bank_code   = COALESCE(p_bank_code, bank_code),
        document_id = COALESCE(p_document_id, document_id),
        status      = COALESCE(p_status, status)
      WHERE id = p_id
      RETURNING *
    )
    SELECT row_to_json(updated.*) INTO v_route FROM updated;
    RETURN json_build_object('success', true, 'data', v_route, 'message', 'Ruta actualizada con exito.');

  ELSIF LOWER(p_action) = 'delete' THEN
    DELETE FROM public.routes WHERE id = p_id;
    RETURN json_build_object('success', true, 'message', 'Ruta eliminada del sistema.');

  ELSE
    RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- Función: update_client_photo
CREATE OR REPLACE FUNCTION public.update_client_photo(p_photo_url text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_client_id BIGINT;
BEGIN
  SELECT id INTO v_client_id FROM public.clients WHERE uid = auth.uid()::text;
  
  IF v_client_id IS NULL THEN
    RETURN json_build_object('success', false, 'message', 'Cliente no encontrado');
  END IF;

  UPDATE public.clients SET photo_url = p_photo_url WHERE id = v_client_id;
  
  RETURN json_build_object('success', true, 'message', 'Foto actualizada');
END;
$function$
;

-- Función: get_user_routes
CREATE OR REPLACE FUNCTION public.get_user_routes(p_user_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_data JSON;
BEGIN
  IF NOT public.is_admin() AND auth.uid() != p_user_id THEN
    RETURN json_build_object('success', false, 'message', 'No autorizado.');
  END IF;

  SELECT json_agg(json_build_object(
    'id', ur.id,
    'user_id', ur.user_id,
    'idroute', ur.idroute,
    'route_name', r.description,
    'route_code', r.code
  )) INTO v_data
  FROM public.user_routes ur
  LEFT JOIN public.routes r ON r.id = ur.idroute
  WHERE ur.user_id = p_user_id;

  RETURN json_build_object('success', true, 'data', COALESCE(v_data, '[]'::json));
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

-- Función: get_recharge_by_id
CREATE OR REPLACE FUNCTION public.get_recharge_by_id(p_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result json;
BEGIN
    SELECT row_to_json(t) INTO v_result FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            r.tickets,
            json_build_object('name', c.name) AS clients,
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route,
            CASE WHEN rs.id IS NOT NULL THEN
                json_build_object('id', s.id, 'name', s.name, 'price', rs.price, 'stop_order', rs.stop_order)
            ELSE NULL END AS stop
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
        LEFT JOIN public.route_stops rs ON rs.id = r.idstop
        LEFT JOIN public.stops s ON s.id = rs.stop_id
        WHERE r.id = p_id
          AND (public.is_admin() OR r.idroute = ANY(public.get_current_user_route_ids()))
    ) t;

    RETURN COALESCE(v_result, 'null'::json);
END;
$function$
;

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
    v_route_ids BIGINT[];
BEGIN
    v_offset := (p_page - 1) * p_per_page;
    v_route_ids := public.get_current_user_route_ids();

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
      AND (public.is_admin() OR r.idroute = ANY(v_route_ids));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            r.tickets,
            json_build_object('name', c.name) AS clients,
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route,
            CASE WHEN rs.id IS NOT NULL THEN
                json_build_object('id', s.id, 'name', s.name, 'price', rs.price, 'stop_order', rs.stop_order)
            ELSE NULL END AS stop
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
        LEFT JOIN public.route_stops rs ON rs.id = r.idstop
        LEFT JOIN public.stops s ON s.id = rs.stop_id
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
          AND (public.is_admin() OR r.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'ASC'  THEN rt.description END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'DESC' THEN rt.description END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'ASC'  THEN r.tickets END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'DESC' THEN r.tickets END DESC NULLS LAST,
            r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text, p_search text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
    v_route_ids BIGINT[];
    v_search text;
BEGIN
    v_offset := (p_page - 1) * p_per_page;
    v_route_ids := public.get_current_user_route_ids();
    v_search := CASE WHEN p_search IS NOT NULL THEN '%' || p_search || '%' ELSE NULL END;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
      AND (p_search IS NULL OR c.name ILIKE v_search OR r.ref ILIKE v_search OR r.id::text = p_search)
      AND (public.is_admin() OR r.idroute = ANY(v_route_ids));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            r.tickets,
            json_build_object('name', c.name) AS clients,
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route,
            CASE WHEN rs.id IS NOT NULL THEN
                json_build_object('id', s.id, 'name', s.name, 'price', rs.price, 'stop_order', rs.stop_order)
            ELSE NULL END AS stop
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
        LEFT JOIN public.route_stops rs ON rs.id = r.idstop
        LEFT JOIN public.stops s ON s.id = rs.stop_id
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
          AND (p_search IS NULL OR c.name ILIKE v_search OR r.ref ILIKE v_search OR r.id::text = p_search)
          AND (public.is_admin() OR r.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'ASC'  THEN rt.description END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'DESC' THEN rt.description END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'ASC'  THEN r.tickets END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'DESC' THEN r.tickets END DESC NULLS LAST,
            r.id DESC
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

-- Función: get_current_app_name
CREATE OR REPLACE FUNCTION public.get_current_app_name()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_agent TEXT;
BEGIN
    v_agent := current_setting('request.headers', true)::json->>'user-agent';
    
    IF v_agent LIKE '%admin-app-agent%' THEN
        RETURN 'admin-app';
    ELSIF v_agent LIKE '%client-app-agent%' THEN
        RETURN 'client-app';
    ELSE
        RETURN NULL;
    END IF;
END;
$function$
;

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
    v_route_ids BIGINT[];
BEGIN
    v_offset := (p_page - 1) * p_per_page;
    v_route_ids := public.get_current_user_route_ids();

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
      AND (public.is_admin() OR r.idroute = ANY(v_route_ids));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            r.tickets,
            json_build_object('name', c.name) AS clients,
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route,
            CASE WHEN rs.id IS NOT NULL THEN
                json_build_object('id', s.id, 'name', s.name, 'price', rs.price, 'stop_order', rs.stop_order)
            ELSE NULL END AS stop
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
        LEFT JOIN public.route_stops rs ON rs.id = r.idstop
        LEFT JOIN public.stops s ON s.id = rs.stop_id
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
          AND (public.is_admin() OR r.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'ASC'  THEN rt.description END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'DESC' THEN rt.description END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'ASC'  THEN r.tickets END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'DESC' THEN r.tickets END DESC NULLS LAST,
            r.id DESC
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

-- Función: get_recharges_paginated
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text, p_search text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_data JSON;
    v_total BIGINT;
    v_route_ids BIGINT[];
    v_search text;
BEGIN
    v_offset := (p_page - 1) * p_per_page;
    v_route_ids := public.get_current_user_route_ids();
    v_search := CASE WHEN p_search IS NOT NULL THEN '%' || p_search || '%' ELSE NULL END;

    SELECT COUNT(*) INTO v_total FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
    WHERE (p_status IS NULL OR r.status = p_status)
      AND (p_date_from IS NULL OR r.date >= p_date_from)
      AND (p_date_to IS NULL OR r.date <= p_date_to)
      AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
           (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
           (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
      AND (p_search IS NULL OR c.name ILIKE v_search OR r.ref ILIKE v_search OR r.id::text = p_search)
      AND (public.is_admin() OR r.idroute = ANY(v_route_ids));

    SELECT json_agg(t) INTO v_data FROM (
        SELECT
            r.id,
            r.idclient,
            r.method,
            r.ref,
            r.picture,
            r.amount,
            r.tasa,
            r.date,
            r.status,
            r."createBy",
            r."createAt",
            r."updateAprobate",
            r.tickets,
            json_build_object('name', c.name) AS clients,
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route,
            CASE WHEN rs.id IS NOT NULL THEN
                json_build_object('id', s.id, 'name', s.name, 'price', rs.price, 'stop_order', rs.stop_order)
            ELSE NULL END AS stop
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
        LEFT JOIN public.route_stops rs ON rs.id = r.idstop
        LEFT JOIN public.stops s ON s.id = rs.stop_id
        WHERE (p_status IS NULL OR r.status = p_status)
          AND (p_date_from IS NULL OR r.date >= p_date_from)
          AND (p_date_to IS NULL OR r.date <= p_date_to)
          AND (p_method IS NULL OR LOWER(r.method) = LOWER(p_method) OR
               (LOWER(p_method) = 'efectivo' AND LOWER(r.method) LIKE '%efectivo%') OR
               (LOWER(p_method) = 'pago_movil' AND LOWER(r.method) LIKE '%pago%movil%'))
          AND (p_search IS NULL OR c.name ILIKE v_search OR r.ref ILIKE v_search OR r.id::text = p_search)
          AND (public.is_admin() OR r.idroute = ANY(v_route_ids))
        ORDER BY
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'ASC'  THEN r.id        END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'id'     AND p_sort_order = 'DESC' THEN r.id        END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'ASC'  THEN r.date      END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'date'   AND p_sort_order = 'DESC' THEN r.date      END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'ASC'  THEN r.amount    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'amount' AND p_sort_order = 'DESC' THEN r.amount    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'ASC'  THEN r.method    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'method' AND p_sort_order = 'DESC' THEN r.method    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'ASC'  THEN r.status    END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'status' AND p_sort_order = 'DESC' THEN r.status    END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'ASC'  THEN c.name END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'client_name' AND p_sort_order = 'DESC' THEN c.name END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'ASC'  THEN rt.description END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'route_name' AND p_sort_order = 'DESC' THEN rt.description END DESC NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'ASC'  THEN r.tickets END ASC  NULLS LAST,
            CASE WHEN p_sort_field = 'tickets' AND p_sort_order = 'DESC' THEN r.tickets END DESC NULLS LAST,
            r.id DESC
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

-- >>> POLÍTICAS DE SEGURIDAD (RLS) <<<

ALTER TABLE "public"."bank_info" ENABLE ROW LEVEL SECURITY;
-- Política: "bank_info_update_admin" sobre "public"."bank_info"
DROP POLICY IF EXISTS "bank_info_update_admin" ON "public"."bank_info";
CREATE POLICY "bank_info_update_admin" ON "public"."bank_info" AS PERMISSIVE FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política: "bank_info_select_all" sobre "public"."bank_info"
DROP POLICY IF EXISTS "bank_info_select_all" ON "public"."bank_info";
CREATE POLICY "bank_info_select_all" ON "public"."bank_info" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "bank_info_insert_admin" sobre "public"."bank_info"
DROP POLICY IF EXISTS "bank_info_insert_admin" ON "public"."bank_info";
CREATE POLICY "bank_info_insert_admin" ON "public"."bank_info" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

-- Política: "bank_info_delete_admin" sobre "public"."bank_info"
DROP POLICY IF EXISTS "bank_info_delete_admin" ON "public"."bank_info";
CREATE POLICY "bank_info_delete_admin" ON "public"."bank_info" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

ALTER TABLE "public"."client_stop_tickets" ENABLE ROW LEVEL SECURITY;
-- Política: "cst_admin_all" sobre "public"."client_stop_tickets"
DROP POLICY IF EXISTS "cst_admin_all" ON "public"."client_stop_tickets";
CREATE POLICY "cst_admin_all" ON "public"."client_stop_tickets" AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política: "cst_select_authenticated" sobre "public"."client_stop_tickets"
DROP POLICY IF EXISTS "cst_select_authenticated" ON "public"."client_stop_tickets";
CREATE POLICY "cst_select_authenticated" ON "public"."client_stop_tickets" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

ALTER TABLE "public"."clients" ENABLE ROW LEVEL SECURITY;
-- Política: "Permitir lectura general de clientes" sobre "public"."clients"
DROP POLICY IF EXISTS "Permitir lectura general de clientes" ON "public"."clients";
CREATE POLICY "Permitir lectura general de clientes" ON "public"."clients" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "Permitir lectura por email" sobre "public"."clients"
DROP POLICY IF EXISTS "Permitir lectura por email" ON "public"."clients";
CREATE POLICY "Permitir lectura por email" ON "public"."clients" AS PERMISSIVE FOR SELECT TO authenticated USING (((email)::text = (auth.jwt() ->> 'email'::text)));

ALTER TABLE "public"."company" ENABLE ROW LEVEL SECURITY;
-- Política: "company_insert_admin" sobre "public"."company"
DROP POLICY IF EXISTS "company_insert_admin" ON "public"."company";
CREATE POLICY "company_insert_admin" ON "public"."company" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

-- Política: "company_select_all" sobre "public"."company"
DROP POLICY IF EXISTS "company_select_all" ON "public"."company";
CREATE POLICY "company_select_all" ON "public"."company" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "company_delete_admin" sobre "public"."company"
DROP POLICY IF EXISTS "company_delete_admin" ON "public"."company";
CREATE POLICY "company_delete_admin" ON "public"."company" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

-- Política: "company_update_admin" sobre "public"."company"
DROP POLICY IF EXISTS "company_update_admin" ON "public"."company";
CREATE POLICY "company_update_admin" ON "public"."company" AS PERMISSIVE FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

ALTER TABLE "public"."horario" ENABLE ROW LEVEL SECURITY;
-- Política: "horario_select_all" sobre "public"."horario"
DROP POLICY IF EXISTS "horario_select_all" ON "public"."horario";
CREATE POLICY "horario_select_all" ON "public"."horario" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "horario_insert_admin" sobre "public"."horario"
DROP POLICY IF EXISTS "horario_insert_admin" ON "public"."horario";
CREATE POLICY "horario_insert_admin" ON "public"."horario" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

-- Política: "horario_update_admin" sobre "public"."horario"
DROP POLICY IF EXISTS "horario_update_admin" ON "public"."horario";
CREATE POLICY "horario_update_admin" ON "public"."horario" AS PERMISSIVE FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política: "horario_delete_admin" sobre "public"."horario"
DROP POLICY IF EXISTS "horario_delete_admin" ON "public"."horario";
CREATE POLICY "horario_delete_admin" ON "public"."horario" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;
-- Política: "Usuarios leen su propio perfil" sobre "public"."profiles"
DROP POLICY IF EXISTS "Usuarios leen su propio perfil" ON "public"."profiles";
CREATE POLICY "Usuarios leen su propio perfil" ON "public"."profiles" AS PERMISSIVE FOR SELECT TO authenticated USING ((id = auth.uid()));

ALTER TABLE "public"."route_horarios" ENABLE ROW LEVEL SECURITY;
-- Política: "route_horarios_insert_admin" sobre "public"."route_horarios"
DROP POLICY IF EXISTS "route_horarios_insert_admin" ON "public"."route_horarios";
CREATE POLICY "route_horarios_insert_admin" ON "public"."route_horarios" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

-- Política: "route_horarios_delete_admin" sobre "public"."route_horarios"
DROP POLICY IF EXISTS "route_horarios_delete_admin" ON "public"."route_horarios";
CREATE POLICY "route_horarios_delete_admin" ON "public"."route_horarios" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

-- Política: "route_horarios_select_all" sobre "public"."route_horarios"
DROP POLICY IF EXISTS "route_horarios_select_all" ON "public"."route_horarios";
CREATE POLICY "route_horarios_select_all" ON "public"."route_horarios" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

ALTER TABLE "public"."route_stops" ENABLE ROW LEVEL SECURITY;
-- Política: "route_stops_insert_admin" sobre "public"."route_stops"
DROP POLICY IF EXISTS "route_stops_insert_admin" ON "public"."route_stops";
CREATE POLICY "route_stops_insert_admin" ON "public"."route_stops" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

-- Política: "route_stops_select_authenticated" sobre "public"."route_stops"
DROP POLICY IF EXISTS "route_stops_select_authenticated" ON "public"."route_stops";
CREATE POLICY "route_stops_select_authenticated" ON "public"."route_stops" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "route_stops_delete_admin" sobre "public"."route_stops"
DROP POLICY IF EXISTS "route_stops_delete_admin" ON "public"."route_stops";
CREATE POLICY "route_stops_delete_admin" ON "public"."route_stops" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

-- Política: "route_stops_update_admin" sobre "public"."route_stops"
DROP POLICY IF EXISTS "route_stops_update_admin" ON "public"."route_stops";
CREATE POLICY "route_stops_update_admin" ON "public"."route_stops" AS PERMISSIVE FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política: "route_stops_select_all" sobre "public"."route_stops"
DROP POLICY IF EXISTS "route_stops_select_all" ON "public"."route_stops";
CREATE POLICY "route_stops_select_all" ON "public"."route_stops" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

ALTER TABLE "public"."routes" ENABLE ROW LEVEL SECURITY;
-- Política: "routes_update_admin" sobre "public"."routes"
DROP POLICY IF EXISTS "routes_update_admin" ON "public"."routes";
CREATE POLICY "routes_update_admin" ON "public"."routes" AS PERMISSIVE FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política: "routes_select_all" sobre "public"."routes"
DROP POLICY IF EXISTS "routes_select_all" ON "public"."routes";
CREATE POLICY "routes_select_all" ON "public"."routes" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "routes_delete_admin" sobre "public"."routes"
DROP POLICY IF EXISTS "routes_delete_admin" ON "public"."routes";
CREATE POLICY "routes_delete_admin" ON "public"."routes" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

-- Política: "routes_insert_admin" sobre "public"."routes"
DROP POLICY IF EXISTS "routes_insert_admin" ON "public"."routes";
CREATE POLICY "routes_insert_admin" ON "public"."routes" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

ALTER TABLE "public"."solicitude" ENABLE ROW LEVEL SECURITY;
-- Política: "users_update_own" sobre "public"."solicitude"
DROP POLICY IF EXISTS "users_update_own" ON "public"."solicitude";
CREATE POLICY "users_update_own" ON "public"."solicitude" AS PERMISSIVE FOR UPDATE TO public USING ((idclient = get_my_client_id())) WITH CHECK ((idclient = get_my_client_id()));

-- Política: "admin_update_all" sobre "public"."solicitude"
DROP POLICY IF EXISTS "admin_update_all" ON "public"."solicitude";
CREATE POLICY "admin_update_all" ON "public"."solicitude" AS PERMISSIVE FOR UPDATE TO public USING (is_admin()) WITH CHECK (is_admin());

-- Política: "users_select_own" sobre "public"."solicitude"
DROP POLICY IF EXISTS "users_select_own" ON "public"."solicitude";
CREATE POLICY "users_select_own" ON "public"."solicitude" AS PERMISSIVE FOR SELECT TO public USING ((idclient = get_my_client_id()));

-- Política: "users_insert_own" sobre "public"."solicitude"
DROP POLICY IF EXISTS "users_insert_own" ON "public"."solicitude";
CREATE POLICY "users_insert_own" ON "public"."solicitude" AS PERMISSIVE FOR INSERT TO public WITH CHECK ((idclient = get_my_client_id()));

-- Política: "admin_select_all" sobre "public"."solicitude"
DROP POLICY IF EXISTS "admin_select_all" ON "public"."solicitude";
CREATE POLICY "admin_select_all" ON "public"."solicitude" AS PERMISSIVE FOR SELECT TO public USING (is_admin());

-- Política: "admin_insert_all" sobre "public"."solicitude"
DROP POLICY IF EXISTS "admin_insert_all" ON "public"."solicitude";
CREATE POLICY "admin_insert_all" ON "public"."solicitude" AS PERMISSIVE FOR INSERT TO public WITH CHECK (is_admin());

-- Política: "admin_delete_all" sobre "public"."solicitude"
DROP POLICY IF EXISTS "admin_delete_all" ON "public"."solicitude";
CREATE POLICY "admin_delete_all" ON "public"."solicitude" AS PERMISSIVE FOR DELETE TO public USING (is_admin());

ALTER TABLE "public"."stops" ENABLE ROW LEVEL SECURITY;
-- Política: "stops_select_all" sobre "public"."stops"
DROP POLICY IF EXISTS "stops_select_all" ON "public"."stops";
CREATE POLICY "stops_select_all" ON "public"."stops" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "stops_update_admin" sobre "public"."stops"
DROP POLICY IF EXISTS "stops_update_admin" ON "public"."stops";
CREATE POLICY "stops_update_admin" ON "public"."stops" AS PERMISSIVE FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- Política: "stops_delete_admin" sobre "public"."stops"
DROP POLICY IF EXISTS "stops_delete_admin" ON "public"."stops";
CREATE POLICY "stops_delete_admin" ON "public"."stops" AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());

-- Política: "stops_insert_admin" sobre "public"."stops"
DROP POLICY IF EXISTS "stops_insert_admin" ON "public"."stops";
CREATE POLICY "stops_insert_admin" ON "public"."stops" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (is_admin());

-- Política: "stops_select_authenticated" sobre "public"."stops"
DROP POLICY IF EXISTS "stops_select_authenticated" ON "public"."stops";
CREATE POLICY "stops_select_authenticated" ON "public"."stops" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;
-- Política: "Usuarios ven lo suyo o Admins ven todo" sobre "public"."transactions"
DROP POLICY IF EXISTS "Usuarios ven lo suyo o Admins ven todo" ON "public"."transactions";
CREATE POLICY "Usuarios ven lo suyo o Admins ven todo" ON "public"."transactions" AS PERMISSIVE FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM clients
  WHERE (clients.id = transactions.idclient))) OR (COALESCE(((auth.jwt() ->> 'is_super_admin'::text))::boolean, false) = true)));

ALTER TABLE "public"."units" ENABLE ROW LEVEL SECURITY;
-- Política: "Permitir lectura general de unidades" sobre "public"."units"
DROP POLICY IF EXISTS "Permitir lectura general de unidades" ON "public"."units";
CREATE POLICY "Permitir lectura general de unidades" ON "public"."units" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Política: "Service role can update payments-evidence" sobre "storage"."objects"
DROP POLICY IF EXISTS "Service role can update payments-evidence" ON "storage"."objects";
CREATE POLICY "Service role can update payments-evidence" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO service_role USING ((bucket_id = 'payments-evidence'::text));

-- Política: "Give authenticated users access to folder units_1" sobre "storage"."objects"
DROP POLICY IF EXISTS "Give authenticated users access to folder units_1" ON "storage"."objects";
CREATE POLICY "Give authenticated users access to folder units_1" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'payments-evidence'::text) AND ((storage.foldername(name))[1] = 'units'::text)));

-- Política: "Give authenticated users UPDATE access to folder units_2" sobre "storage"."objects"
DROP POLICY IF EXISTS "Give authenticated users UPDATE access to folder units_2" ON "storage"."objects";
CREATE POLICY "Give authenticated users UPDATE access to folder units_2" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO authenticated USING (((bucket_id = 'payments-evidence'::text) AND ((storage.foldername(name))[1] = 'units'::text)));

-- Política: "Service role can insert payments-evidence" sobre "storage"."objects"
DROP POLICY IF EXISTS "Service role can insert payments-evidence" ON "storage"."objects";
CREATE POLICY "Service role can insert payments-evidence" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO service_role WITH CHECK ((bucket_id = 'payments-evidence'::text));

-- Política: "Authenticated users can read payments-evidence" sobre "storage"."objects"
DROP POLICY IF EXISTS "Authenticated users can read payments-evidence" ON "storage"."objects";
CREATE POLICY "Authenticated users can read payments-evidence" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO authenticated USING ((bucket_id = 'payments-evidence'::text));

-- Política: "Give authenticated users DELETE access to folder units_3" sobre "storage"."objects"
DROP POLICY IF EXISTS "Give authenticated users DELETE access to folder units_3" ON "storage"."objects";
CREATE POLICY "Give authenticated users DELETE access to folder units_3" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'payments-evidence'::text) AND ((storage.foldername(name))[1] = 'units'::text)));

-- Política: "Lectura pública de archivos bptl2v_0" sobre "storage"."objects"
DROP POLICY IF EXISTS "Lectura pública de archivos bptl2v_0" ON "storage"."objects";
CREATE POLICY "Lectura pública de archivos bptl2v_0" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO authenticated USING ((bucket_id = 'payments-evidence'::text));

-- Política: "Permitir subida a usuarios autenticados bptl2v_0" sobre "storage"."objects"
DROP POLICY IF EXISTS "Permitir subida a usuarios autenticados bptl2v_0" ON "storage"."objects";
CREATE POLICY "Permitir subida a usuarios autenticados bptl2v_0" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((bucket_id = 'payments-evidence'::text));

-- Política: "anon_insert_profiles" sobre "storage"."objects"
DROP POLICY IF EXISTS "anon_insert_profiles" ON "storage"."objects";
CREATE POLICY "anon_insert_profiles" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO anon WITH CHECK (((bucket_id = 'payments-evidence'::text) AND ("left"(name, 9) = 'profiles/'::text)));

-- Política: "Service role can delete payments-evidence" sobre "storage"."objects"
DROP POLICY IF EXISTS "Service role can delete payments-evidence" ON "storage"."objects";
CREATE POLICY "Service role can delete payments-evidence" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO service_role USING ((bucket_id = 'payments-evidence'::text));

-- Política: "public_select_profiles" sobre "storage"."objects"
DROP POLICY IF EXISTS "public_select_profiles" ON "storage"."objects";
CREATE POLICY "public_select_profiles" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO anon, authenticated USING (((bucket_id = 'payments-evidence'::text) AND ("left"(name, 9) = 'profiles/'::text)));

-- >>> TRIGGERS <<<

-- Trigger: on_auth_user_created sobre auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth."users";
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth."users" FOR EACH ROW EXECUTE FUNCTION handle_new_user();

