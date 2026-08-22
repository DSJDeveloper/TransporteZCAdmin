import { supabase } from "./supabaseClient"

export interface RouteStop {
  id: number
  route_id: number
  stop_id: number
  price: number
  stop_order: number
  name: string
  description: string
}

export interface RouteStopForm {
  route_id: number
  stop_id: number
  price: number
  stop_order: number
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getStopsByRoute(idroute: number): Promise<RouteStop[]> {
  const { data: raw, error } = await supabase.rpc("get_stops_by_route", {
    p_idroute: idroute,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<RouteStop[]>
  if (!result.success) throw new Error(result.message ?? "Error al cargar paradas de la ruta")
  return result.data ?? []
}

export async function assignStopToRoute(input: RouteStopForm): Promise<number> {
  const { data: raw, error } = await supabase.rpc("manage_route_stop", {
    p_action: "create",
    p_id: null,
    p_route_id: input.route_id,
    p_stop_id: input.stop_id,
    p_price: input.price,
    p_stop_order: input.stop_order,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<{ id: number }>
  if (!result.success) throw new Error(result.message ?? "Error al asignar parada")
  return result.data?.id ?? 0
}

export async function updateRouteStop(
  id: number,
  input: { price?: number; stop_order?: number },
): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_route_stop", {
    p_action: "update",
    p_id: id,
    p_route_id: null,
    p_stop_id: null,
    p_price: input.price ?? null,
    p_stop_order: input.stop_order ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar parada")
}

export async function removeStopFromRoute(relId: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_route_stop", {
    p_action: "delete",
    p_id: relId,
    p_route_id: null,
    p_stop_id: null,
    p_price: null,
    p_stop_order: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al remover parada")
}
