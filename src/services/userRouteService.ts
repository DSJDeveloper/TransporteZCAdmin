import { supabase } from "./supabaseClient"

export interface UserRoute {
  id: number
  user_id: string
  idroute: number
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getUserRoutes(userId: string): Promise<UserRoute[]> {
  const { data: raw, error } = await supabase.rpc("get_user_routes", {
    p_user_id: userId,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<UserRoute[]>
  if (!result.success) throw new Error(result.message ?? "Error al cargar las rutas del usuario")
  return result.data ?? []
}

export async function assignUserRoutes(userId: string, routeIds: number[]): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_user_routes", {
    p_user_id: userId,
    p_route_ids: routeIds,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al asignar rutas")
}
