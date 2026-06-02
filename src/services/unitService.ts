import { supabase } from "./supabaseClient"

export interface Unit {
  id: number
  name: string
  number: string
  plate: string
  status: number
  driver: string
}

export type UnitForm = Omit<Unit, "id">

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getUnits(): Promise<Unit[]> {
  const { data, error } = await supabase.from("units").select("*").order("id", { ascending: true })
  if (error) throw error
  return data ?? []
}

export async function createUnit(unit: UnitForm): Promise<Unit> {
  const { data: raw, error } = await supabase.rpc("manage_unit", {
    p_action: "create",
    p_unit_id: null,
    p_name: unit.name,
    p_number: unit.number,
    p_plate: unit.plate,
    p_status: unit.status,
    p_driver: unit.driver,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Unit>
  if (!result.success) throw new Error(result.message ?? "Error al crear la unidad")
  return result.data as Unit
}

export async function updateUnit(id: number, unit: Partial<UnitForm>): Promise<Unit> {
  const { data: raw, error } = await supabase.rpc("manage_unit", {
    p_action: "update",
    p_unit_id: id,
    p_name: unit.name ?? null,
    p_number: unit.number ?? null,
    p_plate: unit.plate ?? null,
    p_status: unit.status ?? null,
    p_driver: unit.driver ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Unit>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar la unidad")
  return result.data as Unit
}

export async function deleteUnit(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_unit", {
    p_action: "delete",
    p_unit_id: id,
    p_name: null,
    p_number: null,
    p_plate: null,
    p_status: null,
    p_driver: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar la unidad")
}
