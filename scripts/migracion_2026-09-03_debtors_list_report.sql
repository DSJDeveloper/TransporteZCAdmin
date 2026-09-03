-- =====================================================
-- MIGRACIÓN: get_debtors_list con detalle para reporte PDF
-- Fecha: 2026-09-03
-- Propósito: Alimentar el reporte de deudores (DebtorsCard.vue)
--            agrupado por ruta y filtrable por rol:
--  - auth_user_name: nombre resuelto desde profiles
--    (p.name > raw_user_meta_data.user_name > c.name).
--  - email: correo del cliente (sincronizado con profiles).
--  - idroute: ruta del cliente (permite filtrar supervisor
--    por rutas asignadas en el frontend).
--  - route_name: descripción de la ruta para agrupar.
-- Cambio aditivo: mantiene id, name, documentID, balance,
-- tickets y route_name; NO cambia parámetros ni retorno shape.
-- =====================================================

BEGIN;

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
            COALESCE(NULLIF(p.name, ''), NULLIF(au.raw_user_meta_data->>'user_name', ''), c.name) AS auth_user_name,
            c."documentID",
            c.email,
            c.idroute,
            r.description AS route_name,
            c.balance,
            c.tickets
        FROM public.clients c
        LEFT JOIN public.routes r ON c.idroute = r.id
        LEFT JOIN public.profiles p ON p.id = c.uid::uuid
        LEFT JOIN auth.users au ON au.id = c.uid::uuid
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

COMMIT;
