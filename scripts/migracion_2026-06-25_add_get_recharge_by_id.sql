-- ============================================================
-- Migración: get_recharge_by_id
-- Fecha: 2025-06-25
-- Descripción: RPC para obtener una recarga completa por ID.
--              Usado desde Clientes.vue para el DetalleRecargaModal.
-- ============================================================

-- 1. Eliminar si existe
DROP FUNCTION IF EXISTS public.get_recharge_by_id(integer);

-- 2. Crear la función
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
            json_build_object('name', COALESCE(rt.description, rt.code), 'code', rt.code) AS route
        FROM public.recharge r
        LEFT JOIN public.clients c ON c.id = r.idclient
        LEFT JOIN public.routes rt ON rt.id = r.idroute
        WHERE r.id = p_id
          AND (public.is_admin() OR r.idroute = ANY(public.get_current_user_route_ids()))
    ) t;

    RETURN COALESCE(v_result, 'null'::json);
END;
$function$
;
