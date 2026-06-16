-- =====================================================
-- MIGRACIÓN: Columna tickets en recharge
-- Fecha: 2026-06-16
-- =====================================================
-- Incluye:
-- 1. ALTER TABLE para agregar columna tickets
-- 2. process_payment actualizado (guarda tickets en INSERT)
-- 3. get_recharges_paginated actualizado (incluye tickets
--    en SELECT + ordenamiento)
-- =====================================================

-- =====================================================
-- 1. Schema: agregar columna tickets
-- =====================================================
ALTER TABLE public.recharge ADD COLUMN IF NOT EXISTS tickets NUMERIC;

-- =====================================================
-- 2. Fix process_payment: guardar tickets en recharge
-- =====================================================

CREATE OR REPLACE FUNCTION public.process_payment(p_idclient integer, p_amount numeric, p_method character varying, p_ref character varying DEFAULT NULL::character varying, p_tasa numeric DEFAULT NULL::numeric, p_date date DEFAULT CURRENT_DATE, p_picture character varying DEFAULT NULL::character varying, p_create_by character varying DEFAULT NULL::character varying, p_codigo_banco character varying DEFAULT NULL::character varying)
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

    v_calc := public.calculate_tickets(p_amount, p_method, p_tasa);
    v_amount_in_usd := (v_calc->>'usd_amount')::NUMERIC;
    v_estimated_tickets := (v_calc->>'estimated_tickets')::NUMERIC;

    INSERT INTO public.recharge (
        idclient, method, ref, picture, amount, tasa, date, status, "createBy", "createAt", codigo_banco, idroute, tickets
    )
    VALUES (
        p_idclient,
        p_method,
        NULLIF(p_ref, ''),
        NULLIF(p_picture, ''),
        v_amount_in_usd,
        p_tasa,
        p_date,
        0,
        p_create_by,
        NOW(),
        NULLIF(p_codigo_banco, ''),
        v_idroute,
        v_estimated_tickets
    )
    RETURNING id INTO v_recharge_id;

    RETURN json_build_object(
        'success', true,
        'message', 'Pago registrado exitosamente. En espera por verificación administrativa.',
        'recharge_id', v_recharge_id,
        'estimated_tickets', v_estimated_tickets,
        'current_balance', v_current_balance
    );
EXCEPTION
    WHEN SQLSTATE '23505' THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Esta combinación de banco y referencia ya fue procesada. Verifique los datos e intente de nuevo.'
        );
    WHEN OTHERS THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Error en transacción: ' || SQLERRM
        );
END;
$function$;

-- =====================================================
-- 3. Fix get_recharges_paginated: incluir tickets
-- =====================================================

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
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
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
$function$;
