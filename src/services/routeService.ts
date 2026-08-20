import { supabase } from "./supabaseClient"

export interface Route {
  id: number
  code: string
  description: string
  idbank_info: number | null
  bank_info_name?: string
  status: number
  created_at?: string
}

export type RouteForm = Omit<Route, "id" | "created_at" | "bank_info_name">

export interface RouteName {
  id: number
  code: string
  description: string
  idbank_info: number | null
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getRoutes(): Promise<Route[]> {
  const { data: raw, error } = await supabase.rpc("get_routes")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: Route[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar las rutas")
  return result.data ?? []
}

export async function getRouteNames(): Promise<RouteName[]> {
  const { data: raw, error } = await supabase.rpc("get_route_names")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: RouteName[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar los nombres de rutas")
  return result.data ?? []
}

export async function createRoute(input: RouteForm): Promise<Route> {
  const { data: raw, error } = await supabase.rpc("manage_route", {
    p_action: "create",
    p_id: null,
    p_code: input.code,
    p_description: input.description,
    p_idbank_info: input.idbank_info ?? null,
    p_status: input.status,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Route>
  if (!result.success) throw new Error(result.message ?? "Error al crear la ruta")
  return result.data as Route
}

export async function updateRoute(id: number, input: Partial<RouteForm>): Promise<Route> {
  const { data: raw, error } = await supabase.rpc("manage_route", {
    p_action: "update",
    p_id: id,
    p_code: input.code ?? null,
    p_description: input.description ?? null,
    p_idbank_info: input.idbank_info ?? null,
    p_status: input.status ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Route>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar la ruta")
  return result.data as Route
}

export async function deleteRoute(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_route", {
    p_action: "delete",
    p_id: id,
    p_code: null,
    p_description: null,
    p_idbank_info: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar la ruta")
}
