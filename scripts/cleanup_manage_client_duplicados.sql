-- =====================================================
-- CLEANUP: Eliminar overloads duplicados de manage_client
-- Fecha: 2026-06-16
-- =====================================================
-- En la DB hay 2 overloads que sobreviven:
--   1. manage_client(varchar, bigint, varchar...) sin p_idroute
--      ↑ NO USADO por el frontend
--   2. manage_client(varchar, bigint, varchar..., bigint) con p_idroute
--      ↑ ÚNICO usado por el frontend (clientService.ts)
--
-- Este script elimina el overload sin p_idroute
-- y deja solo el que realmente se necesita.
-- =====================================================

DROP FUNCTION IF EXISTS public.manage_client(
    p_action character varying,
    p_id bigint,
    p_name character varying,
    p_document_id character varying,
    p_email character varying,
    p_phone character varying,
    p_carrer character varying,
    p_credit_limit character varying,
    p_status character varying
);
