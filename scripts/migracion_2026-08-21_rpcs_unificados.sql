-- ============================================================
-- MIGRACIÓN: RPCs Unificados — Todas las versiones finales
-- Fecha: 2026-08-21
-- Propósito: Consolidar en un solo script idempotente las versiones
--            finales de todos los RPCs modificados desde el último
--            commit. Ejecutar después de las migraciones de schema.
--
-- Modelo: Dual-field (clients.balance USD + clients.tickets units)
--         (transactions.amount USD + transactions.ticket units)
--
-- RPCs incluidos (23 funciones):
--   Sección 1: Helpers
--     1. normalize_document_id
--     2. calculate_tickets_from_amount
--     3. calculate_tickets (4-param)
--   Sección 2: Stops & Route Stops
--     4. manage_stop
--     5. get_stops_by_route
--     6. manage_route_stop
--   Sección 3: Clients
--     7. manage_client
--     8. get_client_balance
--     9. get_client_by_uid
--    10. get_debtors_list
--    11. get_client_history
--   Sección 4: Pagos & Recargas
--    12. process_payment (11-param)
--    13. process_recharge_status (dual-write)
--   Sección 5: Cobros
--    14. charge_tickets_bulk (p_idstop + dual-write)
--    15. charge_ticket (DEPRECATED, dual-write)
--    16. add_tickets_to_client (dual-write)
--   Sección 6: Trigger
--    17. handle_new_user
--   Sección 7: Transactions (lectura)
--    18. get_clients_transactions
--    19. get_transactions_paginated
--    20. get_transactions_export (8-param)
--    21. get_transactions_export (9-param)
--   Sección 8: Perfiles & Listados
--    22. get_clients_paginated
--    23. get_complete_user_profile
-- ============================================================

BEGIN;

-- ============================================================
-- Migración: Unique documentID en clients
-- Fecha: 2026-08-21
-- Descripción: Índice único normalizado sobre documentID para
--              impedir cédulas duplicadas (con/sin formato).
--              Actualiza manage_client con validación server-side.
-- ============================================================
update transactions set idclient=158 where idclient=11;
update transactions set idclient=61 where idclient=117;

delete from clients where id in (155,143,160,11,117);



-- 2.2 solicitude.idstop + solicitude.amount: parada y costo del asiento
ALTER TABLE public.solicitude ADD COLUMN IF NOT EXISTS idstop bigint;
ALTER TABLE public.solicitude ADD COLUMN IF NOT EXISTS amount numeric(10,2);

-- ============================================================
-- A: Schema — nuevas columnas en transactions
-- ============================================================
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ticket NUMERIC(10,2) NOT NULL DEFAULT 0.00;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS "newTicketsClient" NUMERIC(10,2) NOT NULL DEFAULT 0.00;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS idstop bigint;
CREATE INDEX IF NOT EXISTS idx_transactions_idstop ON public.transactions (idstop);
-- ============================================================
-- B: Migracion historica de datos
-- ============================================================
-- B1: Copiar valores actuales (ya en USD) como backup de unidades
UPDATE public.transactions SET ticket = amount, "newTicketsClient" = "newBalanceClient";

-- B2: Re-multiplicar amount y newBalanceClient por company.ticket
UPDATE public.transactions
SET amount = amount * COALESCE((SELECT ticket FROM public.company LIMIT 1), 0),
    "newBalanceClient" = "newBalanceClient" * COALESCE((SELECT ticket FROM public.company LIMIT 1), 0);


-- 1.1 sanitize_document_id(text): cédula robusta [^a-zA-Z0-9] (registro público)
DROP FUNCTION IF EXISTS public.sanitize_document_id(character varying);
CREATE OR REPLACE FUNCTION public.sanitize_document_id(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 PARALLEL SAFE
AS $function$
    SELECT UPPER(REGEXP_REPLACE(COALESCE(p_value, ''), '[^a-zA-Z0-9]', '', 'g'))
$function$
;


-- 3. Actualizar manage_client: validación de documentID duplicado

DROP FUNCTION IF EXISTS public.manage_client(character varying, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, bigint, character varying);
CREATE OR REPLACE FUNCTION public.manage_client(
    p_action        character varying,
    p_id            bigint DEFAULT NULL,
    p_name          character varying DEFAULT NULL,
    p_document_id   character varying DEFAULT NULL,
    p_email         character varying DEFAULT NULL,
    p_phone         character varying DEFAULT NULL,
    p_carrer        character varying DEFAULT NULL,
    p_credit_limit  character varying DEFAULT NULL,
    p_status        character varying DEFAULT NULL,
    p_idroute       bigint DEFAULT NULL,
    p_photo_url     character varying DEFAULT NULL
)
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



-- ============================================================
-- SECCIÓN 1: HELPERS
-- ============================================================

-- 1. normalize_document_id
DROP FUNCTION IF EXISTS public.normalize_document_id(character varying);
CREATE OR REPLACE FUNCTION public.normalize_document_id(p_value character varying)
RETURNS text
    LANGUAGE sql
    IMMUTABLE
    SECURITY DEFINER
AS $function$
    SELECT UPPER(REGEXP_REPLACE(COALESCE(p_value, ''), '[.\-\,\s]', '', 'g'));
$function$
;
-- 2. Índice único normalizado sobre documentID
--    Previene duplicados aunque los valores tengan formato distinto
--    (ej. "V-12.345.678" = "V12345678" = "12345678")
DROP INDEX IF EXISTS "idx_clients_document_id_unique";
CREATE UNIQUE INDEX "idx_clients_document_id_unique"
    ON public."clients"
    (public.normalize_document_id("documentID"));
-- -------------------------------------------------------
-- A: Schema -- nueva columna tickets
-- -------------------------------------------------------
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS tickets NUMERIC(10,2) NOT NULL DEFAULT 0.00;

-- -------------------------------------------------------
-- B: Migracion de datos
-- -------------------------------------------------------
-- B1: Copiar balance actual (tickets) -> tickets
UPDATE public.clients SET tickets = balance;

-- B2: Convertir balance a USD (balance * company.ticket)
UPDATE public.clients
SET balance = balance * (SELECT ticket FROM public.company LIMIT 1);
-- 2. calculate_tickets_from_amount
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

-- 3. calculate_tickets (4-param con fallback route_stops → company)
DROP FUNCTION IF EXISTS public.calculate_tickets(numeric, character varying, numeric);
DROP FUNCTION IF EXISTS public.calculate_tickets(numeric, character varying, numeric, bigint);
CREATE OR REPLACE FUNCTION public.calculate_tickets(p_amount numeric, p_method character varying, p_tasa numeric, p_idroute bigint DEFAULT NULL)
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

-- ============================================================
-- SECCIÓN 2: STOPS & ROUTE STOPS
-- ============================================================

-- 1. Tabla stops
CREATE TABLE IF NOT EXISTS public."stops" (
    "id"          bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "name"        character varying(255) NOT NULL,
    "description" character varying(255) DEFAULT ''::character varying,
    "status"      integer NOT NULL DEFAULT 0,
    "created_at"  timestamp with time zone DEFAULT now()
);

ALTER TABLE public."stops" DROP CONSTRAINT IF EXISTS "stops_pkey" CASCADE;
ALTER TABLE public."stops" ADD CONSTRAINT "stops_pkey" PRIMARY KEY (id);

CREATE INDEX IF NOT EXISTS "idx_stops_name" ON public."stops" ("name");

-- 2. Tabla intermedia route_stops
CREATE TABLE IF NOT EXISTS public."route_stops" (
    "id"         bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    "route_id"   bigint NOT NULL,
    "stop_id"    bigint NOT NULL,
    "price"      numeric(10,2) NOT NULL DEFAULT 0,
    "stop_order" integer NOT NULL DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT now()
);

ALTER TABLE public."route_stops" DROP CONSTRAINT IF EXISTS "route_stops_pkey" CASCADE;
ALTER TABLE public."route_stops" ADD CONSTRAINT "route_stops_pkey" PRIMARY KEY (id);

-- FKs
ALTER TABLE public."route_stops" DROP CONSTRAINT IF EXISTS "route_stops_route_id_fkey" CASCADE;
ALTER TABLE public."route_stops"
    ADD CONSTRAINT "route_stops_route_id_fkey"
    FOREIGN KEY ("route_id") REFERENCES public."routes"("id") ON DELETE CASCADE;

ALTER TABLE public."route_stops" DROP CONSTRAINT IF EXISTS "route_stops_stop_id_fkey" CASCADE;
ALTER TABLE public."route_stops"
    ADD CONSTRAINT "route_stops_stop_id_fkey"
    FOREIGN KEY ("stop_id") REFERENCES public."stops"("id") ON DELETE CASCADE;

-- Unique constraint
ALTER TABLE public."route_stops" DROP CONSTRAINT IF EXISTS "route_stops_route_stop_uq" CASCADE;
ALTER TABLE public."route_stops"
    ADD CONSTRAINT "route_stops_route_stop_uq"
    UNIQUE ("route_id", "stop_id");

-- Índices
CREATE INDEX IF NOT EXISTS "idx_route_stops_route_id" ON public."route_stops" ("route_id");
CREATE INDEX IF NOT EXISTS "idx_route_stops_stop_id"  ON public."route_stops" ("stop_id");

-- 3. RLS
ALTER TABLE public."stops" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."route_stops" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "stops_select_all"   ON public."stops";
DROP POLICY IF EXISTS "stops_insert_admin" ON public."stops";
DROP POLICY IF EXISTS "stops_update_admin" ON public."stops";
DROP POLICY IF EXISTS "stops_delete_admin" ON public."stops";

CREATE POLICY "stops_select_all"   ON public."stops" FOR SELECT TO authenticated USING (true);
CREATE POLICY "stops_insert_admin" ON public."stops" FOR INSERT TO authenticated WITH CHECK (is_admin());
CREATE POLICY "stops_update_admin" ON public."stops" FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "stops_delete_admin" ON public."stops" FOR DELETE TO authenticated USING (is_admin());

DROP POLICY IF EXISTS "route_stops_select_all"   ON public."route_stops";
DROP POLICY IF EXISTS "route_stops_insert_admin" ON public."route_stops";
DROP POLICY IF EXISTS "route_stops_update_admin" ON public."route_stops";
DROP POLICY IF EXISTS "route_stops_delete_admin" ON public."route_stops";

CREATE POLICY "route_stops_select_all"   ON public."route_stops" FOR SELECT TO authenticated USING (true);
CREATE POLICY "route_stops_insert_admin" ON public."route_stops" FOR INSERT TO authenticated WITH CHECK (is_admin());
CREATE POLICY "route_stops_update_admin" ON public."route_stops" FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "route_stops_delete_admin" ON public."route_stops" FOR DELETE TO authenticated USING (is_admin());

-- 4. manage_stop
DROP FUNCTION IF EXISTS public.manage_stop(character varying, bigint, character varying, character varying, integer);
CREATE OR REPLACE FUNCTION public.manage_stop(
    p_action      character varying,
    p_id          bigint DEFAULT NULL,
    p_name        character varying DEFAULT NULL,
    p_description character varying DEFAULT NULL,
    p_status      integer DEFAULT NULL
)
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
        RETURN json_build_object('success', false, 'message', 'Accion no reconocida.');
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'message', 'Error: ' || SQLERRM);
END;
$function$
;

-- 5. RPC: get_stops_by_route
DROP FUNCTION IF EXISTS public.get_stops_by_route(bigint);
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

-- 6. RPC: manage_route_stop
DROP FUNCTION IF EXISTS public.manage_route_stop(character varying, bigint, bigint, bigint, numeric, integer);
CREATE OR REPLACE FUNCTION public.manage_route_stop(
    p_action    character varying,
    p_id        bigint DEFAULT NULL,
    p_route_id  bigint DEFAULT NULL,
    p_stop_id   bigint DEFAULT NULL,
    p_price     numeric DEFAULT NULL,
    p_stop_order integer DEFAULT NULL
)
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



-- ============================================================
-- SECCIÓN 3: CLIENTS
-- ============================================================



-- 8. get_client_balance
DROP FUNCTION IF EXISTS public.get_client_balance(integer);
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

-- 9. get_client_by_uid
DROP FUNCTION IF EXISTS public.get_client_by_uid(varchar);
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

-- 10. get_debtors_list
DROP FUNCTION IF EXISTS public.get_debtors_list();
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

-- 11. get_client_history
DROP FUNCTION IF EXISTS public.get_client_history(integer, text, text);
CREATE OR REPLACE FUNCTION public.get_client_history(
    p_client_id integer,
    p_start_date text DEFAULT NULL,
    p_end_date text DEFAULT NULL
)
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

-- ============================================================
-- SECCIÓN 4: PAGOS & RECARGAS
-- ============================================================

-- 12. process_payment (11-param — el usado por frontend)
DROP FUNCTION IF EXISTS public.process_payment(integer, numeric, character varying, character varying, numeric, date, character varying, character varying, character varying, bigint, bigint);
CREATE OR REPLACE FUNCTION public.process_payment(p_idclient integer, p_amount numeric, p_method character varying, p_ref character varying DEFAULT NULL::character varying, p_tasa numeric DEFAULT NULL::numeric, p_date date DEFAULT CURRENT_DATE, p_picture character varying DEFAULT NULL::character varying, p_create_by character varying DEFAULT NULL::character varying, p_codigo_banco character varying DEFAULT NULL::character varying, p_idroute bigint DEFAULT NULL::bigint, p_idshedule bigint DEFAULT NULL::bigint)
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
        idclient, method, ref, picture, amount, tasa, date, status, "createBy", "createAt", codigo_banco, idroute, tickets, idshedule
    )
    VALUES (
        p_idclient, p_method, NULLIF(p_ref, ''), NULLIF(p_picture, ''),
        v_amount_in_usd, p_tasa, p_date, 0, p_create_by, NOW(),
        NULLIF(p_codigo_banco, ''), v_idroute, v_estimated_tickets, p_idshedule
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

-- 13. process_recharge_status (dual-write: balance USD + tickets units)
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
    v_tickets_to_add NUMERIC(10,2) := 0.00;
    v_new_balance NUMERIC(10,2);
    v_new_tickets NUMERIC(10,2);
    v_final_status INTEGER;
    v_log_message VARCHAR(255);
    v_ticket_price NUMERIC(10,2);
BEGIN
    IF LOWER(p_action) NOT IN ('approve', 'reject') THEN
        RETURN json_build_object('success', false, 'message', 'Accion invalida. Use approve o reject.');
    END IF;

    SELECT idclient, status, amount, tasa, method
    INTO v_idclient, v_status, v_amount, v_tasa, v_method
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
        v_final_status := 1;
        v_log_message := 'Recarga verificada y saldo acreditado con exito.';
        v_tickets_to_add := public.calculate_tickets_from_amount(v_amount);

        UPDATE public.clients
        SET balance = balance + v_amount,
            tickets = tickets + v_tickets_to_add
        WHERE id = v_idclient
        RETURNING balance, tickets INTO v_new_balance, v_new_tickets;

    ELSIF LOWER(p_action) = 'reject' THEN
        v_final_status := 2;
        v_log_message := 'Recarga rechazada. No se altero el saldo.';
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
-- DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer);
-- DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer, bigint);
-- DROP FUNCTION IF EXISTS public.charge_tickets_bulk(jsonb, integer, integer, bigint, numeric);

-- CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(
--     p_transactions jsonb,
--     p_create_by    integer,
--     p_idunit       integer DEFAULT NULL::integer,
--     p_idstop       bigint  DEFAULT NULL::bigint
-- )
--  RETURNS json
--  LANGUAGE plpgsql
--  SECURITY DEFINER
-- AS $function$
-- DECLARE
--     v_item              JSONB;
--     v_client_uid        VARCHAR(255);
--     v_ticket_count      INTEGER;
--     v_shedule           VARCHAR(255);
--     v_client_id         BIGINT;
--     v_client_name       VARCHAR(255);
--     v_current_balance   NUMERIC(10,2);
--     v_current_tickets   NUMERIC(10,2);
--     v_credit_limit_raw  VARCHAR(255);
--     v_credit_limit      NUMERIC(10,2);
--     v_new_balance       NUMERIC(10,2);
--     v_new_tickets       NUMERIC(10,2);
--     v_charge_usd        NUMERIC(10,2);
--     v_tickets_to_deduct NUMERIC(10,2);
--     v_count_booking     INTEGER;
--     v_tx_uid            VARCHAR(255);
--     v_is_admin          BOOLEAN;
--     v_idunit            INTEGER;
--     v_idroute           BIGINT;
--     v_company_ticket    NUMERIC(10,2);
--     v_unit_fare         NUMERIC(10,2);
--     v_processed_count   INTEGER := 0;
--     v_response_data     JSONB := '[]'::jsonb;
-- BEGIN
--     -- 1. Permisos y resolución de unidad/ruta
--     v_is_admin := public.is_admin();
--     v_idunit   := COALESCE(p_idunit, p_create_by);

--     SELECT idroute INTO v_idroute
--     FROM public.units
--     WHERE id = v_idunit;

--     -- 2. Tarifa base de la empresa (fallback y conversión)
--     SELECT ticket INTO v_company_ticket
--     FROM public.company
--     LIMIT 1;

--     IF v_company_ticket IS NULL OR v_company_ticket <= 0 THEN
--         RAISE EXCEPTION 'Error de configuracion: company.ticket no valido (%).', v_company_ticket;
--     END IF;

--     -- 3. Determinación de la tarifa según la parada
--     IF p_idstop IS NOT NULL THEN
--         SELECT rs.price INTO v_unit_fare
--         FROM public.route_stops rs
--         WHERE rs.id = p_idstop;

--         IF v_unit_fare IS NULL THEN
--             RAISE EXCEPTION 'La parada con id % no existe en route_stops.', p_idstop;
--         END IF;

--         IF v_unit_fare <= 0 THEN
--             RAISE EXCEPTION 'El precio de la parada % es invalido (%).', p_idstop, v_unit_fare;
--         END IF;
--     ELSE
--         v_unit_fare := v_company_ticket;
--     END IF;

--     -- 4. Iteración y débito de transacciones en lote
--     FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
--         v_client_uid   := v_item->>'client_uid';
--         v_ticket_count := (v_item->>'ticket_count')::INTEGER;
--         v_shedule      := v_item->>'shedule';

--         IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
--             RAISE EXCEPTION 'Registro invalido. Verifique UIDs y cantidades.';
--         END IF;

--         SELECT id, balance, tickets, "creditLimit", name
--         INTO v_client_id, v_current_balance, v_current_tickets,
--              v_credit_limit_raw, v_client_name
--         FROM public.clients
--         WHERE uid = v_client_uid
--         FOR UPDATE;

--         IF v_client_id IS NULL THEN
--             RAISE EXCEPTION 'El cliente con UID % no existe.', v_client_uid;
--         END IF;

--         -- Monto monetario y tickets equivalentes
--         v_charge_usd        := ROUND(v_unit_fare * v_ticket_count, 2);
--         v_tickets_to_deduct := ROUND(v_charge_usd / v_company_ticket, 2);
--         v_new_balance       := v_current_balance - v_charge_usd;
--         v_new_tickets       := v_current_tickets - v_tickets_to_deduct;
--         v_credit_limit      := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

--         -- Validación de crédito/saldo
--         IF NOT v_is_admin AND v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
--             RAISE EXCEPTION 'Saldo insuficiente. Cliente: %, Saldo: $% (% tickets), Cargo: $% (% tickets eq.), Limite: $%.',
--                 v_client_name, v_current_balance, v_current_tickets,
--                 v_charge_usd, v_tickets_to_deduct, v_credit_limit;
--         END IF;

--         -- Conteo de reservas del día
--         SELECT COUNT(*)::INTEGER INTO v_count_booking
--         FROM public.solicitude
--         WHERE idclient = v_client_id
--           AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

--         -- Actualización del saldo dual en clientes
--         UPDATE public.clients
--         SET balance = v_new_balance,
--             tickets = v_new_tickets
--         WHERE id = v_client_id;

--         -- Generación de identificador único de transacción
--         v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS')
--                     || FLOOR(RANDOM() * 100)::TEXT
--                     || v_processed_count::TEXT;

--         -- Inserción con esquema dual e idstop integrado
--         INSERT INTO public.transactions (
--             uid,
--             idclient,
--             "createBy",
--             amount,
--             ticket,
--             status,
--             shedule,
--             "newBalanceClient",
--             "newTicketsClient",
--             idunit,
--             idroute,
--             idstop,
--             created_at
--         )
--         VALUES (
--             v_tx_uid,
--             v_client_id,
--             p_create_by,
--             v_charge_usd,
--             v_tickets_to_deduct,
--             0,
--             v_shedule,
--             v_new_balance,
--             v_new_tickets,
--             v_idunit,
--             v_idroute,
--             p_idstop,
--             NOW()
--         );

--         -- Registro en el array de respuesta
--         v_response_data := v_response_data || jsonb_build_object(
--             'client_uid',      v_client_uid,
--             'amount_debited',  v_charge_usd,
--             'tickets_debited', v_tickets_to_deduct,
--             'new_balance',     v_new_balance,
--             'new_tickets',     v_new_tickets,
--             'booking_count',   v_count_booking
--         );

--         v_processed_count := v_processed_count + 1;
--     END LOOP;

--     RETURN json_build_object(
--         'success',           true,
--         'message',           'Lote de transacciones procesado con exito.',
--         'processed_records', v_processed_count,
--         'unit_fare',         v_unit_fare,
--         'details',           v_response_data
--     );

-- EXCEPTION WHEN OTHERS THEN
--     RETURN json_build_object(
--         'success',           false,
--         'message',           'Rollback: ' || SQLERRM,
--         'processed_records', 0,
--         'details',           '[]'::json
--     );
-- END;
-- $function$;

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
$function$;

-- 15. charge_ticket (DEPRECATED — dual-write: balance USD + tickets units)
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

-- 16. add_tickets_to_client (dual-write: balance USD + tickets units)
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
    RETURN json_build_object(
        'success', false,
        'message', 'Error al procesar la transaccion: ' || SQLERRM
    );
END;
$function$
;

-- ============================================================
-- SECCIÓN 6: TRIGGER
-- ============================================================

-- 17. handle_new_user (INSERT con tickets)
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

-- ============================================================
-- SECCIÓN 7: TRANSACTIONS (LECTURA)
-- ============================================================

-- 18. get_clients_transactions
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
$function$
;

-- 19. get_transactions_paginated
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

-- 20. get_transactions_export (8-param overload)
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

-- 21. get_transactions_export (9-param overload with search)
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

-- ============================================================
-- SECCIÓN 8: PERFILES & LISTADOS
-- ============================================================

-- 22. get_clients_paginated
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

-- 23. get_complete_user_profile
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
-- FIN DE LA MIGRACIÓN
-- ============================================================

COMMIT;




-- ============================================================
-- MIGRACIÓN: Recharges — Información de Parada (route_stops)
-- Fecha: 2026-08-21
-- Propósito: Agregar LEFT JOIN con route_stops + stops a
--            get_recharge_by_id y get_recharges_paginated para
--            retornar stop: { id, name, price, stop_order }.
--            Si idstop es NULL, el campo retorna null transparente.
--
-- Tablas involucradas:
--   recharge.idstop → route_stops.id → route_stops.stop_id → stops.id
-- ============================================================

BEGIN;

-- ============================================================
-- 1. get_recharge_by_id — agregar stop
-- ============================================================
DROP FUNCTION IF EXISTS public.get_recharge_by_id(integer);
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

-- ============================================================
-- 2. get_recharges_paginated (8-param) — agregar stop
-- ============================================================
DROP FUNCTION IF EXISTS public.get_recharges_paginated(integer, integer, integer, date, date, character varying, text, text);
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

-- ============================================================
-- 3. get_recharges_paginated (9-param con search) — agregar stop
-- ============================================================
DROP FUNCTION IF EXISTS public.get_recharges_paginated(integer, integer, integer, date, date, character varying, text, text, text);
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

COMMIT;


-- ============================================================================
-- MIGRACIÓN: Parada obligatoria en recargas (PagoMovil / PagoEfectivo)
-- Fecha: 2026-08-22
--
-- 1. ALTER TABLE recharge: agrega idstop (parada destino, nullable retrocompatible)
-- 2. process_payment: nuevo parámetro opcional p_idstop. Se persiste en
--    recharge.idstop junto con idroute/idshedule.
--    ⚠️ Anti-PGRST203: DROP de la firma de 11 params ANTES del CREATE de 12.
-- ============================================================================

-- ── 1. Columna idstop en recharge ──────────────────────────
ALTER TABLE public.recharge ADD COLUMN IF NOT EXISTS idstop bigint;
CREATE INDEX IF NOT EXISTS idx_recharge_idstop ON public.recharge (idstop);

-- ── 2. process_payment con p_idstop ────────────────────────
DROP FUNCTION IF EXISTS public.process_payment(integer, numeric, character varying, character varying, numeric, date, character varying, character varying, character varying, bigint, bigint);

CREATE OR REPLACE FUNCTION public.process_payment(
    p_idclient integer,
    p_amount numeric,
    p_method character varying,
    p_ref character varying DEFAULT NULL,
    p_tasa numeric DEFAULT NULL,
    p_date date DEFAULT CURRENT_DATE,
    p_picture character varying DEFAULT NULL,
    p_create_by character varying DEFAULT NULL,
    p_codigo_banco character varying DEFAULT NULL,
    p_idroute bigint DEFAULT NULL,
    p_idshedule bigint DEFAULT NULL,
    p_idstop bigint DEFAULT NULL
)
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

NOTIFY pgrst, 'reload schema';




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
