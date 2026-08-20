-- =====================================================
-- CLEANUP: Eliminar RPCs redundantes (sobrecargas no usadas)
-- Fecha: 2026-06-16
-- =====================================================
-- Elimina las sobrecargas de get_recharges_paginated que
-- no se usan desde el frontend (3-param y 6-param),
-- dejando solo la de 8 parámetros (con sort).
-- =====================================================

BEGIN;

-- 1. get_recharges_paginated: eliminar sobrecargas no usadas
DROP FUNCTION IF EXISTS public.get_recharges_paginated(INTEGER, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS public.get_recharges_paginated(INTEGER, INTEGER, INTEGER, DATE, DATE, VARCHAR);

-- Nota: la sobrecarga de 8 parámetros se conserva:
--   get_recharges_paginated(INTEGER, INTEGER, INTEGER, DATE, DATE, VARCHAR, TEXT, TEXT)

-- 2. process_payment: eliminar sobrecarga redundante (sin p_codigo_banco)
--    La sobrecarga con p_codigo_banco (DEFAULT NULL) cubre ambos casos.
DROP FUNCTION IF EXISTS public.process_payment(INTEGER, NUMERIC, VARCHAR, VARCHAR, NUMERIC, DATE, VARCHAR, VARCHAR);

COMMIT;
