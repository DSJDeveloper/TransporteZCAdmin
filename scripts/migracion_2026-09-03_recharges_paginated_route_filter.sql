-- =====================================================
-- MIGRACIÓN: get_recharges_paginated con filtro por ruta
-- Fecha: 2026-09-03
-- Propósito: Permitir filtrar el historial de recargas por ruta
--            (p_idroute) con paginación/totales correctos, manteniendo
--            la restricción por rol del supervisor.
--
-- Cambios:
--  * SE ELIMINAN los overloads previos (sin/con p_search) para evitar
--    ambigüedad de resolución (PGRST203).
--  * Se crea UN solo overload con firma extendida:
--      (..., p_search text DEFAULT NULL, p_idroute bigint DEFAULT NULL)
--    Todos los argumentos tienen DEFAULT => las llamadas antiguas
--    (sin p_idroute) y nuevas (con p_idroute) resuelven a esta función.
--  * Nueva condición en COUNT y SELECT:
--      AND (p_idroute IS NULL OR r.idroute = p_idroute)
--    Se conserva la guarda de seguridad:
--      AND (public.is_admin() OR r.idroute = ANY(v_route_ids))
-- =====================================================

BEGIN;

-- ─────────────────────────────────────────────────────
-- 1) Eliminar overloads previos (idempotente)
-- ─────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_recharges_paginated(integer, integer, integer, date, date, character varying, text, text);
DROP FUNCTION IF EXISTS public.get_recharges_paginated(integer, integer, integer, date, date, character varying, text, text, text);

-- ─────────────────────────────────────────────────────
-- 2) Overload único con p_search + p_idroute
-- ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_recharges_paginated(p_page integer DEFAULT 1, p_per_page integer DEFAULT 10, p_status integer DEFAULT NULL::integer, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_method character varying DEFAULT NULL::character varying, p_sort_field text DEFAULT 'id'::text, p_sort_order text DEFAULT 'DESC'::text, p_search text DEFAULT NULL::text, p_idroute bigint DEFAULT NULL::bigint)
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
      AND (p_idroute IS NULL OR r.idroute = p_idroute)
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
          AND (p_idroute IS NULL OR r.idroute = p_idroute)
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
