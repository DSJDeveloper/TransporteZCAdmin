# Archivos que se deben ejecutar en el orden correcto para el cambio de version, donde se agrega la validacion por cedula para nuevos estudiantes y el cambio calculos de tickets a saldos y paradas en las rutas#

## Primero Ejecutar 
### migracion_2026-08-21_unique_document_id.sql
### Luego ejecutar el siquiente script, para eliminar los clientes duplicados y unificar los movimientos de los duplicados
```
update transactions set idclient=158 where idclient=11;
update transactions set idclient=61 where idclient=117;

delete from clients where id in (155,143,160,11,117);
```
### Luego ejecutar migracion_2026-08-21_refactor_company_ticket_to_stop_price.sql
### Luego ejecuta migracion_2026-08-21_split_balance_tickets.sql 
### migracion_2026-08-21_transactions_dual_fields
## Para la app ejecutar los siguientes archivos
### scripts/migracion_transacciones_stop.sql